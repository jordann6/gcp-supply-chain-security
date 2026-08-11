variable "org_id" {
  description = "Numeric GCP organization ID."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{10,14}$", var.org_id))
    error_message = "org_id must be the numeric organization ID."
  }
}

variable "billing_account" {
  description = "Billing account ID in XXXXXX-XXXXXX-XXXXXX form."
  type        = string
}

variable "seed_project_id" {
  description = "Seed project from the bootstrap layer. Holds state and is the quota project for API calls."
  type        = string
}

variable "folder_id" {
  description = <<-EOT
    Optional folder to create the build and runtime projects under.

    Empty means create them at the organization root. If gcp-landing-zone is
    standing, pass its workloads folder so these projects inherit the org policy
    set there rather than getting a second, divergent copy of it.
  EOT
  type        = string
  default     = ""
}

variable "name_prefix" {
  description = "Prefix for generated project IDs."
  type        = string
  default     = "jn-scs"
}

variable "region" {
  description = "Region for Artifact Registry, KMS, Cloud Build, and Cloud Run."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zone used by the golden image demo VM."
  type        = string
  default     = "us-central1-a"
}

variable "repository_id" {
  description = "Artifact Registry repository name."
  type        = string
  default     = "apps"
}

variable "app_name" {
  description = "Container image and Cloud Run service name."
  type        = string
  default     = "attested-app"
}

variable "image_family" {
  description = <<-EOT
    GCE image family Packer publishes the hardened image into.

    Consumers boot from the family rather than a pinned image name, so a rebake
    rolls forward without touching any instance template.
  EOT
  type        = string
  default     = "hardened-ubuntu-2204"
}

variable "kms_signing_algorithm" {
  description = <<-EOT
    Asymmetric signing algorithm for the attestor key.

    RSA_SIGN_PKCS1_4096_SHA512 is what the binauthz PKIX verifier and the
    gcloud sign-and-create path agree on. Changing this rotates the key and
    invalidates every attestation already signed with the old version.
  EOT
  type        = string
  default     = "RSA_SIGN_PKCS1_4096_SHA512"
}

variable "kms_protection_level" {
  description = <<-EOT
    SOFTWARE or HSM.

    SOFTWARE is the default because the threat this build addresses is an
    unreviewed image reaching production, not key extraction from a datacenter.
    HSM is roughly twenty-five times the price for a key version and changes
    nothing about the control being demonstrated.
  EOT
  type        = string
  default     = "SOFTWARE"

  validation {
    condition     = contains(["SOFTWARE", "HSM"], var.kms_protection_level)
    error_message = "kms_protection_level must be SOFTWARE or HSM."
  }
}

variable "blocking_severities" {
  description = <<-EOT
    Vulnerability severities that fail the build and prevent signing.

    CRITICAL only by default. Set to include HIGH once the base image is pinned
    and patched, otherwise the gate fails on findings in distro packages the
    build does not control and gets switched off within a week.
  EOT
  type        = list(string)
  default     = ["CRITICAL"]
}

variable "enforcement_mode" {
  description = <<-EOT
    Binary Authorization enforcement.

    ENFORCED_BLOCK_AND_AUDIT_LOG refuses the deployment and writes the denial.
    DRYRUN_AUDIT_LOG_ONLY allows it and logs what would have been blocked, which
    is how you would roll this out to an existing fleet without an outage.
  EOT
  type        = string
  default     = "ENFORCED_BLOCK_AND_AUDIT_LOG"

  validation {
    condition     = contains(["ENFORCED_BLOCK_AND_AUDIT_LOG", "DRYRUN_AUDIT_LOG_ONLY"], var.enforcement_mode)
    error_message = "enforcement_mode must be ENFORCED_BLOCK_AND_AUDIT_LOG or DRYRUN_AUDIT_LOG_ONLY."
  }
}

variable "require_cloud_build_attestation" {
  description = <<-EOT
    Also require Google's built-by-cloud-build attestor.

    That attestor proves provenance: the image was produced by Cloud Build in
    this project, not pushed by a laptop. The repo's own attestor proves the
    scan passed. The two answer different questions, so requiring both is the
    honest end state.

    It defaults to false because built-by-cloud-build is created by Google on
    the first build that requests verified provenance, and Binary Authorization
    rejects a policy naming an attestor that does not exist yet. Run one build,
    then set this true and re-apply. That two-phase rollout is also how you would
    add an attestor to a policy already in front of live traffic.
  EOT
  type        = bool
  default     = false
}

variable "image_user_principals" {
  description = <<-EOT
    Principals granted compute.imageUser on the build project, in full IAM
    member form (user:me@example.com, group:..., serviceAccount:...).

    Only needed for someone running the golden image demo who does not already
    inherit the role from a folder or the organization.
  EOT
  type        = list(string)
  default     = []
}

variable "labels" {
  description = "Labels applied to every project and labelled resource."
  type        = map(string)
  default = {
    managed-by = "terraform"
    project    = "gcp-supply-chain-security"
  }
}
