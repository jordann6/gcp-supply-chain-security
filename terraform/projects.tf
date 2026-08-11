# Two projects, split on the boundary the control actually runs across.
#
# The build project owns everything that produces evidence: the registry, the
# scanner, the signing key, the attestor. The runtime project owns the thing
# that consumes it: the Binary Authorization policy and Cloud Run.
#
# The split is the point. If the signing key lives in the same project as the
# deployment policy, anyone who can change the policy can also mint the
# signature that satisfies it, and the control degrades into a label. Splitting
# them means bypassing the gate requires compromising two projects with
# different administrators.

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  build_project_id   = "${var.name_prefix}-build-${random_id.suffix.hex}"
  runtime_project_id = "${var.name_prefix}-run-${random_id.suffix.hex}"

  build_apis = [
    "artifactregistry.googleapis.com",
    "binaryauthorization.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudkms.googleapis.com",
    "compute.googleapis.com",
    "containeranalysis.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "ondemandscanning.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
  ]

  runtime_apis = [
    "artifactregistry.googleapis.com",
    "binaryauthorization.googleapis.com",
    "compute.googleapis.com",
    "containeranalysis.googleapis.com",
    "logging.googleapis.com",
    "run.googleapis.com",
    "serviceusage.googleapis.com",
  ]
}

resource "google_project" "build" {
  name            = local.build_project_id
  project_id      = local.build_project_id
  org_id          = var.folder_id == "" ? var.org_id : null
  folder_id       = var.folder_id == "" ? null : var.folder_id
  billing_account = var.billing_account
  labels          = merge(var.labels, { layer = "build" })

  deletion_policy     = "DELETE"
  auto_create_network = false
}

resource "google_project" "runtime" {
  name            = local.runtime_project_id
  project_id      = local.runtime_project_id
  org_id          = var.folder_id == "" ? var.org_id : null
  folder_id       = var.folder_id == "" ? null : var.folder_id
  billing_account = var.billing_account
  labels          = merge(var.labels, { layer = "runtime" })

  deletion_policy     = "DELETE"
  auto_create_network = false
}

resource "google_project_service" "build" {
  for_each = toset(local.build_apis)

  project = google_project.build.project_id
  service = each.value

  # Left enabled on destroy on purpose. Disabling an API tears down its service
  # agent, and a half-deleted agent blocks the destroy of anything that agent
  # still holds a lease on. The project deletion removes all of it anyway.
  disable_on_destroy = false
}

resource "google_project_service" "runtime" {
  for_each = toset(local.runtime_apis)

  project            = google_project.runtime.project_id
  service            = each.value
  disable_on_destroy = false
}

# Data access logging is off by default on every GCP project. Without this, the
# audit trail records that the Binary Authorization policy was changed but not
# that the signing key was used, which is the half that matters here.
resource "google_project_iam_audit_config" "build" {
  project = google_project.build.project_id
  service = "allServices"

  dynamic "audit_log_config" {
    for_each = ["ADMIN_READ", "DATA_READ", "DATA_WRITE"]
    content {
      log_type = audit_log_config.value
    }
  }
}

resource "google_project_iam_audit_config" "runtime" {
  project = google_project.runtime.project_id
  service = "allServices"

  dynamic "audit_log_config" {
    for_each = ["ADMIN_READ", "DATA_READ", "DATA_WRITE"]
    content {
      log_type = audit_log_config.value
    }
  }
}

# Service agents.
#
# These are Google-managed accounts created when an API is enabled, and they are
# addressed by project number rather than project ID. There is no Terraform
# resource that creates them: google_project_service_identity covers a short
# allowlist of services that does not include compute or binaryauthorization, so
# the emails are constructed. The format is stable and documented.
locals {
  runtime_agents = {
    # Verifies attestations at admission. Needs read access to the attestor in
    # the build project.
    binauthz = "service-${google_project.runtime.number}@gcp-sa-binaryauthorization.iam.gserviceaccount.com"

    # Pulls the container image. Not the same identity as the service account
    # the revision runs as, which is the usual source of confusion when a pull
    # fails and the error says the image does not exist.
    run = "service-${google_project.runtime.number}@serverless-robot-prod.iam.gserviceaccount.com"

    # Reads the source image when an instance is created from another project's
    # image family.
    compute = "service-${google_project.runtime.number}@compute-system.iam.gserviceaccount.com"
  }
}

# Service agent creation is asynchronous. The enable call returns before the
# accounts exist, and an IAM binding naming an account that does not exist yet
# fails with a generic "does not exist" that looks like a typo in the email.
# This is the standard workaround and it is a wait, not a fix.
resource "time_sleep" "runtime_agents" {
  create_duration = "60s"

  depends_on = [google_project_service.runtime]
}
