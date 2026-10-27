#!/usr/bin/env bash
# Put the mirror-and-publish workflow (ci/fork-mirror-and-images.yml) on a personal fork of a
# COSS repository, on its own branch `oan-ci`, and make that branch the fork's default so the
# schedule runs. Nothing is cloned; the GitHub API writes the file.
#
#   ci/install-fork-workflow.sh <component>...        from the catalogue (scripts/components.sh)
#   ci/install-fork-workflow.sh --repo <coss-repo> --product <product> [--branch develop] \
#                               <role>=<dockerfile>[:<context>]...
#
# Afterwards, once per package: GitHub → your profile → Packages → <product>/<role> → Package
# settings → Change visibility → Public. Pushes keep the visibility. Actions on a fresh fork
# must be enabled once in the fork's Actions tab if the API call below is refused.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source scripts/components.sh
ORG=Centre-for-Open-Societal-Systems

role_specs() { local role; for role in $(comp_roles "$1"); do printf '%s=%s
' "$role" "$(comp_dockerfile "$1" "$role")"; done; }

install() {  # install <repo> <product> <branch> <role=dockerfile:context>...
  local repo="$1" product="$2" branch="$3"; shift 3
  local me fork wf matrix spec role df ctx
  me=$(gh api user --jq .login); fork="$me/$repo"
  gh repo view "$fork" >/dev/null 2>&1 || { echo "forking $ORG/$repo"; gh repo fork "$ORG/$repo" --clone=false >/dev/null; sleep 5; }

  matrix=""
  for spec in "$@"; do
    role=${spec%%=*}; df=${spec#*=}; ctx=${df#*:}; df=${df%%:*}
    matrix+="          - { role: $role, dockerfile: $df, context: $ctx }"$'\n'
  done
  # Replace the env block values and the whole example matrix with this repository's.
  wf=$(awk -v up="$ORG/$repo" -v prod="$product" -v br="$branch" -v m="$matrix" '
    /^  UPSTREAM: /       {print "  UPSTREAM: " up; next}
    /^  PRODUCT: /        {print "  PRODUCT: " prod; next}
    /^  MIRROR_BRANCH: /  {print "  MIRROR_BRANCH: " br; next}
    /^        include:$/  {print; printf "%s", m; skip=1; next}
    skip && /^          - \{/ {next}
    {skip=0; print}' ci/fork-mirror-and-images.yml)

  local default sha path existing content
  default=$(gh api "repos/$fork" --jq .default_branch)
  if ! gh api "repos/$fork/branches/oan-ci" >/dev/null 2>&1; then
    sha=$(gh api "repos/$fork/git/ref/heads/$default" --jq .object.sha)
    gh api -X POST "repos/$fork/git/refs" -f ref=refs/heads/oan-ci -f sha="$sha" >/dev/null
    echo "  created oan-ci from $default"
  fi
  path=.github/workflows/oan-images.yml
  existing=$(gh api "repos/$fork/contents/$path?ref=oan-ci" --jq .sha 2>/dev/null || true)
  content=$(printf '%s\n' "$wf" | base64 -w0)
  gh api -X PUT "repos/$fork/contents/$path" -f branch=oan-ci -f message="Mirror $ORG/$repo $branch and publish OAN images" \
    -f content="$content" ${existing:+-f sha="$existing"} >/dev/null
  echo "  workflow: $fork@oan-ci:$path ($*)"
  [ "$default" = oan-ci ] || { gh api -X PATCH "repos/$fork" -f default_branch=oan-ci >/dev/null; echo "  default branch -> oan-ci"; }
  gh api -X PUT "repos/$fork/actions/permissions" -F enabled=true -f allowed_actions=all >/dev/null 2>&1 || echo "  note: could not enable Actions by API; open https://github.com/$fork/actions once"
  sleep 2
  if gh workflow run oan-images.yml --repo "$fork" --ref oan-ci >/dev/null 2>&1; then
    echo "  dispatched: https://github.com/$fork/actions"
  else
    echo "  NOT dispatched (enable Actions in the browser, then: gh workflow run oan-images.yml --repo $fork --ref oan-ci)"
  fi
}

if [ "${1:-}" = --repo ]; then
  repo=""; product=""; branch=develop; specs=()
  while [ $# -gt 0 ]; do
    case "$1" in --repo) repo="$2"; shift 2 ;; --product) product="$2"; shift 2 ;; --branch) branch="$2"; shift 2 ;; *) specs+=("$1"); shift ;; esac
  done
  [ -n "$repo" ] && [ -n "$product" ] && [ ${#specs[@]} -gt 0 ] || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
  echo "$repo:"; install "$repo" "$product" "$branch" "${specs[@]}"
  exit 0
fi
[ $# -gt 0 ] || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
# Several components can share one repository (consent-manager and consent-partner-portal): merge their roles.
declare -A by_repo product_of
for id in "$@"; do
  repo=$(comp_field "$id" 7); product=$(comp_field "$id" 8)
  [ "$product" != - ] || { echo "$id ships no image; skipped"; continue; }
  by_repo[$repo]+="$(role_specs "$id" | tr '\n' ' ')"; product_of[$repo]=$product
done
for repo in "${!by_repo[@]}"; do
  echo "$repo:"
  # shellcheck disable=SC2086
  install "$repo" "${product_of[$repo]}" develop ${by_repo[$repo]}
done
