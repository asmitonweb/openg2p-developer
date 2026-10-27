#!/usr/bin/env bash
# Source checkouts of the components in oan-workspace/: one folder per COSS repository, cloned
# from github.com/Centre-for-Open-Societal-Systems on the `develop` branch. `./oan.sh up` keeps
# the workspace complete for the selected components; `./oan.sh dev` builds the images from it.
#
#   src.sh clone  [component...]   clone what is missing (every repository when none is named);
#                                  an existing checkout is never touched
#   src.sh status [component...]   branch, ahead/behind origin/develop, uncommitted files
#   src.sh dir    <component>      print the checkout path
#
# Forks, branches and pull requests are yours to manage with git and GitHub as usual; the guide
# (docs/developing-a-registry.md) describes the expected flow. Point OAN_<ID>_SRC at a checkout
# of your own (OAN_FARMER_SRC=/path/to/farmer-registry) or OAN_SRC_DIR at a folder holding all
# of them, and the scripts use that instead of oan-workspace/.
#
# Checkouts are made with core.autocrlf=false: shell scripts are copied into Linux images and a
# CRLF checkout breaks every container entrypoint.
set -euo pipefail
export MSYS_NO_PATHCONV=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source scripts/env.sh
# shellcheck disable=SC1091
source scripts/components.sh
# shellcheck disable=SC1091
source scripts/ui.sh
ORG=https://github.com/Centre-for-Open-Societal-Systems
BRANCH="${OAN_SRC_REF:-develop}"
WORKSPACE="${OAN_SRC_DIR:-oan-workspace}"

src_dir() {  # src_dir <id>  -> absolute path of the checkout (may not exist yet)
  # OAN_<ID>_SRC (component id) or OAN_<REPO>_SRC (repository; consent-manager and the partner
  # portal share one) point at a checkout of your own instead of the workspace folder.
  local repo var rvar p
  repo=$(comp_field "$1" 7)
  var="OAN_$(tr '[:lower:]-' '[:upper:]_' <<<"$1")_SRC"
  rvar="OAN_$(tr '[:lower:]-' '[:upper:]_' <<<"$repo")_SRC"
  p="${!var:-${!rvar:-$WORKSPACE/$repo}}"
  case "$p" in /*|[A-Za-z]:*) ;; *) p="$ROOT/$p" ;; esac
  printf '%s' "$p"
}
g() { git -C "$SRC" "$@"; }

clone() {
  local ids=("$@") id repo SRC seen=" "
  [ ${#ids[@]} -gt 0 ] || read -r -a ids <<<"$(comp_ids)"
  for id in "${ids[@]}"; do
    repo=$(comp_field "$id" 7); [ "$repo" != - ] || continue
    SRC=$(src_dir "$id")
    case "$seen" in *" $SRC "*) continue ;; esac; seen+="$SRC "   # consent-manager and the partner portal share a repository
    if [ -e "$SRC/.git" ]; then note "$repo: $SRC ($(g rev-parse --abbrev-ref HEAD))"; continue; fi
    note "cloning $ORG/$repo ($BRANCH) into $SRC"
    mkdir -p "$(dirname "$SRC")"
    git -c core.autocrlf=false clone -q --branch "$BRANCH" "$ORG/$repo.git" "$SRC"
    g config core.autocrlf false
    ok "$repo: $SRC"
  done
}

status() {
  local ids=("$@") id SRC br ab seen=" "
  [ ${#ids[@]} -gt 0 ] || read -r -a ids <<<"$(comp_ids)"
  for id in "${ids[@]}"; do
    [ "$(comp_field "$id" 7)" != - ] || continue
    SRC=$(src_dir "$id")
    case "$seen" in *" $SRC "*) continue ;; esac; seen+="$SRC "
    if [ ! -e "$SRC/.git" ]; then printf '%-22s no checkout (%s)\n' "$id" "$SRC"; continue; fi
    br=$(g rev-parse --abbrev-ref HEAD)
    g fetch -q --no-tags origin "$BRANCH" 2>/dev/null || true
    ab=$(g rev-list --left-right --count "origin/$BRANCH...HEAD" 2>/dev/null | awk '{printf "behind %s, ahead %s", $1, $2}')
    printf '%-22s %s  %s  %s  %s\n' "$id" "$SRC" "$br" "${ab:-?}" "$([ -n "$(g status --porcelain)" ] && echo '(uncommitted changes)' || echo clean)"
  done
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  clone) for id in "$@"; do comp_field "$id" 1 >/dev/null; done; clone "$@" ;;
  status) for id in "$@"; do comp_field "$id" 1 >/dev/null; done; status "$@" ;;
  dir) [ -n "${1:-}" ] || { echo "usage: src.sh dir <component>" >&2; exit 1; }; comp_field "$1" 1 >/dev/null; src_dir "$1"; echo ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
