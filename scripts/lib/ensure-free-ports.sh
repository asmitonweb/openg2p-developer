#!/usr/bin/env bash
# Ensure host ports for Docker stack are free; rewrite .env when occupied.
# shellcheck shell=bash

_port_listening() {
  local port="$1"
  # Git Bash / MSYS: Windows netstat has no -tln and prints its usage text instead,
  # which the checks below would read as "nothing is listening" — leaving every port
  # looking free and the auto-pick a no-op. Use the Windows syntax there.
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*)
      netstat -ano -p tcp 2>/dev/null         | awk '$1 == "TCP" && $4 == "LISTENING" { print $2 }'         | grep -Eq "(^|[.:])${port}$"
      return $?
      ;;
  esac
  if command -v ss >/dev/null 2>&1; then
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[.:\\*])${port}$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[.:\\*])${port}$"
  else
    ! python3 -c "import socket; s=socket.socket(); s.bind(('0.0.0.0', int('${port}'))); s.close()" 2>/dev/null
  fi
}

# True if some openg2p-* container already publishes this host port.
# docker port lines look like:  9000/tcp -> 0.0.0.0:9000
_port_owned_by_openg2p() {
  local port="$1"
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if docker port "$name" 2>/dev/null | grep -Eq "(0\\.0\\.0\\.0|\\[::\\]|127\\.0\\.0\\.1):${port}$"; then
      return 0
    fi
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^openg2p-' || true)
  return 1
}

# Space-separated list of ports reserved in this ensure pass (avoids MinIO API/console collisions).
RESERVED_PORTS="${RESERVED_PORTS:-}"

_port_reserved() {
  local port="$1"
  [[ " ${RESERVED_PORTS} " == *" ${port} "* ]]
}

_reserve_port() {
  local port="$1"
  RESERVED_PORTS="${RESERVED_PORTS} ${port}"
}

_find_free_port() {
  local start="$1"
  local max_offset="${2:-80}"
  local candidate offset
  for offset in $(seq 0 "$max_offset"); do
    candidate=$((start + offset))
    if _port_reserved "$candidate"; then
      continue
    fi
    if ! _port_listening "$candidate"; then
      echo "$candidate"
      return 0
    fi
    if _port_owned_by_openg2p "$candidate"; then
      echo "$candidate"
      return 0
    fi
  done
  echo "ERROR: could not find a free port near ${start}" >&2
  return 1
}

_env_set_var() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
  export "${key}=${value}"
}

# Usage: ensure_host_port ENV_VAR preferred_port [label]
ensure_host_port() {
  local key="$1"
  local preferred="$2"
  local label="${3:-$key}"
  local current="${!key:-$preferred}"
  local chosen previous

  previous="${!key:-}"

  # Prefer the canonical preferred port whenever it is free (or already ours).
  # Avoids sticky auto-picks (e.g. Farmer UI stuck on 3002 after 3001 was busy once).
  if ! _port_listening "$preferred" || _port_owned_by_openg2p "$preferred"; then
    chosen="$preferred"
  elif ! _port_listening "$current" || _port_owned_by_openg2p "$current"; then
    if _port_reserved "$current" && [[ "$current" != "$preferred" ]]; then
      echo "  Port ${label}: ${current} is reserved for another service — searching ..."
      chosen="$(_find_free_port "$preferred")"
    else
      chosen="$current"
    fi
  else
    echo "  Port ${label}: ${preferred} is busy — searching for a free port ..."
    chosen="$(_find_free_port "$preferred")"
  fi

  _reserve_port "$chosen"

  if [[ "$chosen" != "$previous" ]]; then
    if [[ -n "$previous" && "$chosen" != "$previous" ]]; then
      echo "  Port ${label}: ${previous} → ${chosen}"
    elif [[ -z "$previous" ]]; then
      echo "  Port ${label}: ${chosen}"
    fi
    _env_set_var "${ROOT_DIR}/.env" "$key" "$chosen"
    PORTS_CHANGED=1
  else
    export "${key}=${chosen}"
  fi
}

# Ensure all Docker host ports for the given variant (farmer|nsr|both).
docker_registry_ensure_ports() {
  local variant="${1:-both}"
  PORTS_CHANGED=0
  RESERVED_PORTS=""

  echo "Checking host ports (auto-pick if busy) ..."

  # Keep preferred UI layout stable: hub 3000 / farmer 3001 / nsr 3002.
  # When a preferred port is busy, auto-pick must not steal another UI's preferred port.
  _reserve_port 3000
  _reserve_port 3001
  _reserve_port 3002

  ensure_host_port POSTGRES_PORT "${POSTGRES_PORT:-5433}" "Postgres"
  ensure_host_port REDIS_PORT "${REDIS_PORT:-6379}" "Redis"
  ensure_host_port MINIO_API_PORT "${MINIO_API_PORT:-9000}" "MinIO API"
  ensure_host_port MINIO_CONSOLE_PORT "${MINIO_CONSOLE_PORT:-9001}" "MinIO console"
  ensure_host_port KEYCLOAK_PORT "${KEYCLOAK_PORT:-8080}" "Keycloak"
  ensure_host_port ID_GENERATOR_PORT "${ID_GENERATOR_PORT:-8040}" "ID Generator"
  ensure_host_port MASTER_DATA_API_PORT "${MASTER_DATA_API_PORT:-8042}" "Farmer Master Data"
  ensure_host_port NSR_MASTER_DATA_API_PORT "${NSR_MASTER_DATA_API_PORT:-8043}" "NSR Master Data"
  ensure_host_port IAM_STAFF_PORT "${IAM_STAFF_PORT:-8020}" "IAM"
  ensure_host_port AWE_API_PORT "${AWE_API_PORT:-8030}" "AWE API"
  ensure_host_port AWE_UI_PORT "${AWE_UI_PORT:-8031}" "AWE UI"
  ensure_host_port STAFF_PORTAL_UI_PORT "${STAFF_PORTAL_UI_PORT:-3000}" "Staff Portal hub"

  case "$variant" in
    farmer)
      ensure_host_port FARMER_REGISTRY_STAFF_API_PORT "${FARMER_REGISTRY_STAFF_API_PORT:-8001}" "Farmer API"
      ensure_host_port FARMER_REGISTRY_PARTNER_API_PORT "${FARMER_REGISTRY_PARTNER_API_PORT:-8006}" "Farmer partner"
      ensure_host_port FARMER_REGISTRY_UI_PORT 3001 "Farmer UI"
      # Preserve preferred NSR UI port in .env even when only Farmer is started.
      _env_set_var "${ROOT_DIR}/.env" NSR_REGISTRY_UI_PORT 3002
      export NSR_REGISTRY_UI_PORT=3002
      ;;
    nsr)
      ensure_host_port NSR_REGISTRY_STAFF_API_PORT "${NSR_REGISTRY_STAFF_API_PORT:-8011}" "NSR API"
      ensure_host_port NSR_REGISTRY_PARTNER_API_PORT "${NSR_REGISTRY_PARTNER_API_PORT:-8012}" "NSR partner"
      ensure_host_port NSR_REGISTRY_UI_PORT 3002 "NSR UI"
      _env_set_var "${ROOT_DIR}/.env" FARMER_REGISTRY_UI_PORT 3001
      export FARMER_REGISTRY_UI_PORT=3001
      ;;
    both|*)
      ensure_host_port FARMER_REGISTRY_STAFF_API_PORT "${FARMER_REGISTRY_STAFF_API_PORT:-8001}" "Farmer API"
      ensure_host_port FARMER_REGISTRY_PARTNER_API_PORT "${FARMER_REGISTRY_PARTNER_API_PORT:-8006}" "Farmer partner"
      ensure_host_port FARMER_REGISTRY_UI_PORT 3001 "Farmer UI"
      ensure_host_port NSR_REGISTRY_STAFF_API_PORT "${NSR_REGISTRY_STAFF_API_PORT:-8011}" "NSR API"
      ensure_host_port NSR_REGISTRY_PARTNER_API_PORT "${NSR_REGISTRY_PARTNER_API_PORT:-8012}" "NSR partner"
      ensure_host_port NSR_REGISTRY_UI_PORT 3002 "NSR UI"
      ;;
  esac

  # Keep derived URLs in sync with chosen ports.
  _env_set_var "${ROOT_DIR}/.env" KEYCLOAK_URL "http://localhost:${KEYCLOAK_PORT}"
  _env_set_var "${ROOT_DIR}/.env" MINIO_ENDPOINT "localhost:${MINIO_API_PORT}"

  if [[ "${PORTS_CHANGED}" == "1" ]]; then
    echo "Updated .env with free ports (containers will be recreated)."
  else
    echo "  Preferred ports OK (free or already owned by this stack)."
  fi
}
