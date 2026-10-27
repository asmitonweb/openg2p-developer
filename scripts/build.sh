#!/usr/bin/env bash
# Build a registry's images locally from its COSS source repository, exactly as its CI does
# (same Dockerfiles, same build context, default build args), tagged for the local stack:
#
#   oan/<product>/<role>:local        e.g. oan/farmer-registry/staff-api:local
#
# which is what scripts/gen.py writes into the compose files when OAN_IMAGE_PREFIX=oan and
# OAN_IMAGE_TAG=local (the default image source, see oan.sh).
#
#   scripts/build.sh farmer                     all roles
#   scripts/build.sh farmer staff-api celery    some roles
#
# Source: src/<repo> (cloned from github.com/Centre-for-Open-Societal-Systems on first use,
# branch OAN_SRC_REF, default develop). To build from your own checkout instead, point
# OAN_<ID>_SRC at it (OAN_FARMER_SRC=/path/to/farmer-registry) or OAN_SRC_DIR at the folder
# that holds all of them. An existing checkout is never modified or updated by this script.
set -euo pipefail
export MSYS_NO_PATHCONV=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source scripts/registries.sh

id="${1:-}"; shift || true
[ -n "$id" ] || { echo "usage: build.sh <$(reg_ids | sed 's/ $//; s/ /|/g')> [role...]" >&2; exit 1; }
repo=$(reg_field "$id" 4); product=$(reg_field "$id" 5)
ORG=https://github.com/Centre-for-Open-Societal-Systems

# Dockerfile layout per registry (from each repo's CI). Context is always the repo root.
case "$id" in
  farmer) roles="staff-api partner-api celery db-seed staff-ui"; dockerfile() { echo "docker/oan/$1.Dockerfile"; } ;;
  crop|live) roles="staff-api partner-api celery db-seed staff-ui"; dockerfile() { echo "docker/$1/Dockerfile"; } ;;
  da) echo "da-registry has no Dockerfiles yet (the repository is an empty stub); nothing to build" >&2; exit 2 ;;
esac
[ $# -eq 0 ] || roles="$*"

var="OAN_$(tr '[:lower:]' '[:upper:]' <<<"$id")_SRC"
src="${!var:-${OAN_SRC_DIR:-src}/$repo}"
if [ ! -d "$src" ]; then
  echo "cloning $ORG/$repo (${OAN_SRC_REF:-develop}) into $src"
  git clone -q --branch "${OAN_SRC_REF:-develop}" "$ORG/$repo.git" "$src"
fi
echo "building $id from $src ($(git -C "$src" rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout'))"

for role in $roles; do
  df=$(dockerfile "$role")
  [ -f "$src/$df" ] || { echo "  skip  $role: $df not in this checkout"; continue; }
  tag="oan/$product/$role:local"
  echo "  build $tag  ($df)"
  # shellcheck disable=SC2086
  docker build ${OAN_BUILD_ARGS:-} -f "$src/$df" -t "$tag" "$src"
done
