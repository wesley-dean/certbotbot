#!/usr/bin/env bash
## @file issue-dependencies-sync.bash
## @brief Offline mocked tests for additive native issue dependency syncing.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'api /repos/example/repo/issues/100')
    if [[ "${MOCK_GOVERNANCE:-0}" == 1 ]]; then
      printf '%s\n' '{"id":1000,"number":100,"body":"## Dependencies and Governing Decisions\n\n#89, #90, and #88 are background references.\n## Verification\nNo blockers."}'
      exit 0
    fi
    printf '{"id":1000,"number":100,"body":"## Blocked by\\n\\n- #89\\n- #90\\n## Acceptance\\n#88 is not a dependency.","labels":[{"name":"type:task"}]}\n' ;;
  'api /repos/example/repo/issues/89')
    printf '{"id":890,"number":89}\n' ;;
  'api /repos/example/repo/issues/90')
    printf '{"id":900,"number":90}\n' ;;
  'api /repos/example/repo/issues/100/dependencies/blocked_by?per_page=100&page=1')
    if [[ "${MOCK_GET_ERROR:-0}" == 1 ]]; then
      printf 'gh: HTTP 403\n' >&2; exit 1
    fi
    if [[ "${MOCK_EXISTING:-0}" == 1 ]]; then
      printf '[{"number":89,"id":890},{"number":90,"id":900}]\n'
    elif [[ -f "$MOCK_STATE/90" ]]; then
      printf '[{"number":89,"id":890},{"number":90,"id":900}]\n'
    elif [[ -f "$MOCK_STATE/89" ]]; then
      printf '[{"number":89,"id":890}]\n'
    else
      printf '[]\n'
    fi ;;
  'api --method POST /repos/example/repo/issues/100/dependencies/blocked_by -F issue_id=890')
    [[ "${MOCK_POST_ERROR:-0}" != 1 ]] || exit 1
    printf '89\n' >> "$MOCK_STATE/writes"
    touch "$MOCK_STATE/89"
    printf '{}\n' ;;
  'api --method POST /repos/example/repo/issues/100/dependencies/blocked_by -F issue_id=900')
    [[ "${MOCK_POST_ERROR:-0}" != 1 ]] || exit 1
    printf '90\n' >> "$MOCK_STATE/writes"
    touch "$MOCK_STATE/90"
    printf '{}\n' ;;
  *) printf 'Unexpected API invocation: %s\n' "$*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" GH_REPO=example/repo GH_TOKEN=fake MOCK_STATE="$work"
script="$root/scripts/update_issue_dependencies.bash"

MOCK_GOVERNANCE=1 bash "$script" --issue 100 > "$work/output"
[[ ! -e "$work/writes" ]] || { printf 'Governance references incorrectly linked\n' >&2; exit 1; }
bash "$script" --issue 100 > "$work/output"
grep -q 'LINKED #100 blocked by #89' "$work/output"
grep -q 'LINKED #100 blocked by #90' "$work/output"
[[ "$(wc -l < "$work/writes")" -eq 2 ]]
! grep -q '88' "$work/writes"
bash "$script" --issue 100 > "$work/output"
grep -q 'OK #100 blocked by #89' "$work/output"
[[ "$(wc -l < "$work/writes")" -eq 2 ]]
if MOCK_GET_ERROR=1 bash "$script" --issue 100 > "$work/output" 2>&1; then
  printf 'Dependency API failure was ignored\n' >&2; exit 1
fi
[[ "$(wc -l < "$work/writes")" -eq 2 ]]
if MOCK_POST_ERROR=1 MOCK_EXISTING=0 bash "$script" --issue 100 > "$work/output" 2>&1; then
  # Existing state means no POST should be attempted, so this is not the
  # right way to test a POST failure; clear mocked state and retry below.
  :
fi
rm -f "$work/89" "$work/90"
if MOCK_POST_ERROR=1 bash "$script" --issue 100 > "$work/output" 2>&1; then
  printf 'Dependency POST failure was ignored\n' >&2; exit 1
fi
[[ "$(wc -l < "$work/writes")" -eq 2 ]]
printf 'Native dependency synchronization mock tests passed\n'
