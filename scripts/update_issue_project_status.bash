#!/usr/bin/env bash
## @file update_issue_project_status.bash
## @brief Mirror issue lifecycle into a configured GitHub Projects v2 Status.
##
## PROJECT_NUMBER unset, empty, or zero disables this operation.  This
## script never modifies GitHub issue labels, state, or approvals.
## Usage: GH_TOKEN=... PROJECT_NUMBER=12 GH_REPO=owner/repo bash scripts/update_issue_project_status.bash --issue 100
##        GH_TOKEN=... PROJECT_NUMBER=12 GH_REPO=owner/repo bash scripts/update_issue_project_status.bash --all
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }
usage() { printf 'Usage: %s (--issue NUMBER | --all) [--repo owner/repo]\n' "${0##*/}" >&2; exit 2; }

mode='' issue='' repo="${GH_REPO:-}" number="${PROJECT_NUMBER:-0}"
while (($#)); do
  case "$1" in
    --issue) (($# >= 2)) || usage; mode=issue; issue="$2"; shift 2 ;;
    --all) mode=all; shift ;;
    --repo) (($# >= 2)) || usage; repo="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$mode" == all || ( "$mode" == issue && "$issue" =~ ^[1-9][0-9]*$ ) ]] || usage
if [[ -z "$number" || "$number" == 0 ]]; then
  log 'SKIP: PROJECT_NUMBER unset or zero'; exit 0
fi
[[ "$number" =~ ^[1-9][0-9]*$ ]] || die 'PROJECT_NUMBER must be a positive integer or zero'
[[ -n "${GH_TOKEN:-}" ]] || die 'GH_TOKEN is required'
command -v gh >/dev/null || die 'gh is required'
command -v jq >/dev/null || die 'jq is required'
if [[ -z "$repo" ]]; then repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"; fi
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'Invalid repository'
owner="${PROJECT_OWNER:-${repo%%/*}}"
[[ "$owner" =~ ^[A-Za-z0-9_.-]+$ ]] || die 'Invalid project owner'

project="$(gh project view "$number" --owner "$owner" --format json)" || die 'Project lookup failed'
project_id="$(jq -r '.id // empty' <<<"$project")"
[[ -n "$project_id" ]] || die 'Project ID missing'
fields="$(gh project field-list "$number" --owner "$owner" --format json)" || die 'Project field lookup failed'
status_field="$(jq -c '[.fields[] | select(.name == "Status")] | first // empty' <<<"$fields")"
[[ -n "$status_field" ]] || die 'No Status field'
field_id="$(jq -r '.id' <<<"$status_field")"
items="$(gh project item-list "$number" --owner "$owner" --limit 10000 --format json)" || die 'Project item lookup failed'
errors=0

## @brief Compute target Status without inventing approval or delivery.
status_for_issue() {
  local obj="$1" state reason labels
  state="$(jq -r '.state' <<<"$obj")"
  reason="$(jq -r '.state_reason // ""' <<<"$obj")"
  labels="$(jq -r '[.labels[].name] | join(" ")' <<<"$obj")"
  if [[ "$state" == closed ]]; then
    [[ "$reason" == completed ]] && printf 'Done'
  elif [[ " $labels " == *' approved '* ]]; then
    if [[ " $labels " == *' in-progress '* ]]; then printf 'In Progress'; else printf 'Todo'; fi
  else
    printf 'Backlog'
  fi
}

## @brief Find and synchronize exactly one issue item in the configured project.
sync_issue() {
  local n="$1" obj status option_id url item_id matches existing
  obj="$(gh api "/repos/$repo/issues/$n")" || return 1
  [[ "$(jq -r '.pull_request // empty' <<<"$obj")" == '' ]] || return 0
  status="$(status_for_issue "$obj")"
  [[ -n "$status" ]] || { log "SKIP #$n: not-planned closure"; return 0; }
  option_id="$(jq -r --arg name "$status" '[.options[]? | select(.name == $name) | .id] | first // empty' <<<"$status_field")"
  [[ -n "$option_id" ]] || { log "SKIP #$n: Status option '$status' unavailable"; return 0; }
  url="$(jq -r '.html_url' <<<"$obj")"
  matches="$(jq -c --arg url "$url" '[.items[] | select(.content.url? == $url)]' <<<"$items")"
  [[ "$(jq 'length' <<<"$matches")" -le 1 ]] || { log "CONFLICT #$n: multiple project items"; return 1; }
  item_id="$(jq -r '.[0].id // empty' <<<"$matches")"
  if [[ -z "$item_id" ]]; then
    # Do not auto-enroll an unapproved proposal unless a Backlog option exists.
    existing="$(gh project item-add "$number" --owner "$owner" --url "$url" --format json)" || return 1
    item_id="$(jq -r '.id // empty' <<<"$existing")"
    [[ -n "$item_id" ]] || return 1
    items="$(jq --arg id "$item_id" --arg url "$url" '.items += [{"id":$id,"content":{"url":$url}}]' <<<"$items")"
  fi
  gh project item-edit --id "$item_id" --project-id "$project_id" --field-id "$field_id" --single-select-option-id "$option_id" >/dev/null || return 1
  log "SYNCED #$n: $status"
}

if [[ "$mode" == issue ]]; then
  sync_issue "$issue" || errors=$((errors + 1))
else
  page=1
  while :; do
    data="$(gh api "/repos/$repo/issues?state=all&per_page=100&page=$page")" || die 'Issue enumeration failed'
    count="$(jq 'length' <<<"$data")"
    ((count > 0)) || break
    while IFS= read -r n; do
      sync_issue "$n" || errors=$((errors + 1))
    done < <(jq -r '.[] | select(.pull_request == null) | .number' <<<"$data")
    ((count < 100)) && break
    page=$((page + 1))
  done
fi
((errors == 0)) || die "$errors project synchronization error(s)"
