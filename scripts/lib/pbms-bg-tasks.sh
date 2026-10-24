#!/usr/bin/env bash
# Paths and helpers for native PBMS background tasks (staff API + Celery).

pbms_bg_tasks_load_env() {
  PBMS_DEV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  cd "$PBMS_DEV_ROOT"

  if [[ -f .env ]]; then
    # shellcheck disable=SC1091
    source .env
  fi

  OPENG2P_WORKSPACE="${OPENG2P_WORKSPACE:-../openg2p-workspace}"
  OPENG2P_WORKSPACE="$(cd "$PBMS_DEV_ROOT" && cd "$OPENG2P_WORKSPACE" && pwd)"
  PBMS_PATH="${PBMS_PATH:-${OPENG2P_WORKSPACE}/pbms}"
  # The PBMS repo is absent for registry-only clone profiles. Keep the unresolved
  # path rather than failing, so profile-agnostic callers (free-native-stack)
  # still work; anything that actually needs PBMS checks for the directory.
  if [[ -d "$PBMS_PATH" ]]; then
    PBMS_PATH="$(cd "$PBMS_DEV_ROOT" && cd "$PBMS_PATH" && pwd)"
  fi
  GENERATED_DIR="${PBMS_DEV_ROOT}/generated/pbms"

  PBMS_DB_NAME="${PBMS_DB_NAME:-pbmsdb}"
  PBMS_DB_USER="${PBMS_DB_USER:-pbmsuser}"
  PBMS_DB_PASSWORD="${PBMS_DB_PASSWORD:-pbmspass}"
  PBMS_BGTASK_DB_NAME="${PBMS_BGTASK_DB_NAME:-bgtaskdb}"
  PBMS_STAFF_API_PORT="${PBMS_STAFF_API_PORT:-8050}"
  PBMS_REGISTRY_VARIANT="${PBMS_REGISTRY_VARIANT:-farmer-registry}"
  PBMS_WITH_REGISTRY="${PBMS_WITH_REGISTRY:-true}"

  POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
  POSTGRES_PORT="${POSTGRES_PORT:-5432}"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
  REDIS_HOST="${REDIS_HOST:-localhost}"
  REDIS_PORT="${REDIS_PORT:-6379}"
  PBMS_REDIS_DB="${PBMS_REDIS_DB:-1}"
  G2P_BRIDGE_API_PORT="${G2P_BRIDGE_API_PORT:-8002}"

  BG_TASK_MODELS_DIR="${PBMS_PATH}/core/openg2p-bg-task-models"
  PBMS_MODELS_DIR="${PBMS_PATH}/core/openg2p-pbms-models"
  REGISTRY_ADAPTERS_DIR="${PBMS_PATH}/extensions/openg2p-bg-task-registry-adapters"
  STAFF_API_DIR="${PBMS_PATH}/apis/openg2p-pbms-staff-portal-api"
  CELERY_BEAT_DIR="${PBMS_PATH}/core/openg2p-bg-task-celery-beat-producers"
  CELERY_WORKERS_DIR="${PBMS_PATH}/core/openg2p-bg-task-celery-workers"

  STAFF_API_ENV="${GENERATED_DIR}/staff-portal-api.env"
  CELERY_BEAT_ENV="${GENERATED_DIR}/celery-beat.env"
  CELERY_WORKERS_ENV="${GENERATED_DIR}/celery-workers.env"
}

pbms_bg_tasks_registry_db_name() {
  case "${PBMS_REGISTRY_VARIANT}" in
    farmer-registry) echo "farmer_registry_db" ;;
    national-social-registry) echo "nsr_registry_db" ;;
    *)
      # shellcheck disable=SC1091
      source "${PBMS_DEV_ROOT}/scripts/lib/extension-manifest.sh"
      extension_manifest_load "${PBMS_REGISTRY_VARIANT}"
      echo "${EXTENSION_REGISTRY_DB}"
      ;;
  esac
}

pbms_bg_tasks_require_paths() {
  local missing=0
  for path in "$PBMS_PATH" "$STAFF_API_DIR" "$CELERY_BEAT_DIR" "$CELERY_WORKERS_DIR" \
    "$BG_TASK_MODELS_DIR" "$PBMS_MODELS_DIR" "$REGISTRY_ADAPTERS_DIR"; do
    if [[ ! -d "$path" ]]; then
      echo "Missing ${path}. Run: make clone PROFILE=pbms" >&2
      missing=1
    fi
  done
  for env_file in "$STAFF_API_ENV" "$CELERY_BEAT_ENV" "$CELERY_WORKERS_ENV"; do
    if [[ ! -f "$env_file" ]]; then
      echo "Missing ${env_file}. Run: make generate" >&2
      missing=1
    fi
  done
  return "$missing"
}

pbms_bg_tasks_ensure_bgtask_db() {
  if PGPASSWORD="${POSTGRES_PASSWORD}" psql \
    -h "${POSTGRES_HOST}" \
    -p "${POSTGRES_PORT}" \
    -U "${POSTGRES_SUPERUSER:-postgres}" \
    -d postgres \
    -tc "SELECT 1 FROM pg_database WHERE datname = '${PBMS_BGTASK_DB_NAME}'" \
    | grep -q 1; then
    return 0
  fi

  echo "[pbms] Creating database ${PBMS_BGTASK_DB_NAME} ..."
  PGPASSWORD="${POSTGRES_PASSWORD}" psql \
    -h "${POSTGRES_HOST}" \
    -p "${POSTGRES_PORT}" \
    -U "${POSTGRES_SUPERUSER:-postgres}" \
    -d postgres \
    -c "CREATE DATABASE ${PBMS_BGTASK_DB_NAME} OWNER postgres;"
}

pbms_bg_tasks_wait_redis() {
  local i
  echo "Waiting for Redis at ${REDIS_HOST}:${REDIS_PORT} ..."
  for i in $(seq 1 30); do
    if command -v redis-cli >/dev/null 2>&1 \
      && redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" ping 2>/dev/null | grep -q PONG; then
      echo "Redis is ready."
      return 0
    fi
    sleep 1
  done
  echo "Redis is not reachable at ${REDIS_HOST}:${REDIS_PORT}." >&2
  echo "Start Docker Redis (USE_EXTERNAL_REDIS=false make infra-up) or run a local Redis server." >&2
  return 1
}

pbms_bg_tasks_staff_api_url() {
  echo "http://localhost:${PBMS_STAFF_API_PORT}"
}

pbms_bg_tasks_installed() {
  [[ -x "${STAFF_API_DIR}/venv/bin/python" ]] \
    && [[ -x "${CELERY_BEAT_DIR}/venv/bin/python" ]] \
    && [[ -x "${CELERY_WORKERS_DIR}/venv/bin/python" ]]
}

# PBMS Celery workers import g2p_bridge_helper when Bridge is enabled; install
# bridge models if g2p-bridge was cloned after make install-pbms-bg-tasks.
pbms_bg_tasks_ensure_bridge_models() {
  if [[ "${PBMS_WITH_BRIDGE:-true}" != "true" ]]; then
    return 0
  fi

  local bridge_models_dir="${OPENG2P_WORKSPACE}/g2p-bridge/core/models"
  if [[ ! -d "$bridge_models_dir" ]]; then
    echo "[pbms] PBMS_WITH_BRIDGE=true but g2p-bridge is not cloned. Run: make clone PROFILE=bridge" >&2
    return 1
  fi

  if [[ ! -x "${CELERY_WORKERS_DIR}/venv/bin/python" ]]; then
    return 0
  fi

  if "${CELERY_WORKERS_DIR}/venv/bin/python" -c "import openg2p_g2p_bridge_models" 2>/dev/null; then
    return 0
  fi

  echo "[pbms] Installing G2P Bridge models into PBMS Celery worker venv ..."
  (
    cd "$CELERY_WORKERS_DIR"
    # shellcheck disable=SC1091
    source venv/bin/activate
    pip install -e "$bridge_models_dir"
  )
}
