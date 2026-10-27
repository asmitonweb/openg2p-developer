# The registries a developer can choose. Sourced by the other scripts.
#
#   id      Compose project / "namespace" (matches the Kubernetes namespace on the dev cluster)
#   chart   COSS wrapper chart in oan-helm (its version is <ID>_VERSION in versions.env)
#   release Helm release name; resource names are derived from it (<release>-staff-portal-api, ...)
#   repo    source repository under github.com/Centre-for-Open-Societal-Systems
#   product image path segment used by the charts (<ecr>/<group>/<product>/<role>)
#
# Fields are separated by '|'. Keep the order: scripts print it as the menu.
REGISTRIES=(
  "farmer|openg2p-farmer-registry|farmer-registry|farmer-registry|farmer-registry"
  "crop|openg2p-cropsown-registry|cropsown-registry|cropsown-regsitry|cropsown-registry"
  "live|openg2p-livestock-registry|livestock-registry|livestock-registry|livestock-registry"
  "da|openg2p-da-registry|da-registry|da-registry|da-registry"
)
# Registries that have buildable images today. da-registry is an empty repository and its
# chart ships no images, so it renders but cannot run; ask for it explicitly.
DEFAULT_REGISTRIES="farmer crop live"

reg_field() {  # reg_field <id> <n>   (1=id 2=chart 3=release 4=repo 5=product)
  local r
  for r in "${REGISTRIES[@]}"; do
    [ "${r%%|*}" = "$1" ] && { cut -d'|' -f"$2" <<<"$r"; return 0; }
  done
  echo "unknown registry: $1 (choose from: $(reg_ids))" >&2
  return 1
}
reg_ids() { local r; for r in "${REGISTRIES[@]}"; do printf '%s ' "${r%%|*}"; done; }
reg_version() {  # chart version pinned in versions.env
  local id; id=$(tr '[:lower:]' '[:upper:]' <<<"$1")
  eval "printf '%s' \"\${${id}_VERSION}\""
}
