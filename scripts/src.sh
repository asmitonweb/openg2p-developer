#!/usr/bin/env bash
# Source checkouts of the components in oan-workspace/: one folder per COSS repository, cloned
# from github.com/Centre-for-Open-Societal-Systems on the `develop` branch. `./oan.sh up` keeps
# the workspace complete for the selected components; `./oan.sh dev` builds the images from it.
#
#   src.sh clone  [component...]   clone what is missing (every repository when none is named);
#                                  an existing checkout is never touched
#   src.sh status [component...]   branch, ahead/behind COSS develop, uncommitted files
#   src.sh sync   [component...]   bring the checkout up to date with COSS develop before a PR:
#                                  fetch COSS develop (never your fork), stash your uncommitted
#                                  work, rebase the branch onto it (develop itself fast-forwards),
#                                  pop the stash; stops on the first conflict and says how to
#                                  finish; exit 1 when any checkout needed your attention
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
ORG_PATH=Centre-for-Open-Societal-Systems
BRANCH="${OAN_SRC_REF:-develop}"
WORKSPACE="${OAN_SRC_DIR:-oan-workspace}"
NL=$'\n'

src_dir() {  # src_dir <id>  -> absolute path of the checkout (may not exist yet)
  # OAN_<ID>_SRC (component id) or OAN_<REPO>_SRC (repository; consent-manager and the partner
  # portal share one) point at a checkout of your own instead of the workspace folder.
  local repo var rvar p
  repo=$(comp_field "$1" 7)
  var="OAN_$(tr '[:lower:]-' '[:upper:]_' <<<"$1")_SRC"
  rvar="OAN_$(tr '[:lower:]-' '[:upper:]_' <<<"$repo")_SRC"
  p="${!var:-${!rvar:-$WORKSPACE/$repo}}"
  case "$p" in /*|[A-Za-z]:*) ;; *) p="$ROOT/$p" ;; esac
  # Git for Windows: MSYS_NO_PATHCONV is set, so native git must get D:/... not /d/...
  if command -v cygpath >/dev/null 2>&1; then p=$(cygpath -m "$p"); fi
  printf '%s' "$p"
}
g() { git -C "$SRC" "$@"; }

coss_remote() {  # coss_remote <repo>: the remote that points at the COSS repository (origin on a
  # fresh clone, upstream after the rename in the guide); never a fork. Empty when there is none.
  local r url
  for r in $(g remote); do
    url=$(g remote get-url "$r" 2>/dev/null) || continue
    case "${url%/}" in *"$ORG_PATH/$1"|*"$ORG_PATH/$1.git") echo "$r"; return ;; esac
  done
}

current_branch() { g symbolic-ref --short -q HEAD || echo HEAD; }   # HEAD = detached or unborn

in_progress() {  # a rebase, merge, cherry-pick or revert is under way in $SRC
  local p path
  for p in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    path=$(g rev-parse --git-path "$p")                       # relative to the checkout unless absolute
    case "$path" in /*|[A-Za-z]:*) ;; *) path="$SRC/$path" ;; esac
    [ -e "$path" ] && return 0
  done
  return 1
}

each_checkout() {  # each_checkout <fn> [component...]: fn <id> with SRC set, once per repository;
  # returns 1 when any call did
  local fn=$1 ids id SRC seen="$NL" rc=0; shift
  ids=("$@")
  [ ${#ids[@]} -gt 0 ] || read -r -a ids <<<"$(comp_ids)"
  for id in "${ids[@]}"; do
    [ "$(comp_field "$id" 7)" != - ] || continue
    SRC=$(src_dir "$id")
    case "$seen" in *"$NL$SRC$NL"*) continue ;; esac; seen+="$SRC$NL"   # consent-manager and the partner portal share a repository
    "$fn" "$id" || rc=1
  done
  return $rc
}

clone_one() {
  local repo; repo=$(comp_field "$1" 7)
  if [ -e "$SRC/.git" ]; then note "$repo: $SRC ($(current_branch))"; return; fi
  note "cloning $ORG/$repo ($BRANCH) into $SRC"
  mkdir -p "$(dirname "$SRC")"
  git -c core.autocrlf=false clone -q --branch "$BRANCH" "$ORG/$repo.git" "$SRC"
  g config core.autocrlf false
  ok "$repo: $SRC"
}

status_one() {
  local id=$1 br remote ab
  if [ ! -e "$SRC/.git" ]; then printf '%-22s no checkout (%s)\n' "$id" "$SRC"; return; fi
  br=$(current_branch)
  remote=$(coss_remote "$(comp_field "$id" 7)")
  if [ -n "$remote" ]; then
    g fetch -q --no-tags "$remote" "+refs/heads/$BRANCH:refs/remotes/$remote/$BRANCH" 2>/dev/null || true
    ab=$(g rev-list --left-right --count "$remote/$BRANCH...HEAD" 2>/dev/null | awk '{printf "behind %s, ahead %s", $1, $2}' || true)
  else
    ab="no COSS remote"
  fi
  printf '%-22s %s  %s  %s  %s\n' "$id" "$SRC" "$br" "${ab:-?}" "$([ -n "$(g status --porcelain)" ] && echo '(uncommitted changes)' || echo clean)"
}

pop_back() {  # restore the stash after a step that changed nothing
  [ "$1" = 1 ] || return 0
  if g stash pop -q >/dev/null; then note "stash popped"; else warn "stash pop failed; your work is in: git stash list"; fi
}

sync_one() {  # fetch COSS develop -> stash -> rebase (develop: fast-forward) -> pop; return 1 when stopped
  local id=$1 repo br remote target stashed=0 before after ahead hint=""
  repo=$(comp_field "$id" 7)
  if [ ! -e "$SRC/.git" ]; then note "$repo: no checkout ($SRC), skipped"; return 0; fi
  if in_progress; then
    warn "$repo: a rebase, merge, cherry-pick or revert is in progress in $SRC; finish or abort it first"; return 1
  fi
  br=$(current_branch)
  if [ "$br" = HEAD ]; then warn "$repo: detached HEAD (or no commits yet) in $SRC; switch to your branch first"; return 1; fi
  remote=$(coss_remote "$repo")
  if [ -z "$remote" ]; then
    g remote add upstream "$ORG/$repo.git" || { warn "$repo: could not add the COSS remote in $SRC"; return 1; }
    remote=upstream; note "$repo: remote upstream added -> $ORG/$repo.git (COSS, never your fork)"
  fi
  target="$remote/$BRANCH"
  step "$repo: $br onto $target"
  if ! g fetch -q --no-tags "$remote" "+refs/heads/$BRANCH:refs/remotes/$remote/$BRANCH"; then
    warn "$repo: cannot fetch $BRANCH from $remote ($(g remote get-url "$remote")); nothing changed"; return 1
  fi
  if [ "$br" = "$BRANCH" ] && [ "$(g rev-list --count "$target..HEAD")" != 0 ]; then
    warn "$repo: $BRANCH has commits that are not on $target; never commit on $BRANCH. Move them to a branch:"
    echo "    git -C \"$SRC\" switch -c <change-name> && git -C \"$SRC\" branch -f $BRANCH $target" >&2
    return 1
  fi
  if [ "$(g rev-list --count "HEAD..$target")" = 0 ]; then   # nothing new on COSS: leave the tree alone
    ahead=$(g rev-list --count "$target..HEAD")
    [ "$(comp_kind "$id")" = source ] || hint="; ./oan.sh reload $id to run it"
    if [ "$ahead" = 0 ]; then ok "$repo: $br is at $target$hint"; else ok "$repo: $br is already on top of $target ($ahead commit(s) ahead)$hint"; fi
    return 0
  fi
  if [ -n "$(g status --porcelain)" ]; then
    before=$(g rev-parse -q --verify refs/stash || true)
    if ! g stash push -q -u -m "oan sync $(date +%Y-%m-%dT%H:%M)"; then
      warn "$repo: could not stash the uncommitted work in $SRC (see git status); nothing changed"; return 1
    fi
    after=$(g rev-parse -q --verify refs/stash || true)
    if [ "$before" != "$after" ]; then stashed=1; note "uncommitted work stashed (git stash list)"; fi
  fi
  if [ "$br" = "$BRANCH" ]; then
    if ! g merge -q --ff-only "$target" >/dev/null; then
      warn "$repo: could not fast-forward $BRANCH to $target (see the git message above)"
      pop_back "$stashed"; return 1
    fi
  elif ! g rebase -q "$target"; then
    if in_progress; then
      warn "$repo: rebase stopped on a conflict. In $SRC:"
      echo "    fix the conflicts, git add <files>, git rebase --continue   (or git rebase --abort)" >&2
      [ "$stashed" = 1 ] && echo "    then git stash pop  (your uncommitted work is kept in the stash until you do)" >&2
    else
      warn "$repo: rebase onto $target did not start (see the git message above)"
      pop_back "$stashed"
    fi
    return 1
  fi
  if [ "$stashed" = 1 ]; then
    if g stash pop -q >/dev/null; then
      note "stash popped"
    else
      warn "$repo: your uncommitted work conflicts with the new $target. In $SRC:"
      echo "    fix the conflicting or colliding files, git add <files>, then git stash drop  (the stash is kept until you drop it)" >&2
      return 1
    fi
  fi
  ahead=$(g rev-list --count "$target..HEAD")
  [ "$(comp_kind "$id")" = source ] || hint="; ./oan.sh reload $id to run it"
  if [ "$ahead" = 0 ]; then
    ok "$repo: $br is at $target$hint"
  else
    ok "$repo: $br rebased, $ahead commit(s) ahead of $target$hint"
    note "already pushed? the rebase rewrote the commits: git push --force-with-lease"
  fi
  return 0
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  clone|status|sync)
    for id in "$@"; do comp_field "$id" 1 >/dev/null; done
    each_checkout "${cmd}_one" "$@" ;;
  dir) [ -n "${1:-}" ] || { echo "usage: src.sh dir <component>" >&2; exit 1; }; comp_field "$1" 1 >/dev/null; src_dir "$1"; echo ;;
  *) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
