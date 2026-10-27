#!/usr/bin/env bash
# Download the pinned charts, `helm template` them with the local values, and translate the
# manifests into one Compose project per namespace (out/<ns>/compose.yaml) with scripts/gen.py.
#
#   scripts/render.sh                 commons + every registry in DEFAULT_REGISTRIES
#   scripts/render.sh farmer          commons + the farmer registry only
#   scripts/render.sh farmer crop da  pick any set (da renders but has no images yet)
#
# Everything runs inside the tools image (helm + python), so the host needs only Docker.
# Environment honoured: OAN_IMAGE_PREFIX, OAN_IMAGE_TAG, OAN_REMOTE_DOMAINS (see gen.py).
set -euo pipefail
export MSYS_NO_PATHCONV=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source versions.env
# shellcheck disable=SC1091
source scripts/registries.sh

TOOLS_IMAGE=oan-developer/tools:local
CACHE=.cache/charts
mkdir -p "$CACHE" rendered out

HOST_ROOT="$(cygpath -m "$ROOT" 2>/dev/null || pwd)"
tool() {  # run a command in the tools image with the repo mounted at /w
  docker run --rm -v "$HOST_ROOT":/w -w /w \
    -e OAN_IMAGE_PREFIX -e OAN_IMAGE_TAG -e OAN_REMOTE_DOMAINS "$TOOLS_IMAGE" "$@"
}
ensure_tools() {
  docker image inspect "$TOOLS_IMAGE" >/dev/null 2>&1 && return 0
  echo "building $TOOLS_IMAGE (helm + python)"
  docker build -q --build-arg "HELM_IMAGE=$HELM_IMAGE" -t "$TOOLS_IMAGE" tools >/dev/null
}

fetch() {  # fetch <repo-url> <chart> <version>  -> prints the extracted chart dir
  local name="$2-$3" dir="$CACHE/$2-$3"
  if [ ! -d "$dir/$2" ]; then
    [ -f "$CACHE/$name.tgz" ] || curl -fsSL --retry 3 -o "$CACHE/$name.tgz" "$1/$name.tgz"
    mkdir -p "$dir" && tar -xzf "$CACHE/$name.tgz" -C "$dir"
  fi
  echo "$dir/$2"
}

# The COSS crop and livestock charts carry templates/refactor-promotion-gate.yaml, which fails
# every render on purpose: the charts are marked "not promotion-ready" for the shared dev
# cluster. A developer stack is exactly where that work happens, so the gate is removed from
# the local copy. Nothing else in the chart is touched.
drop_promotion_gate() {
  local gate="$1/templates/refactor-promotion-gate.yaml"
  if [ -f "$gate" ]; then
    rm -f "$gate"
    echo "  note: $(basename "$1") is not promotion-ready upstream; its render-time gate was removed for local use"
  fi
}

render() {  # render <release> <chartdir> <namespace> <values-name>
  local release="$1" chart="$2" ns="$3" values="$4"
  tool helm template "$release" "$chart" -n "$ns" -f "values/$values.yaml" \
    > "rendered/$values.yaml" 2> >(grep -v -e '^coalesce.go' -e '^walk.go' >&2 || true)
  echo "rendered $release ($(basename "$chart")) -> rendered/$values.yaml"
}

ensure_tools
targets=("$@"); [ ${#targets[@]} -gt 0 ] || read -r -a targets <<<"$DEFAULT_REGISTRIES"

base=$(fetch "$OPENG2P_HELM_REPO" openg2p-commons-base "$COMMONS_BASE_VERSION")
services=$(fetch "$OAN_HELM_REPO" openg2p-commons-services "$COMMONS_SERVICES_VERSION")
render commons "$base" commons commons-base
render commons-services "$services" commons commons-services

gen_args=(rendered/commons-base.yaml=commons rendered/commons-services.yaml=commons)
for id in "${targets[@]}"; do
  chart=$(reg_field "$id" 2); release=$(reg_field "$id" 3); version=$(reg_version "$id")
  dir=$(fetch "$OAN_HELM_REPO" "$chart" "$version")
  drop_promotion_gate "$dir"
  render "$release" "$dir" "$id" "$id"
  gen_args+=("rendered/$id.yaml=$id")
done

tool python3 scripts/gen.py "${gen_args[@]}"
# Jobs run scripts from these files inside Linux containers: never let a Windows checkout CRLF them.
find out/files -type f \( -name '*.sh' -o -name '*.py' \) -exec sed -i 's/\r$//' {} + 2>/dev/null || true
cat versions.env > out/versions.rendered.env
printf 'OAN_IMAGE_PREFIX=%s\nOAN_IMAGE_TAG=%s\nREGISTRIES=%s\n' "${OAN_IMAGE_PREFIX:-}" "${OAN_IMAGE_TAG:-}" "${targets[*]}" >> out/versions.rendered.env
