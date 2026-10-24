#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/registry-variant.sh"

VARIANT="${1:-}"
registry_variant_validate "$VARIANT"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/.env"
fi

registry_variant_ensure_run_ready "$VARIANT"
bash "${ROOT_DIR}/scripts/free-variant-ports.sh" "$VARIANT"
bash "${ROOT_DIR}/scripts/start-registry-variant.sh" "$VARIANT"

echo
echo "${LABEL} native stack"
case "$VARIANT" in
  farmer-registry) SETUP_HINT="make farmer-setup" ;;
  national-social-registry) SETUP_HINT="make nsr-setup" ;;
  *) SETUP_HINT="make extension-setup NAME=${VARIANT}" ;;
esac
echo "One-time DB setup if not done yet: ${SETUP_HINT}"
echo
echo "${LABEL} URLs:"
echo "  Staff UI : http://localhost:$(source "${GENERATED_DIR}/staff-portal-ui.env" && echo "${PORT}")"
echo "  Staff API: http://localhost:$(source "${GENERATED_DIR}/staff-portal-api.env" && echo "${REGISTRY_STAFF_PORTAL_API_APP_PORT}")/docs"
echo "  Master Data: http://localhost:$(source "${GENERATED_DIR}/master-data-api.env" && echo "${MASTER_DATA_API_PORT}")/docs"
echo "  IAM API  : http://localhost:${IAM_STAFF_PORT:-8020}"
echo "  AWE API  : http://localhost:${AWE_API_PORT:-8030}/v1/awe/health"
echo "  AWE Admin: http://localhost:${AWE_UI_PORT:-8031}/"
echo

wait
