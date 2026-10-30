#!/usr/bin/env bash
# shellcheck shell=bash
## @file tests/issue-kanban-report.bash
## @brief Mock live issue data and check Kanban visibility and swimlanes.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'api /repos/example/repo/issues?state=all&per_page=100&page=1')
    cat <<'JSON'
[
 {"number":1,"title":"Story high","html_url":"https://github.com/example/repo/issues/1","state":"open","labels":[{"name":"approved"},{"name":"type:story"},{"name":"priority:high"}]},
 {"number":2,"title":"Task high","html_url":"https://github.com/example/repo/issues/2","state":"open","labels":[{"name":"approved"},{"name":"type:task"},{"name":"priority:high"}]},
 {"number":3,"title":"Invisible task","html_url":"https://github.com/example/repo/issues/3","state":"open","labels":[{"name":"type:task"}]},
 {"number":4,"title":"Task in progress","html_url":"https://github.com/example/repo/issues/4","state":"open","labels":[{"name":"approved"},{"name":"type:task"},{"name":"in-progress"},{"name":"priority:high"}]},
 {"number":5,"title":"Story medium","html_url":"https://github.com/example/repo/issues/5","state":"closed","state_reason":"completed","labels":[{"name":"approved"},{"name":"type:story"}]},
 {"number":6,"title":"Declined","html_url":"https://github.com/example/repo/issues/6","state":"closed","state_reason":"not_planned","labels":[{"name":"approved"},{"name":"type:story"}]}
]
JSON
    ;;
  'api /repos/example/repo/issues/2/parent'|'api /repos/example/repo/issues/4/parent')
    printf '{"number":1}\n' ;;
  *) printf 'Unexpected gh: %s\n' "$*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$work/bin/gh"
PATH="$work/bin:$PATH" GH_REPO=example/repo bash "$root/scripts/render_issue_kanban.bash" > "$work/board.md"
grep -Fq '| Priority | Todo | In Progress | Done |' "$work/board.md"
grep -Fq 'Story high' "$work/board.md"
grep -Fq '↳ [#2 Task high]' "$work/board.md"
grep -Fq 'Task in progress' "$work/board.md"
grep -Fq 'Story medium' "$work/board.md"
! grep -Fq 'Invisible task' "$work/board.md"
! grep -Fq 'Declined' "$work/board.md"
printf 'Markdown Kanban report mock checks passed\n'
