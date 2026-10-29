#!/usr/bin/env bash
## @file update_issue_dependencies.bash
## @brief Add explicit blocked-by issue references as native GitHub dependencies.
##
## @details
## Only references within a level-two "Dependencies" or "Blocked by" section
## are considered.  A missing section makes no changes.  Existing native
## relationships are preserved; this script never removes dependencies.
## Failure to read an issue or its dependency list is fatal for that issue.
## The script treats issue text as untrusted data and only passes validated
## numeric issue identifiers to the GitHub CLI.
##
## Usage:
##   GH_TOKEN=... GH_REPO=owner/repo bash scripts/update_issue_dependencies.bash --issue 123
##   GH_TOKEN=... GH_REPO=owner/repo bash scripts/update_issue_dependencies.bash --all
set -euo pipefail

usage() {
  printf 'Usage: %s (--issue NUMBER | --all) [--repo owner/repo]\n' "${0##*/}" >&2
  exit 2
}
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

mode='' issue='' repo="${GH_REPO:-}"
while (($#)); do
  case "$1" in
    --issue) (($# >= 2)) || usage; mode=issue; issue="$2"; shift 2 ;;
    --all) mode=all; shift ;;
    --repo) (($# >= 2)) || usage; repo="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$mode" == all || ( "$mode" == issue && "$issue" =~ ^[1-9][0-9]*$ ) ]] || usage
[[ -n "${GH_TOKEN:-}" ]] || fail 'GH_TOKEN is required'
command -v gh >/dev/null || fail 'gh is required'
command -v jq >/dev/null || fail 'jq is required'
[[ -n "$repo" ]] || repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'Invalid repository'
api="/repos/$repo"
errors=0

## @brief Extract unique #number references from the dependency section.
## @return One issue number per line, empty output if none are declared.
declared_blockers() {
  local body="$1" section
  section="$(printf '%s\n' "$body" | awk '
    /^##[[:space:]]+(Dependencies|Blocked by)([[:space:]:]|$)/ {active=1; next}
    /^##[[:space:]]+/ {if (active) exit}
    active {print}
  ')"
  # Tokenize on nonreference separators; do not match parts of URLs or
  # unrelated prose outside the explicit section.
  printf '%s\n' "$section" |
    grep -Eo '#[1-9][0-9]*' |
    tr -d '#' |
    sort -nu || true
}

## @brief List complete native blockers; propagate API failures.
## @return JSON array of blocker issue objects.
native_blockers() {
  local n="$1" page=1 batch combined='[]' count
  while :; do
    batch="$(gh api "$api/issues/$n/dependencies/blocked_by?per_page=100&page=$page")" || return 1
    jq -e 'type == "array"' <<<"$batch" >/dev/null || return 1
    combined="$(jq -cn --argjson a "$combined" --argjson b "$batch" '$a + $b')" || return 1
    count="$(jq 'length' <<<"$batch")"
    ((count < 100)) && break
    page=$((page + 1))
  done
  printf '%s\n' "$combined"
}

## @brief Reconcile one issue and verify each newly posted relationship.
reconcile() {
  local n="$1" obj blocker obj_blocker blocker_id native existing current
  obj="$(gh api "$api/issues/$n")" || return 1
  [[ "$(jq -r '.pull_request // empty' <<<"$obj")" == '' ]] || return 0
  native="$(native_blockers "$n")" || { log "ERROR #$n: unable to read native dependencies"; return 1; }
  while IFS= read -r blocker; do
    [[ -n "$blocker" ]] || continue
    [[ "$blocker" != "$n" ]] || { log "CONFLICT #$n: self-blocking declaration"; return 1; }
    existing="$(jq -r --argjson n "$blocker" '[.[] | select(.number == $n)] | length' <<<"$native")" || return 1
    if [[ "$existing" != 0 ]]; then
      log "OK #$n blocked by #$blocker"
      continue
    fi
    obj_blocker="$(gh api "$api/issues/$blocker")" || { log "ERROR #$n: blocker #$blocker unavailable"; return 1; }
    [[ "$(jq -r '.pull_request // empty' <<<"$obj_blocker")" == '' ]] || {
      log "CONFLICT #$n: blocker #$blocker is a pull request"; return 1;
    }
    blocker_id="$(jq -er '.id | select(type == "number" and . > 0)' <<<"$obj_blocker")" || return 1
    gh api --method POST "$api/issues/$n/dependencies/blocked_by" -F "issue_id=$blocker_id" >/dev/null || {
      log "ERROR #$n: failed to add blocker #$blocker"; return 1;
    }
    current="$(native_blockers "$n")" || { log "ERROR #$n: unable to verify blocker"; return 1; }
    [[ "$(jq -r --argjson number "$blocker" '[.[] | select(.number == $number)] | length' <<<"$current")" != 0 ]] || {
      log "ERROR #$n: blocker #$blocker was not persisted"; return 1;
    }
    native="$current"
    log "LINKED #$n blocked by #$blocker"
  done < <(declared_blockers "$(jq -r '.body // ""' <<<"$obj")")
}

if [[ "$mode" == issue ]]; then
  reconcile "$issue" || errors=$((errors + 1))
else
  page=1
  while :; do
    data="$(gh api "$api/issues?state=all&per_page=100&page=$page")" || fail 'Unable to list issues'
    count="$(jq 'length' <<<"$data")"
    ((count > 0)) || break
    while IFS= read -r n; do
      reconcile "$n" || errors=$((errors + 1))
    done < <(jq -r '.[] | select(.pull_request == null) | .number' <<<"$data")
    ((count < 100)) && break
    page=$((page + 1))
  done
fi
((errors == 0)) || fail "$errors dependency reconciliation error(s)"
