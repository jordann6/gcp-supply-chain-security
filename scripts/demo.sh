#!/usr/bin/env bash
#
# The demo. Four acts, each one runnable on its own.
#
#   ./scripts/demo.sh env        write .demo.env from terraform output
#   ./scripts/demo.sh blocked    push an unsigned image and watch the deploy fail
#   ./scripts/demo.sh allowed    run the real pipeline and watch it succeed
#   ./scripts/demo.sh images     prove trustedImageProjects on two VM creates
#   ./scripts/demo.sh all        all four in order
#   ./scripts/demo.sh clean      delete the demo service and any leftover VMs
#
# A blocked deployment is the expected outcome in two of these, so this script
# treats a non-zero gcloud exit as a pass where that is the point and says so.
# Nothing here silently swallows a failure it did not predict.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.demo.env"

rule() { printf '\n\033[1m%s\033[0m\n%s\n' "$1" "$(printf '=%.0s' {1..70})"; }
note() { printf '  %s\n' "$1"; }
pass() { printf '\033[32m  PASS  %s\033[0m\n' "$1"; }
fail() {
  printf '\033[31m  FAIL  %s\033[0m\n' "$1"
  exit 1
}

load_env() {
  if [ ! -f "${ENV_FILE}" ]; then
    fail "No ${ENV_FILE}. Run: ./scripts/demo.sh env"
  fi
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
}

cmd_env() {
  rule "Writing ${ENV_FILE} from terraform output"
  terraform -chdir="${REPO_ROOT}/terraform" output -raw env >"${ENV_FILE}"
  chmod 0600 "${ENV_FILE}"
  note "Holds project IDs and resource names, no credentials. Gitignored anyway."
  cat "${ENV_FILE}"
}

# Act one. An image that is real, in the right registry, built by the right
# Cloud Build, and unsigned.
cmd_blocked() {
  load_env

  rule "Act 1: pushing an unattested image"
  gcloud builds submit "${REPO_ROOT}" \
    --project="${BUILD_PROJECT}" \
    --region="${REGION}" \
    --config="${REPO_ROOT}/app/cloudbuild-unsigned.yaml" \
    --substitutions="_REPO=${REPO},_APP=${APP_NAME},_TAG=unattested,_BUILDER_SA=${BUILDER_SA}"

  local digest image
  digest=$(gcloud artifacts docker images describe \
    "${REPO}/${APP_NAME}:unattested" \
    --project="${BUILD_PROJECT}" \
    --format='value(image_summary.digest)')
  image="${REPO}/${APP_NAME}@${digest}"

  note "Image exists in the trusted registry: ${image}"
  note "It carries no attestation, so the policy should refuse it."

  rule "Act 1: attempting to deploy it"
  local out=0
  gcloud run deploy "${APP_NAME}-unattested" \
    --project="${RUNTIME_PROJECT}" \
    --region="${REGION}" \
    --image="${image}" \
    --service-account="${RUNTIME_SA}" \
    --binary-authorization=default \
    --no-allow-unauthenticated \
    --port=8080 \
    --quiet >/tmp/scs-blocked.log 2>&1 || out=$?

  if [ "${out}" -eq 0 ]; then
    note "The deployment succeeded, which means the gate is not enforcing."
    note "Check enforcement_mode: DRYRUN_AUDIT_LOG_ONLY allows and only logs."
    fail "Unattested image deployed"
  fi

  if grep -qi "denied by attestor\|Binary Authorization\|binauthz" /tmp/scs-blocked.log; then
    pass "Deployment refused by Binary Authorization"
    grep -i "denied by attestor\|Binary Authorization\|violates" /tmp/scs-blocked.log | sed 's/^/    /' | head -5
  else
    note "Deploy failed, but not visibly on Binary Authorization. Full output:"
    sed 's/^/    /' /tmp/scs-blocked.log
    fail "Failed for the wrong reason, which proves nothing"
  fi
}

# Act two. The same source, through the pipeline that scans and signs it.
cmd_allowed() {
  load_env

  rule "Act 2: the real pipeline, build to scan to sign to deploy"
  gcloud builds submit "${REPO_ROOT}" \
    --project="${BUILD_PROJECT}" \
    --region="${REGION}" \
    --config="${REPO_ROOT}/app/cloudbuild.yaml" \
    --substitutions="^|^_REPO=${REPO}|_APP=${APP_NAME}|_TAG=$(date +%Y%m%d-%H%M%S)|_SEVERITIES=${BLOCKING_SEVERITIES}|_ATTESTOR=${ATTESTOR}|_ATTESTOR_PROJECT=${ATTESTOR_PROJECT}|_KMS_KEY_VERSION=${KMS_KEY_VERSION}|_RUNTIME_PROJECT=${RUNTIME_PROJECT}|_RUNTIME_SA=${RUNTIME_SA}|_REGION=${REGION}|_BUILDER_SA=${BUILDER_SA}"

  local url
  url=$(gcloud run services describe "${APP_NAME}" \
    --project="${RUNTIME_PROJECT}" \
    --region="${REGION}" \
    --format='value(status.url)')

  pass "Attested image deployed to ${url}"

  rule "Act 2: calling it"
  # The service is not public, so this needs an identity token. That is the
  # landing zone's domain restricted sharing constraint doing its job, not an
  # oversight in the demo.
  curl -sS -H "Authorization: Bearer $(gcloud auth print-identity-token)" "${url}" |
    sed 's/^/    /'
  echo

  rule "Act 2: what the registry now knows about that digest"
  gcloud container binauthz attestations list \
    --project="${ATTESTOR_PROJECT}" \
    --attestor="${ATTESTOR}" \
    --attestor-project="${ATTESTOR_PROJECT}" \
    --format='table(resourceUri)' | sed 's/^/    /'
}

# Act three. The same idea one layer down, on VM images instead of containers.
cmd_images() {
  load_env

  rule "Act 3a: creating a VM from a stock public image"
  local out=0
  gcloud compute instances create scs-demo-stock \
    --project="${RUNTIME_PROJECT}" \
    --zone="${ZONE}" \
    --subnet="runtime-${REGION}" \
    --no-address \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --machine-type=e2-micro \
    --quiet >/tmp/scs-stock.log 2>&1 || out=$?

  if [ "${out}" -eq 0 ]; then
    gcloud compute instances delete scs-demo-stock \
      --project="${RUNTIME_PROJECT}" --zone="${ZONE}" --quiet >/dev/null 2>&1 || true
    fail "Stock image booted, so trustedImageProjects is not in effect"
  fi

  if grep -qi "trustedImageProjects\|constraint\|not allowed" /tmp/scs-stock.log; then
    pass "Stock image refused by compute.trustedImageProjects"
    grep -i "constraint\|trustedImage\|violat" /tmp/scs-stock.log | sed 's/^/    /' | head -5
  else
    sed 's/^/    /' /tmp/scs-stock.log
    fail "Create failed for the wrong reason"
  fi

  rule "Act 3b: creating a VM from the hardened family"
  gcloud compute instances create scs-demo-hardened \
    --project="${RUNTIME_PROJECT}" \
    --zone="${ZONE}" \
    --subnet="runtime-${REGION}" \
    --no-address \
    --image-family="${IMAGE_FAMILY}" \
    --image-project="${BUILD_PROJECT}" \
    --machine-type=e2-micro \
    --shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --quiet

  pass "Hardened image booted"
  note "Deleting it now. It is billed per second and proves nothing further."
  gcloud compute instances delete scs-demo-hardened \
    --project="${RUNTIME_PROJECT}" --zone="${ZONE}" --quiet
}

cmd_clean() {
  load_env
  rule "Removing demo leftovers"

  for svc in "${APP_NAME}" "${APP_NAME}-unattested"; do
    gcloud run services delete "${svc}" \
      --project="${RUNTIME_PROJECT}" --region="${REGION}" --quiet >/dev/null 2>&1 &&
      note "deleted service ${svc}" || true
  done

  for vm in scs-demo-stock scs-demo-hardened; do
    gcloud compute instances delete "${vm}" \
      --project="${RUNTIME_PROJECT}" --zone="${ZONE}" --quiet >/dev/null 2>&1 &&
      note "deleted instance ${vm}" || true
  done

  note "Done. Terraform destroy is a separate step, see scripts/destroy.sh."
}

case "${1:-all}" in
env) cmd_env ;;
blocked) cmd_blocked ;;
allowed) cmd_allowed ;;
images) cmd_images ;;
clean) cmd_clean ;;
all)
  cmd_env
  cmd_blocked
  cmd_allowed
  cmd_images
  rule "All four acts passed"
  ;;
*)
  echo "usage: $0 {env|blocked|allowed|images|clean|all}" >&2
  exit 2
  ;;
esac
