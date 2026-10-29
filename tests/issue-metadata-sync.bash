#!/usr/bin/env bash
## @file issue-metadata-sync.bash
## @brief Credential-free mocked acceptance tests for metadata synchronization.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
cmd="$*"
case "$cmd" in
  'api /repos/example/repo/issues/100')
    case "${MOCK_ISSUE_MODE:-todo}" in
      progress) printf '%s\n' '{"number":100,"state":"open","labels":[{"name":"approved"},{"name":"in-progress"}],"html_url":"https://github.com/example/repo/issues/100"}'; exit 0 ;;
      done) printf '%s\n' '{"number":100,"state":"closed","state_reason":"completed","labels":[],"html_url":"https://github.com/example/repo/issues/100"}'; exit 0 ;;
      declined) printf '%s\n' '{"number":100,"state":"closed","state_reason":"not_planned","labels":[],"html_url":"https://github.com/example/repo/issues/100"}'; exit 0 ;;
    esac
    printf '%s\n' '{"id":10000,"number":100,"body":"## Parent Story or Maintenance Exception\n\n#89 - test parent.\n\n## Objective\n","labels":[{"name":"type:task"},{"name":"approved"}],"state":"open","html_url":"https://github.com/example/repo/issues/100"}' ;;
  'api /repos/example/repo/issues/89')
    printf '%s\n' '{"id":8900,"number":89,"labels":[{"name":"type:story"}]}' ;;
  'api /repos/example/repo/issues/100/parent')
    case "${MOCK_PARENT_MODE:-missing}" in
      missing) if [[ -f "$MOCK_STATE/linked" ]]; then printf '{"number":89}\n'; else printf 'gh: HTTP 404: Not Found\n' >&2; exit 1; fi ;;
      forbidden) printf 'gh: HTTP 403: Forbidden\n' >&2; exit 1 ;;
      ratelimited) printf 'gh: HTTP 429: Rate limit\n' >&2; exit 1 ;;
      linked) printf '{"number":89}\n' ;;
      conflict) printf '{"number":88}\n' ;;
      malformed) printf '{"wrong":"payload"}\n' ;;
    esac ;;
  'api --method POST /repos/example/repo/issues/89/sub_issues -F sub_issue_id=10000')
    if [[ "${MOCK_POST_FAIL:-0}" == 1 ]]; then exit 1; fi
    printf '%s\n' "$cmd" >> "$MOCK_STATE/writes"
    touch "$MOCK_STATE/linked"
    printf '{}\n' ;;
  'project view 12 --owner example --format json')
    printf '%s\n' '{"id":"PVT_12"}' ;;
  'project field-list 12 --owner example --format json')
    printf '%s\n' '{"fields":[{"id":"FIELD_1","name":"Status","options":[{"id":"O_TODO","name":"Todo"},{"id":"O_PROGRESS","name":"In Progress"},{"id":"O_DONE","name":"Done"},{"id":"O_BACKLOG","name":"Backlog"}]}]}' ;;
  'project item-list 12 --owner example --limit 10000 --format json')
    if [[ "${MOCK_ITEM_MODE:-existing}" == absent ]]; then
      printf '{"items":[]}\n'
    else
      printf '{"items":[{"id":"ITEM_1","content":{"url":"https://github.com/example/repo/issues/100"}}]}\n'
    fi ;;
  'project item-add 12 --owner example --url https://github.com/example/repo/issues/100 --format json')
    printf '%s\n' "$cmd" >> "$MOCK_STATE/writes"
    printf '{"id":"ITEM_2"}\n' ;;
  project\ item-edit*)
    if [[ "${MOCK_EDIT_FAIL:-0}" == 1 ]]; then exit 1; fi
    printf '%s\n' "$cmd" >> "$MOCK_STATE/writes" ;;
  *) printf 'Unexpected gh invocation: %s\n' "$cmd" >&2; exit 1 ;;
esac
MOCK
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" MOCK_STATE="$work" GH_REPO=example/repo GH_TOKEN=mocked-token
parent="$root/scripts/update_issue_parent_child_relationships.bash"
project="$root/scripts/update_issue_project_status.bash"

# Verify 404 enables a create, without real GitHub mutations.
MOCK_PARENT_MODE=missing MOCK_POST_FAIL=0 bash "$parent" --issue 100 >/dev/null 2>&1 || {
  # The post-read must report the newly linked parent; the mock below switches
  # mode after POST to represent the remote state transition.
  printf 'Parent creation did not complete\n' >&2; exit 1;
}
[[ "$(grep -c 'sub_issue_id=10000' "$work/writes")" == 1 ]] || exit 1
: > "$work/writes"
MOCK_PARENT_MODE=linked bash "$parent" --issue 100 >/dev/null
[[ ! -s "$work/writes" ]] || exit 1
for mode in forbidden ratelimited conflict malformed; do
  if MOCK_PARENT_MODE="$mode" bash "$parent" --issue 100 >/dev/null 2>&1; then
    printf 'Unsafe parent lookup accepted: %s\n' "$mode" >&2; exit 1
  fi
  [[ ! -s "$work/writes" ]] || exit 1
done

unset GH_TOKEN
out="$(PROJECT_NUMBER=0 bash "$project" --issue 100)"
[[ "$out" == *'SKIP: PROJECT_NUMBER unset or zero'* ]] || exit 1
if PROJECT_NUMBER=invalid bash "$project" --issue 100 >/dev/null 2>&1; then exit 1; fi
export GH_TOKEN=mocked-token

MOCK_ITEM_MODE=existing PROJECT_NUMBER=12 bash "$project" --issue 100 >/dev/null
grep -q -- '--single-select-option-id O_TODO' "$work/writes" || exit 1
: > "$work/writes"
MOCK_ITEM_MODE=absent PROJECT_NUMBER=12 bash "$project" --issue 100 >/dev/null
grep -q 'project item-add' "$work/writes" || exit 1
grep -q -- '--id ITEM_2' "$work/writes" || exit 1
: > "$work/writes"
MOCK_ISSUE_MODE=progress PROJECT_NUMBER=12 bash "$project" --issue 100 >/dev/null
grep -q -- '--single-select-option-id O_PROGRESS' "$work/writes" || exit 1
: > "$work/writes"
MOCK_ISSUE_MODE=done PROJECT_NUMBER=12 bash "$project" --issue 100 >/dev/null
grep -q -- '--single-select-option-id O_DONE' "$work/writes" || exit 1
: > "$work/writes"
MOCK_ISSUE_MODE=declined PROJECT_NUMBER=12 bash "$project" --issue 100 >/dev/null
[[ ! -s "$work/writes" ]] || exit 1
if MOCK_EDIT_FAIL=1 PROJECT_NUMBER=12 bash "$project" --issue 100 >/dev/null 2>&1; then
  printf 'Project edit error was swallowed\n' >&2; exit 1
fi
printf 'Issue metadata synchronization mock tests passed\n'
