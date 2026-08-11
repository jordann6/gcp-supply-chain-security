# Artifact Registry, in the build project only.
#
# One repository, and the runtime project gets read access to it rather than a
# copy of it. Promotion by re-push is how the digest changes between
# environments, and once the digest changes the attestation no longer applies to
# what is running. Promote by reference, never by copy.

resource "google_artifact_registry_repository" "apps" {
  # checkov:skip=CKV_GCP_84: no CMEK on the repository. It would mean a second
  # KMS key, in the same region, that has to exist before the first push and be
  # kept alive as long as any image is referenced. The threat here is an
  # unreviewed image being deployed, which a CMEK does nothing about: the
  # signature, not the encryption, is what makes an image trustworthy. Google
  # encrypts the contents at rest either way.
  project       = google_project.build.project_id
  location      = var.region
  repository_id = var.repository_id
  description   = "Container images gated by Binary Authorization"
  format        = "DOCKER"
  labels        = var.labels

  docker_config {
    # Tags stay mutable so the demo can push :vulnerable and :clean to the same
    # repo. In a real repo this is true, because a mutable tag lets an attested
    # digest be replaced by an unattested one under the same name. Binary
    # Authorization resolves tags to digests before evaluating, so the deploy
    # would still be blocked, which is precisely the argument for digest pinning
    # being a defence in depth rather than the control itself.
    immutable_tags = false
  }

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      older_than = "2592000s"
    }
  }

  depends_on = [google_project_service.build]
}

# The Cloud Run service agent in the runtime project is the identity that pulls
# the image. Granting the revision's own service account instead is the usual
# mistake, and it produces a pull failure that reads like a missing image.
resource "google_artifact_registry_repository_iam_member" "runtime_pull" {
  project    = google_artifact_registry_repository.apps.project
  location   = google_artifact_registry_repository.apps.location
  repository = google_artifact_registry_repository.apps.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${local.runtime_agents.run}"

  depends_on = [time_sleep.runtime_agents]
}
