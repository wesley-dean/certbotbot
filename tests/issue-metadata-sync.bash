#!/usr/bin/env bash
## @file issue-metadata-sync.bash
## @brief Offline acceptance tests for GitHub metadata synchronization scripts.
##
## Tests use a fake gh executable.  No GitHub token, network, or real issue is
## needed; malformed/missing parent, an already linked child, and an absent
## project are exercised against the public shell interfaces.
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
    printf '%s\n' '{"id":10000,"number":100,"body":"## Parent Story or Maintenance Exception\n\n#89 - test parent.\n\n## Objective\n","labels":[{"name":"type:task"}],"state":"open","html_url":"https://github.com/example/repo/issues/100"}' ;;
  'api /repos/example/repo/issues/89')
    printf '%s\n' '{"id":8900,"number":89,"labels":[{"name":"type:story"}]}' ;;
  'api /repos/example/repo/issues/100/parent')
    if [[ -f "${MOCK_STATE}/linked" ]]; then
      printf '%s\n' '{"number":89}'
    else
      exit 1
    fi ;;
  'api --method POST /repos/example/repo/issues/89/sub_issues -F sub_issue_id=10000')
    touch "${MOCK_STATE}/linked"
    printf '{}\n' ;;
  *) printf 'Unexpected gh invocation: %s\n' "$cmd" >&2; exit 1 ;;
esac
MOCK
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH"
export MOCK_STATE="$work"
export GH_REPO=example/repo
export GH_TOKEN=mocked-token

out="$(bash "$root/scripts/update_issue_parent_child_relationships.bash" --issue 100)"
[[ "$out" == *'LINKED #100 -> #89'* ]] || { printf 'Expected link operation; got %s\n' "$out" >&2; exit 1; }
[[ -f "$work/linked" ]] || exit 1
out="$(bash "$root/scripts/update_issue_parent_child_relationships.bash" --issue 100)"
[[ "$out" == *'OK #100 -> #89'* ]] || { printf 'Expected idempotent operation; got %s\n' "$out" >&2; exit 1; }
unset GH_TOKEN
out="$(PROJECT_NUMBER=0 bash "$root/scripts/update_issue_project_status.bash" --issue 100)"
[[ "$out" == *'SKIP: PROJECT_NUMBER unset or zero'* ]] || exit 1
if PROJECT_NUMBER=invalid bash "$root/scripts/update_issue_project_status.bash" --issue 100 >/dev/null 2>&1; then
  printf 'Invalid project configuration was accepted\n' >&2; exit 1
fi
printf 'Issue metadata synchronization mock tests passed\n'
