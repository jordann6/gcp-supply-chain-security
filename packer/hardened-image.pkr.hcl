# Card 02: the golden image.
#
# Packer boots a stock Canonical image in the build project, hardens it, and
# publishes the result into an image family. Consumers reference the family, not
# a version, so a rebake rolls every future instance forward without editing an
# instance template anywhere.
#
# This runs in the build project on purpose. The runtime project carries the
# trustedImageProjects constraint that forbids stock images, so a bake attempted
# there would be blocked by the policy it exists to satisfy.
#
#   packer init .
#   packer build -var project_id=$BUILD_PROJECT hardened-image.pkr.hcl

packer {
  required_plugins {
    googlecompute = {
      source  = "github.com/hashicorp/googlecompute"
      version = "~> 1.1"
    }
  }
}

variable "project_id" {
  type        = string
  description = "Build project the image is baked and published in."
}

variable "zone" {
  type        = string
  default     = "us-central1-a"
}

variable "image_family" {
  type        = string
  default     = "hardened-ubuntu-2204"
}

variable "source_image_family" {
  type        = string
  default     = "ubuntu-2204-lts"
  description = "Stock family to harden from. Pinned to LTS so a bake is reproducible within a release."
}

variable "machine_type" {
  type        = string
  default     = "e2-small"
  description = "Bake instance. Deleted when the build finishes; it exists for about five minutes."
}

locals {
  timestamp = formatdate("YYYYMMDD-hhmmss", timestamp())
}

variable "network" {
  type        = string
  default     = "bake"
  description = "VPC in the build project. There is no default network, by design."
}

variable "subnetwork" {
  type        = string
  default     = "bake-us-central1"
  description = "Subnet in the bake VPC."
}

source "googlecompute" "hardened" {
  project_id          = var.project_id
  zone                = var.zone
  source_image_family = var.source_image_family
  ssh_username        = "packer"

  network    = var.network
  subnetwork = var.subnetwork

  # The one firewall rule that permits SSH targets this tag. Without it the bake
  # instance boots and Packer times out waiting for a connection that the
  # implied deny is dropping.
  tags = ["packer-bake"]

  image_name        = "${var.image_family}-${local.timestamp}"
  image_family      = var.image_family
  image_description = "CIS-informed Ubuntu 22.04, baked by Packer"

  image_labels = {
    managed-by  = "packer"
    project     = "gcp-supply-chain-security"
    source-fmly = var.source_image_family
  }

  machine_type = var.machine_type
  disk_size    = 20
  disk_type    = "pd-balanced"

  # The bake instance gets a public address and no service account. Packer needs
  # outbound access to apt, and the alternative (Private Google Access plus a
  # Cloud NAT) is real infrastructure that has to exist before the first bake and
  # bills by the hour whether or not anything is being baked. A five minute
  # instance with no identity attached is the cheaper trade here.
  omit_external_ip = false
  use_internal_ip  = false

  # Shielded VM. Secure Boot rejects unsigned kernel modules, vTPM anchors
  # measured boot, and integrity monitoring makes tampering visible after the
  # fact rather than never. All three cost nothing.
  enable_secure_boot          = true
  enable_vtpm                 = true
  enable_integrity_monitoring = true

  metadata = {
    block-project-ssh-keys = "TRUE"
  }
}

build {
  name    = "hardened-ubuntu"
  sources = ["source.googlecompute.hardened"]

  provisioner "shell" {
    script          = "scripts/harden.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }

  # Proves the hardening took before the image is published. A bake that says it
  # hardened and did not is worse than no golden image at all, because the
  # constraint downstream will happily pin every instance to it.
  provisioner "shell" {
    script          = "scripts/verify.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
