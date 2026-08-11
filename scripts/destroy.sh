#!/usr/bin/env bash
#
# Teardown, in the order that actually works.
#
# terraform destroy on its own does not fully clean this build, and each gap is
# a property of GCP rather than a bug in the config:
#
#   1. Packer publishes GCE images outside Terraform state, so destroy has never
#      heard of them.
#   2. A KMS key cannot be deleted. Versions can only be scheduled for
#      destruction, with a 24 hour minimum, and destroy silently drops the key
#      from state while leaving it standing.
#   3. The Binary Authorization policy is a per-project singleton. Destroy
#      resets it to the permissive default rather than removing it, so a project
#      that survives teardown is left accepting anything.
#   4. Cloud Run services created by the pipeline are not in Terraform state
#      either, and a service holds a lease on the registry it pulls from.
#
# Deleting the projects resolves all four at once, which is why that is the last
# step and why the earlier steps exist for the case where the projects stay.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.demo.env"

rule() { printf '\n\033[1m%s\033[0m\n%s\n' "$1" "$(printf '=%.0s' {1..70})"; }
note() { printf '  %s\n' "$1"; }

if [ ! -f "${ENV_FILE}" ]; then
  echo "No ${ENV_FILE}. Run ./scripts/demo.sh env while the stack is still up." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${ENV_FILE}"

read -r -p "Destroy ${BUILD_PROJECT} and ${RUNTIME_PROJECT}? [yes/NO] " confirm
[ "${confirm}" = "yes" ] || { echo "Aborted."; exit 1; }

rule "1. Pipeline-created Cloud Run services"
gcloud run services list --project="${RUNTIME_PROJECT}" --region="${REGION}" \
  --format='value(metadata.name)' 2>/dev/null | while read -r svc; do
  [ -n "${svc}" ] || continue
  note "deleting service ${svc}"
  gcloud run services delete "${svc}" \
    --project="${RUNTIME_PROJECT}" --region="${REGION}" --quiet
done

rule "2. Demo instances"
gcloud compute instances list --project="${RUNTIME_PROJECT}" \
  --format='value(name,zone)' 2>/dev/null | while read -r name zone; do
  [ -n "${name}" ] || continue
  note "deleting instance ${name}"
  gcloud compute instances delete "${name}" \
    --project="${RUNTIME_PROJECT}" --zone="${zone}" --quiet
done

rule "3. Packer images (invisible to terraform destroy)"
gcloud compute images list --project="${BUILD_PROJECT}" \
  --filter="family=${IMAGE_FAMILY}" --format='value(name)' 2>/dev/null | while read -r img; do
  [ -n "${img}" ] || continue
  note "deleting image ${img}"
  gcloud compute images delete "${img}" --project="${BUILD_PROJECT}" --quiet
done

rule "4. Container images"
# Deleted before the repository so the destroy of the repository is not racing
# a Cloud Run revision that still references a digest inside it.
gcloud artifacts docker images list "${REPO}" \
  --include-tags --format='value(DIGEST)' 2>/dev/null | sort -u | while read -r digest; do
  [ -n "${digest}" ] || continue
  note "deleting ${APP_NAME}@${digest}"
  gcloud artifacts docker images delete "${REPO}/${APP_NAME}@${digest}" \
    --project="${BUILD_PROJECT}" --delete-tags --quiet 2>/dev/null || true
done

rule "5. Scheduling KMS key version destruction"
# Scheduling rather than deleting, because deleting is not on offer. The 24 hour
# minimum is the recovery window, and it is the reason this build costs a few
# cents after teardown rather than nothing.
# Parsed by label, not by position. The Terraform output carries a
# //cloudkms.googleapis.com/v1/ prefix that the gcloud form does not, so
# counting slashes takes the wrong field from one of the two.
field() {
  echo "$1" | tr '/' '\n' | awk -v k="$2" 'found { print; exit } $0 == k { found = 1 }'
}

KEY_LOCATION="$(field "${KMS_KEY_VERSION}" locations)"
KEY_RING="$(field "${KMS_KEY_VERSION}" keyRings)"
KEY_NAME="$(field "${KMS_KEY_VERSION}" cryptoKeys)"
gcloud kms keys versions list \
  --project="${BUILD_PROJECT}" \
  --location="${KEY_LOCATION}" \
  --keyring="${KEY_RING}" \
  --key="${KEY_NAME}" \
  --filter="state=ENABLED" \
  --format='value(name)' 2>/dev/null | while read -r ver; do
  [ -n "${ver}" ] || continue
  note "scheduling destruction of ${ver##*/}"
  gcloud kms keys versions destroy "${ver##*/}" \
    --project="${BUILD_PROJECT}" \
    --location="${KEY_LOCATION}" \
    --keyring="${KEY_RING}" \
    --key="${KEY_NAME}" --quiet
done

rule "6. terraform destroy"
terraform -chdir="${REPO_ROOT}/terraform" destroy -auto-approve

rule "7. Verifying"
for p in "${BUILD_PROJECT}" "${RUNTIME_PROJECT}"; do
  state=$(gcloud projects describe "${p}" --format='value(lifecycleState)' 2>/dev/null || echo "GONE")
  note "${p}: ${state}"
done
note "DELETE_REQUESTED is the expected state. GCP purges after 30 days, and the"
note "project counts against the billing account's project quota until it does."

rule "Left standing on purpose"
note "The seed project and state bucket, so the state history survives."
note "Destroy those with: terraform -chdir=bootstrap destroy, after setting"
note "force_destroy_state = true."
