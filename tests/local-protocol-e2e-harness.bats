#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "$BATS_TEST_DIRNAME/.." && pwd -P)"
  HARNESS="$REPO_ROOT/tests/e2e-local/run.bash"
  TOPOLOGY="$REPO_ROOT/tests/e2e-local/compose.yml"
  S3_CREDS="$REPO_ROOT/tests/e2e-local/s3.json"
}

@test "local harness Bash syntax is valid without Docker" {
  run bash -n "$HARNESS"
  [ "$status" -eq 0 ]
}

@test "invalid local harness invocation fails before invoking Docker" {
  run bash "$HARNESS" no-such-mode
  [ "$status" -eq 64 ]
  [[ "$output" == *'usage: run.bash fetch|up|status|down'* ]]
}

@test "all upstream images are pinned to full immutable digests" {
  run grep -Ec '^[[:space:]]+image: [^[:space:]]+@sha256:[0-9a-f]{64}$' "$TOPOLOGY"
  [ "$status" -eq 0 ]
  [ "$output" = 3 ]
  run grep -Ec '^[[:space:]]+platform: linux/amd64$' "$TOPOLOGY"
  [ "$status" -eq 0 ]
  [ "$output" = 3 ]
}

@test "no published ports, host networking, Docker socket or privileged services" {
  run grep -En '^[[:space:]]*(ports:|network_mode:|privileged:|build:|network_mode: host)' "$TOPOLOGY"
  [ "$status" -ne 0 ]
  run grep -En '/var/run/docker.sock|/etc/letsencrypt|/root/.aws' "$TOPOLOGY"
  [ "$status" -ne 0 ]
  run grep -E '^[[:space:]]+internal: true$' "$TOPOLOGY"
  [ "$status" -eq 0 ]
}

@test "test-only SeaweedFS credentials are literal and not host secrets" {
  run jq -e '(.identities | length) == 1 and (.identities[0].credentials | length) == 1' "$S3_CREDS"
  [ "$status" -eq 0 ]
  run grep -F 'CBOTBOT_LOCAL_TEST_ACCESS_ONLY' "$S3_CREDS"
  [ "$status" -eq 0 ]
  run grep -F 'CBOTBOT_LOCAL_TEST_SECRET_NOT_A_CLOUD_KEY' "$S3_CREDS"
  [ "$status" -eq 0 ]
}

@test "harness provides project-scoped teardown and cached-only startup" {
  run grep -F 'compose down --volumes --remove-orphans --timeout 10' "$HARNESS"
  [ "$status" -eq 0 ]
  run grep -F 'compose up --no-build --pull never --detach' "$HARNESS"
  [ "$status" -eq 0 ]
  run grep -F 'docker network inspect' "$HARNESS"
  [ "$status" -eq 0 ]
}
