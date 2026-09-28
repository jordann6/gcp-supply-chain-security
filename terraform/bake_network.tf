# Network for the Packer bake, in the build project.
#
# The build project is created with auto_create_network false like everything
# else here, so there is no default VPC for Packer to land in and no default
# firewall rules to inherit. That is the correct starting point, and it means
# the bake path has to be written down rather than assumed.

resource "google_compute_network" "bake" {
  project                 = google_project.build.project_id
  name                    = "bake"
  auto_create_subnetworks = false

  depends_on = [google_project_service.build]
}

resource "google_compute_subnetwork" "bake" {
  project                  = google_project.build.project_id
  name                     = "bake-${var.region}"
  region                   = var.region
  network                  = google_compute_network.bake.id
  ip_cidr_range            = "10.30.0.0/24"
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# SSH to the bake instance, and only to the bake instance, and only through
# Identity-Aware Proxy.
#
# Packer tunnels its SSH session through IAP (use_iap in the Packer source), so
# the only source that ever needs port 22 is Google's IAP forwarding range. The
# connection is authorized by IAM (iap.tunnelResourceAccessor, held by the
# project owner who runs the bake), not by where it comes from, so nothing
# about the rule breaks for the next operator. IAP TCP forwarding has no hourly
# charge; it is standing up Cloud NAT that would.
#
# The target tag still matters: a bake instance exists for about five minutes
# and carries this tag, and nothing else in the project ever does, so the rule
# has no target when a bake is not running.
resource "google_compute_firewall" "bake_ssh" {
  project       = google_project.build.project_id
  name          = "bake-ssh"
  network       = google_compute_network.bake.name
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = ["35.235.240.0/20"] # IAP TCP forwarding
  target_tags   = ["packer-bake"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "bake_deny_all" {
  project       = google_project.build.project_id
  name          = "bake-deny-all-ingress"
  network       = google_compute_network.bake.name
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
