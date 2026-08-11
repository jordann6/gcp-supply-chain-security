# The build identity.
#
# A dedicated service account rather than the legacy Cloud Build default. The
# default account carries roles/editor on its own project, which would let a
# compromised build step rewrite the very policy that is supposed to constrain
# it. Google is retiring that default for new projects, and this build assumes
# it is already gone.

resource "google_service_account" "builder" {
  project      = google_project.build.project_id
  account_id   = "cloudbuild-runner"
  display_name = "Cloud Build runner for the attested pipeline"

  depends_on = [google_project_service.build]
}

# Push the image it just built. Writer, not admin: the builder may add versions,
# never delete them, so evidence of what shipped cannot be erased by the thing
# that shipped it.
resource "google_artifact_registry_repository_iam_member" "builder_push" {
  project    = google_artifact_registry_repository.apps.project
  location   = google_artifact_registry_repository.apps.location
  repository = google_artifact_registry_repository.apps.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.builder.email}"
}

locals {
  builder_build_roles = [
    # Required for any build running as a user-managed service account. Without
    # it the build fails before the first step with an error about the logs
    # bucket, which reads like a storage problem and is a permissions problem.
    "roles/logging.logWriter",

    # Runs the synchronous vulnerability scan and reads its results back.
    "roles/ondemandscanning.admin",

    # Writes the attestation occurrence once the scan comes back clean.
    "roles/containeranalysis.occurrences.editor",

    # Reads the uploaded source archive out of the Cloud Build staging bucket.
    "roles/storage.objectViewer",
  ]
}

resource "google_project_iam_member" "builder" {
  for_each = toset(local.builder_build_roles)

  project = google_project.build.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.builder.email}"
}

# Cross-project deploy rights. run.developer rather than run.admin, so the
# builder can create and update services but cannot change their IAM and make
# one public.
resource "google_project_iam_member" "builder_deploy" {
  project = google_project.runtime.project_id
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.builder.email}"
}

# Deploying a Cloud Run revision that runs as another service account is an
# impersonation, and GCP treats it as one. This grant is scoped to the single
# runtime account rather than to the project, so the builder cannot deploy a
# service running as anything else.
resource "google_service_account_iam_member" "builder_acts_as_runtime" {
  service_account_id = google_service_account.runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.builder.email}"
}
