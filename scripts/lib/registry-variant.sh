#!/usr/bin/env bash
# Shared helpers for Registry Gen2 domain variants.

registry_variant_root() {
  echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
}

registry_variant_load_env() {
  local root
  root="$(registry_variant_root)"
  if [[ -f "${root}/.env" ]]; then
    # shellcheck disable=SC1091
    source "${root}/.env"
  fi
}

registry_variant_resolve_path() {
  local root="$1"
  local path="$2"
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/workspace-path.sh"
  if [[ "$path" != /* ]]; then
    path="${root}/${path}"
  fi
  workspace_resolve "$path"
}

registry_variant_is_custom() {
  local variant="$1"
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/extension-manifest.sh"
  extension_manifest_is_builtin_variant "$variant" && return 1
  extension_manifest_exists "$variant"
}

registry_variant_validate() {
  local variant="$1"
  if [[ "$variant" == "farmer-registry" || "$variant" == "national-social-registry" ]]; then
    return 0
  fi
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/extension-manifest.sh"
  if extension_manifest_exists "$variant"; then
    return 0
  fi
  echo "Unknown VARIANT '${variant}'." >&2
  echo "Built-in: farmer-registry, national-social-registry" >&2
  echo "Custom: bootstrap with make extension-package NAME=${variant}" >&2
  return 1
}

registry_variant_open_data_dir() {
  local root
  root="$(registry_variant_root)"
  registry_variant_resolve_path "$root" "${OPENG2P_DATA_DIR:-${OPENG2P_WORKSPACE}/openg2p-data}"
}

registry_variant_paths() {
  local variant="$1"
  local root
  root="$(registry_variant_root)"
  registry_variant_load_env

  OPENG2P_WORKSPACE="$(registry_variant_resolve_path "$root" "${OPENG2P_WORKSPACE:-../openg2p-workspace}")"
  REGISTRY_ROOT="${OPENG2P_WORKSPACE}/registry-platform"
  GENERATED_DIR="${root}/generated/${variant}"

  API_DIR="${REGISTRY_ROOT}/apis/openg2p-registry-staff-api"
  CELERY_DIR="${REGISTRY_ROOT}/celery/openg2p-registry-celery-worker"
  CELERY_BEAT_DIR="${REGISTRY_ROOT}/celery/openg2p-registry-celery-beat"
  DEFAULT_UI_DIR="${REGISTRY_ROOT}/ui/staff-ui"
  LEGACY_UI_DIR="${REGISTRY_ROOT}/ui/staff-portal-ui"
  MASTER_DATA_ROOT="${OPENG2P_WORKSPACE}/master-data-service"
  MASTER_DATA_API_DIR="${MASTER_DATA_ROOT}/master-data-api"
  MASTER_DATA_SEED_DIR="${MASTER_DATA_ROOT}/docker/db-seed"

  case "$variant" in
    farmer-registry)
      PRODUCT_REPO="${OPENG2P_WORKSPACE}/farmer-registry"
      EXTENSION_DIR="${PRODUCT_REPO}/farmer-extension"
      DB_SEED_DIR="${PRODUCT_REPO}/docker/db-seed"
      UI_DIR="${FARMER_REGISTRY_UI_PATH:-$DEFAULT_UI_DIR}"
      MASTER_DATA_API_PORT="${MASTER_DATA_API_PORT:-8042}"
      # XKM demo pack has core codelists only (no domains/agriculture subtree).
      MASTER_DATA_PACK_DOMAINS="${MASTER_DATA_PACK_DOMAINS:-}"
      LABEL="Farmer Registry"
      ;;
    national-social-registry)
      PRODUCT_REPO="${OPENG2P_WORKSPACE}/national-social-registry"
      EXTENSION_DIR="${PRODUCT_REPO}/nsr-extension"
      DB_SEED_DIR="${PRODUCT_REPO}/docker/db-seed"
      UI_DIR="${NSR_REGISTRY_UI_PATH:-$DEFAULT_UI_DIR}"
      MASTER_DATA_API_PORT="${NSR_MASTER_DATA_API_PORT:-8043}"
      MASTER_DATA_PACK_DOMAINS="${MASTER_DATA_PACK_DOMAINS:-}"
      LABEL="National Social Registry"
      ;;
    *)
      # shellcheck disable=SC1091
      source "$(dirname "${BASH_SOURCE[0]}")/extension-manifest.sh"
      extension_manifest_load "$variant"
      PRODUCT_REPO="${EXTENSION_PRODUCT_REPO_PATH}"
      DB_SEED_DIR="${PRODUCT_REPO}/docker/db-seed"
      UI_DIR="${DEFAULT_UI_DIR}"
      MASTER_DATA_API_PORT="${EXTENSION_MASTER_DATA_API_PORT:-${MASTER_DATA_API_PORT:-8042}}"
      MASTER_DATA_PACK_DOMAINS="${MASTER_DATA_PACK_DOMAINS:-}"
      LABEL="${EXTENSION_LABEL}"
      ;;
  esac

  if [[ "$UI_DIR" != /* ]]; then
    UI_DIR="$(registry_variant_resolve_path "$root" "$UI_DIR")"
  fi

  if [[ ! -d "$UI_DIR" || ! -f "${UI_DIR}/package.json" ]]; then
    if [[ -d "$DEFAULT_UI_DIR" && -f "${DEFAULT_UI_DIR}/package.json" ]]; then
      UI_DIR="$DEFAULT_UI_DIR"
    elif [[ -d "$LEGACY_UI_DIR" && -f "${LEGACY_UI_DIR}/package.json" ]]; then
      UI_DIR="$LEGACY_UI_DIR"
    fi
  fi

  META_DATA_DIR="$(find "${EXTENSION_DIR}/src" -type d -name meta_data 2>/dev/null | head -1 || true)"
  SAMPLE_DATA_DIR="$(find "${EXTENSION_DIR}/src" -type d -name sample_data 2>/dev/null | head -1 || true)"
  AWE_META_DATA_DIR="$(find "${EXTENSION_DIR}/src" -type d -name awe_meta_data 2>/dev/null | head -1 || true)"
}

registry_variant_db_settings() {
  local variant="$1"
  case "$variant" in
    farmer-registry)
      REGISTRY_DB_NAME="${FARMER_REGISTRY_DB:-farmer_registry_db}"
      MASTER_DATA_DB_NAME="${FARMER_MASTER_DATA_DB:-farmer_master_data_db}"
      REGISTRY_STAFF_API_PORT="${FARMER_REGISTRY_STAFF_API_PORT:-8001}"
      ;;
    national-social-registry)
      REGISTRY_DB_NAME="${NSR_REGISTRY_DB:-nsr_registry_db}"
      MASTER_DATA_DB_NAME="${NSR_MASTER_DATA_DB:-nsr_master_data_db}"
      REGISTRY_STAFF_API_PORT="${NSR_REGISTRY_STAFF_API_PORT:-8011}"
      ;;
    *)
      # shellcheck disable=SC1091
      source "$(dirname "${BASH_SOURCE[0]}")/extension-manifest.sh"
      extension_manifest_load "$variant"
      REGISTRY_DB_NAME="${EXTENSION_REGISTRY_DB}"
      MASTER_DATA_DB_NAME="${EXTENSION_MASTER_DATA_DB}"
      REGISTRY_STAFF_API_PORT="${EXTENSION_STAFF_API_PORT}"
      ;;
  esac

  POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
  POSTGRES_PORT="${POSTGRES_PORT:-5432}"
  POSTGRES_SUPERUSER="${POSTGRES_SUPERUSER:-postgres}"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
}

registry_variant_export_psql() {
  export PGHOST="${POSTGRES_HOST}"
  export PGPORT="${POSTGRES_PORT}"
  export PGUSER="${POSTGRES_SUPERUSER}"
  export PGPASSWORD="${POSTGRES_PASSWORD}"
  export PGDATABASE="${REGISTRY_DB_NAME}"
}

registry_variant_run_sql_tree() {
  local dir="$1"
  local label="$2"
  local apply_script
  apply_script="$(dirname "${BASH_SOURCE[0]}")/apply_seed_sql.py"

  if [[ ! -d "$dir" ]]; then
    echo "[seed] No ${label} directory at ${dir}, skipping."
    return 0
  fi

  local sql_files
  sql_files="$(find "$dir" -name '*.sql' -type f | sort)"
  if [[ -z "$sql_files" ]]; then
    echo "[seed] No SQL files in ${dir}, skipping."
    return 0
  fi

  if [[ -d "$DB_SEED_DIR" ]]; then
    registry_variant_ensure_db_seed_venv
  fi

  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/ensure-psycopg2-python.sh"
  local python_bin
  python_bin="$(ensure_psycopg2_python "$(registry_variant_root)")"

  echo "[seed] Applying ${label} from ${dir} ..."
  # lookup-data/ seeds g2p_attributes + g2p_attribute_values, which live in the
  # Master Data database, not the registry database. Everything else in the
  # meta_data tree targets the registry DB.
  registry_variant_export_master_psql
  local rel patched_sql
  while IFS= read -r sql_file; do
    rel="${sql_file#${dir}/}"
    echo "[seed]   -> ${rel}"
    if [[ "$rel" == lookup-data/* ]]; then
      # farmer-registry@1.3 seeds "ON CONFLICT (value_id)", but master-data-service
      # made the g2p_attribute_values primary key the composite
      # (value_id, attribute_id). The INSERT already supplies both columns, so
      # widening the conflict target preserves the intended insert-if-absent
      # semantics. Drop this rewrite once the two repos agree on the key.
      patched_sql="$(mktemp)"
      sed 's/ON CONFLICT (value_id) DO NOTHING/ON CONFLICT (value_id, attribute_id) DO NOTHING/' "$sql_file" > "$patched_sql"
      env PGHOST="$MD_PGHOST" PGPORT="$MD_PGPORT" PGUSER="$MD_PGUSER" PGPASSWORD="$MD_PGPASSWORD" PGDATABASE="$MD_PGDATABASE" "$python_bin" "$apply_script" "$patched_sql"
      rm -f "$patched_sql"
    else
      "$python_bin" "$apply_script" "$sql_file"
    fi
  done <<< "$sql_files"
}

registry_variant_clear_sample_data() {
  local variant="$1"
  local clear_script
  clear_script="$(dirname "${BASH_SOURCE[0]}")/clear_registry_sample_data.py"

  if [[ -d "$DB_SEED_DIR" ]]; then
    registry_variant_ensure_db_seed_venv
  fi

  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/ensure-psycopg2-python.sh"
  local python_bin
  python_bin="$(ensure_psycopg2_python "$(registry_variant_root)")"

  VARIANT="$variant" "$python_bin" "$clear_script"
}

registry_variant_export_master_psql() {
  export MD_PGHOST="${POSTGRES_HOST}"
  export MD_PGPORT="${POSTGRES_PORT}"
  export MD_PGUSER="${POSTGRES_SUPERUSER}"
  export MD_PGPASSWORD="${POSTGRES_PASSWORD}"
  export MD_PGDATABASE="${MASTER_DATA_DB_NAME}"
}

registry_variant_ensure_master_data_geo_schema() {
  local schema_sql
  schema_sql="$(dirname "${BASH_SOURCE[0]}")/../sql/master-data-geo-schema.sql"
  if [[ ! -f "$schema_sql" ]]; then
    echo "[seed] Missing master data geo schema at ${schema_sql}" >&2
    return 1
  fi

  registry_variant_export_master_psql
  echo "[seed] Ensuring master-data geo tables in ${MASTER_DATA_DB_NAME} ..."
  PGHOST="$MD_PGHOST" PGPORT="$MD_PGPORT" PGUSER="$MD_PGUSER" \
    PGPASSWORD="$MD_PGPASSWORD" PGDATABASE="$MD_PGDATABASE" \
    psql -v ON_ERROR_STOP=1 -f "$schema_sql"
}

registry_variant_export_awe_psql() {
  export AWE_PGHOST="${POSTGRES_HOST}"
  export AWE_PGPORT="${POSTGRES_PORT}"
  export AWE_PGUSER="${POSTGRES_SUPERUSER}"
  export AWE_PGPASSWORD="${POSTGRES_PASSWORD}"
  export AWE_PGDATABASE="${AWE_DB_NAME:-awe}"
}

registry_variant_ensure_db_seed_venv() {
  if [[ ! -d "$DB_SEED_DIR" ]]; then
    echo "[seed] No db-seed directory at ${DB_SEED_DIR}." >&2
    return 1
  fi

  if [[ ! -x "${DB_SEED_DIR}/venv/bin/python" ]]; then
    echo "[seed] Installing db-seed Python dependencies ..."
    VARIANT="$VARIANT" bash "$(dirname "${BASH_SOURCE[0]}")/../install-registry-db-seed.sh" "$VARIANT"
    return 0
  fi

  if ! "${DB_SEED_DIR}/venv/bin/python" -c "import psycopg2" >/dev/null 2>&1; then
    echo "[seed] Installing psycopg2 into db-seed venv ..."
    (
      # shellcheck disable=SC1091
      source "${DB_SEED_DIR}/venv/bin/activate"
      pip install 'psycopg2-binary>=2.9.12'
    )
  fi
}

registry_variant_run_db_seed_python() {
  local script_name="$1"
  shift

  registry_variant_ensure_db_seed_venv

  if [[ ! -x "${DB_SEED_DIR}/venv/bin/python" ]]; then
    echo "[seed] db-seed venv missing at ${DB_SEED_DIR}/venv after install." >&2
    return 1
  fi

  if [[ -n "${OPENG2P_DATA_DIR:-}" ]]; then
    local root
    root="$(registry_variant_root)"
    OPENG2P_DATA_DIR="$(registry_variant_resolve_path "$root" "$OPENG2P_DATA_DIR")"
    export OPENG2P_DATA_DIR
  fi

  (
    cd "$DB_SEED_DIR"
    # shellcheck disable=SC1091
    source venv/bin/activate
    "$@"
    python3 "$script_name"
  )
}

registry_variant_seed_awe_meta_data() {
  local variant="$1"

  registry_variant_load_env
  export KEYCLOAK_DEV_USER="${KEYCLOAK_DEV_USER:-staff}"

  if [[ -z "${AWE_META_DATA_DIR:-}" || ! -d "$AWE_META_DATA_DIR" ]]; then
    echo "[seed] No AWE meta-data directory for ${variant}, skipping."
    return 0
  fi

  registry_variant_export_awe_psql

  local sql_files
  sql_files="$(find "$AWE_META_DATA_DIR" -name '*.sql' -type f | sort)"
  local apply_script
  apply_script="$(dirname "${BASH_SOURCE[0]}")/apply_seed_sql.py"
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/ensure-psycopg2-python.sh"
  local python_bin
  python_bin="$(ensure_psycopg2_python "$(registry_variant_root)")"

  if [[ -z "$sql_files" ]]; then
    echo "[seed] No AWE SQL files in ${AWE_META_DATA_DIR}, skipping."
  else
    echo "[seed] Applying AWE meta-data from ${AWE_META_DATA_DIR} ..."
    while IFS= read -r sql_file; do
      echo "[seed]   -> ${sql_file#${AWE_META_DATA_DIR}/}"
      PGHOST="$AWE_PGHOST" PGPORT="$AWE_PGPORT" PGUSER="$AWE_PGUSER" \
        PGPASSWORD="$AWE_PGPASSWORD" PGDATABASE="$AWE_PGDATABASE" \
        "$python_bin" "$apply_script" "$sql_file"
    done <<< "$sql_files"
  fi

  echo "[seed]   -> callback_secret (AWE DB, delete + insert)"
  AWE_CALLBACK_CALLER_SERVICE="${AWE_CALLBACK_CALLER_SERVICE:-registry}"
  export AWE_CALLBACK_CALLER_SERVICE
  bash "$(dirname "${BASH_SOURCE[0]}")/../seed-awe-callback-secret.sh"
}

registry_variant_venv_python() {
  local project_dir="$1"
  if [[ -x "${project_dir}/venv/bin/python" ]]; then
    echo "${project_dir}/venv/bin/python"
  elif [[ -x "${project_dir}/venv/bin/python3" ]]; then
    echo "${project_dir}/venv/bin/python3"
  else
    return 1
  fi
}

registry_variant_ensure_run_ready() {
  local variant="$1"
  local root
  root="$(registry_variant_root)"
  registry_variant_load_env
  registry_variant_paths "$variant"

  local celery_beat_dir="${REGISTRY_ROOT}/celery/openg2p-registry-celery-beat"
  local iam_api_dir="${OPENG2P_WORKSPACE}/iam-service/iam-staff-portal-api"
  local awe_dir="${OPENG2P_WORKSPACE}/awe"
  local master_data_api_dir="${OPENG2P_WORKSPACE}/master-data-service/master-data-api"

  if ! registry_variant_venv_python "$API_DIR" >/dev/null 2>&1 \
    || ! registry_variant_venv_python "$CELERY_DIR" >/dev/null 2>&1 \
    || ! registry_variant_venv_python "$celery_beat_dir" >/dev/null 2>&1; then
    echo "[run] Installing registry API, Celery worker, and Celery beat ..."
    VARIANT="$variant" bash "${root}/scripts/install-registry-extension.sh"
  fi

  if ! registry_variant_venv_python "$iam_api_dir" >/dev/null 2>&1; then
    echo "[run] Installing IAM staff API ..."
    bash "${root}/scripts/install-iam.sh"
  fi

  if ! registry_variant_venv_python "$master_data_api_dir" >/dev/null 2>&1; then
    echo "[run] Installing Master Data API ..."
    bash "${root}/scripts/install-master-data.sh"
  fi

  if [[ ! -d "${awe_dir}/venv" ]]; then
    echo "[run] Installing AWE ..."
    bash "${root}/scripts/install-awe.sh"
  fi

  if [[ -d "$UI_DIR" && ! -x "${UI_DIR}/node_modules/.bin/next" ]]; then
    echo "[run] Installing staff UI npm dependencies ..."
    bash "${root}/scripts/install-registry-ui.sh"
  fi
}
