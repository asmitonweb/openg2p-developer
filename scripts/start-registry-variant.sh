#!/usr/bin/env bash
# Start a registry variant native stack in the background (no blocking wait).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/registry-variant.sh"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/run-service.sh"

VARIANT="${1:-}"
registry_variant_validate "$VARIANT"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/.env"
fi

registry_variant_ensure_run_ready "$VARIANT"
registry_variant_paths "$VARIANT"

"${ROOT_DIR}/scripts/infra-wait.sh"
"${ROOT_DIR}/scripts/id-generator-wait.sh"
"${ROOT_DIR}/scripts/generate-config.sh" >/dev/null

if [[ ! -d "$API_DIR" ]]; then
  echo "Registry platform not found at ${REGISTRY_ROOT}. Run: make clone" >&2
  exit 1
fi

if [[ ! -f "${GENERATED_DIR}/staff-portal-api.env" ]]; then
  echo "Missing generated env files. Run: make generate" >&2
  exit 1
fi

AWE_DIR="${OPENG2P_WORKSPACE}/awe"
AWE_ENV="${ROOT_DIR}/generated/awe/awe-api.env"
AWE_API_PORT="${AWE_API_PORT:-8030}"
AWE_UI_PORT="${AWE_UI_PORT:-8031}"

wait_for_awe_health() {
  local i
  for i in $(seq 1 30); do
    if curl -sf "http://localhost:${AWE_API_PORT}/v1/awe/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "AWE API did not become ready on port ${AWE_API_PORT}." >&2
  return 1
}

start_awe_admin_ui() {
  local ui_dir="${AWE_DIR}/ui"
  if [[ ! -d "$ui_dir" || ! -f "${ui_dir}/package.json" ]]; then
    return 0
  fi
  if ! command -v npx >/dev/null 2>&1; then
    return 0
  fi
  bash "${ROOT_DIR}/scripts/lib/ensure-awe-ui-vite-config.sh" "$ui_dir"
  bash "${ROOT_DIR}/scripts/lib/ensure-awe-ui-config.sh" "$ui_dir"
  echo "Starting awe-admin-ui from ${ui_dir} (port ${AWE_UI_PORT}) ..."
  (
    cd "$ui_dir"
    exec npx vite --config .openg2p-vite.config.mjs
  ) &
  echo "awe-admin-ui pid=$!"
}

if [[ -f "$AWE_ENV" && -d "${AWE_DIR}/venv" ]]; then
  run_service "awe-api" "$AWE_DIR" "$AWE_ENV" \
    bash -c 'exec uvicorn awe.main:app --host "${UVICORN_HOST:-0.0.0.0}" --port "${UVICORN_PORT}" --log-level info'
  wait_for_awe_health
  start_awe_admin_ui
else
  echo "AWE not ready. Run: make install-awe && make awe-init" >&2
fi

IAM_API_DIR="${OPENG2P_WORKSPACE}/iam-service/iam-staff-portal-api"
IAM_ENV="${ROOT_DIR}/generated/iam/staff-portal-api.env"
if [[ -f "$IAM_ENV" && -x "${IAM_API_DIR}/venv/bin/python" ]]; then
  run_service "iam-staff-api" "$IAM_API_DIR" "$IAM_ENV" \
    python -m iam_staff_portal_api.main run
fi

MASTER_DATA_ENV="${GENERATED_DIR}/master-data-api.env"
if [[ -f "$MASTER_DATA_ENV" && -x "${MASTER_DATA_API_DIR}/venv/bin/python" ]]; then
  # Prefer package ASGI path — fastapi-common "run" with worker_type=uvicorn
  # looks for repo-root main:app, which this service does not ship.
  run_service "${VARIANT}-master-data-api" "$MASTER_DATA_API_DIR" "$MASTER_DATA_ENV" \
    bash -c 'exec uvicorn openg2p_gen2_master_data.main:app --host "${MASTER_DATA_API_HOST:-0.0.0.0}" --port "${MASTER_DATA_API_PORT:-${UVICORN_PORT}}" --log-level info'
fi

run_service "${VARIANT}-staff-api" "$API_DIR" "${GENERATED_DIR}/staff-portal-api.env" \
  python -m openg2p_registry_staff_api.main run

if [[ -f "${GENERATED_DIR}/celery-workers.env" ]]; then
  # shellcheck disable=SC1090
  source "${GENERATED_DIR}/celery-workers.env"
fi
# Use package main.py (not repo-root main.py) so REGISTRY_EXTENSION_MODULE aliasing runs.
run_service_stop "${VARIANT}-celery-worker" "openg2p-registry-celery-worker.*${REGISTRY_CELERY_WORKERS_WORKER_QUEUE:-farmer_registry_worker_queue}" "${CELERY_DIR}"
run_service "${VARIANT}-celery-worker" "$CELERY_DIR" "${GENERATED_DIR}/celery-workers.env" \
  bash -c 'exec celery -A openg2p_registry_celery_worker.main:celery_app worker -Q "${REGISTRY_CELERY_WORKERS_WORKER_QUEUE}" -l info --concurrency="${REGISTRY_CELERY_CONCURRENCY:-2}"'
run_service_verify "${VARIANT}-celery-worker"

CELERY_BEAT_DIR="${REGISTRY_ROOT}/celery/openg2p-registry-celery-beat"
if [[ -x "${CELERY_BEAT_DIR}/venv/bin/python" && -f "${GENERATED_DIR}/celery-beat.env" ]]; then
  # shellcheck disable=SC1090
  source "${GENERATED_DIR}/celery-beat.env"
  REGISTRY_BEAT_TOKEN="${REGISTRY_CELERY_BEAT_DB_DBNAME:-farmer_registry_db}"
  run_service_stop_celery_beats "${REGISTRY_BEAT_TOKEN}"
  run_service_stop "${VARIANT}-celery-beat" "openg2p-registry-celery-beat.*celery_app beat" "${CELERY_BEAT_DIR}"
  run_service_stop "${VARIANT}-celery-beat-worker" "openg2p-registry-celery-beat.*worker -Q celery" "${CELERY_BEAT_DIR}"

  run_service "${VARIANT}-celery-beat" "$CELERY_BEAT_DIR" "${GENERATED_DIR}/celery-beat.env" \
    bash -c 'exec celery -A openg2p_registry_celery_beat.main:celery_app beat -l info --schedule "/tmp/celery-beat-${REGISTRY_CELERY_BEAT_DB_DBNAME}.db"'
  run_service_verify "${VARIANT}-celery-beat"

  run_service "${VARIANT}-celery-beat-worker" "$CELERY_BEAT_DIR" "${GENERATED_DIR}/celery-beat.env" \
    bash -c 'exec celery -A openg2p_registry_celery_beat.main:celery_app worker -Q celery -l info --concurrency=1'
  run_service_verify "${VARIANT}-celery-beat-worker"

  run_service_assert_single "${VARIANT} Celery beat" "openg2p_registry_celery_beat.main:celery_app beat" 1
fi

if [[ -d "$UI_DIR" && -x "${UI_DIR}/node_modules/.bin/next" ]]; then
  cp "${GENERATED_DIR}/staff-portal-ui.env" "${UI_DIR}/.env.local"
  run_service "${VARIANT}-staff-ui" "$UI_DIR" "${GENERATED_DIR}/staff-portal-ui.env" \
    bash -c 'exec npm run dev -- -p "${PORT:-3000}"'
fi

echo "${LABEL} services started."
