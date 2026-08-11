# The attestor and the note behind it.
#
# A Container Analysis note is the thing occurrences hang off. One note per
# claim you want to make about an artifact, which is why this one is named for
# the claim rather than for the team: "vulnerability scan passed", not
# "platform-team-attestor". When a second claim gets added later, it gets its
# own note and its own key, and the policy can require both independently.

resource "google_container_analysis_note" "scan_passed" {
  project = google_project.build.project_id
  name    = "vulnerability-scan-passed"

  attestation_authority {
    hint {
      human_readable_name = "Vulnerability scan passed with no blocking findings"
    }
  }

  depends_on = [google_project_service.build]
}

resource "google_binary_authorization_attestor" "scan_gate" {
  project     = google_project.build.project_id
  name        = "vulnerability-scan-passed"
  description = "Signs a digest only after Artifact Analysis returns no blocking severities"

  attestation_authority_note {
    note_reference = google_container_analysis_note.scan_passed.name

    public_keys {
      id = data.google_kms_crypto_key_version.attestor.id

      pkix_public_key {
        public_key_pem      = data.google_kms_crypto_key_version.attestor.public_key[0].pem
        signature_algorithm = data.google_kms_crypto_key_version.attestor.public_key[0].algorithm
      }
    }
  }

  depends_on = [google_project_service.build]
}

# Attaching an occurrence to a note is a separate permission from writing to the
# project that owns the note. Without this the build fails at the signing step
# with a permission error on the note, not on the key, which sends you looking
# in the wrong place.
resource "google_container_analysis_note_iam_member" "builder_attacher" {
  project = google_container_analysis_note.scan_passed.project
  note    = google_container_analysis_note.scan_passed.name
  role    = "roles/containeranalysis.notes.attacher"
  member  = "serviceAccount:${google_service_account.builder.email}"
}

# Attaching an occurrence and reading one back are separate permissions, and the
# builder needs both. It signs, then polls until the attestation is readable
# before handing off to the deploy step. Without this grant the poll sees an
# empty list forever: the attestation exists, the call succeeds, and it returns
# nothing, so the failure looks like a propagation delay that never resolves.
resource "google_container_analysis_note_iam_member" "builder_reader" {
  project = google_container_analysis_note.scan_passed.project
  note    = google_container_analysis_note.scan_passed.name
  role    = "roles/containeranalysis.notes.occurrences.viewer"
  member  = "serviceAccount:${google_service_account.builder.email}"
}

# Lets the build service account create attestations against this attestor.
# Deliberately not attestorsAdmin: the builder may add evidence, never redefine
# what the attestor accepts as evidence.
resource "google_binary_authorization_attestor_iam_member" "builder_sign" {
  project  = google_binary_authorization_attestor.scan_gate.project
  attestor = google_binary_authorization_attestor.scan_gate.name
  role     = "roles/binaryauthorization.attestorsViewer"
  member   = "serviceAccount:${google_service_account.builder.email}"
}

# The cross-project half. The runtime project's Binary Authorization agent has
# to read this attestor to verify a signature against it. This one grant is the
# entire reason the two-project split works: read access to verify, with no path
# to sign.
resource "google_binary_authorization_attestor_iam_member" "runtime_verify" {
  project  = google_binary_authorization_attestor.scan_gate.project
  attestor = google_binary_authorization_attestor.scan_gate.name
  role     = "roles/binaryauthorization.attestorsVerifier"
  member   = "serviceAccount:${local.runtime_agents.binauthz}"

  depends_on = [time_sleep.runtime_agents]
}

# The verifier also has to read the note the occurrences are attached to.
# Granting only attestorsVerifier produces a denial that claims no attestation
# exists, when the attestation exists and cannot be read.
resource "google_container_analysis_note_iam_member" "runtime_viewer" {
  project = google_container_analysis_note.scan_passed.project
  note    = google_container_analysis_note.scan_passed.name
  role    = "roles/containeranalysis.notes.occurrences.viewer"
  member  = "serviceAccount:${local.runtime_agents.binauthz}"

  depends_on = [time_sleep.runtime_agents]
}

# Signing is the only thing the builder may do with the key. Not decrypt, not
# destroy versions, not read the key material.
resource "google_kms_crypto_key_iam_member" "builder_signer" {
  crypto_key_id = google_kms_crypto_key.attestor.id
  role          = "roles/cloudkms.signerVerifier"
  member        = "serviceAccount:${google_service_account.builder.email}"
}
