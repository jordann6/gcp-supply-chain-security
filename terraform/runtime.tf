# The runtime side.
#
# Terraform deliberately does not create the Cloud Run service. Terraform owns
# the platform and the policy; the pipeline owns the deployment. Two reasons,
# and the second is the important one.
#
# The mechanical reason: a Cloud Run service needs an image that exists, and on
# a first apply no image has been built yet.
#
# The real reason: if Terraform created the service, the demo would prove that
# Terraform can be blocked by Binary Authorization, which nobody deploys with.
# The deployment that has to be blocked is the one a pipeline makes at three in
# the morning, so that is the one the demo makes.

resource "google_service_account" "runtime" {
  project      = google_project.runtime.project_id
  account_id   = "attested-app"
  display_name = "Identity the Cloud Run revision runs as"

  depends_on = [google_project_service.runtime]
}

# Nothing is granted to this account. The demo app talks to no Google API, and
# an identity with no permissions is the correct starting point for one that
# does: add the grant when the call is added, not in advance.

# Minimal network for the golden image demo. The projects are created with
# auto_create_network false, so there is no default VPC and no default firewall
# rules to argue with.
resource "google_compute_network" "runtime" {
  project                 = google_project.runtime.project_id
  name                    = "runtime"
  auto_create_subnetworks = false

  depends_on = [google_project_service.runtime]
}

resource "google_compute_subnetwork" "runtime" {
  project                  = google_project.runtime.project_id
  name                     = "runtime-${var.region}"
  region                   = var.region
  network                  = google_compute_network.runtime.id
  ip_cidr_range            = "10.20.0.0/24"
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Explicit default deny, logged.
#
# A VPC with no rules already denies ingress by implied rule, so this changes
# nothing about what is allowed. It changes what is visible: the implied rule is
# not logged and does not appear in the console, so a network with no rules and
# a network whose rules were deleted look identical. This one is written down,
# and it produces a log line when something is turned away.
#
# Nothing is opened. The golden image demo proves that an instance can or cannot
# be created from a given image, and it never needs to be reachable.
resource "google_compute_firewall" "deny_all_ingress" {
  project       = google_project.runtime.project_id
  name          = "deny-all-ingress"
  network       = google_compute_network.runtime.name
  direction     = "INGRESS"
  priority      = 65534
  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
