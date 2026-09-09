#!/usr/bin/env bash
# Idempotently create the OpenG2P local "staff" Keycloak realm, OIDC clients,
# roles, and a default developer user. Safe to re-run on every `make infra-up`.
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak:8080}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-staff}"
IAM_STAFF_PORT="${IAM_STAFF_PORT:-8020}"
FARMER_REGISTRY_UI_PORT="${FARMER_REGISTRY_UI_PORT:-3001}"
NSR_REGISTRY_UI_PORT="${NSR_REGISTRY_UI_PORT:-3002}"
STAFF_PORTAL_UI_PORT="${STAFF_PORTAL_UI_PORT:-3000}"
PBMS_HTTP_PORT="${PBMS_HTTP_PORT:-8069}"
G2P_BRIDGE_API_PORT="${G2P_BRIDGE_API_PORT:-8002}"
SPAR_MAPPER_API_PORT="${SPAR_MAPPER_API_PORT:-8004}"
SPAR_BENE_API_PORT="${SPAR_BENE_API_PORT:-8005}"
KEYCLOAK_IAM_CLIENT_SECRET="${KEYCLOAK_IAM_CLIENT_SECRET:-dev-iam-staff-secret}"
KEYCLOAK_AWE_RESOLVER_CLIENT_SECRET="${KEYCLOAK_AWE_RESOLVER_CLIENT_SECRET:-dev-awe-resolver-secret}"
AWE_UI_PORT="${AWE_UI_PORT:-8031}"
KEYCLOAK_DEV_USER="${KEYCLOAK_DEV_USER:-staff}"
KEYCLOAK_DEV_PASSWORD="${KEYCLOAK_DEV_PASSWORD:-staff}"
# AWE demo approvers (Stage 1 / Stage 2) — password matches helm aweApproverUserPassword.
KEYCLOAK_AWE_APPROVER_PASSWORD="${KEYCLOAK_AWE_APPROVER_PASSWORD:-pass}"
AWE_APPROVER_ROLES=(
  "Operations Administrator"
  "Technical Administrator"
)

if [[ -f /scripts/lib/keycloak-registry-roles.sh ]]; then
  # shellcheck disable=SC1091
  source /scripts/lib/keycloak-registry-roles.sh
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/lib/keycloak-registry-roles.sh" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/lib/keycloak-registry-roles.sh"
else
  echo "[keycloak-init] Missing keycloak-registry-roles.sh" >&2
  exit 1
fi

KCADM="${KCADM:-/opt/keycloak/bin/kcadm.sh}"

wait_for_keycloak() {
  local host="${KEYCLOAK_HOST:-keycloak}"
  local port="${KEYCLOAK_PORT:-8080}"
  local attempt

  for attempt in $(seq 1 60); do
    if (echo >"/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "Keycloak did not become ready at ${KEYCLOAK_URL}" >&2
  return 1
}

kc_login() {
  "${KCADM}" config credentials \
    --server "${KEYCLOAK_URL}" \
    --realm master \
    --user "${KEYCLOAK_ADMIN}" \
    --password "${KEYCLOAK_ADMIN_PASSWORD}" >/dev/null
}

realm_exists() {
  "${KCADM}" get "realms/${KEYCLOAK_REALM}" >/dev/null 2>&1
}

ensure_realm() {
  if realm_exists; then
    echo "[keycloak-init] Realm '${KEYCLOAK_REALM}' already exists"
    return 0
  fi

  echo "[keycloak-init] Creating realm '${KEYCLOAK_REALM}' ..."
  "${KCADM}" create realms \
    -s "realm=${KEYCLOAK_REALM}" \
    -s enabled=true \
    -s sslRequired=none \
    -s registrationAllowed=false \
    -s loginWithEmailAllowed=true \
    -s duplicateEmailsAllowed=false \
    -s resetPasswordAllowed=true \
    -s editUsernameAllowed=false \
    -s bruteForceProtected=false
}

# Applied on every run (ensure_realm returns early for an existing realm). Keycloak's
# 5-minute default access-token lifespan expires mid-run during the sample seed, which
# submits 25 households one at a time and fails with "Access token expired".
ensure_realm_token_lifespans() {
  echo "[keycloak-init] Setting realm token lifespans (dev) ..."
  "${KCADM}" update "realms/${KEYCLOAK_REALM}"     -s accessTokenLifespan=1800     -s ssoSessionIdleTimeout=7200     -s ssoSessionMaxLifespan=36000 >/dev/null
}

client_internal_id() {
  local client_id="$1"
  "${KCADM}" get clients -r "${KEYCLOAK_REALM}" -q "clientId=${client_id}" --fields id 2>/dev/null \
    | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1
}

ensure_client() {
  local client_id="$1"
  shift
  local internal_id
  internal_id="$(client_internal_id "${client_id}" || true)"

  if [[ -z "${internal_id}" ]]; then
    echo "[keycloak-init]   + client ${client_id}"
    "${KCADM}" create clients -r "${KEYCLOAK_REALM}" -s "clientId=${client_id}" "$@"
  else
    echo "[keycloak-init]   ~ client ${client_id}"
    "${KCADM}" update "clients/${internal_id}" -r "${KEYCLOAK_REALM}" "$@"
  fi
}

ensure_client_role() {
  local client_id="$1"
  local role_name="$2"
  local client_uuid
  client_uuid="$(client_internal_id "${client_id}")"
  [[ -n "${client_uuid}" ]] || return 0

  if "${KCADM}" get "clients/${client_uuid}/roles/${role_name}" -r "${KEYCLOAK_REALM}" >/dev/null 2>&1; then
    return 0
  fi

  echo "[keycloak-init]   + client role ${client_id}/${role_name}"
  "${KCADM}" create "clients/${client_uuid}/roles" -r "${KEYCLOAK_REALM}" -s "name=${role_name}" >/dev/null 2>&1 || true
}

assign_client_role() {
  local username="$1"
  local client_id="$2"
  local role_name="$3"

  if ! "${KCADM}" get users -r "${KEYCLOAK_REALM}" -q "username=${username}" --fields id >/dev/null 2>&1; then
    return 0
  fi

  "${KCADM}" add-roles \
    -r "${KEYCLOAK_REALM}" \
    --uusername "${username}" \
    --cclientid "${client_id}" \
    --rolename "${role_name}" >/dev/null 2>&1 || true
}

assign_realm_management_role() {
  local service_account_username="$1"
  local role_name="$2"

  "${KCADM}" add-roles \
    -r "${KEYCLOAK_REALM}" \
    --uusername "${service_account_username}" \
    --cclientid realm-management \
    --rolename "${role_name}" >/dev/null 2>&1 || true
}

ensure_user() {
  # ensure_user <username> <password> <email> <firstName> <lastName>
  local username="$1"
  local password="$2"
  local email="$3"
  local first_name="$4"
  local last_name="$5"
  local user_id

  user_id="$("${KCADM}" get users -r "${KEYCLOAK_REALM}" -q "username=${username}" --fields id 2>/dev/null \
    | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1)"

  if [[ -z "${user_id}" ]]; then
    echo "[keycloak-init] Creating user '${username}'"
    "${KCADM}" create users -r "${KEYCLOAK_REALM}" \
      -s "username=${username}" \
      -s enabled=true \
      -s "email=${email}" \
      -s emailVerified=true \
      -s "firstName=${first_name}" \
      -s "lastName=${last_name}"
  else
    echo "[keycloak-init] User '${username}' already exists"
  fi

  "${KCADM}" set-password -r "${KEYCLOAK_REALM}" \
    --username "${username}" \
    --new-password "${password}" \
    --temporary=false
}

ensure_dev_user() {
  ensure_user \
    "${KEYCLOAK_DEV_USER}" \
    "${KEYCLOAK_DEV_PASSWORD}" \
    "${KEYCLOAK_DEV_USER}@localhost" \
    "Local" \
    "Developer"

  for role in "${REGISTRY_STAFF_CLIENT_ROLES[@]}"; do
    assign_client_role "${KEYCLOAK_DEV_USER}" "nsr-registry-staff-portal" "${role}"
    assign_client_role "${KEYCLOAK_DEV_USER}" "farmer-registry-staff-portal" "${role}"
  done

  assign_client_role "${KEYCLOAK_DEV_USER}" "awe-admin-portal" "AWE_ADMIN"
}

# AWE seeded policies use alex.carter (Stage 1) and nina.patel (Stage 2).
ensure_awe_approver_users() {
  local username role

  echo "[keycloak-init] Ensuring AWE approver users (Op Admin + Tech Admin) ..."

  ensure_user "alex.carter" "${KEYCLOAK_AWE_APPROVER_PASSWORD}" \
    "alex.carter@email.com" "Alex" "Carter"
  ensure_user "nina.patel" "${KEYCLOAK_AWE_APPROVER_PASSWORD}" \
    "nina.patel@email.com" "Nina" "Patel"

  for username in alex.carter nina.patel; do
    for role in "${AWE_APPROVER_ROLES[@]}"; do
      assign_client_role "${username}" "farmer-registry-staff-portal" "${role}"
      assign_client_role "${username}" "nsr-registry-staff-portal" "${role}"
    done
  done
}

ensure_awe_clients() {
  ensure_client "awe-admin-portal" \
    -s enabled=true \
    -s publicClient=true \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=true \
    -s 'redirectUris=["http://localhost:'"${AWE_UI_PORT}"'/*"]' \
    -s 'webOrigins=["http://localhost:'"${AWE_UI_PORT}"'"]'

  ensure_client_role "awe-admin-portal" "AWE_ADMIN"
  ensure_client_role "awe-admin-portal" "AWE_VIEWER"

  ensure_client "awe-admin-resolver" \
    -s enabled=true \
    -s publicClient=false \
    -s secret="${KEYCLOAK_AWE_RESOLVER_CLIENT_SECRET}" \
    -s serviceAccountsEnabled=true \
    -s standardFlowEnabled=false \
    -s directAccessGrantsEnabled=false

  for role in view-users view-clients query-groups; do
    assign_realm_management_role "service-account-awe-admin-resolver" "${role}"
  done
}

echo "[keycloak-init] Waiting for Keycloak at ${KEYCLOAK_URL} ..."
wait_for_keycloak
kc_login
ensure_realm
ensure_realm_token_lifespans

echo "[keycloak-init] Ensuring OIDC clients in realm '${KEYCLOAK_REALM}' ..."

# IAM Staff Portal API — confidential client used for the browser SSO code flow.
# Include Staff/Farmer/NSR UI URLs so Keycloak accepts post_logout_redirect_uri
# (IAM logout uses login_providers.default_redirect_uri).
# Keycloak 26 kcadm rejects dotted -s 'attributes.foo=...'; pass attributes as JSON.
IAM_POST_LOGOUT_REDIRECT_URIS="http://localhost:${STAFF_PORTAL_UI_PORT}/*##http://localhost:${FARMER_REGISTRY_UI_PORT}/*##http://localhost:${NSR_REGISTRY_UI_PORT}/*##http://localhost:${IAM_STAFF_PORT}/auth/callback"
IAM_CLIENT_ATTRIBUTES="$(printf '{"post.logout.redirect.uris":"%s"}' "${IAM_POST_LOGOUT_REDIRECT_URIS}")"
ensure_client "iam-staff-portal" \
  -s enabled=true \
  -s publicClient=false \
  -s secret="${KEYCLOAK_IAM_CLIENT_SECRET}" \
  -s standardFlowEnabled=true \
  -s directAccessGrantsEnabled=true \
  -s serviceAccountsEnabled=false \
  -s 'redirectUris=["http://localhost:'"${IAM_STAFF_PORT}"'/auth/callback","http://localhost:'"${STAFF_PORTAL_UI_PORT}"'/*","http://localhost:'"${FARMER_REGISTRY_UI_PORT}"'/*","http://localhost:'"${NSR_REGISTRY_UI_PORT}"'/*"]' \
  -s 'webOrigins=["+"]' \
  -s "attributes=${IAM_CLIENT_ATTRIBUTES}"

ensure_client "nsr-registry-staff-portal" \
  -s enabled=true \
  -s publicClient=true \
  -s standardFlowEnabled=true \
  -s directAccessGrantsEnabled=true \
  -s 'redirectUris=["http://localhost:'"${NSR_REGISTRY_UI_PORT}"'/*"]' \
  -s 'webOrigins=["http://localhost:'"${NSR_REGISTRY_UI_PORT}"'"]'

ensure_client "farmer-registry-staff-portal" \
  -s enabled=true \
  -s publicClient=true \
  -s standardFlowEnabled=true \
  -s directAccessGrantsEnabled=true \
  -s 'redirectUris=["http://localhost:'"${FARMER_REGISTRY_UI_PORT}"'/*"]' \
  -s 'webOrigins=["http://localhost:'"${FARMER_REGISTRY_UI_PORT}"'"]'

ensure_client "g2p-bridge" \
  -s enabled=true \
  -s publicClient=false \
  -s secret=dev-g2p-bridge-secret \
  -s serviceAccountsEnabled=true \
  -s standardFlowEnabled=false \
  -s directAccessGrantsEnabled=true \
  -s 'redirectUris=["http://localhost:'"${G2P_BRIDGE_API_PORT}"'/*"]' \
  -s 'webOrigins=["+"]'

ensure_client "spar-mapper" \
  -s enabled=true \
  -s publicClient=false \
  -s secret=dev-spar-mapper-secret \
  -s serviceAccountsEnabled=true \
  -s standardFlowEnabled=false \
  -s directAccessGrantsEnabled=true \
  -s 'redirectUris=["http://localhost:'"${SPAR_MAPPER_API_PORT}"'/*"]' \
  -s 'webOrigins=["+"]'

ensure_client "spar-bene-portal" \
  -s enabled=true \
  -s publicClient=true \
  -s standardFlowEnabled=true \
  -s directAccessGrantsEnabled=true \
  -s 'redirectUris=["http://localhost:'"${SPAR_BENE_API_PORT}"'/*"]' \
  -s 'webOrigins=["+"]'

ensure_client "openg2p-pbms-local" \
  -s enabled=true \
  -s publicClient=true \
  -s standardFlowEnabled=true \
  -s directAccessGrantsEnabled=true \
  -s 'redirectUris=["http://localhost:'"${PBMS_HTTP_PORT}"'/*"]' \
  -s 'webOrigins=["http://localhost:'"${PBMS_HTTP_PORT}"'"]'

ensure_awe_clients

for role in "${REGISTRY_STAFF_CLIENT_ROLES[@]}"; do
  ensure_client_role "nsr-registry-staff-portal" "${role}"
  ensure_client_role "farmer-registry-staff-portal" "${role}"
done

ensure_dev_user
ensure_awe_approver_users

if [[ -f /keycloak-ensure-extension-clients.sh ]]; then
  OPENG2P_WORKSPACE="${OPENG2P_WORKSPACE:-/workspace}" \
    bash /keycloak-ensure-extension-clients.sh || true
fi

echo "[keycloak-init] Done. Realm: ${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}"
echo "[keycloak-init] Dev login: ${KEYCLOAK_DEV_USER} / ${KEYCLOAK_DEV_PASSWORD}"
echo "[keycloak-init] AWE Stage 1 approver: alex.carter / ${KEYCLOAK_AWE_APPROVER_PASSWORD}"
echo "[keycloak-init] AWE Stage 2 approver: nina.patel / ${KEYCLOAK_AWE_APPROVER_PASSWORD}"
