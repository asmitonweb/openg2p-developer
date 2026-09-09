#!/usr/bin/env bash
# Shared helpers for Docker-only Farmer / NSR stacks.
# shellcheck shell=bash

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ensure-free-ports.sh"

docker_registry_resolve_compose() {
  # Prefer Compose V2 plugin (`docker compose`). Fall back to legacy binary.
  # IMPORTANT: use an array — quoting "docker compose" as one string fails.
  if [[ -n "${COMPOSE:-}" ]]; then
    # Allow override from Make/env: COMPOSE="docker compose" or COMPOSE=docker-compose
    # shellcheck disable=SC2206
    COMPOSE_CMD=(${COMPOSE})
  elif docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
  else
    echo "ERROR: neither 'docker compose' nor 'docker-compose' is available." >&2
    return 1
  fi
}

docker_registry_compose() {
  "${COMPOSE_CMD[@]}" "$@"
}

docker_registry_compose_files() {
  COMPOSE_FILES=(
    -f compose/docker-compose.infra.yml
    -f compose/docker-compose.commons.yml
    -f compose/docker-compose.registry.yml
    -f compose/docker-compose.pbms.yml
    -f compose/docker-compose.bridge.yml
    -f compose/docker-compose.spar.yml
  )
}

docker_registry_prepare_env() {
  local variant="${1:-both}"

  if [[ ! -f .env ]]; then
    cp .env.example .env
    echo "Created .env from .env.example"
  fi

  # Export every .env assignment so `docker compose` interpolation sees them.
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a

  if [[ "${USE_EXTERNAL_REDIS:-true}" == "true" ]]; then
    echo "Docker registry requires Compose Redis — setting USE_EXTERNAL_REDIS=false in .env"
    _env_set_var "${ROOT_DIR}/.env" USE_EXTERNAL_REDIS false
  fi
  export USE_EXTERNAL_REDIS=false

  # Defaults before port scan
  POSTGRES_PORT="${POSTGRES_PORT:-5433}"
  REDIS_PORT="${REDIS_PORT:-6379}"
  MINIO_API_PORT="${MINIO_API_PORT:-9000}"
  MINIO_CONSOLE_PORT="${MINIO_CONSOLE_PORT:-9001}"
  KEYCLOAK_PORT="${KEYCLOAK_PORT:-8080}"
  ID_GENERATOR_PORT="${ID_GENERATOR_PORT:-8040}"
  MASTER_DATA_API_PORT="${MASTER_DATA_API_PORT:-8042}"
  NSR_MASTER_DATA_API_PORT="${NSR_MASTER_DATA_API_PORT:-8043}"
  FARMER_REGISTRY_STAFF_API_PORT="${FARMER_REGISTRY_STAFF_API_PORT:-8001}"
  FARMER_REGISTRY_PARTNER_API_PORT="${FARMER_REGISTRY_PARTNER_API_PORT:-8006}"
  FARMER_REGISTRY_UI_PORT="${FARMER_REGISTRY_UI_PORT:-3001}"
  NSR_REGISTRY_STAFF_API_PORT="${NSR_REGISTRY_STAFF_API_PORT:-8011}"
  NSR_REGISTRY_PARTNER_API_PORT="${NSR_REGISTRY_PARTNER_API_PORT:-8012}"
  NSR_REGISTRY_UI_PORT="${NSR_REGISTRY_UI_PORT:-3002}"
  IAM_STAFF_PORT="${IAM_STAFF_PORT:-8020}"
  AWE_API_PORT="${AWE_API_PORT:-8030}"
  AWE_UI_PORT="${AWE_UI_PORT:-8031}"
  STAFF_PORTAL_UI_PORT="${STAFF_PORTAL_UI_PORT:-3000}"
  LOAD_SAMPLE_DATA="${LOAD_SAMPLE_DATA:-true}"
  LOAD_GEO_DATA="${LOAD_GEO_DATA:-true}"
  LOAD_TEMPLATES="${LOAD_TEMPLATES:-true}"
  LOAD_IMAGES="${LOAD_IMAGES:-false}"
  AWE_REGISTRY_CALLBACK_SECRET_ID="${AWE_REGISTRY_CALLBACK_SECRET_ID:-00000000-0000-4000-8000-000000000001}"
  AWE_REGISTRY_CALLBACK_HMAC_SECRET="${AWE_REGISTRY_CALLBACK_HMAC_SECRET:-dev-registry-awe-callback-secret}"
  AWE_CALLBACK_CALLER_SERVICE="${AWE_CALLBACK_CALLER_SERVICE:-registry}"
  POSTGRES_SUPERUSER="${POSTGRES_SUPERUSER:-postgres}"

  docker_registry_ensure_ports "$variant"

  # Re-load after port rewrites
  set -a
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/.env"
  set +a
  export USE_EXTERNAL_REDIS=false
}

docker_registry_wait_http() {
  local url="$1"
  local label="$2"
  local attempts="${3:-60}"
  echo "Waiting for ${label} (${url}) ..."
  for _ in $(seq 1 "$attempts"); do
    if curl -sf "$url" >/dev/null 2>&1; then
      echo "  ${label} is ready."
      return 0
    fi
    sleep 2
  done
  echo "ERROR: ${label} did not become ready" >&2
  return 1
}

# Stop existing containers for this variant (+ shared infra/commons) before a clean up.
# Volumes are kept (no -v); variant DBs are reset on the next up for a clean migrate+seed.
docker_registry_down_variant() {
  local variant="$1"
  local profile seed_profile label

  case "$variant" in
    farmer)
      profile="farmer-registry"
      seed_profile="farmer-registry-seed"
      label="Farmer"
      ;;
    nsr)
      profile="nsr-registry"
      seed_profile="nsr-registry-seed"
      label="NSR"
      ;;
    *)
      echo "Unknown variant for down: ${variant}" >&2
      return 1
      ;;
  esac

  echo "Stopping any existing ${label} Docker stack (infra + IAM/AWE + ${label}) ..."
  docker_registry_compose "${COMPOSE_FILES[@]}" \
    --profile infra --profile with-redis --profile commons \
    --profile "${profile}" --profile "${seed_profile}" \
    down --remove-orphans || true
  echo "  Previous ${label} stack stopped (volumes kept; variant DBs reset on next up)."
}

# Drop + recreate this variant's registry/master DBs so migrate creates current schema
# (kept volumes otherwise leave stale columns and seed hits duplicate keys).
docker_registry_reset_variant_dbs() {
  local variant="$1"
  local reg_db md_db

  case "$variant" in
    farmer)
      reg_db="farmer_registry_db"
      md_db="farmer_master_data_db"
      ;;
    nsr)
      reg_db="nsr_registry_db"
      md_db="nsr_master_data_db"
      ;;
    *)
      echo "Unknown variant for DB reset: ${variant}" >&2
      return 1
      ;;
  esac

  echo "Resetting ${reg_db} + ${md_db} for clean migrate+seed ..."
  docker_registry_compose "${COMPOSE_FILES[@]}" --profile infra exec -T postgres \
    psql -U "${POSTGRES_SUPERUSER}" -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname IN ('${reg_db}', '${md_db}')
  AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS ${reg_db};
DROP DATABASE IF EXISTS ${md_db};
CREATE DATABASE ${reg_db} OWNER postgres;
CREATE DATABASE ${md_db} OWNER postgres;
\\c ${reg_db}
CREATE EXTENSION IF NOT EXISTS pg_trgm;
SQL
  echo "  ${reg_db} and ${md_db} recreated."
}

# Reset the shared AWE database so approval policies/stages are re-seeded from scratch.
# Kept volumes otherwise leave stale stages behind: the db-seed only adds stages that are
# missing, so an old "Stage 1" keeps its previous approver and the sample seed fails with
# AWE-008 "Task is not assigned to you". Must run before AWE starts so it migrates fresh.
docker_registry_reset_awe_db() {
  echo "Resetting awe database for clean policy seed ..."
  docker_registry_compose "${COMPOSE_FILES[@]}" --profile infra exec -T postgres     psql -U "${POSTGRES_SUPERUSER}" -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = 'awe'
  AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS awe;
CREATE DATABASE awe OWNER postgres;
\c awe
CREATE EXTENSION IF NOT EXISTS pg_trgm;
SQL
  echo "  awe recreated."
}

docker_registry_container_publishes() {
  local name="$1"
  local port="$2"
  docker port "$name" 2>/dev/null | grep -Eq "(0\\.0\\.0\\.0|\\[::\\]|127\\.0\\.0\\.1):${port}$"
}

docker_registry_start_infra() {
  echo "Starting infra (Postgres, Redis, MinIO, Keycloak, ID Generator) ..."
  echo "  Postgres host port: ${POSTGRES_PORT}  Redis: ${REDIS_PORT}  Keycloak: ${KEYCLOAK_PORT}"
  docker_registry_compose "${COMPOSE_FILES[@]}" --profile infra --profile with-redis \
    up -d --remove-orphans --force-recreate
  bash "${ROOT_DIR}/scripts/infra-wait.sh"
  docker_registry_compose -f compose/docker-compose.infra.yml --profile infra \
    up keycloak-init --abort-on-container-exit || true
}

# start_commons re-runs the infra profile, which recreates keycloak-init and lets it run
# detached. The sample seed logs in as the AWE approvers (alex.carter / nina.patel), so the
# realm must be fully provisioned first — otherwise the password grant fails with 401.
docker_registry_wait_keycloak_init() {
  local name="openg2p-keycloak-init"
  local i state
  echo "Waiting for Keycloak realm provisioning ..."
  for i in $(seq 1 120); do
    state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)"
    case "$state" in
      exited)
        echo "  Keycloak realm provisioning complete."
        return 0
        ;;
      missing)
        echo "  ${name} not present — skipping wait."
        return 0
        ;;
    esac
    sleep 5
  done
  echo "  WARNING: ${name} still running; continuing anyway." >&2
}

# The sample seed logs in as the AWE approvers with a Keycloak password grant. Waiting on
# the keycloak-init container's state is racy (compose recreates it, so an old "exited"
# instance can be observed), so verify the thing the seed actually needs: a working grant.
docker_registry_wait_awe_approver_login() {
  local client_id="$1"
  local user="${2:-alex.carter}"
  local pass="${KEYCLOAK_AWE_APPROVER_PASSWORD:-pass}"
  local url="${KEYCLOAK_URL:-http://localhost:8080}/realms/${KEYCLOAK_REALM:-staff}/protocol/openid-connect/token"
  local i code

  echo "Waiting for AWE approver login (${user}) ..."
  for i in $(seq 1 90); do
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url"       -d grant_type=password -d "client_id=${client_id}"       -d "username=${user}" -d "password=${pass}" 2>/dev/null || echo 000)"
    if [[ "$code" == "200" ]]; then
      echo "  AWE approver login ready."
      return 0
    fi
    sleep 5
  done
  echo "  WARNING: ${user} still cannot log in (last HTTP ${code}); seeding may fail." >&2
}

docker_registry_start_commons() {
  echo "Starting commons (IAM + AWE + Staff Portal hub) ..."
  docker_registry_compose "${COMPOSE_FILES[@]}" \
    --profile infra --profile with-redis --profile commons \
    up -d --remove-orphans --force-recreate
  docker_registry_wait_http "http://localhost:${IAM_STAFF_PORT}/ping" "IAM staff API"
  docker_registry_wait_http "http://localhost:${AWE_API_PORT}/v1/awe/health" "AWE API"
  docker_registry_wait_staff_portal_hub
  docker_registry_wait_keycloak_init
}

docker_registry_seed_awe_callback() {
  echo "Seeding AWE callback secret ..."
  local tmp_sql
  tmp_sql="$(mktemp)"
  export AWE_CALLBACK_SECRET_ID="$AWE_REGISTRY_CALLBACK_SECRET_ID"
  export AWE_CALLBACK_HMAC_SECRET="$AWE_REGISTRY_CALLBACK_HMAC_SECRET"
  export AWE_CALLBACK_CALLER_SERVICE
  envsubst '${AWE_CALLBACK_HMAC_SECRET} ${AWE_CALLBACK_SECRET_ID} ${AWE_CALLBACK_CALLER_SERVICE}' \
    < "${ROOT_DIR}/scripts/sql/awe-callback-secret.sql.tpl" > "$tmp_sql"

  for _ in $(seq 1 30); do
    if docker_registry_compose "${COMPOSE_FILES[@]}" --profile infra exec -T postgres \
      psql -U "${POSTGRES_SUPERUSER}" -d awe -tc "SELECT to_regclass('public.callback_secret')" \
      | grep -q callback_secret; then
      break
    fi
    sleep 2
  done

  docker_registry_compose "${COMPOSE_FILES[@]}" --profile infra exec -T postgres \
    psql -U "${POSTGRES_SUPERUSER}" -d awe -v ON_ERROR_STOP=1 < "$tmp_sql"
  rm -f "$tmp_sql"
  echo "  AWE callback secret ready."
}

docker_registry_register_iam_apps() {
  # Args: JSON array of {mnemonic,url}
  local variants_json="$1"
  local payload_file="${ROOT_DIR}/config/registry_registration_payload.json"

  if [[ ! -f "$payload_file" ]]; then
    echo "Missing ${payload_file}" >&2
    return 1
  fi

  local scripts_src="${ROOT_DIR}/scripts"
  local payload_src="$payload_file"
  local iam_env_src="${ROOT_DIR}/generated/iam/docker/staff-portal-api.env"

  # Git Bash / MSYS rewrites arguments that look like absolute POSIX paths into Windows
  # paths, which turned the container-side /opt/... arguments into C:/Program Files/Git/opt/...
  # Disable that conversion for this command and hand Docker Windows-style host paths.
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*)
      scripts_src="$(cygpath -m "$scripts_src")"
      payload_src="$(cygpath -m "$payload_src")"
      iam_env_src="$(cygpath -m "$iam_env_src")"
      export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
      ;;
  esac

  echo "Registering IAM staff portal application(s) ..."
  docker_registry_compose "${COMPOSE_FILES[@]}" --profile commons run --rm --no-deps \
    -v "${scripts_src}:/opt/openg2p-scripts:ro" \
    -v "${payload_src}:/opt/registry_registration_payload.json:ro" \
    -v "${iam_env_src}:/opt/iam.env:ro" \
    -e IAM_STAFF_ENV_FILE=/opt/iam.env \
    -e REGISTRY_IAM_PAYLOAD=/opt/registry_registration_payload.json \
    -e REGISTRY_IAM_VARIANTS="${variants_json}" \
    --entrypoint python \
    iam-staff-api \
    /opt/openg2p-scripts/lib/iam_register_registry_apps.py
}

docker_registry_migrate_master_data() {
  # master-data-api does not migrate its own schema at startup, and the variant
  # master-data DB is dropped/recreated on every up — without this the db-seed
  # geo load fails with: relation "g2p_geo_levels" does not exist.
  local profile="$1"
  local service="$2"

  echo "Migrating Master Data schema (${service}) ..."
  ( export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
    docker_registry_compose "${COMPOSE_FILES[@]}" --profile "${profile}"       run --rm --no-deps --entrypoint python "${service}"       -m openg2p_gen2_master_data.main migrate >/dev/null )
  echo "  Master Data schema ready."
}

docker_registry_variant_meta() {
  # Sets: profile seed_profile staff_port partner_port ui_port label seed_service mnemonic master_data_port master_data_service
  local variant="$1"
  case "$variant" in
    farmer)
      profile="farmer-registry"
      seed_profile="farmer-registry-seed"
      staff_port="${FARMER_REGISTRY_STAFF_API_PORT}"
      partner_port="${FARMER_REGISTRY_PARTNER_API_PORT}"
      ui_port="${FARMER_REGISTRY_UI_PORT}"
      master_data_port="${MASTER_DATA_API_PORT}"
      master_data_service="farmer-master-data-api"
      label="Farmer Registry"
      seed_service="farmer-registry-db-seed"
      mnemonic="farmer-registry-staff-portal"
      ;;
    nsr)
      profile="nsr-registry"
      seed_profile="nsr-registry-seed"
      staff_port="${NSR_REGISTRY_STAFF_API_PORT}"
      partner_port="${NSR_REGISTRY_PARTNER_API_PORT}"
      ui_port="${NSR_REGISTRY_UI_PORT}"
      master_data_port="${NSR_MASTER_DATA_API_PORT}"
      master_data_service="nsr-master-data-api"
      label="National Social Registry"
      seed_service="nsr-registry-db-seed"
      mnemonic="nsr-registry-staff-portal"
      ;;
    *)
      echo "Unknown variant: ${variant} (expected farmer|nsr)" >&2
      return 1
      ;;
  esac
}

docker_registry_print_urls() {
  local label="$1"
  local ui_port="$2"
  local staff_port="$3"
  local partner_port="$4"
  local master_data_port="$5"
  echo
  echo "${label} is up and seeded."
  echo "  Staff Portal : http://localhost:${STAFF_PORTAL_UI_PORT:-3000}  (hub — links to apps)"
  echo "  ${label} UI  : http://localhost:${ui_port}  (staff / staff)"
  echo "  Staff API    : http://localhost:${staff_port}/docs"
  echo "  Partner API  : http://localhost:${partner_port}/docs"
  echo "  Master Data  : http://localhost:${master_data_port}/docs"
  echo "  IAM          : http://localhost:${IAM_STAFF_PORT}"
  echo "  AWE API      : http://localhost:${AWE_API_PORT}/v1/awe/health"
  echo "  AWE Admin    : http://localhost:${AWE_UI_PORT}/"
  echo "  Keycloak     : http://localhost:${KEYCLOAK_PORT:-8080}  (staff / staff)"
  echo "  Postgres     : localhost:${POSTGRES_PORT}"
  echo "  Redis        : localhost:${REDIS_PORT}"
}

docker_registry_seed_variant() {
  local seed_profile="$1"
  local seed_service="$2"
  local label="$3"
  echo "Seeding ${label} (LOAD_SAMPLE_DATA=${LOAD_SAMPLE_DATA}) ..."
  docker_registry_compose "${COMPOSE_FILES[@]}" --profile "${seed_profile}" \
    run --rm --no-deps \
    -e "LOAD_SAMPLE_DATA=${LOAD_SAMPLE_DATA}" \
    -e "LOAD_GEO_DATA=${LOAD_GEO_DATA}" \
    -e "LOAD_TEMPLATES=${LOAD_TEMPLATES}" \
    -e "LOAD_IMAGES=${LOAD_IMAGES}" \
    -e "AWE_DB_SEED_ENABLED=true" \
    "${seed_service}"

  # Farmer sample JSON still ships legacy enums and skips history tables.
  if [[ "$seed_service" == "farmer-registry-db-seed" && "${LOAD_SAMPLE_DATA}" == "true" ]]; then
    echo "Post-processing Farmer sample seed (enums + history) ..."
    PGHOST=localhost \
      PGPORT="${POSTGRES_PORT}" \
      PGDATABASE=farmer_registry_db \
      PGUSER="${POSTGRES_SUPERUSER}" \
      PGPASSWORD="${POSTGRES_PASSWORD}" \
      bash "${ROOT_DIR}/scripts/farmer-post-seed.sh"
  fi
}

# Ensure infra/commons are running without tearing them down (no --force-recreate).
docker_registry_ensure_infra_commons() {
  echo "Ensuring infra is up (no recreate) ..."
  docker_registry_compose "${COMPOSE_FILES[@]}" --profile infra --profile with-redis \
    up -d --remove-orphans
  bash "${ROOT_DIR}/scripts/infra-wait.sh"
  # keycloak-init is idempotent; ignore failures if realm already OK
  docker_registry_compose -f compose/docker-compose.infra.yml --profile infra \
    up keycloak-init --abort-on-container-exit || true

  echo "Ensuring commons (IAM + AWE + Staff Portal hub) are up (no recreate) ..."
  docker_registry_compose "${COMPOSE_FILES[@]}" \
    --profile infra --profile with-redis --profile commons \
    up -d --remove-orphans
  docker_registry_wait_http "http://localhost:${IAM_STAFF_PORT}/ping" "IAM staff API"
  docker_registry_wait_http "http://localhost:${AWE_API_PORT}/v1/awe/health" "AWE API"
  docker_registry_wait_staff_portal_hub
  docker_registry_seed_awe_callback
}

docker_registry_wait_staff_portal_hub() {
  # Hub is optional-ish for API work but required for the app-launcher experience.
  docker_registry_wait_http "http://localhost:${STAFF_PORTAL_UI_PORT:-3000}/" "Staff Portal hub" 60 || true
}

# Resume after a failed *-up: keep running containers, start missing ones, seed.
# Optional: RESET_DBS=1 to drop/recreate variant DBs and recreate apps (migrate) first.
docker_registry_continue_variant() {
  local variant="$1"
  local profile seed_profile staff_port partner_port ui_port label seed_service mnemonic master_data_port master_data_service
  local recreate_flag=()

  docker_registry_variant_meta "$variant"

  echo "============================================="
  echo " Continue ${label} (resume; no full teardown)"
  echo "============================================="

  bash "${ROOT_DIR}/scripts/sync-image-env.sh"
  bash "${ROOT_DIR}/scripts/generate-docker-config.sh"
  docker_registry_ensure_infra_commons

  # Re-resolve ports after env sync / generate
  docker_registry_variant_meta "$variant"

  if [[ "${RESET_DBS:-0}" == "1" || "${RESET_DBS:-}" == "true" ]]; then
    echo "RESET_DBS=1 — resetting ${variant} DBs and recreating app containers ..."
    docker_registry_reset_variant_dbs "$variant"
    recreate_flag=(--force-recreate)
  fi

  echo "Starting/ensuring ${label} containers (master-data, APIs, Celery, UI) ..."
  if [[ ${#recreate_flag[@]} -gt 0 ]]; then
    docker_registry_compose "${COMPOSE_FILES[@]}" \
      --profile infra --profile with-redis --profile commons --profile "${profile}" \
      up -d --remove-orphans "${recreate_flag[@]}"
  else
    docker_registry_compose "${COMPOSE_FILES[@]}" \
      --profile infra --profile with-redis --profile commons --profile "${profile}" \
      up -d --remove-orphans
  fi

  docker_registry_wait_http "http://localhost:${master_data_port}/ping" "Master Data API" 90
  docker_registry_migrate_master_data "${profile}" "${master_data_service}"
  docker_registry_wait_http "http://localhost:${staff_port}/ping" "${label} staff API" 90

  local variants_json
  variants_json="$(
    python3 - <<PY
import json
print(json.dumps([
  {"mnemonic": "${mnemonic}", "url": "http://localhost:${ui_port}"},
]))
PY
  )"
  docker_registry_register_iam_apps "${variants_json}"
  docker_registry_wait_awe_approver_login "$mnemonic"
  docker_registry_seed_variant "$seed_profile" "$seed_service" "$label"
  docker_registry_print_urls "$label" "$ui_port" "$staff_port" "$partner_port" "$master_data_port"
}

# Stop every OpenG2P compose profile (infra, commons, farmer, nsr, pbms, bridge, spar).
docker_registry_down_all() {
  echo "Stopping all OpenG2P Docker Compose services ..."
  docker_registry_compose "${COMPOSE_FILES[@]}" \
    --profile infra --profile with-redis --profile commons \
    --profile farmer-registry --profile farmer-registry-seed \
    --profile nsr-registry --profile nsr-registry-seed \
    --profile pbms --profile bridge --profile spar --profile full \
    down --remove-orphans || true
  echo "  All OpenG2P compose services stopped (volumes kept)."
  echo "  Remove volumes too: make docker-clean"
}

# VARIANT=farmer|nsr
docker_registry_up_variant() {
  local variant="$1"
  local profile seed_profile staff_port partner_port ui_port label seed_service mnemonic master_data_port master_data_service

  docker_registry_variant_meta "$variant"

  echo "============================================="
  echo " Docker-only ${label}"
  echo "============================================="

  bash "${ROOT_DIR}/scripts/sync-image-env.sh"

  # Always stop first so port maps / images / env are applied cleanly on up.
  docker_registry_down_variant "$variant"

  # Regenerate after port selection so UI/IAM/AWE env match published ports.
  bash "${ROOT_DIR}/scripts/generate-docker-config.sh"

  docker_registry_start_infra
  docker_registry_reset_awe_db
  docker_registry_start_commons
  docker_registry_seed_awe_callback
  docker_registry_reset_variant_dbs "$variant"

  # Refresh ports from env (may have been rewritten)
  docker_registry_variant_meta "$variant"

  echo "Starting ${label} containers (master-data, staff API, partner API, Celery, UI) ..."
  docker_registry_compose "${COMPOSE_FILES[@]}" \
    --profile infra --profile with-redis --profile commons --profile "${profile}" \
    up -d --remove-orphans --force-recreate

  docker_registry_wait_http "http://localhost:${master_data_port}/ping" "Master Data API" 90
  docker_registry_migrate_master_data "${profile}" "${master_data_service}"
  docker_registry_wait_http "http://localhost:${staff_port}/ping" "${label} staff API" 90

  local variants_json
  variants_json="$(
    python3 - <<PY
import json
print(json.dumps([
  {"mnemonic": "${mnemonic}", "url": "http://localhost:${ui_port}"},
]))
PY
  )"
  docker_registry_register_iam_apps "${variants_json}"
  docker_registry_wait_awe_approver_login "$mnemonic"
  docker_registry_seed_variant "$seed_profile" "$seed_service" "$label"
  docker_registry_print_urls "$label" "$ui_port" "$staff_port" "$partner_port" "$master_data_port"
}
