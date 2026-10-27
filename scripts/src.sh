#!/usr/bin/env bash
# Source checkouts for registry development: fork, clone, branch, sync, open the pull request.
# Usually called through ./oan.sh src <command> ...
#
#   src.sh clone  <registry>            src/<repo>: your fork as `origin`, COSS as `upstream`
#   src.sh branch <registry> <name>     new branch <name> from the newest upstream develop
#   src.sh sync   <registry>            fetch upstream, fast-forward develop, rebase your branch
#   src.sh status [registry...]         branch, ahead/behind upstream develop, uncommitted files
#   src.sh pr     <registry>            push the branch to your fork and open the PR on COSS develop
#
# Layout of a checkout (src/<repo>, or the folder OAN_<ID>_SRC / OAN_SRC_DIR point at):
#   upstream  https://github.com/Centre-for-Open-Societal-Systems/<repo>   never pushed to
#   origin    https://github.com/<you>/<repo>                              your fork; branches go here
# When GitHub CLI (gh) is logged in, `clone` creates the fork for you. Without gh, origin is the
# COSS repository itself; you then need push rights there or must add your fork by hand.
#
# Checkouts are made with core.autocrlf=false: shell scripts are copied into Linux images and a
# CRLF checkout breaks every container entrypoint.
set -euo pipefail
export MSYS_NO_PATHCONV=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ -f .env ] && set -a && . ./.env && set +a
# shellcheck disable=SC1091
source scripts/registries.sh
ORG=Centre-for-Open-Societal-Systems
UPSTREAM_BRANCH="${OAN_SRC_REF:-develop}"

src_dir() {  # src_dir <id>  -> path of the checkout (may not exist yet)
  local var repo
  var="OAN_$(tr '[:lower:]' '[:upper:]' <<<"$1")_SRC"
  repo=$(reg_field "$1" 4)
  printf '%s' "${!var:-${OAN_SRC_DIR:-src}/$repo}"
}
have_gh() { command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; }
g() { git -C "$SRC" "$@"; }
need_src() {
  SRC=$(src_dir "$1")
  [ -d "$SRC/.git" ] || { echo "no checkout at $SRC: run ./oan.sh src clone $1" >&2; exit 1; }
}
current_branch() { g rev-parse --abbrev-ref HEAD; }
dirty() { [ -n "$(g status --porcelain)" ]; }

clone() {
  local id="$1" repo origin
  repo=$(reg_field "$id" 4)
  SRC=$(src_dir "$id")
  if [ -d "$SRC/.git" ]; then
    echo "$SRC already exists ($(g remote get-url origin))"
    g remote get-url upstream >/dev/null 2>&1 || g remote add upstream "https://github.com/$ORG/$repo.git"
    return 0
  fi
  origin="https://github.com/$ORG/$repo.git"
  if have_gh; then
    local me; me=$(gh api user --jq .login)
    if ! gh repo view "$me/$repo" >/dev/null 2>&1; then
      echo "forking $ORG/$repo to $me/$repo"
      gh repo fork "$ORG/$repo" --clone=false >/dev/null
    fi
    origin="https://github.com/$me/$repo.git"
  else
    echo "gh is not logged in: cloning $ORG/$repo directly. To work from a fork, run 'gh auth login' first," >&2
    echo "or add it later: git -C $SRC remote set-url origin https://github.com/<you>/$repo.git" >&2
  fi
  echo "cloning $origin into $SRC"
  git -c core.autocrlf=false clone -q --origin origin "$origin" "$SRC"
  g config core.autocrlf false
  g remote get-url upstream >/dev/null 2>&1 || g remote add upstream "https://github.com/$ORG/$repo.git"
  g fetch -q --no-tags upstream "$UPSTREAM_BRANCH"
  g checkout -q -B "$UPSTREAM_BRANCH" "upstream/$UPSTREAM_BRANCH"
  g branch -q --set-upstream-to "upstream/$UPSTREAM_BRANCH" "$UPSTREAM_BRANCH"
  echo "ready: $SRC on $UPSTREAM_BRANCH (tracks upstream). Next: ./oan.sh src branch $id <feature-name>"
}

branch() {
  local id="$1" name="${2:-}"
  [ -n "$name" ] || { echo "usage: ./oan.sh src branch <registry> <branch-name>" >&2; exit 1; }
  need_src "$id"
  dirty && { echo "uncommitted changes in $SRC: commit or stash them first" >&2; exit 1; }
  g fetch -q --no-tags upstream "$UPSTREAM_BRANCH"
  g checkout -q -b "$name" "upstream/$UPSTREAM_BRANCH"
  echo "$SRC: on $name from upstream/$UPSTREAM_BRANCH ($(g rev-parse --short HEAD))"
}

sync() {
  local id="$1" br
  need_src "$id"
  br=$(current_branch)
  g fetch -q --no-tags upstream "$UPSTREAM_BRANCH"
  if [ "$br" = "$UPSTREAM_BRANCH" ]; then
    dirty && { echo "uncommitted changes on $br: commit or stash them first" >&2; exit 1; }
    g merge -q --ff-only "upstream/$UPSTREAM_BRANCH"
  else
    g branch -q -f "$UPSTREAM_BRANCH" "upstream/$UPSTREAM_BRANCH"
    if dirty; then
      echo "uncommitted changes on $br: develop was updated, but your branch was not rebased" >&2
    else
      g rebase -q "upstream/$UPSTREAM_BRANCH" || { echo "rebase stopped on a conflict: resolve in $SRC, then 'git rebase --continue'" >&2; exit 1; }
    fi
  fi
  # keep the fork's develop equal to upstream so its PRs show only your commits
  if [ "$(g remote get-url origin)" != "$(g remote get-url upstream)" ]; then
    g push -q origin "upstream/$UPSTREAM_BRANCH:refs/heads/$UPSTREAM_BRANCH" 2>/dev/null || echo "could not push $UPSTREAM_BRANCH to origin (fork): skipped" >&2
  fi
  echo "$SRC: $br is on top of upstream/$UPSTREAM_BRANCH ($(g rev-parse --short "upstream/$UPSTREAM_BRANCH"))"
  [ "$br" = "$UPSTREAM_BRANCH" ] || echo "rebuild what you run: ./oan.sh reload $id"
}

status() {
  local ids=("$@") id br ab
  [ ${#ids[@]} -gt 0 ] || read -r -a ids <<<"$(reg_ids)"
  for id in "${ids[@]}"; do
    SRC=$(src_dir "$id")
    if [ ! -d "$SRC/.git" ]; then printf '%-7s no checkout (%s)\n' "$id" "$SRC"; continue; fi
    br=$(current_branch)
    g fetch -q --no-tags upstream "$UPSTREAM_BRANCH" 2>/dev/null || true
    ab=$(g rev-list --left-right --count "upstream/$UPSTREAM_BRANCH...HEAD" 2>/dev/null | awk '{printf "behind %s, ahead %s", $1, $2}')
    printf '%-7s %s  %s  %s  %s\n' "$id" "$SRC" "$br" "${ab:-?}" "$(dirty && echo '(uncommitted changes)' || echo clean)"
  done
}

pr() {
  local id="$1" br repo
  need_src "$id"
  repo=$(reg_field "$id" 4)
  br=$(current_branch)
  [ "$br" != "$UPSTREAM_BRANCH" ] || { echo "you are on $UPSTREAM_BRANCH: create a branch first (./oan.sh src branch $id <name>)" >&2; exit 1; }
  dirty && { echo "uncommitted changes in $SRC: commit them first" >&2; exit 1; }
  g fetch -q --no-tags upstream "$UPSTREAM_BRANCH"
  [ "$(g rev-list --count "HEAD..upstream/$UPSTREAM_BRANCH")" = 0 ] || echo "note: upstream $UPSTREAM_BRANCH moved on; ./oan.sh src sync $id rebases you onto it" >&2
  g push -q -u origin "$br"
  local head="$br" owner
  owner=$(g remote get-url origin | sed -E 's#.*github.com[:/]([^/]+)/.*#\1#')
  [ "$owner" = "$ORG" ] || head="$owner:$br"
  if have_gh; then
    gh pr create --repo "$ORG/$repo" --base "$UPSTREAM_BRANCH" --head "$head" --fill --web
  else
    echo "open: https://github.com/$ORG/$repo/compare/$UPSTREAM_BRANCH...$head?expand=1"
  fi
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  clone|branch|sync|pr) [ -n "${1:-}" ] || { echo "usage: ./oan.sh src $cmd <$(reg_ids | sed 's/ $//; s/ /|/g')> ..." >&2; exit 1; }; reg_field "$1" 1 >/dev/null; "$cmd" "$@" ;;
  status) status "$@" ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
