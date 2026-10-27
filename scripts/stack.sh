#!/usr/bin/env bash
# Start and stop parts of the generated stack in Helm release order. Each Kubernetes
# namespace is its own Compose project (out/<ns>/compose.yaml): commons, then one project per
# registry (farmer, crop, live, da). Usually called through ./oan.sh.
#
#   scripts/stack.sh up farmer          commons core + commons services + the farmer registry
#   scripts/stack.sh up esignet         any profile from out/REPORT.md, or a service name
#   scripts/stack.sh stop farmer        stop the farmer project (commons keeps running)
#   scripts/stack.sh stop all           stop everything; volumes are always kept
#   scripts/stack.sh rerun <job>...     run a finished job again (e.g. farmer-registry-db-seed)
#   scripts/stack.sh ps | ram | down    status / memory per project / remove containers (volumes kept)
#
# On Kubernetes, Helm installs commons, then commons-services, then the registry, and the
# keycloak-init jobs of later releases find the realm admin the first one created. Compose has
# no release boundary, so `up` replays that order explicitly:
#   1. infrastructure   2. postgres-init jobs   3. the base keycloak-init job
#   4. the remaining keycloak-init jobs   5. the requested apps and their jobs
# Jobs that already exited 0 are not re-run; use `rerun` for that.
set -euo pipefail
export MSYS_NO_PATHCONV=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source scripts/registries.sh
export COMPOSE_PROFILES='*'
NETWORK=openg2p
TSV=out/services.tsv  # namespace, profile, service, kind
[ -f "$TSV" ] || { echo "out/services.tsv missing: run ./oan.sh render first" >&2; exit 1; }

# Profiles (Helm subcharts) of the commons project. INFRA starts before any job runs.
INFRA="postgresql redis redis-auth keycloak minio kafka softhsm"
CORE="postgresql redis keycloak minio"
COMMONS="$CORE iam-service master-data awe staff-portal-ui commons-services"
LONG='statefulset|deployment|forwarder'

namespaces() { cut -f1 "$TSV" | sort -u; }
is_ns() { namespaces | grep -qx -- "$1"; }
dc() {  # dc <ns> <compose args...>: the generated file plus the hand-kept override, if any
  local ns="$1"; shift
  local files=(-f "out/$ns/compose.yaml")
  [ -f "overrides/$ns.yaml" ] && files+=(-f "overrides/$ns.yaml")
  docker compose "${files[@]}" "$@"
}
by_ns() {  # by_ns <compose verb + flags...> -- <service...>: run per owning project
  local args=() ns svc
  while [ "$1" != "--" ]; do args+=("$1"); shift; done; shift
  [ $# -gt 0 ] || return 0
  for ns in $(namespaces); do
    mapfile -t svc < <(printf '%s\n' "$@" | awk -F'\t' -v ns="$ns" 'NR==FNR {want[$1]; next} $1==ns && ($3 in want) {print $3}' - "$TSV" | sort -u)
    [ ${#svc[@]} -eq 0 ] || dc "$ns" "${args[@]}" "${svc[@]}"
  done
}

# A selection is a list of "<ns><TAB><profile>" lines. Targets: a registry id (commons + its
# whole project), core, commons, all, a profile name, or a service name (stands for its profile).
expand() {
  local t p
  for t in "$@"; do
    case "$t" in
      core) for p in $CORE; do printf 'commons\t%s\n' "$p"; done ;;
      commons) for p in $COMMONS; do printf 'commons\t%s\n' "$p"; done ;;
      all) awk -F'\t' '$2!="-" {print $1"\t"$2}' "$TSV" ;;
      *) if [ "$t" != commons ] && is_ns "$t"; then
           expand commons; awk -F'\t' -v ns="$t" '$1==ns && $2!="-" {print $1"\t"$2}' "$TSV"
         elif awk -F'\t' -v t="$t" '$2==t {f=1} END {exit !f}' "$TSV"; then
           awk -F'\t' -v t="$t" '$2==t {print $1"\t"$2}' "$TSV"
         else
           p=$(awk -F'\t' -v s="$t" '$3==s && $2!="-" {print $1"\t"$2; exit}' "$TSV")
           [ -n "$p" ] || { echo "unknown registry, profile or service: $t (registries: $(reg_ids))" >&2; exit 1; }
           printf '%s\n' "$p"
         fi ;;
    esac
  done | awk '!seen[$0]++'
}
project_only() {  # a registry's own project, without commons (for stop)
  awk -F'\t' -v ns="$1" '$1==ns && $2!="-" {print $1"\t"$2}' "$TSV" | awk '!seen[$0]++'
}

# services <kinds-regex> <selection>: service names of the selected (ns, profile) pairs
services() {
  local kinds="$1" sel="$2"
  [ -n "$sel" ] || return 0
  awk -F'\t' -v k="^($kinds)$" 'NR==FNR {want[$1 FS $2]; next} (($1 FS $2) in want) && $4 ~ k {print $3}' <(printf '%s\n' "$sel") "$TSV"
}
ns_jobs() {  # ns_jobs <profile> <namespaces...>: that profile's jobs in the given projects
  local profile="$1"; shift
  local ns
  for ns in "$@"; do awk -F'\t' -v ns="$ns" -v p="$profile" '$1==ns && $2==p && $4=="job" {print $3}' "$TSV"; done
}

state() { docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$1" 2>/dev/null || echo "missing -"; }
pending() {  # drop jobs that already completed successfully
  local j
  for j in "$@"; do [ "$(state "$j")" = "exited 0" ] || echo "$j"; done
}
wait_jobs() {  # poll until each job exited 0, or stayed failed after its retries
  local j s deadline=$((SECONDS + ${JOB_TIMEOUT:-900})) failed=0
  for j in "$@"; do
    while :; do
      s=$(state "$j")
      case "$s" in
        "exited 0") echo "  ok    $j"; break ;;
        exited*)
          sleep 3
          if [ "$(state "$j")" = "$s" ]; then echo "  FAIL  $j (${s#exited }): docker logs $j"; failed=1; break; fi ;;
        *) [ $SECONDS -lt $deadline ] || { echo "  TIMEOUT $j"; failed=1; break; }
           sleep 2 ;;
      esac
    done
  done
  return $failed
}
run_jobs() {  # $1 = label; rest = jobs
  local label="$1"; shift
  local todo
  mapfile -t todo < <(pending "$@")
  [ ${#todo[@]} -gt 0 ] || return 0
  echo "$label: ${#todo[@]} job(s)"
  by_ns up -d -- "${todo[@]}"
  wait_jobs "${todo[@]}"
}
prepare() {
  docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null
}

up() {
  local sel infra apps ns_list svc
  sel=$(expand core "$@") || exit 1  # every app needs postgres + keycloak
  infra=$(awk -F'\t' -v i=" $INFRA " '$1=="commons" && index(i, " "$2" ")' <<<"$sel")
  apps=$(awk -F'\t' -v i=" $INFRA " '!($1=="commons" && index(i, " "$2" "))' <<<"$sel")
  mapfile -t ns_list < <(cut -f1 <<<"$sel" | sort -u)
  prepare

  # Databases first: Keycloak needs the database the postgres-init job creates, and MinIO's init
  # container waits for Keycloak, so `up -d` on all of them at once would never return.
  local dbs="postgresql redis redis-auth"
  echo "infrastructure: $(cut -f2 <<<"$infra" | tr '\n' ' ')+ gateway"
  mapfile -t svc < <(services "$LONG" "$(awk -F'\t' -v i=" $dbs " 'index(i, " "$2" ")' <<<"$infra")")
  by_ns up -d -- gateway "${svc[@]}"
  # its conf is a bind-mounted file: a re-render changes it without recreating the container
  docker exec gateway nginx -s reload >/dev/null 2>&1 || true

  mapfile -t svc < <(ns_jobs postgres-init "${ns_list[@]}")
  run_jobs "postgres-init" "${svc[@]}"
  mapfile -t svc < <(services "$LONG" "$(awk -F'\t' -v i=" $dbs " '!index(i, " "$2" ")' <<<"$infra")")
  [ ${#svc[@]} -eq 0 ] || by_ns up -d -- "${svc[@]}"
  mapfile -t svc < <(ns_jobs keycloak-init "${ns_list[@]}" | grep '^commons-keycloak-init-' || true)
  run_jobs "keycloak-init (base realm + admin)" "${svc[@]}"
  mapfile -t svc < <(ns_jobs keycloak-init "${ns_list[@]}" | grep -v '^commons-keycloak-init-' || true)
  run_jobs "keycloak-init (services)" "${svc[@]}"

  [ -n "$apps" ] || return 0
  local long jobs
  mapfile -t long < <(services "$LONG" "$apps")
  mapfile -t jobs < <(pending $(services job "$apps" | grep -vE '^(commons-keycloak-init-|.*-(pg|postgres)-init|.*-kc-init)' || true))
  echo "apps: $(cut -f2 <<<"$apps" | sort -u | tr '\n' ' ')"
  by_ns up -d -- "${long[@]}" "${jobs[@]}"
  [ ${#jobs[@]} -eq 0 ] || { echo "app jobs:"; wait_jobs "${jobs[@]}" || true; }
}

stop() {
  local sel="" t svc
  for t in "$@"; do
    if [ "$t" != commons ] && is_ns "$t"; then sel+=$(project_only "$t")$'\n'; else sel+=$(expand "$t")$'\n'; fi
  done
  mapfile -t svc < <(services "$LONG" "$sel")
  [ ${#svc[@]} -gt 0 ] && by_ns stop -- "${svc[@]}"
}

ram() {
  local ns ids
  for ns in $(namespaces); do
    ids=$(docker ps -q --filter "label=com.docker.compose.project=$ns")
    [ -n "$ids" ] || { echo "$ns: not running"; continue; }
    docker stats --no-stream --format '{{.MemUsage}}\t{{.Name}}' $ids | sort -h -r \
      | awk -F'\t' -v ns="$ns" '{split($1,a," "); v=a[1]; m=v+0
          if (v ~ /GiB/) m*=1024; else if (v ~ /KiB/) m/=1024; t+=m
          if (NR <= 5) printf "  %8.0f MiB  %s\n", m, $2}
          END {printf "%s: %.0f MiB across %d containers\n", ns, t, NR}'
  done
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  up) [ $# -gt 0 ] || { echo "usage: stack.sh up <$(reg_ids | sed 's/ $//; s/ /|/g')|commons|profile|service>..." >&2; exit 1; }; up "$@" ;;
  stop) [ $# -gt 0 ] || set -- all; stop "$@" ;;
  rerun) by_ns up -d --force-recreate --no-deps -- "$@"; wait_jobs "$@" ;;
  create) prepare; for ns in $(namespaces); do dc "$ns" create; done ;;
  ps) for ns in $(namespaces); do echo "== $ns"; dc "$ns" ps -a --format 'table {{.Name}}\t{{.Status}}'; done ;;
  ram) ram ;;
  down) for ns in $(namespaces | sort -r); do dc "$ns" down; done ;;
  *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
