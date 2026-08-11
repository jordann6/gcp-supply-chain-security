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

# The key version resource name is
# projects/P/locations/L/keyRings/R/cryptoKeys/K/cryptoKeyVersions/V
# and gcloud wants each part as its own flag.
IFS='/' read -ra P <<<"${KEY_VERSION}"
KEY_PROJECT="${P[1]}"
KEY_LOCATION="${P[3]}"
KEY_RING="${P[5]}"
KEY_NAME="${P[7]}"
KEY_VERSION_NUM="${P[9]}"

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
