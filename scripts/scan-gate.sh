#!/usr/bin/env bash
#
# The gate. Scans an image and exits non-zero if it carries a blocking severity.
#
# On-demand scanning rather than the automatic Artifact Registry scan, and the
# reason is timing. Automatic scanning is asynchronous: the push returns, the
# occurrence appears some seconds or minutes later, and a pipeline that wants to
# gate on it has to poll and guess how long "not found yet" means "clean". On
# demand scanning is synchronous, so a clean result is a result rather than the
# absence of one.
#
#   scan-gate.sh <image-uri> [blocking-severities] [scan-location]

set -euo pipefail

IMAGE="${1:?usage: scan-gate.sh <image-uri> [severities] [location]}"
SEVERITIES="${2:-CRITICAL}"
LOCATION="${3:-us}"

echo "==> Scanning ${IMAGE}"

# --remote scans the image in the registry rather than pulling it locally, so
# this step needs no Docker daemon and no disk.
SCAN=$(gcloud artifacts docker images scan "${IMAGE}" \
  --remote \
  --location="${LOCATION}" \
  --format='value(response.scan)')

if [ -z "${SCAN}" ]; then
  echo "==> Scan returned no result name, refusing to treat that as clean"
  exit 1
fi

echo "==> Scan ${SCAN}"

FOUND=$(gcloud artifacts docker images list-vulnerabilities "${SCAN}" \
  --format='value(vulnerability.effectiveSeverity)')

# Summary first, so a failed build shows what it found without needing the raw
# list read back out of the log.
echo "==> Findings by severity"
if [ -z "${FOUND}" ]; then
  echo "    none"
else
  echo "${FOUND}" | sort | uniq -c | sort -rn | sed 's/^/    /'
fi

blocking=0
IFS=',' read -ra WANTED <<<"${SEVERITIES}"
for sev in "${WANTED[@]}"; do
  count=$(echo "${FOUND}" | grep -cx "${sev}" || true)
  if [ "${count}" -gt 0 ]; then
    echo "==> ${count} ${sev} finding(s)"
    blocking=$((blocking + count))
  fi
done

if [ "${blocking}" -gt 0 ]; then
  echo "==> BLOCKED: ${blocking} finding(s) at or above the configured severity"
  echo "==> No attestation will be created, so this digest cannot be deployed"
  exit 1
fi

echo "==> PASSED: no findings at ${SEVERITIES}"
