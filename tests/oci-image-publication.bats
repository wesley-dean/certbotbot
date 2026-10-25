#!/usr/bin/env bats

setup() {
  ROOT="$(mktemp -d)"
  mkdir -p "$ROOT/bin"
  export GITHUB_EVENT_PATH="$ROOT/event.json"
  export GITHUB_EVENT_NAME=workflow_run
  export GITHUB_OUTPUT="$ROOT/outputs"
  export GH_TOKEN=fixture-read-token
  export GH_REPO=wesley-dean/certbotbot
  export PATH="$ROOT/bin:$PATH"
  VERIFY="$BATS_TEST_DIRNAME/../ci/verify-oci-publish-event.bash"
  PROOF="$ROOT/verified-oci-gate.txt"
  cat > "$GITHUB_EVENT_PATH" <<'JSON'
{
  "action": "completed",
  "repository": {"full_name": "wesley-dean/certbotbot"},
  "workflow_run": {
    "name": "OCI release validation",
    "path": ".github/workflows/oci-release-validation.yml",
    "event": "workflow_run",
    "head_branch": "main",
    "head_repository": {"full_name": "wesley-dean/certbotbot"},
    "conclusion": "success",
    "id": 800101,
    "run_attempt": 2
  }
}
JSON
  cat > "$PROOF" <<'PROOF'
gate_run_id=800101
gate_run_attempt=2
source_run_id=700901
source_attempt=1
source_sha=0123456789abcdef0123456789abcdef01234567
release_version=0.3.1
handoff_manifest_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
producer_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
PROOF
  cat > "$ROOT/source-run.json" <<'JSON'
{
  "name": "Versioning",
  "event": "push",
  "head_branch": "main",
  "head_repository": {"full_name": "wesley-dean/certbotbot"},
  "head_sha": "0123456789abcdef0123456789abcdef01234567",
  "run_attempt": 1,
  "status": "completed",
  "conclusion": "success"
}
JSON
  cat > "$ROOT/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == api && "$2" == repos/wesley-dean/certbotbot/actions/runs/700901 ]] ||
  exit 69
cat -- "$GH_MOCK_SOURCE_RUN"
GH
  chmod +x "$ROOT/bin/gh"
  export GH_MOCK_SOURCE_RUN="$ROOT/source-run.json"
}

teardown() {
  rm -rf -- "$ROOT"
}

@test "exact successful gate and Versioning run produce nonsecret immutable identity" {
  run bash "$VERIFY" "$PROOF"
  [ "$status" -eq 0 ]
  grep -Fxq 'source_run_id=700901' "$GITHUB_OUTPUT"
  grep -Fxq 'source_attempt=1' "$GITHUB_OUTPUT"
  grep -Fxq 'release_version=0.3.1' "$GITHUB_OUTPUT"
  grep -Fxq 'source_sha=0123456789abcdef0123456789abcdef01234567' "$GITHUB_OUTPUT"
  ! grep -q fixture-read-token "$GITHUB_OUTPUT"
}

@test "failed skipped cancelled and unfinished OCI gates cannot publish" {
  local conclusion
  for conclusion in failure skipped cancelled null; do
    jq --arg outcome "$conclusion" '.workflow_run.conclusion=$outcome' \
      "$GITHUB_EVENT_PATH" > "$ROOT/altered"
    mv -- "$ROOT/altered" "$GITHUB_EVENT_PATH"
    run bash "$VERIFY" "$PROOF"
    [ "$status" -ne 0 ]
  done
}

@test "only the trusted main-branch OCI gate event can select publication" {
  GITHUB_EVENT_NAME=pull_request run bash "$VERIFY" "$PROOF"
  [ "$status" -ne 0 ]
  jq '.workflow_run.event="push"' "$GITHUB_EVENT_PATH" > "$ROOT/altered"
  mv -- "$ROOT/altered" "$GITHUB_EVENT_PATH"
  run bash "$VERIFY" "$PROOF"
  [ "$status" -ne 0 ]
  jq '.workflow_run.event="workflow_run" | .workflow_run.head_repository.full_name="untrusted/fork"' \
    "$GITHUB_EVENT_PATH" > "$ROOT/altered"
  mv -- "$ROOT/altered" "$GITHUB_EVENT_PATH"
  run bash "$VERIFY" "$PROOF"
  [ "$status" -ne 0 ]
}

@test "a different workflow with the same display name is not trusted" {
  jq '.workflow_run.path=".github/workflows/other.yml"' \
    "$GITHUB_EVENT_PATH" > "$ROOT/altered"
  mv -- "$ROOT/altered" "$GITHUB_EVENT_PATH"
  run bash "$VERIFY" "$PROOF"
  [ "$status" -ne 0 ]
}

@test "same-run artifact is not accepted for another gate attempt or run" {
  jq '.workflow_run.run_attempt=3' "$GITHUB_EVENT_PATH" > "$ROOT/altered"
  mv -- "$ROOT/altered" "$GITHUB_EVENT_PATH"
  run bash "$VERIFY" "$PROOF"
  [ "$status" -ne 0 ]
  jq '.workflow_run.run_attempt=2 | .workflow_run.id=800102' \
    "$GITHUB_EVENT_PATH" > "$ROOT/altered"
  mv -- "$ROOT/altered" "$GITHUB_EVENT_PATH"
  run bash "$VERIFY" "$PROOF"
  [ "$status" -ne 0 ]
}

@test "untrusted or malformed gate proof inventory fails without source execution" {
  printf '%s\n' 'some shell $(touch /tmp/insecure)' >> "$PROOF"
  run bash "$VERIFY" "$PROOF"
  [ "$status" -ne 0 ]
  sed -i '$d' "$PROOF"
  sed -i 's/release_version=0.3.1/release_version=0.3.1$(false)/' "$PROOF"
  run bash "$VERIFY" "$PROOF"
  [ "$status" -ne 0 ]
}

@test "mismatched or incomplete original Versioning run fails closed" {
  local result
  for result in failure skipped cancelled; do
    jq --arg outcome "$result" '.conclusion=$outcome' \
      "$ROOT/source-run.json" > "$ROOT/altered"
    mv -- "$ROOT/altered" "$ROOT/source-run.json"
    run bash "$VERIFY" "$PROOF"
    [ "$status" -ne 0 ]
    jq '.conclusion="success"' "$ROOT/source-run.json" > "$ROOT/altered"
    mv -- "$ROOT/altered" "$ROOT/source-run.json"
  done
  jq '.head_sha="ffffffffffffffffffffffffffffffffffffffff"' \
    "$ROOT/source-run.json" > "$ROOT/altered"
  mv -- "$ROOT/altered" "$ROOT/source-run.json"
  run bash "$VERIFY" "$PROOF"
  [ "$status" -ne 0 ]
}

@test "registry workflow publishes automatically after hard gate with immutable action and fixed amd64" {
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/publish-image.yml"
  local gate="$BATS_TEST_DIRNAME/../.github/workflows/oci-release-validation.yml"
  grep -Fq 'workflows: [OCI release validation]' "$workflow"
  grep -Fq 'needs: verify' "$workflow"
  grep -Fq "if: \${{ needs.verify.result == 'success' }}" "$workflow"
  ! grep -Fq 'CERTBOTBOT_IMAGE_PUBLISH_ENABLED' "$workflow"
  grep -Fq 'name: oci-registry-publish' "$workflow"
  grep -Fq 'required_registries: dockerhub,ghcr' "$workflow"
  grep -Fq 'uses: wesley-dean/publish_image@94d42d58eab435d50991f561f27382c4dc3cedb4' "$workflow"
  grep -Fq 'verified_release_ref: refs/tags/v' "$workflow"
  grep -Fq 'platforms: linux/amd64' "$workflow"
  grep -Fq 'name: verified-oci-gate-' "$gate"
  grep -Fq 'retention-days: 1' "$gate"
  ! grep -Eq '^  (push|pull_request|schedule|workflow_dispatch):' "$workflow"
  ! grep -Eq 'packages: write|publish_image@' "$gate"
}
