#!/usr/bin/env bash
# Build a component's images locally from its COSS source checkout, exactly as its CI does (same
# Dockerfiles, same build context, default build args), tagged for the local stack:
#
#   oan/<product>/<role>:local        e.g. oan/farmer-registry/staff-api:local
#
# which is what scripts/gen.py writes into the compose files when OAN_IMAGE_PREFIX=oan and
# OAN_IMAGE_TAG=local (OAN_IMAGE_SOURCE=local, see oan.sh).
#
#   scripts/build.sh farmer                     all roles of a component
#   scripts/build.sh farmer staff-api celery    some roles
#   scripts/build.sh consent-manager            commons services work the same way
#
# Source: oan-workspace/<repo> (cloned from github.com/Centre-for-Open-Societal-Systems `develop` by
# scripts/src.sh). To build from your own checkout instead, point OAN_<ID>_SRC at it
# (OAN_FARMER_SRC=/path/to/farmer-registry; ID = component id upper-cased, '-' -> '_') or
# OAN_SRC_DIR at the folder that holds all of them. An existing checkout is never modified.
set -euo pipefail
export MSYS_NO_PATHCONV=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source scripts/components.sh
# shellcheck disable=SC1091
source scripts/ui.sh

id="${1:-}"; shift || true
[ -n "$id" ] || { echo "usage: build.sh <component> [role...]   components: $(comp_ids)" >&2; exit 1; }
product=$(comp_field "$id" 8)
[ "$product" != - ] || { echo "$id ships no image (nothing to build)" >&2; exit 2; }
roles=$(comp_roles "$id"); [ $# -eq 0 ] || roles="$*"

src=$(scripts/src.sh dir "$id")
[ -d "$src/.git" ] || scripts/src.sh clone "$id"
# Scripts the Dockerfiles copy into Linux images must be LF. A checkout made with Git's Windows
# default (core.autocrlf=true) is CRLF and every entrypoint dies with "no such file or directory".
if crlf=$(git -C "$src" ls-files --eol 2>/dev/null | awk '$1=="i/lf" && $2=="w/crlf" {print $4}' | head -3) && [ -n "$crlf" ]; then
  fail "refusing to build: $src has CRLF working files that are LF in git (e.g. $(head -1 <<<"$crlf"))"
  echo "fix: git -C \"$src\" config core.autocrlf false && git -C \"$src\" rm -rq --cached . && git -C \"$src\" reset -q --hard" >&2
  exit 1
fi
step "Build $id from $src ($(git -C "$src" rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout'))"

for role in $roles; do
  spec=$(comp_dockerfile "$id" "$role") || { warn "$id has no role '$role' (roles: $(comp_roles "$id"))"; continue; }
  df=${spec%%:*}; ctx=${spec#*:}
  [ -f "$src/$df" ] || { note "skip $role: $df not in this checkout"; continue; }
  tag="oan/$product/$role:local"
  note "$tag  ($df, context $ctx)"
  t0=$SECONDS
  # shellcheck disable=SC2086
  docker build ${OAN_BUILD_ARGS:-} -f "$src/$df" -t "$tag" "$src/$ctx"
  ok "$tag $C_DIM($(elapsed $t0))$C_OFF"
done
