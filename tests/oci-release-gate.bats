#!/usr/bin/env bats

setup() {
  ROOT="$(mktemp -d)"
  export GITHUB_EVENT_PATH="$ROOT/event.json"
  export GITHUB_EVENT_NAME=workflow_run
  export TRUSTED_SOURCE_SHA=0123456789abcdef0123456789abcdef01234567
  export TRUSTED_RUN_ID=99123
  export TRUSTED_ATTEMPT=2
  VERIFY="$BATS_TEST_DIRNAME/../ci/verify-oci-release-event.bash"
  cat > "$GITHUB_EVENT_PATH" <<'JSON'
{
  "action": "completed",
  "repository": {"full_name": "wesley-dean/certbotbot"},
  "workflow_run": {
    "name": "Versioning",
    "event": "push",
    "head_branch": "main",
    "conclusion": "success",
    "head_repository": {"full_name": "wesley-dean/certbotbot"},
    "head_sha": "0123456789abcdef0123456789abcdef01234567",
    "id": 99123,
    "run_attempt": 2
  }
}
JSON
}

teardown() {
  rm -rf -- "$ROOT"
}

@test "trusted completed Versioning push is an eligible release-validation event" {
  run bash "$VERIFY"
  [ "$status" -eq 0 ]
}

@test "failed skipped and cancelled upstream runs are rejected" {
  local result
  for result in failure skipped cancelled null; do
    jq --arg outcome "$result" '.workflow_run.conclusion=$outcome' \
      "$GITHUB_EVENT_PATH" > "$ROOT/change.json"
    mv "$ROOT/change.json" "$GITHUB_EVENT_PATH"
    run bash "$VERIFY"
    [ "$status" -ne 0 ]
    jq '.workflow_run.conclusion="success"' "$GITHUB_EVENT_PATH" > "$ROOT/change.json"
    mv "$ROOT/change.json" "$GITHUB_EVENT_PATH"
  done
}

@test "fork and wrong repository cannot authorize image validation" {
  jq '.workflow_run.head_repository.full_name="untrusted/fork"' \
    "$GITHUB_EVENT_PATH" > "$ROOT/change.json"
  mv "$ROOT/change.json" "$GITHUB_EVENT_PATH"
  run bash "$VERIFY"
  [ "$status" -ne 0 ]
}

@test "a PR or manually dispatched upstream run is not a release trigger" {
  jq '.workflow_run.event="pull_request"' \
    "$GITHUB_EVENT_PATH" > "$ROOT/change.json"
  mv "$ROOT/change.json" "$GITHUB_EVENT_PATH"
  run bash "$VERIFY"
  [ "$status" -ne 0 ]
}

@test "wrong source SHA and run attempt reject reuse across workflows" {
  TRUSTED_SOURCE_SHA=abcdef0123456789abcdef0123456789abcdef01 run bash "$VERIFY"
  [ "$status" -ne 0 ]
  TRUSTED_ATTEMPT=3 run bash "$VERIFY"
  [ "$status" -ne 0 ]
  TRUSTED_RUN_ID=99124 run bash "$VERIFY"
  [ "$status" -ne 0 ]
}

@test "release gate refuses unknown event or non-main branch" {
  GITHUB_EVENT_NAME=push run bash "$VERIFY"
  [ "$status" -ne 0 ]
  jq '.workflow_run.head_branch="other"' "$GITHUB_EVENT_PATH" > "$ROOT/change.json"
  mv "$ROOT/change.json" "$GITHUB_EVENT_PATH"
  run bash "$VERIFY"
  [ "$status" -ne 0 ]
}

@test "OCI gate has no registry write authority and only amd64 build" {
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/oci-release-validation.yml"
  grep -Fq 'workflows: [Versioning]' "$workflow"
  grep -Fq 'gh' "$BATS_TEST_DIRNAME/../ci/verify-oci-public-release.bash"
  grep -Fq -- '--platform linux/amd64' "$workflow"
  grep -Fq -- '--build-arg BUILD_KIND=release' "$workflow"
  grep -Fq 'bash tests/oci-runtime.bash docker' "$workflow"
  grep -Fq 'bash tests/oci-runtime.bash podman' "$workflow"
  ! grep -Eq 'packages: write|docker (push|login)|podman push|publish_image@' "$workflow"
}
