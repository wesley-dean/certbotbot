#!/usr/bin/env bash
## @file update_issue_parent_child_relationships.bash
## @brief Reconcile native GitHub task-parent relationships from issue descriptions.
##
## Usage: GH_TOKEN=... GH_REPO=owner/repo bash scripts/update_issue_parent_child_relationships.bash --issue 100
##        GH_TOKEN=... GH_REPO=owner/repo bash scripts/update_issue_parent_child_relationships.bash --all
##
## The first #number under the task's "Parent Story" heading is its
## declaration.  Native relationships are not overwritten if they conflict.
## No approval, milestone, state, or issue-body changes are performed.
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
    --issue) (($# >= 2)) || usage; mode='issue'; issue="$2"; shift 2 ;;
    --all) mode='all'; shift ;;
    --repo) (($# >= 2)) || usage; repo="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$mode" == 'all' || ( "$mode" == 'issue' && "$issue" =~ ^[1-9][0-9]*$ ) ]] || usage
[[ -n "${GH_TOKEN:-}" ]] || fail 'GH_TOKEN is required'
command -v gh >/dev/null || fail 'gh is required'
command -v jq >/dev/null || fail 'jq is required'
if [[ -z "$repo" ]]; then
  repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
fi
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'Invalid repository'
api="/repos/$repo"
errors=0

## @brief Extract the first issue reference in a dedicated parent section.
## @return Prints a positive issue number, or nothing when undeclared.
declared_parent() {
  local body="$1" section
  section="$(printf '%s\n' "$body" | awk '
    /^##[[:space:]]+Parent([[:space:]]|$)/ {active=1; next}
    /^##[[:space:]]+/ {if (active) exit}
    active {print}
  ')"
  if [[ "$section" =~ \#([1-9][0-9]*) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

## @brief Reconcile a task; report conflicts without reparenting.
reconcile() {
  local number="$1" child declared current parent id labels
  child="$(gh api "$api/issues/$number")" || return 1
  [[ "$(jq -r '.pull_request // empty' <<<"$child")" == '' ]] || return 0
  labels="$(jq -r '[.labels[].name] | join(" ")' <<<"$child")"
  [[ " $labels " == *' type:task '* ]] || return 0
  declared="$(declared_parent "$(jq -r '.body // ""' <<<"$child")")"
  [[ -n "$declared" ]] || { log "SKIP #$number: no declared parent"; return 0; }
  [[ "$declared" != "$number" ]] || { log "CONFLICT #$number: self-parent"; return 1; }
  parent="$(gh api "$api/issues/$declared")" || { log "ERROR #$number: parent #$declared unavailable"; return 1; }
  [[ "$(jq -r '.pull_request // empty' <<<"$parent")" == '' ]] || { log "CONFLICT #$number: parent #$declared is a PR"; return 1; }
  [[ "$(jq -r '[.labels[].name] | index("type:story") != null' <<<"$parent")" == 'true' ]] || {
    log "CONFLICT #$number: parent #$declared is not type:story"; return 1;
  }
  current="$(gh api "$api/issues/$number/parent" --silent 2>/dev/null || true)"
  if [[ -n "$current" ]]; then
    id="$(jq -r '.number // empty' <<<"$current")"
    if [[ "$id" == "$declared" ]]; then
      log "OK #$number -> #$declared"; return 0
    fi
    log "CONFLICT #$number: native parent #$id, declared #$declared"; return 1
  fi
  id="$(jq -r '.id' <<<"$child")"
  [[ "$id" =~ ^[1-9][0-9]*$ ]] || { log "ERROR #$number: missing numeric issue ID"; return 1; }
  gh api --method POST "$api/issues/$declared/sub_issues" -F "sub_issue_id=$id" >/dev/null || {
    log "ERROR #$number: failed to create relationship"; return 1;
  }
  current="$(gh api "$api/issues/$number/parent")" || return 1
  [[ "$(jq -r '.number' <<<"$current")" == "$declared" ]] || {
    log "ERROR #$number: relationship not verified"; return 1;
  }
  log "LINKED #$number -> #$declared"
}

if [[ "$mode" == issue ]]; then
  reconcile "$issue" || errors=$((errors + 1))
else
  page=1
  while :; do
    data="$(gh api "$api/issues?state=all&per_page=100&page=$page")" || fail 'Unable to list issues'
    count="$(jq 'length' <<<"$data")"
    ((count > 0)) || break
    while IFS= read -r number; do
      reconcile "$number" || errors=$((errors + 1))
    done < <(jq -r '.[] | select(.pull_request == null) | select([.labels[].name] | index("type:task") != null) | .number' <<<"$data")
    ((count < 100)) && break
    page=$((page + 1))
  done
fi
((errors == 0)) || fail "$errors relationship reconciliation error(s)"
