#!/usr/bin/env bash
# OAN developer stack: Commons Base + Commons Services + the registries, services and dashboards
# you select, on Docker Compose, rendered from the same Helm charts as the shared dev cluster.
#
#   ./oan.sh select                       pick components in a checklist (saved to .env)
#   ./oan.sh up [component...]            one command: render, source into oan-workspace/, images, start
#   ./oan.sh dev <component>              the same, images built from your code in oan-workspace/
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
# Image source (where the OAN images come from), via OAN_IMAGE_SOURCE in .env or the shell:
#   ghcr   (default) pull ghcr.io/asmitonweb/<product>/<role>:latest (built from COSS develop);
#          an image that cannot be pulled yet is built from source and tagged with that name
#   local  always build from the checkouts in oan-workspace/ with scripts/build.sh (oan/…:local);
#          `./oan.sh dev` switches to it. See docs/developing-a-registry.md.
set -euo pipefail
export MSYS_NO_PATHCONV=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
[ -f .env ] && set -a && . ./.env && set +a
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

set_env() {  # set_env KEY VALUE: persist a setting in .env (created if needed)
  touch .env
  if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi
}
selection() {  # selection [component...]: the closure of the arguments, else of the saved selection
  comp_closure "${@:-$(selected_components)}"
}
namespaces_of() {  # projects the components live in (commons always)
  { echo commons; for id in "$@"; do comp_field "$id" 6; done; } | awk '!seen[$0]++'
}
rendered_for() {  # is out/ current for this selection and image source?
  [ -f out/versions.rendered.env ] || return 1
  grep -qx "OAN_IMAGE_PREFIX=$OAN_IMAGE_PREFIX" out/versions.rendered.env || return 1
  grep -qx "COMPONENTS=$(printf '%s\n' "$@" | sort | tr '\n' ' ')" out/versions.rendered.env || return 1
  # a change to versions.env, values or images.yaml re-renders
  local newest
  newest=$(ls -t versions.env images.yaml values/*.yaml scripts/gen.py scripts/components.sh | head -1)
  [ ! "$newest" -nt out/versions.rendered.env ]
}
compose_files() { local f=(-f "out/$1/compose.yaml"); [ -f "overrides/$1.yaml" ] && f+=(-f "overrides/$1.yaml"); printf '%s\n' "${f[@]}"; }
images_of() {  # images_of <ns>: images of a project that come from this stack's OAN remap
  docker compose -f "out/$1/compose.yaml" config --images 2>/dev/null | grep -E "^$OAN_IMAGE_PREFIX/" | sort -u
}
services_running() {  # services_running <ns> <image>: services of the project that run the image
  docker compose -f "out/$1/compose.yaml" config 2>/dev/null \
    | awk -v img="$2" '/^  [A-Za-z0-9_.-]+:$/ {svc=$1; sub(/:$/, "", svc)} $1=="image:" && $2==img {print svc}'
}
build_missing() {  # build_missing <image...>: build each image from source and give it the expected name
  local img rest product role comp
  for img in "$@"; do
    rest=${img#"$OAN_IMAGE_PREFIX/"}; product=${rest%%/*}; role=${rest#*/}; role=${role%%:*}
    comp=$(comp_for_image "$product" "$role") || { warn "no component builds $img (scripts/components.sh)"; continue; }
    scripts/build.sh "$comp" "$role"
    [ "$img" = "oan/$product/$role:local" ] || docker tag "oan/$product/$role:local" "$img"
  done
}
ensure_images() {  # ensure_images <ns...>: pull (with progress) or build every OAN image of the projects
  local ns img missing=() svcs=()
  for ns in "$@"; do
    [ -f "out/$ns/compose.yaml" ] || continue
    while read -r img; do
      docker image inspect "$img" >/dev/null 2>&1 && continue
      missing+=("$img")
      [ "$OAN_IMAGE_SOURCE" = ghcr ] && mapfile -t -O ${#svcs[@]} svcs < <(services_running "$ns" "$img")
    done < <(images_of "$ns")
    if [ "$OAN_IMAGE_SOURCE" = ghcr ] && [ ${#svcs[@]} -gt 0 ]; then
      note "pulling ${#svcs[@]} image reference(s) for $ns from $OAN_IMAGE_PREFIX"
      docker compose -f "out/$ns/compose.yaml" pull --ignore-pull-failures "${svcs[@]}" || true
      svcs=()
    fi
  done
  [ ${#missing[@]} -gt 0 ] || { ok "images present"; return 0; }
  local unpulled=()
  for img in "${missing[@]}"; do docker image inspect "$img" >/dev/null 2>&1 || unpulled+=("$img"); done
  [ ${#unpulled[@]} -gt 0 ] || return 0
  if [ "$OAN_IMAGE_SOURCE" = ghcr ]; then
    warn "not on GHCR (yet): ${unpulled[*]}"
    note "building from source instead and tagging with the published name (a later pull replaces it)"
  fi
  build_missing "${unpulled[@]}"
}

# ── interactive checklist ──────────────────────────────────────────────────
select_menu() {
  local ids=() kinds=() titles=() checked=() r i n cur=0 key saved=" $(selected_components | tr '\n' ' ') "
  for r in "${COMPONENTS[@]}"; do
    [ "$(cut -d'|' -f2 <<<"$r")" != source ] || continue   # code only: always in the workspace, nothing to run
    ids+=("${r%%|*}"); kinds+=("$(cut -d'|' -f2 <<<"$r")"); titles+=("$(cut -d'|' -f13 <<<"$r")")
  done
  n=${#ids[@]}
  for ((i = 0; i < n; i++)); do case "$saved" in *" ${ids[i]} "*) checked[i]=1 ;; *) checked[i]=0 ;; esac; done
  check() {  # check <i>: tick it and what it requires
    local j req; checked[$1]=1; req=$(comp_field "${ids[$1]}" 12)
    [ "$req" = - ] || for j in "${!ids[@]}"; do case " $req " in *" ${ids[j]} "*) check "$j" ;; esac; done
  }
  uncheck() {  # uncheck <i>: untick it and what depends on it
    local j; checked[$1]=0
    for j in "${!ids[@]}"; do [ "${checked[j]}" = 1 ] && case " $(comp_field "${ids[j]}" 12) " in *" ${ids[$1]} "*) uncheck "$j" ;; esac; done
  }
  result() { local i; for ((i = 0; i < n; i++)); do [ "${checked[i]}" = 1 ] && printf '%s ' "${ids[i]}"; done; }
  # The menu is drawn on stderr: stdout carries only the result (the caller captures it).
  if [ -z "$UI_TTY" ]; then
    echo "Components (current selection marked):" >&2
    for ((i = 0; i < n; i++)); do printf '  %2d %s %-24s %s\n' $((i + 1)) "$([ "${checked[i]}" = 1 ] && echo '[x]' || echo '[ ]')" "${ids[i]}" "${titles[i]}" >&2; done
    printf 'numbers to toggle (space separated), Enter to keep: ' >&2
    read -r line
    for i in $line; do i=$((i - 1)); [ "${checked[i]}" = 1 ] && uncheck "$i" || check "$i"; done
    result; return 0
  fi
  exec 3>&2
  local lines=$((n + 3)) kind_shown
  draw() {
    local i mark cursor
    printf '%s%sSelect components%s  %sspace%s toggle  %s↑↓/jk%s move  %senter%s save  %sq%s cancel\n' "$C_BOLD" "$C_BLUE" "$C_OFF" "$C_BOLD" "$C_OFF" "$C_BOLD" "$C_OFF" "$C_BOLD" "$C_OFF" "$C_BOLD" "$C_OFF" >&3
    for ((i = 0; i < n; i++)); do
      [ "${checked[i]}" = 1 ] && mark="${C_GREEN}[x]${C_OFF}" || mark="[ ]"
      [ $i -eq $cur ] && cursor="${C_BLUE}▶${C_OFF}" || cursor=" "
      printf '\e[K %s %s %-24s %s%-9s%s %s\n' "$cursor" "$mark" "${ids[i]}" "$C_DIM" "${kinds[i]}" "$C_OFF" "${titles[i]}" >&3
    done
    printf '\e[K%sselected:%s %s\n' "$C_DIM" "$C_OFF" "$(result)" >&3
    printf '\e[K%sservices become part of commons; features and add-ons join their registry%s\n' "$C_DIM" "$C_OFF" >&3
  }
  printf '\e[?25l' >&3; trap 'printf "\e[?25h" >&3' RETURN
  draw
  while :; do
    IFS= read -rsn1 key
    case "$key" in
      $'\e') IFS= read -rsn2 -t 0.1 rest || rest=""; case "$rest" in '[A') key=k ;; '[B') key=j ;; *) key=q ;; esac ;;
    esac
    case "$key" in
      k) cur=$(( (cur - 1 + n) % n )) ;;
      j) cur=$(( (cur + 1) % n )) ;;
      ' ') [ "${checked[cur]}" = 1 ] && uncheck "$cur" || check "$cur" ;;
      [1-9]) i=$((key - 1)); [ $i -lt $n ] && { cur=$i; [ "${checked[i]}" = 1 ] && uncheck "$i" || check "$i"; } ;;
      '') printf '\e[?25h' >&3; result; return 0 ;;
      q) printf '\e[?25h' >&3; return 1 ;;
    esac
    printf '\e[%dA' "$lines" >&3; draw
  done
}
do_select() {
  local picked
  picked=$(select_menu) || { echo "selection unchanged"; return 0; }
  picked=$(comp_closure $picked | tr '\n' ' '); picked=${picked% }
  [ -n "$picked" ] || { echo "nothing selected; keeping the previous selection"; return 0; }
  set_env OAN_COMPONENTS "\"$picked\""
  ok "OAN_COMPONENTS=\"$picked\" saved to .env"
  export OAN_COMPONENTS="$picked"
}

reload() {  # reload <id> [role...]: rebuild from src/ and restart the services that run those images
  local id="$1"; shift
  [ "$OAN_IMAGE_SOURCE" = local ] || { echo "reload needs OAN_IMAGE_SOURCE=local (./oan.sh dev $id sets it)" >&2; exit 1; }
  scripts/build.sh "$id" "$@"
  local product ns roles role img s long=() jobs=()
  product=$(comp_field "$id" 8); ns=$(comp_field "$id" 6)
  [ -f "out/$ns/compose.yaml" ] || { echo "nothing rendered for $id: ./oan.sh dev $id first" >&2; exit 1; }
  roles="$*"; [ -n "$roles" ] || roles=$(comp_roles "$id")
  for role in $roles; do
    img="$OAN_IMAGE_PREFIX/$product/$role:$OAN_IMAGE_TAG"
    for s in $(services_running "$ns" "$img"); do
      if awk -F'\t' -v ns="$ns" -v s="$s" '$1==ns && $3==s && $4=="job"' out/services.tsv | grep -q .; then jobs+=("$s"); else long+=("$s"); fi
    done
  done
  if [ ${#long[@]} -gt 0 ]; then
    step "Restart: ${long[*]}"
    mapfile -t cf < <(compose_files "$ns")
    docker compose "${cf[@]}" up -d --force-recreate --no-deps "${long[@]}"
  fi
  if [ ${#jobs[@]} -gt 0 ]; then
    note "jobs using a rebuilt image (run again with ./oan.sh rerun <job>): ${jobs[*]}"
    for s in "${jobs[@]}"; do case "$s" in *-db-seed) note "metadata/seed change: ./oan.sh rerun $s";; esac; done
  fi
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
      registry) echo "  $(printf '%-17s' "$id registry") http://$(grep -m1 'registryHostname:' "values/$id.yaml" | awk '{print $2}')" ;;
      addon) echo "  $(printf '%-17s' "$id") http://$(grep -m1 '^host:' "values/$id.yaml" | awk '{print $2}')" ;;
      service) echo "  $(printf '%-17s' "$id") see out/REPORT.md (gateway hosts)" ;;
    esac
  done
  echo "  All gateway hosts: out/REPORT.md · seeded staff users: out/files/*keycloak-init*/config/clients.yaml"
}

up() {
  local sel regs
  mapfile -t sel < <(selection "$@")
  [ ${#sel[@]} -gt 0 ] || { echo "nothing selected: ./oan.sh select" >&2; exit 1; }
  UI_T0=$SECONDS
  rendered_for "${sel[@]}" || scripts/render.sh "${sel[@]}"
  step "Workspace: every OAN repository in ${OAN_SRC_DIR:-oan-workspace}/"
  scripts/src.sh clone
  step "Images"
  mapfile -t ns < <(namespaces_of "${sel[@]}")
  ensure_images "${ns[@]}"
  regs=$(for id in "${sel[@]}"; do [ "$(comp_kind "$id")" = registry ] && [ -f "out/$id/compose.yaml" ] && echo "$id"; done | tr '\n' ' ')
  # shellcheck disable=SC2086
  scripts/stack.sh up ${regs:-commons}
  urls "${sel[@]}"
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  select) do_select ;;
  up)
    if [ $# -eq 0 ] && [ -z "${OAN_COMPONENTS:-}" ] && [ -n "$UI_TTY" ]; then do_select; fi
    for id in "$@"; do comp_field "$id" 1 >/dev/null; done
    up "$@" ;;
  dev)
    id="${1:-}"; [ -n "$id" ] || { echo "usage: ./oan.sh dev <component>   ($(comp_ids))" >&2; exit 1; }
    comp_field "$id" 1 >/dev/null
    [ "$OAN_IMAGE_SOURCE" = local ] || { set_env OAN_IMAGE_SOURCE local; note "OAN_IMAGE_SOURCE=local written to .env: images now come from your source checkouts"; }
    sel=$(comp_closure $(selected_components) "$id" | tr '\n' ' '); sel=${sel% }
    [ "$sel" = "${OAN_COMPONENTS:-}" ] || { set_env OAN_COMPONENTS "\"$sel\""; note "OAN_COMPONENTS=\"$sel\""; }
    OAN_IMAGE_SOURCE=local OAN_COMPONENTS="$sel" exec "$0" up ;;
  src) scripts/src.sh "$@" ;;
  reload) id="${1:-}"; [ -n "$id" ] || { echo "usage: ./oan.sh reload <component> [role...]" >&2; exit 1; }; comp_field "$id" 1 >/dev/null; reload "$@" ;;
  build) scripts/build.sh "$@" ;;
  pull)
    mapfile -t ns < <(namespaces_of $(selection "$@"))
    for n in "${ns[@]}"; do
      [ -f "out/$n/compose.yaml" ] || continue
      mapfile -t svcs < <(for img in $(images_of "$n"); do services_running "$n" "$img"; done | sort -u)
      [ ${#svcs[@]} -eq 0 ] || docker compose -f "out/$n/compose.yaml" pull --ignore-pull-failures "${svcs[@]}"
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
    for r in "${COMPONENTS[@]}"; do printf '%-24s %-9s %-26s %s\n' "$(cut -d'|' -f1 <<<"$r")" "$(cut -d'|' -f2 <<<"$r")" "$(cut -d'|' -f7 <<<"$r")" "$(cut -d'|' -f13 <<<"$r")"; done
    echo; echo "selected: $(selected_components | tr '\n' ' ')" ;;
  *) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
