#!/usr/bin/env bash
# Download the pinned charts, `helm template` them with the local values, and translate the
# manifests into one Compose project per namespace (out/<ns>/compose.yaml) with scripts/gen.py.
#
#   scripts/render.sh                       the current selection (OAN_COMPONENTS in .env, else farmer)
#   scripts/render.sh farmer                commons + the farmer registry
#   scripts/render.sh farmer farmer-dashboard aggregation-api
#                                           components pull in what they require (see scripts/components.sh)
#
# What a component does to the render:
#   registry  its chart becomes the project out/<id>
#   service   a `--set` on the commons-services chart (the service is part of that chart)
#   feature   a `--set` on its registry's chart
#   addon     its own chart, rendered into its registry's project
# Everything runs inside the tools image (helm + python), so the host needs only Docker.
# Environment honoured: OAN_IMAGE_PREFIX, OAN_IMAGE_TAG, OAN_REMOTE_DOMAINS (see gen.py).
set -euo pipefail
export MSYS_NO_PATHCONV=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source scripts/env.sh
# shellcheck disable=SC1091
source versions.env
# shellcheck disable=SC1091
source scripts/components.sh
# shellcheck disable=SC1091
source scripts/ui.sh

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
  note "building $TOOLS_IMAGE (helm + python)"
  docker build -q --build-arg "HELM_IMAGE=$HELM_IMAGE" -t "$TOOLS_IMAGE" tools >/dev/null
}

fetch() {  # fetch <repo-url> <chart> <version>  -> prints the extracted chart dir
  local name="$2-$3" dir="$CACHE/$2-$3"
  if [ ! -d "$dir/$2" ]; then
    [ -f "$CACHE/$name.tgz" ] || { curl -fsSL --retry 3 -o "$CACHE/$name.tgz.part" "$1/$name.tgz" && mv "$CACHE/$name.tgz.part" "$CACHE/$name.tgz"; }
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
    note "$(basename "$1") is not promotion-ready upstream; its render-time gate was removed for local use"
  fi
}

# sets_for <chart> <ns> <targets...>: --set flags of the selected service/feature components
# that live in that chart (field 5) and namespace
sets_for() {
  local chart="$1" ns="$2"; shift 2
  local id kind set
  for id in "$@"; do
    kind=$(comp_kind "$id")
    [ "$kind" = service ] || [ "$kind" = feature ] || continue
    [ "$(comp_field "$id" 5)" = "$chart" ] && [ "$(comp_field "$id" 6)" = "$ns" ] || continue
    set=$(comp_field "$id" 11); [ "$set" != - ] || continue
    printf -- '--set %s ' "${set//,/ --set }"
  done
}

render() {  # render <release> <chartdir> <namespace> <values-name> [helm flags...]
  local release="$1" chart="$2" ns="$3" values="$4"; shift 4
  # shellcheck disable=SC2068
  tool helm template "$release" "$chart" -n "$ns" -f "values/$values.yaml" $@ \
    > "rendered/$values.yaml" 2> >(grep -v -e '^coalesce.go' -e '^walk.go' >&2 || true)
  ok "$release ($(basename "$chart"))${*:+ $*} -> rendered/$values.yaml"
}

if [ $# -gt 0 ]; then mapfile -t targets < <(comp_closure "$@"); else mapfile -t targets < <(comp_closure $(selected_components)); fi
step "Render: ${targets[*]}"
# rendered/ and out/ are rewritten in place: two renders at once corrupt them
LOCK="$ROOT/.cache/render.lock"
mkdir -p "$ROOT/.cache"
mkdir "$LOCK" 2>/dev/null || { fail "another render is running (if not, remove $LOCK)"; exit 1; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
ensure_tools

base=$(fetch "$OPENG2P_HELM_REPO" openg2p-commons-base "$COMMONS_BASE_VERSION")
services=$(fetch "$OAN_HELM_REPO" openg2p-commons-services "$COMMONS_SERVICES_VERSION")
render commons "$base" commons commons-base
# shellcheck disable=SC2046
render commons-services "$services" commons commons-services $(sets_for openg2p-commons-services commons "${targets[@]}")

gen_args=(rendered/commons-base.yaml=commons rendered/commons-services.yaml=commons)
for id in "${targets[@]}"; do
  case "$(comp_kind "$id")" in
    registry)
      chart=$(comp_field "$id" 3); release=$(comp_field "$id" 5); version=$(comp_version "$id")
      dir=$(fetch "$OAN_HELM_REPO" "$chart" "$version")
      drop_promotion_gate "$dir"
      # shellcheck disable=SC2046
      render "$release" "$dir" "$id" "$id" $(sets_for "$chart" "$id" "${targets[@]}")
      gen_args+=("rendered/$id.yaml=$id") ;;
    addon)
      chart=$(comp_field "$id" 3); release=$(comp_field "$id" 5); ns=$(comp_field "$id" 6); version=$(comp_version "$id")
      dir=$(fetch "$OAN_HELM_REPO" "$chart" "$version")
      render "$release" "$dir" "$ns" "$id"
      gen_args+=("rendered/$id.yaml=$ns") ;;
  esac
done

# extras/<component>.yaml: plain Kubernetes objects a component's chart expects to be provisioned
# outside the chart (catalogue ConfigMaps, Secrets), handed to gen.py in the component's namespace.
for id in "${targets[@]}"; do
  [ -f "extras/$id.yaml" ] && gen_args+=("extras/$id.yaml=$(comp_field "$id" 6)")
done

tool python3 scripts/gen.py "${gen_args[@]}"
# Jobs run scripts from these files inside Linux containers: never let a Windows checkout CRLF them.
find out/files -type f \( -name '*.sh' -o -name '*.py' \) -exec sed -i 's/\r$//' {} + 2>/dev/null || true
cat versions.env > out/versions.rendered.env
printf 'OAN_IMAGE_PREFIX=%s\nOAN_IMAGE_TAG=%s\nCOMPONENTS=%s\n' "${OAN_IMAGE_PREFIX:-}" "${OAN_IMAGE_TAG:-}" "$(printf '%s\n' "${targets[@]}" | sort | tr '\n' ' ')" >> out/versions.rendered.env
