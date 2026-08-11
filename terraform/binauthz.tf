# The enforcement point.
#
# This is the only resource in the repo that says no. Everything else exists so
# that this one has something trustworthy to check.

locals {
  required_attestors = concat(
    [google_binary_authorization_attestor.scan_gate.id],
    var.require_cloud_build_attestation
    ? ["projects/${google_project.build.project_id}/attestors/built-by-cloud-build"]
    : [],
  )
}

resource "google_binary_authorization_policy" "runtime" {
  project = google_project.runtime.project_id

  # Google's own system images (the Cloud Run and GKE control plane containers)
  # are signed by Google and evaluated against Google's policy. Setting this to
  # DISABLE means the platform's own components have to satisfy your attestor,
  # which they cannot, and nothing starts.
  global_policy_evaluation_mode = "ENABLE"

  default_admission_rule {
    evaluation_mode         = "REQUIRE_ATTESTATION"
    enforcement_mode        = var.enforcement_mode
    require_attestations_by = local.required_attestors
  }

  depends_on = [
    google_binary_authorization_attestor_iam_member.runtime_verify,
    google_container_analysis_note_iam_member.runtime_viewer,
  ]
}
