# The enforcement point.
#
# This is the only resource in the repo that says no. Everything else exists so
# that this one has something trustworthy to check.

# Written as a plain conditional between two whole lists rather than as a
# concat with a conditionally empty tail.
#
# That is not a style preference. The concat form produced a tuple the provider
# serialised wrong: applies sent one element instead of two, alternating which
# one survived, and the false branch sent an empty list that the API rejected
# outright with "evaluation mode requires at least one require_attestations_by".
# The API accepts both attestors when the same policy is imported with gcloud,
# so the defect is on the write path in the provider, not in Binary
# Authorization. Both branches here are ordinary known lists.
locals {
  required_attestors = var.require_cloud_build_attestation ? [
    google_binary_authorization_attestor.scan_gate.id,
    "projects/${google_project.build.project_id}/attestors/built-by-cloud-build",
    ] : [
    google_binary_authorization_attestor.scan_gate.id,
  ]
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
