#!/usr/bin/env bash
# One-time (re-runnable) onboarding of a component on the RUNNING local stack.
# Usually called through ./oan.sh onboard <component>.
#
#   onboard.sh aggregation-api
#
# aggregation-api: runs the upstream scripts/register-aggregator.py of oan-aggregation-api
# inside python:3.12-slim on the `openg2p` network (nothing is installed on the host). The script
#   - creates the Keycloak client `aggregation-layer` in the staff realm (CONSENT_MANAGER_ADMIN),
#   - generates the Ed25519 signing key (oan-workspace/oan-aggregation-api/deploy/keys/aggregation-layer.p12),
#   - registers partner PARTNER_AGGREGATION_LAYER in Partner Management,
#   - creates one Consent Manager binding per catalogue entry (approving its own AWE tasks),
#   - writes the client secret into deploy/.env.
# Afterwards the key (encrypted with the Secret's `password`) and the client secret are pinned
# in state/secrets.json, the stack is re-rendered and the service is recreated.
# The catalogue is the one rendered from extras/aggregation-api.yaml (out/files), so render the
# selection with the component first (./oan.sh select, then ./oan.sh up).
set -euo pipefail
export MSYS_NO_PATHCONV=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source scripts/env.sh
# shellcheck disable=SC1091
source scripts/components.sh
# shellcheck disable=SC1091
source scripts/ui.sh

host_path() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }
PY_IMAGE=python:3.12-slim
NETWORK=openg2p

onboard_aggregation_api() {
  local id=aggregation-api src catalog svc compose
  local files=()
  step "Onboard $id"

  command -v docker >/dev/null 2>&1 || { fail "docker is not available"; return 1; }
  docker network inspect "$NETWORK" >/dev/null 2>&1 \
    || { fail "network $NETWORK not found: start the stack first (./oan.sh up)"; return 1; }

  src=$(scripts/src.sh dir "$id")
  if [ ! -d "$src/.git" ]; then
    note "no checkout at $src, cloning"
    scripts/src.sh clone "$id"
  fi
  [ -f "$src/scripts/register-aggregator.py" ] \
    || { fail "$src/scripts/register-aggregator.py missing (checkout is not oan-aggregation-api develop?)"; return 1; }
  ok "source $src"

  catalog=out/files/commons-services-aggregation-api/catalog/registries.yaml
  [ -f "$catalog" ] \
    || { fail "$catalog not found: render a selection that includes $id first"; return 1; }
  compose=out/commons/compose.yaml
  svc=$(awk -F'\t' -v c=commons-services '$1=="commons" && $2==c && $3 ~ /aggregation-api--pod$/ {print $3; exit}' out/services.tsv)
  [ -n "$svc" ] || { fail "no aggregation-api service in out/services.tsv"; return 1; }
  ok "catalogue $catalog, service $svc"

  # In-network URLs (the gateway answers on every <service>.<ns>.svc.cluster.local alias).
  # Keycloak issues tokens for its public hostname whatever URL is used to reach it.
  # The staff login of the script is the seeded staff realm user admin (see out/files/*keycloak-init*).
  step "register-aggregator.py"
  docker run --rm --network "$NETWORK" \
    -v "$(host_path "$src")":/src -v "$(host_path "$ROOT")":/w -w /src \
    -e G2P_KEYCLOAK=http://commons-keycloak.commons.svc.cluster.local \
    -e G2P_CM=http://commons-services-cm-api.commons.svc.cluster.local \
    -e G2P_PM_ADMIN=http://commons-services-pm-staff-portal-api.commons.svc.cluster.local \
    -e G2P_PM_KEYS=http://commons-services-pm-partner-api.commons.svc.cluster.local \
    -e G2P_KC_ADMIN=admin \
    -e G2P_STAFF_USER="${OAN_STAFF_USER:-admin}" -e G2P_STAFF_PASSWORD="${OAN_STAFF_PASSWORD:-admin}" \
    "$PY_IMAGE" sh -c '
      set -e
      pip install -q --disable-pip-version-check httpx cryptography pydantic pyyaml
      export G2P_KC_ADMIN_PASSWORD="$(python /w/scripts/onboard-aggregation-api.py admin-password)"
      python /w/scripts/onboard-aggregation-api.py prep
      python scripts/register-aggregator.py --catalog /w/'"$catalog"'
      python /w/scripts/onboard-aggregation-api.py pin
    ' || { fail "onboarding failed (see the output above; the script is re-runnable)"; return 1; }
  ok "onboarded; key and client secret pinned in state/secrets.json"

  step "Re-render and recreate $svc"
  # the rendered selection (`up <ids>` may differ from the one saved in .env)
  local comps
  comps=$(grep -m1 '^COMPONENTS=' out/versions.rendered.env 2>/dev/null | cut -d= -f2- | tr -d '"')
  # shellcheck disable=SC2046,SC2086
  scripts/render.sh ${comps:-$(selected_components)}
  files=(-f "$compose")
  [ -f overrides/commons.yaml ] && files+=(-f overrides/commons.yaml)
  COMPOSE_PROFILES='*' docker compose "${files[@]}" up -d --force-recreate --no-deps "$svc"
  ok "$svc recreated"
  note "the Consent Manager caches policies for up to 60s before the first request works"
}

case "${1:-}" in
  aggregation-api) onboard_aggregation_api ;;
  "") fail "usage: onboard.sh <component>   (onboardable: aggregation-api)"; exit 2 ;;
  *) fail "nothing to onboard for '$1' (onboardable: aggregation-api)"; exit 2 ;;
esac
