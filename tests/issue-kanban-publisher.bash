#!/usr/bin/env bash
# shellcheck shell=bash
## @file tests/issue-kanban-publisher.bash
## @brief Exercise Kanban issue creation, updates, and ownership safeguards.
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
    case "${CASE:-create}" in
      create) printf '[]\n' ;;
      existing|unmanaged)
        printf '[{"number":500,"title":"Development Kanban"}]\n' ;;
      duplicate)
        printf '[{"number":500,"title":"Development Kanban"},{"number":501,"title":"Development Kanban"}]\n' ;;
    esac ;;
  'api /repos/example/repo/issues/500')
    if [[ "${CASE:-}" == unmanaged ]]; then
      printf '{"number":500,"title":"Development Kanban","body":"Human-authored"}\n'
    else
      printf '{"number":500,"title":"Development Kanban","body":"<!-- managed-by: render_issue_kanban.bash -->\\nOld board"}\n'
    fi ;;
  'api /repos/example/repo/issues/500/parent') exit 1 ;;
  'api /repos/example/repo/issues/1/parent') exit 1 ;;
  'api /repos/example/repo/issues?state=all&per_page=100&page=2')
    printf '[]\n' ;;
  'api --method POST /repos/example/repo/issues --input '*)
    cp "${*: -1}" "$MOCK_HOME/payload.json"
    printf '{"number":501}\n' ;;
  'api --method PATCH /repos/example/repo/issues/500 --input '*)
    cp "${*: -1}" "$MOCK_HOME/payload.json"
    printf '{"number":500}\n' ;;
  *)
    # Renderer listing shares the same endpoint as the publisher.
    printf 'Unexpected gh command: %s\n' "$*" >&2
    exit 1 ;;
esac
MOCK
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" GH_REPO=example/repo GH_TOKEN=test-token MOCK_HOME="$work"
export KANBAN_ISSUE_TITLE='Development Kanban'
publisher="$root/scripts/publish_issue_kanban.bash"

CASE=create bash "$publisher" > "$work/log"
grep -q 'CREATED issue #501' "$work/log"
jq -e '.title == "Development Kanban" and (.body | contains("managed-by: render_issue_kanban.bash"))' "$work/payload.json" >/dev/null
rm -f "$work/payload.json"

CASE=existing bash "$publisher" > "$work/log"
grep -q 'UPDATED issue #500' "$work/log"
[[ -s "$work/payload.json" ]]
rm -f "$work/payload.json"

if CASE=unmanaged bash "$publisher" >/dev/null 2>&1; then
  printf 'Unmanaged issue was overwritten\n' >&2; exit 1
fi
[[ ! -e "$work/payload.json" ]]
if CASE=duplicate bash "$publisher" >/dev/null 2>&1; then
  printf 'Duplicate exact titles were accepted\n' >&2; exit 1
fi
[[ ! -e "$work/payload.json" ]]
printf 'Kanban publisher mock checks passed\n'
