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

# SSH to the bake instance, and only to the bake instance.
#
# The target tag matters more than the source range here. A bake instance exists
# for about five minutes and carries this tag; nothing else in the project ever
# does, so the rule has no target when a bake is not running. Narrowing the
# source instead would mean either pinning the operator's public address, which
# breaks for the next person and for CI, or standing up Cloud NAT and IAP, which
# bills by the hour whether or not anything is being baked.
#
# The honest summary: this is a five minute exposure of a machine with no data
# on it, no service account attached, and password authentication off, traded
# against permanent infrastructure. In a build that bakes continuously rather
# than on demand, the NAT is the right answer instead.
resource "google_compute_firewall" "bake_ssh" {
  # checkov:skip=CKV_GCP_2: see above. Scoped by target tag to instances that
  # only exist during a bake, rather than left open to the whole network.
  project       = google_project.build.project_id
  name          = "bake-ssh"
  network       = google_compute_network.bake.name
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = ["0.0.0.0/0"]
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
