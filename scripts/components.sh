# The catalogue of everything a developer can select, run and change. Sourced by the scripts.
#
# One line per component, fields separated by '|':
#   1 id        name used on the command line (./oan.sh up <id>, dev <id>, src ... <id>)
#   2 kind      registry   its own Compose project (namespace <id>) from an oan-helm registry chart
#               service    part of the commons-services chart, switched on by a Helm value
#               feature    part of a registry chart, switched on by a Helm value (needs that registry)
#               addon      its own oan-helm chart rendered into a registry's project
#   3 chart     oan-helm chart (registry, addon) or '-' (lives in another component's chart)
#   4 version   variable in versions.env holding the chart version, or '-'
#   5 release   Helm release name (resource names derive from it); for service/feature: the chart it belongs to
#   6 ns        Compose project / Kubernetes namespace
#   7 repo      source repository under github.com/Centre-for-Open-Societal-Systems (the COSS spelling)
#   8 product   image path segment: <prefix>/<product>/<role>; '-' when the component ships no image
#   9 dockerfile default path of a role's Dockerfile in the repository, with {role}, optionally
#               ':<context>' (build context folder; default the repository root)
#  10 roles     image roles (space separated); a role may carry its own path as
#               role=<dockerfile>[:<context>]. The services that run a role are found in the compose file
#               Sources all live on the COSS `develop` branch (main is an empty stub in most repositories)
#  11 set       Helm values that switch the component on, as key=value (comma separated) for the chart in field 5
#  12 requires  components that must be selected with it (space separated) or '-'
#  13 title     one line shown in the menu
#
# Keep registries first: the menu prints the file order.
COMPONENTS=(
  "farmer|registry|openg2p-farmer-registry|FARMER_VERSION|farmer-registry|farmer|farmer-registry|farmer-registry|docker/oan/{role}.Dockerfile|staff-api partner-api celery db-seed staff-ui|-|-|Farmer registry"
  "crop|registry|openg2p-cropsown-registry|CROP_VERSION|cropsown-registry|crop|cropsown-regsitry|cropsown-registry|docker/{role}/Dockerfile|staff-api partner-api celery db-seed staff-ui|-|-|Crop sown registry"
  "live|registry|openg2p-livestock-registry|LIVE_VERSION|livestock-registry|live|livestock-registry|livestock-registry|docker/{role}/Dockerfile|staff-api partner-api celery db-seed staff-ui|-|-|Livestock registry"
  "da|registry|openg2p-da-registry|DA_VERSION|da-registry|da|da-registry|-|-|-|-|-|DA registry (empty stub upstream: renders nothing yet)"
  "consent-manager|service|-|-|openg2p-commons-services|commons|consent-management|commons|docker/{role}/Dockerfile|consent-manager-api consent-manager-sanity consent-manager-ui=ui/Dockerfile:ui|-|-|Consent Manager (OAN build; always part of commons)"
  "aggregation-api|service|-|-|openg2p-commons-services|commons|oan-aggregation-api|commons|deploy/Dockerfile|aggregation-api|aggregationApi.enabled=true|consent-manager|Aggregation layer over the OAN services"
  "consent-partner-portal|service|-|-|openg2p-commons-services|commons|consent-management|commons|partner-portal/Dockerfile:partner-portal|consent-partner-portal|consentPartnerPortal.enabled=true|consent-manager|Consent partner portal"
  "farmer-dashboard-api|feature|-|-|openg2p-farmer-registry|farmer|farmer-registry-dashboard-api|farmer-registry|Dockerfile|dashboard-api|dashboardApi.enabled=true|farmer|Farmer dashboard API (reads the registry database)"
  "farmer-dashboard|addon|farmer-registry-dashboard|FARMER_DASHBOARD_VERSION|farmer-registry-dashboard|farmer|oan_farmerregistry_dashboard|farmer-registry|Dockerfile|dashboard|-|farmer-dashboard-api|Farmer dashboard (Next.js)"
  "crop-dashboard-api|feature|-|-|openg2p-cropsown-registry|crop|cropsown-registry-dashboard-api|cropsown-registry|Dockerfile|dashboard-api|dashboardApi.enabled=true|crop|Crop sown dashboard API"
  "crop-dashboard|addon|cropsown-registry-dashboard|CROP_DASHBOARD_VERSION|cropsown-registry-dashboard|crop|oan_cropsown_dashboard|cropsown-registry|Dockerfile|dashboard|-|crop-dashboard-api|Crop sown dashboard (Next.js)"
  "live-dashboard-api|feature|-|-|openg2p-livestock-registry|live|livestock-registry-dashbaord-api|livestock-registry|Dockerfile|dashboard-api|dashboardApi.enabled=true|live|Livestock dashboard API"
  "live-dashboard|addon|livestock-registry-dashboard|LIVE_DASHBOARD_VERSION|livestock-registry-dashboard|live|oan_livestock_dashboard|livestock-registry|Dockerfile|dashboard|-|live-dashboard-api|Livestock dashboard (Next.js)"
)
# What `./oan.sh up` starts when nothing is selected yet.
DEFAULT_COMPONENTS="farmer"

comp_field() {  # comp_field <id> <n>
  local r
  for r in "${COMPONENTS[@]}"; do
    [ "${r%%|*}" = "$1" ] && { cut -d'|' -f"$2" <<<"$r"; return 0; }
  done
  echo "unknown component: $1 (choose from: $(comp_ids))" >&2
  return 1
}
comp_ids() { local r; for r in "${COMPONENTS[@]}"; do printf '%s ' "${r%%|*}"; done; }
comp_kind() { comp_field "$1" 2; }
comp_by_kind() { local r; for r in "${COMPONENTS[@]}"; do [ "$(cut -d'|' -f2 <<<"$r")" = "$1" ] && printf '%s ' "${r%%|*}"; done; }
comp_version() {  # chart version pinned in versions.env
  local var; var=$(comp_field "$1" 4); [ "$var" != - ] || return 0
  eval "printf '%s' \"\${$var}\""
}
# comp_closure <id>...: the ids plus everything they require, in dependency order, unique
comp_closure() {
  local id req
  for id in "$@"; do
    req=$(comp_field "$id" 12) || return 1
    [ "$req" = - ] || comp_closure $req
    echo "$id"
  done | awk '!seen[$0]++'
}
# comp_for_image <product> <role>: the component that builds that image, or nothing
comp_for_image() {
  local r spec
  for r in "${COMPONENTS[@]}"; do
    [ "$(cut -d'|' -f8 <<<"$r")" = "$1" ] || continue
    for spec in $(cut -d'|' -f10 <<<"$r"); do
      [ "${spec%%=*}" = "$2" ] && { printf '%s' "${r%%|*}"; return 0; }
    done
  done
  return 1
}
comp_roles() { local spec; for spec in $(comp_field "$1" 10); do printf '%s ' "${spec%%=*}"; done; }
# comp_dockerfile <id> <role>: "<dockerfile>:<context>" of that role
comp_dockerfile() {
  local pattern ctx spec df c
  pattern=$(comp_field "$1" 9); ctx=.
  case "$pattern" in *:*) ctx=${pattern#*:}; pattern=${pattern%%:*} ;; esac
  for spec in $(comp_field "$1" 10); do
    [ "${spec%%=*}" = "$2" ] || continue
    if [ "$spec" = "$2" ]; then printf '%s:%s' "${pattern//\{role\}/$2}" "$ctx"
    else df=${spec#*=}; c=.; case "$df" in *:*) c=${df#*:}; df=${df%%:*} ;; esac; printf '%s:%s' "$df" "$c"
    fi
    return 0
  done
  return 1
}
# The current selection: OAN_COMPONENTS from .env, else the default.
selected_components() { comp_closure ${OAN_COMPONENTS:-$DEFAULT_COMPONENTS}; }

# Backwards-compatible names for the registry-only helpers.
reg_ids() { comp_by_kind registry; }
reg_field() {  # reg_field <id> <n>   (1=id 2=chart 3=release 4=repo 5=product)
  case "$2" in 1) comp_field "$1" 1 ;; 2) comp_field "$1" 3 ;; 3) comp_field "$1" 5 ;; 4) comp_field "$1" 7 ;; 5) comp_field "$1" 8 ;; esac
}
reg_version() { comp_version "$1"; }
DEFAULT_REGISTRIES="farmer crop live"
