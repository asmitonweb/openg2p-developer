#!/usr/bin/env bash
# OAN developer stack: Commons Base + Commons Services + one registry, on Docker Compose,
# rendered from the same Helm charts that run on the shared dev cluster.
#
#   ./oan.sh up <farmer|crop|live|da>     one command: tools image, render, images, start
#   ./oan.sh pull <registry>              fetch the newest published images (latest moved on GHCR)
#   ./oan.sh build <registry> [role...]   (re)build the registry's images from source (src/<repo>)
#   ./oan.sh render [registry...]         re-render the compose projects from the pinned charts
#   ./oan.sh stop <registry|all>          stop containers; data volumes are kept
#   ./oan.sh down                         remove all containers of the stack; volumes are kept
#   ./oan.sh rerun <job>                  run a finished job again, e.g. farmer-registry-db-seed
#   ./oan.sh ps | ram | logs <service>    status, memory per project, follow a container's logs
#   ./oan.sh versions                     refresh versions.env from the published indexes
#   ./oan.sh urls                         browser URLs and seeded users
#
# Image source (where the registry images come from), via OAN_IMAGE_SOURCE in .env or the shell:
#   ghcr   (default) pull ghcr.io/asmitonweb/<product>/<role>:latest (built from COSS develop);
#          an image that cannot be pulled yet is built from source and tagged with that name
#   local  always build from the COSS source repositories with scripts/build.sh (oan/…:local)
set -euo pipefail
export MSYS_NO_PATHCONV=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
[ -f .env ] && set -a && . ./.env && set +a
# shellcheck disable=SC1091
source scripts/registries.sh

# OAN images are tracked by a floating tag (latest), unlike the version-pinned OpenG2P images.
: "${OAN_IMAGE_SOURCE:=ghcr}"
case "$OAN_IMAGE_SOURCE" in
  local) export OAN_IMAGE_PREFIX=oan OAN_IMAGE_TAG=local ;;
  # Published from the asmitonweb forks (mirrors of COSS develop) because org packages can only
  # be made public by repository admins; move the prefix to the organisation when that changes.
  ghcr)  export OAN_IMAGE_PREFIX="${OAN_IMAGE_PREFIX:-ghcr.io/asmitonweb}" OAN_IMAGE_TAG="${OAN_IMAGE_TAG:-latest}" ;;
  *) echo "OAN_IMAGE_SOURCE must be ghcr or local" >&2; exit 1 ;;
esac

# Every Helm subchart is a Compose profile; without this, `compose config` sees only profile-less services.
export COMPOSE_PROFILES='*'

need() { command -v "$1" >/dev/null 2>&1 || { echo "$1 is required" >&2; exit 1; }; }
need docker; need git; need curl
docker info >/dev/null 2>&1 || { echo "Docker is not running" >&2; exit 1; }

rendered_for() {  # is out/ current for this registry and image source?
  [ -f out/versions.rendered.env ] && [ -f "out/$1/compose.yaml" ] || return 1
  grep -qx "OAN_IMAGE_PREFIX=$OAN_IMAGE_PREFIX" out/versions.rendered.env || return 1
  # a change to versions.env, values or images.yaml re-renders
  local newest
  newest=$(ls -t versions.env images.yaml values/*.yaml scripts/gen.py | head -1)
  [ ! "$newest" -nt out/versions.rendered.env ]
}
images_of() {  # images of a project that come from this stack's registry remap
  docker compose -f "out/$1/compose.yaml" config --images 2>/dev/null | grep -E "^$OAN_IMAGE_PREFIX/" | sort -u
}
ensure_images() {
  local id="$1" img missing=()
  while read -r img; do docker image inspect "$img" >/dev/null 2>&1 || missing+=("$img"); done < <(images_of "$id")
  [ ${#missing[@]} -gt 0 ] || return 0
  if [ "$OAN_IMAGE_SOURCE" = local ]; then
    echo "images to build: ${missing[*]}"
    scripts/build.sh "$id"
    return 0
  fi
  local unpulled=() product
  for img in "${missing[@]}"; do
    echo "pulling $img"
    docker pull -q "$img" >/dev/null 2>&1 || unpulled+=("$img")
  done
  [ ${#unpulled[@]} -gt 0 ] || return 0
  # Not published (yet): build the registry from source and give the builds the published names,
  # so the rendered compose files stay the same and a later `docker pull` replaces them.
  echo "not on GHCR yet: ${unpulled[*]}"
  echo "building from source instead (OAN_IMAGE_SOURCE=local does this always)"
  scripts/build.sh "$id"
  product=$(reg_field "$id" 5)
  for img in "${unpulled[@]}"; do
    role=${img##*/}; role=${role%%:*}
    docker tag "oan/$product/$role:local" "$img"
  done
}

urls() {
  local id="${1:-}"
  echo "Commons:"
  echo "  Staff portal      http://staff-portal.openg2p.localtest.me"
  echo "  Keycloak          http://keycloak.openg2p.localtest.me  (admin password: state/secrets.json -> commons/commons-keycloak)"
  echo "  Master Data UI    http://master-data-ui.openg2p.localtest.me"
  echo "  AWE               http://awe.openg2p.localtest.me"
  echo "  Postgres          127.0.0.1:5433 (user postgres, password: state/secrets.json -> commons/commons-postgresql)"
  [ -f out/REPORT.md ] && { echo "All gateway hosts: out/REPORT.md"; }
  echo "Registry UIs: http://<registryHostname> from values/<registry>.yaml, e.g. http://farmer-registry.openg2p.localtest.me"
  echo "Seeded staff users and passwords: out/files/*keycloak-init*/config/clients.yaml"
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  up)
    id="${1:-}"; [ -n "$id" ] || { echo "usage: ./oan.sh up <$(reg_ids | sed 's/ $//; s/ /|/g')>" >&2; exit 1; }
    reg_field "$id" 1 >/dev/null
    rendered_for "$id" || scripts/render.sh ${OAN_RENDER_ALL:+$DEFAULT_REGISTRIES} ${OAN_RENDER_ALL:-"$id"}
    [ -f "out/$id/compose.yaml" ] || { echo "the $(reg_field "$id" 2) chart renders no workloads yet (every component is disabled upstream): nothing to start for '$id'. See docs/registries.md." >&2; exit 2; }
    ensure_images "$id"
    scripts/stack.sh up "$id"
    echo; urls "$id" ;;
  build) scripts/build.sh "$@" ;;
  pull)
    id="${1:-}"; [ -n "$id" ] || { echo "usage: ./oan.sh pull <registry>" >&2; exit 1; }
    [ -f "out/$id/compose.yaml" ] || { echo "render first: ./oan.sh render $id" >&2; exit 1; }
    while read -r img; do docker pull "$img"; done < <(images_of "$id")
    echo "restart to use them: ./oan.sh up $id" ;;
  render) scripts/render.sh "$@" ;;
  stop|down|rerun|ps|ram|create) scripts/stack.sh "$cmd" "$@" ;;
  logs) docker logs -f --tail 200 "$@" ;;
  versions) scripts/latest.sh ;;
  urls) urls ;;
  *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
