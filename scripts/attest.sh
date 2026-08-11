#!/usr/bin/env bash
#
# Signs a digest with the KMS key behind the attestor.
#
# Only ever called after scan-gate.sh exits zero. That ordering is the entire
# control: the signature means "this exact digest passed the scan", and it means
# that only because nothing else in the pipeline can reach the key.
#
#   attest.sh <image-uri-with-digest> <attestor> <attestor-project> <kms-key-version>

set -euo pipefail

IMAGE="${1:?usage: attest.sh <image@digest> <attestor> <attestor-project> <kms-key-version>}"
ATTESTOR="${2:?missing attestor}"
ATTESTOR_PROJECT="${3:?missing attestor project}"
KEY_VERSION="${4:?missing kms key version resource name}"

case "${IMAGE}" in
*@sha256:*) ;;
*)
  # A tag can be moved to point at a different digest after the signature is
  # made. Signing a tag would produce an attestation that says nothing about
  # what actually runs.
  echo "==> Refusing to attest a tag. Pass image@sha256:... instead of ${IMAGE}"
  exit 1
  ;;
esac

# gcloud wants each part of the key version as its own flag.
#
# Parsed by label rather than by position, because the same key version is
# spelled two different ways depending on where it came from. Terraform's
# google_kms_crypto_key_version id is a full service name and carries a
# //cloudkms.googleapis.com/v1/ prefix; the gcloud and REST forms start at
# projects/. Counting slashes works with one and silently takes the wrong field
# from the other.
field() {
  echo "$1" | tr '/' '\n' | awk -v k="$2" 'found { print; exit } $0 == k { found = 1 }'
}

KEY_PROJECT="$(field "${KEY_VERSION}" projects)"
KEY_LOCATION="$(field "${KEY_VERSION}" locations)"
KEY_RING="$(field "${KEY_VERSION}" keyRings)"
KEY_NAME="$(field "${KEY_VERSION}" cryptoKeys)"
KEY_VERSION_NUM="$(field "${KEY_VERSION}" cryptoKeyVersions)"

for pair in "project:${KEY_PROJECT}" "location:${KEY_LOCATION}" "keyring:${KEY_RING}" \
  "key:${KEY_NAME}" "version:${KEY_VERSION_NUM}"; do
  if [ -z "${pair#*:}" ]; then
    echo "==> Could not read the ${pair%%:*} out of ${KEY_VERSION}"
    exit 1
  fi
done

echo "==> Attesting ${IMAGE}"
echo "    attestor  ${ATTESTOR} in ${ATTESTOR_PROJECT}"
echo "    key       ${KEY_NAME} version ${KEY_VERSION_NUM}"

# sign-and-create is idempotent in the way that matters: a second run against a
# digest that already carries this attestor's signature reports the occurrence
# already exists rather than creating a duplicate. Rebuilding the same commit
# therefore does not accumulate signatures.
if gcloud beta container binauthz attestations sign-and-create \
  --project="${ATTESTOR_PROJECT}" \
  --artifact-url="${IMAGE}" \
  --attestor="${ATTESTOR}" \
  --attestor-project="${ATTESTOR_PROJECT}" \
  --keyversion-project="${KEY_PROJECT}" \
  --keyversion-location="${KEY_LOCATION}" \
  --keyversion-keyring="${KEY_RING}" \
  --keyversion-key="${KEY_NAME}" \
  --keyversion="${KEY_VERSION_NUM}" 2>&1 | tee /tmp/attest.log; then
  echo "==> Signed"
elif grep -qi "already exists" /tmp/attest.log; then
  echo "==> Attestation already present for this digest, nothing to do"
else
  echo "==> Signing failed"
  exit 1
fi

# Wait until the attestation is actually readable before letting the build move
# on to the deploy.
#
# sign-and-create returns as soon as the occurrence is written, but Binary
# Authorization reads it through Container Analysis, and that read is eventually
# consistent. A deploy issued immediately after a successful sign can be refused
# with "no attestations found", which is the most misleading possible error: the
# attestation exists, the key is trusted, and the policy is correct.
#
# This polls for the digest rather than sleeping a fixed interval, so it costs
# nothing when the occurrence is already visible and still covers a slow read.
echo "==> Waiting for the attestation to become visible"
deadline=$((SECONDS + 120))
while [ "${SECONDS}" -lt "${deadline}" ]; do
  if gcloud container binauthz attestations list \
    --project="${ATTESTOR_PROJECT}" \
    --attestor="${ATTESTOR}" \
    --attestor-project="${ATTESTOR_PROJECT}" \
    --format='value(resourceUri)' 2>/dev/null | grep -qF "${IMAGE##*@}"; then
    echo "==> Visible after $((SECONDS - deadline + 120))s"
    exit 0
  fi
  sleep 5
done

echo "==> Attestation was signed but is still not readable after 120s"
echo "==> Failing here rather than letting the deploy fail with a misleading error"
exit 1
