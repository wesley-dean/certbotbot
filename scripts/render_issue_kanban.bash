#!/usr/bin/env bash
# shellcheck shell=bash
## @file scripts/render_issue_kanban.bash
## @brief Render approved GitHub stories and tasks as a Markdown Kanban table.
## @details
## Read-only GitHub reporting.  The current approved label controls visibility;
## closed issues are included only when they were completed and remain approved.
## An approved task without an approved/visible parent remains visible in an
## "Standalone tasks" group.  Native parent relationships take precedence.
## This tool never changes issues, labels, dependencies, or project fields.
##
## @par Usage
## @code
## GH_REPO=wesley-dean/certbotbot bash scripts/render_issue_kanban.bash
## bash scripts/render_issue_kanban.bash --repo owner/repo > board.md
## @endcode
set -euo pipefail

usage() {
  printf 'Usage: %s [--repo owner/repo]\n' "${0##*/}" >&2
  exit 2
}

repo="${GH_REPO:-}"
while (($#)); do
  case "$1" in
    --repo) (($# >= 2)) || usage; repo="$2"; shift 2 ;;
    *) usage ;;
  esac
done
command -v gh >/dev/null || { printf 'gh is required\n' >&2; exit 1; }
command -v jq >/dev/null || { printf 'jq is required\n' >&2; exit 1; }
if [[ -z "$repo" ]]; then
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi
[[ "$repo" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || {
  printf 'Invalid repository: %s\n' "$repo" >&2
  exit 2
}
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
printf '[]\n' > "$tmp"
page=1
while :; do
  batch="$(gh api "/repos/$repo/issues?state=all&per_page=100&page=$page")" || {
    printf 'Unable to retrieve issue page %s\n' "$page" >&2
    exit 1
  }
  jq -e 'type == "array"' <<<"$batch" >/dev/null || exit 1
  jq -s '.[0] + (.[1] | map(select(.pull_request == null)))' "$tmp" <(printf '%s\n' "$batch") > "$tmp.next"
  mv "$tmp.next" "$tmp"
  count="$(jq 'length' <<<"$batch")"
  ((count < 100)) && break
  page=$((page + 1))
done

# Native GitHub parent links supersede textual references. The issue's own
# approval is required even when its parent was approved separately.
parents='{}'
while IFS= read -r n; do
  [[ -n "$n" ]] || continue
  if parent="$(gh api "/repos/$repo/issues/$n/parent" 2>/dev/null)"; then
    id="$(jq -r '.number // empty' <<<"$parent")"
    if [[ "$id" =~ ^[1-9][0-9]*$ ]]; then
      parents="$(jq -cn --argjson old "$parents" --arg n "$n" --argjson id "$id" '$old + {($n):$id}')"
    fi
  fi
done < <(jq -r '.[] | select([.labels[].name] | index("approved") != null) | select([.labels[].name] | index("type:task") != null) | .number' "$tmp")

jq -r --arg repo "$repo" --argjson parents "$parents" '
  def labels: [.labels[]?.name];
  def approved: (labels | index("approved") != null);
  def role: if (labels | index("type:story")) then "story"
            elif (labels | index("type:task")) then "task"
            else "other" end;
  def lane: if (labels | index("priority:high")) then "High"
            elif (labels | index("priority:low")) then "Low"
            else "Medium" end;
  def status: if .state == "closed" then
                 if .state_reason == "completed" then "Done" else "Excluded" end
              elif (labels | index("in-progress")) then "In Progress"
              else "Todo" end;
  def clean: gsub("[|\\r\\n]"; " ") | gsub(" +"; " ");
  def link: "[#\(.number) \(.title | clean)](\(.html_url))";
  [ .[] | select(approved) | select(role != "other") |
    . + {role:role, lane:lane, status:status} |
    select(.status != "Excluded")
  ] as $issues |
  ($issues | map(select(.role == "story"))) as $stories |
  ($issues | map(select(.role == "task"))) as $tasks |
  def block($lane; $status):
    ($stories | map(select(.lane == $lane and .status == $status)) | sort_by(.number)) as $in |
    ($in | map(. as $s |
      ($tasks | map(select(($parents[(.number|tostring)] // -1) == $s.number)) | sort_by(.number)) as $children |
      "**\($s | link)**" +
      (if ($children|length) > 0 then
         "<br>" + ($children | map("↳ " + link) | join("<br>"))
       else "" end))) as $groups |
    ($tasks | map(select(.lane == $lane and .status == $status) |
      select(($parents[(.number|tostring)] // -1) as $p |
        ($stories | any(.number == $p and .lane == $lane and .status == $status)) | not))
      | sort_by(.number)) as $other |
    (($groups + (if ($other|length) > 0 then
         ["**Standalone / cross-lane tasks**<br>" + ($other | map("↳ " + link) | join("<br>"))]
       else [] end)) | join("<br><br>")) as $out |
    if $out == "" then "—" else $out end;
  "# Kanban — \($repo)",
  "",
  "Only currently approved issues are shown. Medium includes unlabeled normal priority.",
  "Technical tasks appear beneath their story when both share a priority/status cell; cross-lane tasks are shown separately to preserve their actual state.",
  "",
  "| Priority | Todo | In Progress | Done |",
  "|:--|:--|:--|:--|",
  (["High","Medium","Low"][] as $lane |
    "| **\($lane)** | \(block($lane; "Todo")) | \(block($lane; "In Progress")) | \(block($lane; "Done")) |")
' "$tmp"
