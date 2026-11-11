#!/usr/bin/env bats
##
## @file test-gate.bats
## @brief Deterministic no-network tests for the workflow metadata gate.
##
## @details
##   A disposable Git repository supplies real base/head commit snapshots.
##   A fake gh executable returns fixed Actions API JSON; no GitHub
##   credentials, workflows, certificates, or network are used.
##
setup() {
  sandbox=$(mktemp -d)
  work="$sandbox/repository"
  mkdir -p "$work/.github/workflows" "$sandbox/bin" "$sandbox/replies"
  script="$BATS_TEST_DIRNAME/../ci/test-gate.bash"

  git -C "$work" init -q
  git -C "$work" config user.name 'Test Gate Fixture'
  git -C "$work" config user.email 'test-gate@example.invalid'
  printf '%s\n' '## test-gate:required=true' 'name: Unit test' \
    > "$work/.github/workflows/test.yml"
  printf '%s\n' '## test-gate:required=false' 'name: Optional test' \
    > "$work/.github/workflows/optional.yml"
  git -C "$work" add -A
  git -C "$work" commit -qm baseline
  base=$(git -C "$work" rev-parse HEAD)
  git -C "$work" commit --allow-empty -qm candidate
  head=$(git -C "$work" rev-parse HEAD)
  write_event
  write_replies

  cat > "$sandbox/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for endpoint in "$@"; do :; done
case "$endpoint" in
  */actions/workflows/test.yml)
    cat "$GH_POC_FIXTURE/replies/state.json" ;;
  */actions/workflows/test.yml/runs\?*)
    cat "$GH_POC_FIXTURE/replies/runs.json" ;;
  */actions/runs/*/jobs\?*)
    cat "$GH_POC_FIXTURE/replies/jobs.json" ;;
  *)
    printf 'unrecognized mock API request: %s\n' "$endpoint" >&2
    exit 1 ;;
esac
EOF
  chmod +x "$sandbox/bin/gh"
}

teardown() {
  rm -rf "$sandbox"
}

write_event() {
  cat > "$sandbox/event.json" <<EOF
{
  "pull_request": {
    "number": 99,
    "base": {"sha": "$base"},
    "head": {
      "sha": "$head",
      "ref": "agent/test",
      "repo": {"full_name": "wesley-dean/certbotbot"}
    }
  }
}
EOF
}

write_replies() {
  cat > "$sandbox/replies/state.json" <<'EOF'
{"path":".github/workflows/test.yml","state":"active"}
EOF
  cat > "$sandbox/replies/runs.json" <<EOF
{
  "workflow_runs": [{
    "id": 123,
    "head_sha": "$head",
    "head_branch": "agent/test",
    "event": "push",
    "status": "completed",
    "conclusion": "success",
    "created_at": "2026-11-11T13:00:00Z",
    "run_attempt": 1
  }]
}
EOF
  cat > "$sandbox/replies/jobs.json" <<'EOF'
{"total_count":2,"jobs":[
  {"status":"completed","conclusion":"success"},
  {"status":"completed","conclusion":"success"}
]}
EOF
}

commit_candidate() {
  git -C "$work" add -A
  git -C "$work" commit --allow-empty -qm revised
  head=$(git -C "$work" rev-parse HEAD)
  write_event
  write_replies
}

run_gate() {
  cd "$work" || return 1
  run env PATH="$sandbox/bin:$PATH" \
    GH_POC_FIXTURE="$sandbox" GH_TOKEN='fixture-only' \
    GITHUB_REPOSITORY='wesley-dean/certbotbot' \
    GITHUB_EVENT_PATH="$sandbox/event.json" \
    TEST_GATE_MAX_ATTEMPTS=1 TEST_GATE_POLL_SECONDS=0 \
    bash "$script" run
}

@test "recognizes required=true and required=false and excludes optional workflows" {
  cd "$work" || return 1
  run bash "$script" inventory "$base" "$head"
  [ "$status" -eq 0 ]
  [ "$output" = '.github/workflows/test.yml' ]
}

@test "accepts liberal whitespace around namespaced declaration punctuation" {
  printf '%s\n' '  ###   test-gate  :  required  =  true ' 'name: Unit test' \
    > "$work/.github/workflows/test.yml"
  commit_candidate
  cd "$work" || return 1
  run bash "$script" inventory "$base" "$head"
  [ "$status" -eq 0 ]
  [ "$output" = '.github/workflows/test.yml' ]
}

@test "base required=true remains authoritative if candidate sets false" {
  printf '%s\n' '## test-gate:required=false' 'name: Unit test' \
    > "$work/.github/workflows/test.yml"
  commit_candidate
  cd "$work" || return 1
  run bash "$script" inventory "$base" "$head"
  [ "$status" -eq 0 ]
  [ "$output" = '.github/workflows/test.yml' ]
}

@test "rejects duplicate metadata declarations" {
  printf '%s\n' '## test-gate:required=true' '## test-gate:required=false' \
    > "$work/.github/workflows/test.yml"
  commit_candidate
  cd "$work" || return 1
  run bash "$script" inventory "$base" "$head"
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate"* ]]
}

@test "rejects malformed case-variant Boolean" {
  printf '%s\n' '## test-gate:required=TRUE' \
    > "$work/.github/workflows/test.yml"
  commit_candidate
  cd "$work" || return 1
  run bash "$script" inventory "$base" "$head"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed"* ]]
}

@test "rejects removal of a required workflow" {
  rm "$work/.github/workflows/test.yml"
  commit_candidate
  cd "$work" || return 1
  run bash "$script" inventory "$base" "$head"
  [ "$status" -ne 0 ]
  [[ "$output" == *"removed or renamed"* ]]
}

@test "passes only when an automatic exact-head run and every job succeed" {
  run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"all 1 required workflows succeeded"* ]]
}

@test "rejects disabled workflows even when an old run passed" {
  printf '%s\n' '{"path":".github/workflows/test.yml","state":"disabled_manually"}' \
    > "$sandbox/replies/state.json"
  run_gate
  [ "$status" -ne 0 ]
  [[ "$output" == *"disabled_manually"* ]]
}

@test "rejects a failed required workflow" {
  sed -i 's/"conclusion": "success"/"conclusion": "failure"/' \
    "$sandbox/replies/runs.json"
  run_gate
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not succeed"* ]]
}

@test "rejects a skipped matrix job even if the workflow says success" {
  printf '%s\n' '{"total_count":2,"jobs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"skipped"}]}' \
    > "$sandbox/replies/jobs.json"
  run_gate
  [ "$status" -ne 0 ]
  [[ "$output" == *"required jobs missing, skipped"* ]]
}

@test "rejects truncated job inventories instead of ignoring missing jobs" {
  printf '%s\n' '{"total_count":3,"jobs":[{"status":"completed","conclusion":"success"}]}' \
    > "$sandbox/replies/jobs.json"
  run_gate
  [ "$status" -ne 0 ]
  [[ "$output" == *"required jobs missing"* ]]
}

@test "does not accept an old revision's successful run" {
  sed -i 's/"head_sha": "[^"]*"/"head_sha": "0123456789012345678901234567890123456789"/' \
    "$sandbox/replies/runs.json"
  run_gate
  [ "$status" -ne 0 ]
  [[ "$output" == *"timed out"* ]]
}

@test "does not silently accept an absent required workflow run" {
  printf '%s\n' '{"workflow_runs":[]}' > "$sandbox/replies/runs.json"
  run_gate
  [ "$status" -ne 0 ]
  [[ "$output" == *"timed out"* ]]
}

@test "waits only a bounded interval for an unfinished workflow" {
  sed -i 's/"status": "completed"/"status": "in_progress"/' \
    "$sandbox/replies/runs.json"
  run_gate
  [ "$status" -ne 0 ]
  [[ "$output" == *"timed out"* ]]
}

@test "refuses fork PR results with unsupported identity policy" {
  sed -i 's/"full_name": "wesley-dean\/certbotbot"/"full_name": "other\/certbotbot"/' \
    "$sandbox/event.json"
  run_gate
  [ "$status" -ne 0 ]
  [[ "$output" == *"fork PRs"* ]]
}

@test "accepts a PR-triggered run linked to the exact PR head" {
  cat > "$sandbox/replies/runs.json" <<EOF
{
  "workflow_runs": [{
    "id": 123,
    "head_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "head_branch": "agent/test",
    "event": "pull_request",
    "pull_requests": [{"number": 99, "head": {"sha": "$head"}}],
    "status": "completed",
    "conclusion": "success",
    "created_at": "2026-11-11T13:00:00Z",
    "run_attempt": 1
  }]
}
EOF
  run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"all 1 required workflows succeeded"* ]]
}

@test "rejects an unrelated PR-triggered successful run" {
  cat > "$sandbox/replies/runs.json" <<EOF
{
  "workflow_runs": [{
    "id": 123,
    "head_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "head_branch": "agent/test",
    "event": "pull_request",
    "pull_requests": [{"number": 100, "head": {"sha": "$head"}}],
    "status": "completed",
    "conclusion": "success",
    "created_at": "2026-11-11T13:00:00Z",
    "run_attempt": 1
  }]
}
EOF
  run_gate
  [ "$status" -ne 0 ]
  [[ "$output" == *"timed out"* ]]
}
