#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/workspace-path.sh"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/clone-profiles.sh"

PROFILE="${1:-${PROFILE:-${SETUP_PROFILE:-registry}}}"
PROFILE="$(clone_profile_normalize "$PROFILE")"

OPENG2P_WORKSPACE="$(workspace_open)"
mkdir -p "$OPENG2P_WORKSPACE"

ODOO_REF="${ODOO_REF:-17.0}"
PBMS_REF="${PBMS_REF:-develop}"
REGISTRY_REF="${REGISTRY_REF:-1.2}"
IAM_REF="${IAM_REF:-1.4}"
MASTER_DATA_REF="${MASTER_DATA_REF:-1.1}"
FARMER_REGISTRY_REF="${FARMER_REGISTRY_REF:-1.2}"
NSR_REF="${NSR_REF:-1.1}"
G2P_BRIDGE_REF="${G2P_BRIDGE_REF:-develop}"
SPAR_REF="${SPAR_REF:-develop}"
AWE_REF="${AWE_REF:-1.2}"

clone_repo() {
  local name="$1"
  local url="$2"
  local ref="$3"
  local path="$4"
  local depth="${5:-}"

  local target="${OPENG2P_WORKSPACE}/${path}"
  if [[ -d "${target}/.git" ]]; then
    echo "==> Updating ${name} (${target})"
    if [[ -n "$depth" ]]; then
      git -C "$target" fetch --depth "$depth" origin "$ref" 2>/dev/null \
        || git -C "$target" fetch --tags --prune origin
    else
      git -C "$target" fetch --tags --prune origin
    fi
    git -C "$target" checkout "$ref" 2>/dev/null || git -C "$target" checkout -B "$ref" "origin/${ref}"
    git -C "$target" pull --ff-only origin "$ref" 2>/dev/null || true
  else
    echo "==> Cloning ${name} -> ${target}"
    mkdir -p "$(dirname "$target")"
    if [[ -n "$depth" ]]; then
      if git clone --depth "$depth" --single-branch --branch "$ref" "$url" "$target"; then
        return 0
      fi
      echo "    Shallow clone failed; retrying full single-branch clone ..." >&2
    fi
    git clone --branch "$ref" --single-branch "$url" "$target" 2>/dev/null || {
      git clone "$url" "$target"
      git -C "$target" checkout "$ref"
    }
  fi
}

clone_repo_key() {
  local key="$1"
  case "$key" in
    odoo)
      clone_repo "Odoo 17" "https://github.com/odoo/odoo.git" "$ODOO_REF" "odoo17" "1"
      ;;
    pbms)
      clone_repo "OpenG2P PBMS" "https://github.com/OpenG2P/pbms.git" "$PBMS_REF" "pbms"
      ;;
    odoo_commons)
      clone_repo "OpenG2P Odoo Commons" "https://github.com/OpenG2P/openg2p-odoo-commons.git" "$PBMS_REF" "openg2p-odoo-commons"
      ;;
    registry_platform)
      clone_repo "Registry Platform" "https://github.com/OpenG2P/registry-platform.git" "$REGISTRY_REF" "registry-platform"
      ;;
    iam_service)
      clone_repo "IAM Service" "https://github.com/OpenG2P/iam.git" "$IAM_REF" "iam-service"
      ;;
    master_data_service)
      clone_repo "Master Data Service" "https://github.com/OpenG2P/master-data-service.git" "$MASTER_DATA_REF" "master-data-service"
      ;;
    openg2p_data)
      clone_repo "OpenG2P Sample Data" "https://github.com/OpenG2P/openg2p-data.git" "develop" "openg2p-data"
      ;;
    farmer_registry)
      clone_repo "Farmer Registry" "https://github.com/OpenG2P/farmer-registry.git" "$FARMER_REGISTRY_REF" "farmer-registry"
      ;;
    national_social_registry)
      clone_repo "National Social Registry" "https://github.com/OpenG2P/national-social-registry.git" "$NSR_REF" "national-social-registry"
      ;;
    g2p_bridge)
      clone_repo "G2P Bridge" "https://github.com/OpenG2P/g2p-bridge.git" "$G2P_BRIDGE_REF" "g2p-bridge"
      ;;
    spar)
      clone_repo "SPAR" "https://github.com/OpenG2P/spar.git" "$SPAR_REF" "spar"
      ;;
    awe)
      clone_repo "Approval Workflow Engine (AWE)" "https://github.com/OpenG2P/awe.git" "$AWE_REF" "awe"
      ;;
    *)
      echo "Unknown repository key: ${key}" >&2
      return 1
      ;;
  esac
}

REPO_KEYS="$(clone_profile_repo_keys "$PROFILE" || exit 1)"

echo "============================================="
echo " Clone profile: ${PROFILE}"
echo " Workspace    : ${OPENG2P_WORKSPACE}"
echo "============================================="

if [[ -z "$REPO_KEYS" ]]; then
  echo "No product repositories required for profile '${PROFILE}'."
else
  for key in $REPO_KEYS; do
    clone_repo_key "$key"
  done
fi

echo
echo "Repositories for profile '${PROFILE}' are under: ${OPENG2P_WORKSPACE}"
echo "Other profiles: make clone-profiles"
echo "Next: make generate && make infra-up"
