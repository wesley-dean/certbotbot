#!/usr/bin/env bash
# shellcheck shell=bash
## @file scripts/publish_issue_kanban.bash
## @brief Publish a generated Markdown Kanban report into one managed GitHub issue.
## @details
## Exact title matching and a body marker protect unrelated issues.  Duplicate
## exact titles cause a hard failure.  Newly created issues remain unapproved
## and without story/task type, so they cannot appear on the generated board.
## The script writes only the target issue's body after ownership verification.
## It never modifies labels, state, milestones, or issue relationships.
##
## @par Usage
## @code
## GH_REPO=owner/repo GH_TOKEN=... bash scripts/publish_issue_kanban.bash
## KANBAN_ISSUE_TITLE="Development Kanban" bash scripts/publish_issue_kanban.bash
## @endcode
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
repo="${GH_REPO:-}"
title="${KANBAN_ISSUE_TITLE:-Development Kanban}"
marker='<!-- managed-by: render_issue_kanban.bash -->'

while (($#)); do
  case "$1" in
    --repo) (($# >= 2)) || die '--repo requires owner/repo'; repo="$2"; shift 2 ;;
    --title) (($# >= 2)) || die '--title requires text'; title="$2"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "${GH_TOKEN:-}" ]] || die 'GH_TOKEN is required'
command -v gh >/dev/null || die 'gh is required'
command -v jq >/dev/null || die 'jq is required'
[[ -n "$repo" ]] || repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'Invalid repository'
[[ -n "$title" && "$title" != *$'\n'* ]] || die 'Invalid issue title'
api="/repos/$repo"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
issues="$tmp/issues.json"
printf '[]\n' > "$issues"

page=1
while :; do
  batch="$(gh api "$api/issues?state=all&per_page=100&page=$page")" || die 'Unable to enumerate issues'
  jq -e 'type == "array"' <<<"$batch" >/dev/null || die 'Invalid issue listing'
  jq -s '.[0] + (.[1] | map(select(.pull_request == null)))' "$issues" <(printf '%s\n' "$batch") > "$tmp/next"
  mv "$tmp/next" "$issues"
  count="$(jq 'length' <<<"$batch")"
  ((count < 100)) && break
  page=$((page + 1))
done

matches="$(jq -c --arg title "$title" '[.[] | select(.title == $title)]' "$issues")"
count="$(jq 'length' <<<"$matches")"
((count <= 1)) || die "Multiple issues have the exact title '$title'; refusing to choose"

if ((count == 1)); then
  number="$(jq -r '.[0].number' <<<"$matches")"
  existing="$(gh api "$api/issues/$number")" || die 'Unable to verify existing target issue'
  [[ "$(jq -r '.title' <<<"$existing")" == "$title" ]] || die 'Target issue title changed during lookup'
  body="$(jq -r '.body // ""' <<<"$existing")"
  [[ "$body" == *"$marker"* ]] || die "Issue #$number has the title but is not marked as managed; refusing overwrite"
else
  number=''
fi

# Generate completely before mutating anything. A failed renderer must leave
# the current published board untouched.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_REPO="$repo" bash "$script_dir/render_issue_kanban.bash" > "$tmp/board.md" || die 'Kanban generation failed'
[[ -s "$tmp/board.md" ]] || die 'Refusing to publish an empty board'
{ printf '%s\n\n' "$marker"; cat "$tmp/board.md"; } > "$tmp/body.md"
jq -n --arg title "$title" --rawfile body "$tmp/body.md" '{title:$title,body:$body}' > "$tmp/payload.json"

if [[ -n "$number" ]]; then
  [[ "$body" == "$(cat "$tmp/body.md")" ]] && {
    printf 'UNCHANGED issue #%s\n' "$number"
    exit 0
  }
  gh api --method PATCH "$api/issues/$number" --input "$tmp/payload.json" >/dev/null || die 'Issue update failed'
  printf 'UPDATED issue #%s\n' "$number"
else
  response="$(gh api --method POST "$api/issues" --input "$tmp/payload.json")" || die 'Issue creation failed'
  number="$(jq -er '.number | select(type == "number")' <<<"$response")" || die 'Issue creation response was invalid'
  printf 'CREATED issue #%s\n' "$number"
fi
