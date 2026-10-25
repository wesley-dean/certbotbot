#!/usr/bin/env bats

## @file tests/client-shipped.bats
## @brief Checks the exact generated standalone client release representation.
## @details
## These cases operate on the checksummed build artifact rather than maintained
## modules, using a private directory with no vendor or producer executables.

setup() {
  : "${BASH_STARTER_CLIENT_ARTIFACT:?Shipped client artifact is required}"
  : "${BASH_STARTER_ARTIFACT:?Producer artifact is required}"
  TEST_ROOT="$(mktemp -d)"
  cp -- "$BASH_STARTER_CLIENT_ARTIFACT" "$TEST_ROOT/certbotbot-client.bash"
  cp -- "$BASH_STARTER_CLIENT_ARTIFACT.sha256" "$TEST_ROOT/certbotbot-client.bash.sha256"
  chmod 0700 "$TEST_ROOT/certbotbot-client.bash"
}

teardown() {
  rm -rf -- "$TEST_ROOT"
}

@test "shipped client has a matching conventional SHA-256 companion" {
  run bash -c 'cd "$1" && sha256sum -c certbotbot-client.bash.sha256' _ "$TEST_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'certbotbot-client.bash: OK'* ]]
  [ ! -e "$TEST_ROOT/certbotbot-client.bash.256" ]
}

@test "shipped client runs without any source, vendor or producer artifacts" {
  [ ! -e "$TEST_ROOT/src" ]
  [ ! -e "$TEST_ROOT/lib" ]
  [ ! -e "$TEST_ROOT/vendor" ]
  [ ! -e "$TEST_ROOT/certbotbot.bash" ]
  run bash -n "$TEST_ROOT/certbotbot-client.bash"
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1" && ./certbotbot-client.bash --help' _ "$TEST_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'--destination DIRECTORY'* ]]
  [[ "$output" != *'renew-all'* ]]
}

@test "shipped client and producer share exact version and build provenance" {
  run "$TEST_ROOT/certbotbot-client.bash" --version
  [ "$status" -eq 0 ]
  local client_version="$output"
  run "$BASH_STARTER_ARTIFACT" --version
  [ "$status" -eq 0 ]
  [ "$output" = "$client_version" ]
  [[ "$output" == *'version:'* ]]
  [[ "$output" == *'build-commit:'* ]]
}

@test "shipped client rejects a positional DNS name without contacting AWS" {
  mkdir "$TEST_ROOT/private"
  run env PATH="/usr/bin:/bin" \
    bash "$TEST_ROOT/certbotbot-client.bash" \
      --destination "$TEST_ROOT/private/current" \
      --s3-bucket fixture-bucket example.com
  [ "$status" -eq 64 ]
  [ ! -e "$TEST_ROOT/private/current" ]
}

@test "shipped client lacks issuer, Route53 and AWS mutation entrypoints" {
  ! grep -Eq '^certbotbot_(renew|publish|reconcile|certbot|crypto|backup|retention|s3_put)[a-z_]*\(\)' \
    "$TEST_ROOT/certbotbot-client.bash"
  ! grep -Fq 's3api put-object' "$TEST_ROOT/certbotbot-client.bash"
  ! grep -Fq 's3api delete-object' "$TEST_ROOT/certbotbot-client.bash"
}
