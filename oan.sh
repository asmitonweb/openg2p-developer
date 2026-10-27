#!/usr/bin/env bash
# OAN developer stack: Commons Base + Commons Services + the registries, services and dashboards
# you select, on Docker Compose, rendered from the same Helm charts as the shared dev cluster.
#
#   ./oan.sh select                       pick what runs in a checklist (saved to .env; mandatory parts are fixed)
#   ./oan.sh up [component...]            one command: render, every repo into oan-workspace/, images, start
#   ./oan.sh dev [component...]           the same, images built from your code in oan-workspace/
#   ./oan.sh src <clone|status|dir> ...   the checkouts in oan-workspace/ (COSS develop)
#   ./oan.sh reload <component> [role...] rebuild roles from oan-workspace/ and restart what runs them
#   ./oan.sh pull [component...]          fetch the newest published images (latest moved on GHCR)
#   ./oan.sh build <component> [role...]  (re)build a component's images from oan-workspace/<repo>
#   ./oan.sh render [component...]        re-render the compose projects from the pinned charts
#   ./oan.sh onboard aggregation-api      one-shot registration of a service on the running stack
#   ./oan.sh stop <registry|all>          stop containers; data volumes are kept
#   ./oan.sh down                         remove all containers of the stack; volumes are kept
#   ./oan.sh rerun <job>                  run a finished job again, e.g. farmer-registry-db-seed
#   ./oan.sh ps | ram | logs <service>    status, memory per project, follow a container's logs
#   ./oan.sh versions                     refresh versions.env from the published indexes
#   ./oan.sh urls                         browser URLs and seeded users
#   ./oan.sh components                   the catalogue (scripts/components.sh)
#
# `up <component...>` and `dev <component...>` add the components to the saved selection.
#
# Image source (where the OAN images come from), via OAN_IMAGE_SOURCE in the shell or .env:
#   ghcr   (default) pull ghcr.io/asmitonweb/<product>/<role>:latest (built from COSS develop);
#          an image that cannot be pulled yet is built from source and tagged with that name
#   local  always build from the checkouts in oan-workspace/ with scripts/build.sh (oan/…:local);
#          `./oan.sh dev` switches to it. See docs/developing-a-registry.md.
set -euo pipefail
export MSYS_NO_PATHCONV=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source scripts/env.sh
# shellcheck disable=SC1091
source scripts/components.sh
# shellcheck disable=SC1091
source scripts/ui.sh

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

selection() {  # selection [component...]: the closure of the arguments, else of the saved selection
  if [ $# -gt 0 ]; then comp_closure "$@"; else comp_closure $(selected_components); fi
}
namespaces_of() {  # projects the components live in (commons always)
  { echo commons; for id in "$@"; do comp_field "$id" 6; done; } | awk '!seen[$0]++'
}
rendered_for() {  # is out/ current for this selection, image source and tag?
  [ -f out/versions.rendered.env ] || return 1
  grep -qxF "OAN_IMAGE_PREFIX=$OAN_IMAGE_PREFIX" out/versions.rendered.env || return 1
  grep -qxF "OAN_IMAGE_TAG=$OAN_IMAGE_TAG" out/versions.rendered.env || return 1
  grep -qxF "COMPONENTS=$(printf '%s\n' "$@" | sort | tr '\n' ' ')" out/versions.rendered.env || return 1
  # a change to versions.env, values, extras or images.yaml re-renders
  local newest
  newest=$(ls -t versions.env images.yaml values/*.yaml extras/*.yaml scripts/gen.py scripts/components.sh 2>/dev/null | head -1)
  [ ! "$newest" -nt out/versions.rendered.env ]
}
compose_files() { local f=(-f "out/$1/compose.yaml"); [ -f "overrides/$1.yaml" ] && f+=(-f "overrides/$1.yaml"); printf '%s\n' "${f[@]}"; }
dc() { local ns="$1"; shift; local cf; mapfile -t cf < <(compose_files "$ns"); docker compose "${cf[@]}" "$@"; }
images_of() {  # images_of <ns>: images of a project that come from this stack's OAN remap
  dc "$1" config --images | awk -v p="$OAN_IMAGE_PREFIX/" 'index($0, p) == 1' | sort -u
}
services_running() {  # services_running <ns> <image>: services of the project that run the image
  dc "$1" config | awk -v img="$2" '/^  [A-Za-z0-9_.-]+:$/ {svc=$1; sub(/:$/, "", svc)} $1=="image:" && $2==img {print svc}'
}
build_missing() {  # build_missing <image...>: build each image from source and give it the expected name
  local img rest product role comp
  for img in "$@"; do
    rest=${img#"$OAN_IMAGE_PREFIX/"}; product=${rest%%/*}; role=${rest#*/}; role=${role%%:*}
    comp=$(comp_for_image "$product" "$role") || { warn "no component builds $img (scripts/components.sh)"; continue; }
    scripts/build.sh "$comp" "$role" || { fail "build of $img failed"; exit 1; }
    [ "$img" = "oan/$product/$role:local" ] || docker tag "oan/$product/$role:local" "$img"
  done
}
ensure_images() {  # ensure_images <ns...>: pull (with progress) or build every OAN image of the projects
  local ns img list missing=() svcs=()
  for ns in "$@"; do
    [ -f "out/$ns/compose.yaml" ] || continue
    list=$(images_of "$ns") || { fail "docker compose config failed for out/$ns/compose.yaml"; exit 1; }
    while read -r img; do
      [ -n "$img" ] || continue
      docker image inspect "$img" >/dev/null 2>&1 && continue
      missing+=("$img")
      [ "$OAN_IMAGE_SOURCE" = ghcr ] && mapfile -t -O ${#svcs[@]} svcs < <(services_running "$ns" "$img")
    done <<<"$list"
    if [ "$OAN_IMAGE_SOURCE" = ghcr ] && [ ${#svcs[@]} -gt 0 ]; then
      note "pulling ${#svcs[@]} image reference(s) for $ns from $OAN_IMAGE_PREFIX"
      dc "$ns" pull --ignore-pull-failures "${svcs[@]}" || true
      svcs=()
    fi
  done
  [ ${#missing[@]} -gt 0 ] || { ok "images present"; return 0; }
  local unpulled=()
  for img in "${missing[@]}"; do docker image inspect "$img" >/dev/null 2>&1 || unpulled+=("$img"); done
  [ ${#unpulled[@]} -gt 0 ] || return 0
  if [ "$OAN_IMAGE_SOURCE" = ghcr ]; then
    warn "not on GHCR (yet): ${unpulled[*]}"
    case "$OAN_IMAGE_TAG" in
      latest|develop) note "building from source instead and tagging with the published name (a later pull replaces it)" ;;
      *) fail "OAN_IMAGE_TAG=$OAN_IMAGE_TAG names a specific build; a local build of develop would not be that. Publish it, or use latest."; exit 1 ;;
    esac
  fi
  build_missing "${unpulled[@]}"
}

# ── interactive checklist ──────────────────────────────────────────────────
select_menu() {
  local ids=() kinds=() titles=() checked=() locked=() r i n cur=0 key saved=" $(selected_components | tr '\n' ' ') " mandatory=" $(comp_mandatory)"
  for r in "${COMPONENTS[@]}"; do
    [ "$(cut -d'|' -f2 <<<"$r")" != source ] || continue   # code only: always in the workspace, nothing to run
    ids+=("${r%%|*}"); kinds+=("$(cut -d'|' -f2 <<<"$r")"); titles+=("$(cut -d'|' -f13 <<<"$r")")
  done
  n=${#ids[@]}
  for ((i = 0; i < n; i++)); do
    case "$saved" in *" ${ids[i]} "*) checked[i]=1 ;; *) checked[i]=0 ;; esac
    case "$mandatory" in *" ${ids[i]} "*) locked[i]=1; checked[i]=1 ;; *) locked[i]=0 ;; esac
  done
  check() {  # check <i>: tick it and what it requires
    local j req; checked[$1]=1; req=$(comp_field "${ids[$1]}" 12)
    if [ "$req" != - ]; then for j in "${!ids[@]}"; do case " $req " in *" ${ids[j]} "*) check "$j" ;; esac; done; fi
    return 0
  }
  uncheck() {  # uncheck <i>: untick it and what depends on it; mandatory ones stay
    local j
    if [ "${locked[$1]}" = 1 ]; then return 0; fi
    checked[$1]=0
    for j in "${!ids[@]}"; do
      if [ "${checked[j]}" = 1 ]; then case " $(comp_field "${ids[j]}" 12) " in *" ${ids[$1]} "*) uncheck "$j" ;; esac; fi
    done
    return 0
  }
  toggle() { if [ "${checked[$1]}" = 1 ]; then uncheck "$1"; else check "$1"; fi; }
  result() { local i; for ((i = 0; i < n; i++)); do [ "${checked[i]}" = 1 ] && printf '%s ' "${ids[i]}"; done; return 0; }
  # The menu is drawn on stderr: stdout carries only the result (the caller captures it).
  if [ -z "$UI_TTY" ]; then
    echo "Components (current selection marked):" >&2
    for ((i = 0; i < n; i++)); do printf '  %2d %s %-24s %s%s\n' $((i + 1)) "$([ "${checked[i]}" = 1 ] && echo '[x]' || echo '[ ]')" "${ids[i]}" "${titles[i]}" "$([ "${locked[i]}" = 1 ] && echo ' (always)')" >&2; done
    printf 'numbers to toggle (space separated), Enter to keep: ' >&2
    read -r line || line=""
    for i in $line; do
      case "$i" in *[!0-9]*|'') echo "ignored: $i" >&2; continue ;; esac
      [ "$i" -ge 1 ] && [ "$i" -le "$n" ] || { echo "ignored: $i (1-$n)" >&2; continue; }
      toggle $((i - 1))
    done
    result; return 0
  fi
  exec 3>&2
  local lines=$((n + 3))
  draw() {
    local i mark cursor
    printf '%s%sSelect components%s  %sspace%s toggle  %s↑↓/jk%s move  %senter%s save  %sq%s cancel\n' "$C_BOLD" "$C_BLUE" "$C_OFF" "$C_BOLD" "$C_OFF" "$C_BOLD" "$C_OFF" "$C_BOLD" "$C_OFF" "$C_BOLD" "$C_OFF" >&3
    for ((i = 0; i < n; i++)); do
      if [ "${locked[i]}" = 1 ]; then mark="${C_DIM}[x]${C_OFF}"
      elif [ "${checked[i]}" = 1 ]; then mark="${C_GREEN}[x]${C_OFF}"; else mark="[ ]"; fi
      [ $i -eq $cur ] && cursor="${C_BLUE}▶${C_OFF}" || cursor=" "
      printf '\e[K %s %s %-24s %s%-9s%s %s%s\n' "$cursor" "$mark" "${ids[i]}" "$C_DIM" "${kinds[i]}" "$C_OFF" "${titles[i]}" "$([ "${locked[i]}" = 1 ] && printf ' %salways%s' "$C_DIM" "$C_OFF")" >&3
    done
    printf '\e[K%sselected:%s %s\n' "$C_DIM" "$C_OFF" "$(result)" >&3
    printf '\e[K%sservices become part of commons; features and add-ons join their registry%s\n' "$C_DIM" "$C_OFF" >&3
  }
  printf '\e[?25l' >&3
  trap 'printf "\e[?25h" >&3' RETURN
  trap 'printf "\e[?25h\n" >&3; exit 130' INT
  draw
  while :; do
    IFS= read -rsn1 key || key=q
    case "$key" in
      $'\e')
        IFS= read -rsn2 -t 0.2 rest || rest=""
        case "$rest" in '[A'|'OA') key=k ;; '[B'|'OB') key=j ;; '') key=q ;; *) IFS= read -rsn1 -t 0.1 _ || true; key=ignore ;; esac ;;
      $'\r') key='' ;;
    esac
    case "$key" in
      k) cur=$(( (cur - 1 + n) % n )) ;;
      j) cur=$(( (cur + 1) % n )) ;;
      ' ') toggle "$cur" ;;
      [1-9]) i=$((key - 1)); [ $i -lt $n ] && { cur=$i; toggle "$i"; } ;;
      '') printf '\e[?25h' >&3; result; return 0 ;;
      q) printf '\e[?25h' >&3; return 1 ;;
    esac
    printf '\e[%dA' "$lines" >&3; draw
  done
}
do_select() {  # returns 1 when the user cancelled
  local picked
  picked=$(select_menu) || { echo "cancelled; selection unchanged"; return 1; }
  picked=$(comp_closure $picked | tr '\n' ' '); picked=${picked% }
  [ -n "$picked" ] || { echo "nothing selected; keeping the previous selection"; return 0; }
  set_env OAN_COMPONENTS "\"$picked\""
  ok "OAN_COMPONENTS=\"$picked\" saved to .env"
  export OAN_COMPONENTS="$picked"
}
add_to_selection() {  # add_to_selection <component...>: persist the saved selection plus these
  local sel
  sel=$(comp_closure $(selected_components) "$@" | tr '\n' ' '); sel=${sel% }
  [ "$sel" = "${OAN_COMPONENTS:-}" ] || { set_env OAN_COMPONENTS "\"$sel\""; note "OAN_COMPONENTS=\"$sel\""; }
  export OAN_COMPONENTS="$sel"
}

reload() {  # reload <id> [role...]: rebuild from the workspace and restart the services that run those images
  local id="$1"; shift
  [ "$OAN_IMAGE_SOURCE" = local ] || { echo "reload needs OAN_IMAGE_SOURCE=local (./oan.sh dev $id sets it)" >&2; exit 1; }
  local product ns roles role img s long=() jobs=()
  product=$(comp_field "$id" 8); ns=$(comp_field "$id" 6)
  [ "$product" != - ] || { echo "$id ships no image; nothing to reload" >&2; exit 1; }
  [ -f "out/$ns/compose.yaml" ] || { echo "nothing rendered for $id: ./oan.sh dev $id first" >&2; exit 1; }
  scripts/build.sh "$id" "$@"
  roles="$*"; [ -n "$roles" ] || roles=$(comp_roles "$id")
  for role in $roles; do
    img="$OAN_IMAGE_PREFIX/$product/$role:$OAN_IMAGE_TAG"
    for s in $(services_running "$ns" "$img"); do
      if awk -F'\t' -v ns="$ns" -v s="$s" '$1==ns && $3==s && $4=="job"' out/services.tsv | grep -q .; then jobs+=("$s"); else long+=("$s"); fi
    done
  done
  if [ ${#long[@]} -gt 0 ]; then
    step "Restart: ${long[*]}"
    dc "$ns" up -d --force-recreate --no-deps "${long[@]}"
  fi
  if [ ${#jobs[@]} -gt 0 ]; then
    note "jobs using a rebuilt image (run again with ./oan.sh rerun <job>): ${jobs[*]}"
    for s in "${jobs[@]}"; do case "$s" in *-db-seed) note "metadata/seed change: ./oan.sh rerun $s";; esac; done
  fi
  [ ${#long[@]} -gt 0 ] || [ ${#jobs[@]} -gt 0 ] || warn "no rendered service runs an image of $id (${roles})"
}

urls() {
  step "Ready"
  echo "  Staff portal      http://staff-portal.openg2p.localtest.me"
  echo "  Keycloak          http://keycloak.openg2p.localtest.me  (admin password: state/secrets.json -> commons/commons-keycloak)"
  echo "  Master Data UI    http://master-data-ui.openg2p.localtest.me"
  echo "  AWE               http://awe.openg2p.localtest.me"
  echo "  Postgres          127.0.0.1:5433 (user postgres, password: state/secrets.json -> commons/commons-postgresql)"
  local id
  for id in "$@"; do
    case "$(comp_kind "$id")" in
      registry) [ -f "out/$id/compose.yaml" ] && echo "  $(printf '%-17s' "$id registry") http://$(grep -m1 'registryHostname:' "values/$id.yaml" | awk '{print $2}')" ;;
      addon) echo "  $(printf '%-17s' "$id") http://$(grep -m1 '^host:' "values/$id.yaml" | awk '{print $2}')" ;;
      service) echo "  $(printf '%-17s' "$id") see out/REPORT.md (gateway hosts)" ;;
    esac
  done
  echo "  All gateway hosts: out/REPORT.md · seeded staff users: out/files/*keycloak-init*/config/clients.yaml"
}

up() {
  local sel regs=() id
  mapfile -t sel < <(selection "$@")
  [ ${#sel[@]} -gt 0 ] || { echo "nothing selected: ./oan.sh select" >&2; exit 1; }
  UI_T0=$EPOCHSECONDS
  rendered_for "${sel[@]}" || scripts/render.sh "${sel[@]}"
  step "Workspace: every OAN repository in ${OAN_SRC_DIR:-oan-workspace}/"
  scripts/src.sh clone || warn "some repositories could not be cloned; the stack still starts"
  step "Images"
  mapfile -t ns < <(namespaces_of "${sel[@]}")
  ensure_images "${ns[@]}"
  for id in "${sel[@]}"; do
    if [ "$(comp_kind "$id")" = registry ] && [ -f "out/$id/compose.yaml" ]; then regs+=("$id"); fi
  done
  [ ${#regs[@]} -gt 0 ] || regs=(commons)
  scripts/stack.sh up "${regs[@]}"
  urls "${sel[@]}"
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  select) do_select || exit 1 ;;
  up)
    for id in "$@"; do comp_field "$id" 1 >/dev/null; done
    if [ $# -eq 0 ] && [ -z "${OAN_COMPONENTS:-}" ] && [ -n "$UI_TTY" ]; then do_select || exit 1; fi
    [ $# -eq 0 ] || add_to_selection "$@"
    up ;;
  dev)
    for id in "$@"; do comp_field "$id" 1 >/dev/null; done
    if [ $# -eq 0 ] && [ -z "${OAN_COMPONENTS:-}" ] && [ -n "$UI_TTY" ]; then do_select || exit 1; fi
    [ "$OAN_IMAGE_SOURCE" = local ] || { set_env OAN_IMAGE_SOURCE local; note "OAN_IMAGE_SOURCE=local written to .env: images now come from your source checkouts"; }
    [ $# -eq 0 ] || add_to_selection "$@"
    OAN_IMAGE_SOURCE=local exec "$ROOT/oan.sh" up ;;
  src) scripts/src.sh "$@" ;;
  reload) id="${1:-}"; [ -n "$id" ] || { echo "usage: ./oan.sh reload <component> [role...]" >&2; exit 1; }; comp_field "$id" 1 >/dev/null; reload "$@" ;;
  build) scripts/build.sh "$@" ;;
  pull)
    mapfile -t ns < <(namespaces_of $(selection "$@"))
    for n in "${ns[@]}"; do
      [ -f "out/$n/compose.yaml" ] || continue
      mapfile -t svcs < <(for img in $(images_of "$n"); do services_running "$n" "$img"; done | sort -u)
      [ ${#svcs[@]} -eq 0 ] || dc "$n" pull --ignore-pull-failures "${svcs[@]}"
    done
    echo "restart to use them: ./oan.sh up" ;;
  render) scripts/render.sh "$@" ;;
  onboard) scripts/onboard.sh "$@" ;;
  stop|down|rerun|ps|ram|create) scripts/stack.sh "$cmd" "$@" ;;
  logs) docker logs -f --tail 200 "$@" ;;
  versions) scripts/latest.sh ;;
  urls) urls $(selection) ;;
  components)
    printf '%-24s %-9s %-26s %s\n' id kind "source (COSS)" title
    for r in "${COMPONENTS[@]}"; do IFS='|' read -r c1 c2 _ _ _ _ c7 _ _ _ _ _ c13 <<<"$r"; printf '%-24s %-9s %-26s %s\n' "$c1" "$c2" "$c7" "$c13"; done
    echo; echo "selected: $(selected_components | tr '\n' ' ')" ;;
  *) sed -n '2,28p' "$ROOT/oan.sh" | sed 's/^# \{0,1\}//' ;;
esac
