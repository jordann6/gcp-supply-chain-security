output "build_project_id" {
  description = "Project holding the registry, scanner, signing key, and attestor."
  value       = google_project.build.project_id
}

output "runtime_project_id" {
  description = "Project holding the Binary Authorization policy and Cloud Run."
  value       = google_project.runtime.project_id
}

output "repository" {
  description = "Artifact Registry repository host path for docker push."
  value       = "${var.region}-docker.pkg.dev/${google_project.build.project_id}/${google_artifact_registry_repository.apps.repository_id}"
}

output "attestor" {
  description = "Attestor the runtime policy requires."
  value       = google_binary_authorization_attestor.scan_gate.id
}

output "kms_key_version" {
  description = "Key version the build signs with."
  value       = data.google_kms_crypto_key_version.attestor.id
}

output "builder_service_account" {
  description = "Service account Cloud Build runs as."
  value       = google_service_account.builder.email
}

output "runtime_service_account" {
  description = "Service account the Cloud Run revision runs as."
  value       = google_service_account.runtime.email
}

output "image_family" {
  description = "Image family Packer publishes into and trustedImageProjects pins to."
  value       = var.image_family
}

# Everything the demo and the pipeline need, in one place, so neither has to
# hardcode a project ID that changes on every apply.
output "env" {
  description = "Source this into a shell: terraform output -raw env > ../.demo.env"
  value       = <<-EOT
    export BUILD_PROJECT="${google_project.build.project_id}"
    export RUNTIME_PROJECT="${google_project.runtime.project_id}"
    export REGION="${var.region}"
    export ZONE="${var.zone}"
    export REPO="${var.region}-docker.pkg.dev/${google_project.build.project_id}/${google_artifact_registry_repository.apps.repository_id}"
    export APP_NAME="${var.app_name}"
    export IMAGE_FAMILY="${var.image_family}"
    export ATTESTOR="${google_binary_authorization_attestor.scan_gate.name}"
    export ATTESTOR_PROJECT="${google_project.build.project_id}"
    export KMS_KEY_VERSION="${data.google_kms_crypto_key_version.attestor.id}"
    export BUILDER_SA="${google_service_account.builder.email}"
    export RUNTIME_SA="${google_service_account.runtime.email}"
    export BLOCKING_SEVERITIES="${join(",", var.blocking_severities)}"
  EOT
}
