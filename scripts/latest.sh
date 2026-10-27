#!/usr/bin/env bash
# Rewrite versions.env with the newest published chart of each layer:
#   Commons Base      newest release candidate in github.com/OpenG2P/versions (commons/CHANGELOG.md)
#   Commons Services  newest openg2p-commons-services in the COSS oan-helm repository index
#   registries        newest openg2p-<registry>-registry in the same index
# Nothing is cloned; both sources are read over HTTPS. Review the diff, re-render, test, commit.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source versions.env

latest_rc() {  # first "release candidate" row of a OpenG2P/versions changelog
  curl -fsSL --retry 3 "https://raw.githubusercontent.com/OpenG2P/versions/develop/$1/CHANGELOG.md" \
    | grep -m1 -oE '`[^`]+`\]\([^)]*\) \| [0-9-]+ \| release candidate' | sed -E 's/^`([^`]+)`.*/\1/'
}
index_latest() {  # newest version of a chart in a Helm repo index (semver order as published: first entry)
  awk -v c="  $2:" '$0==c {f=1; next} f && /^  [a-z]/ {exit} f && /^      version:/ {print $2; exit}' "$1"
}

idx=$(mktemp)
curl -fsSL --retry 3 "$OAN_HELM_REPO/index.yaml" -o "$idx"

set_var() {  # set_var NAME value
  [ -n "$2" ] || { echo "could not determine $1; keeping the pin" >&2; return 0; }
  sed -i -E "s/^$1=.*/$1=$2/" versions.env
  echo "$1=$2"
}
set_var COMMONS_BASE_VERSION "$(latest_rc commons)"
set_var COMMONS_SERVICES_VERSION "$(index_latest "$idx" openg2p-commons-services)"
set_var FARMER_VERSION "$(index_latest "$idx" openg2p-farmer-registry)"
set_var CROP_VERSION "$(index_latest "$idx" openg2p-cropsown-registry)"
set_var LIVE_VERSION "$(index_latest "$idx" openg2p-livestock-registry)"
set_var DA_VERSION "$(index_latest "$idx" openg2p-da-registry)"
rm -f "$idx"
echo "versions.env updated; review with: git diff versions.env"
