#!/usr/bin/env bats

setup() {
  : "${BASH_STARTER_ARTIFACT:?Artifact path required}"
  ROOT="$(mktemp -d)"
  mkdir -m 700 "$ROOT/bin"
  cat >"$ROOT/bin/aws" <<'MOCK'
#!/usr/bin/env bash
# Refuse all network calls during entrypoint argument tests.
exit 90
MOCK
  chmod 755 "$ROOT/bin/aws"
  PATH="$ROOT/bin:$PATH"
  export PATH
}

teardown() {
  rm -rf -- "$ROOT"
}

@test "help documents the public certificate interface" {
  run "${BASH_STARTER_ARTIFACT}" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--include-subdomains"* ]]
  [[ "$output" == *"--upload-no-renewal"* ]]
}

@test "version retains release provenance" {
  run "${BASH_STARTER_ARTIFACT}" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"build-commit:"* ]]
}

@test "missing identity is rejected without external calls" {
  run env -u DOMAIN "${BASH_STARTER_ARTIFACT}" --s3-bucket test-bucket
  [ "$status" -eq 64 ]
}

@test "multiple identities are rejected without external calls" {
  run "${BASH_STARTER_ARTIFACT}" --s3-bucket test-bucket example.com foo.example.com
  [ "$status" -eq 64 ]
}

@test "malformed wildcard is rejected before lifecycle" {
  run "${BASH_STARTER_ARTIFACT}" --s3-bucket test-bucket 'foo.*.example.com'
  [ "$status" -eq 64 ]
}

@test "a valid identity fails closed before Certbot when S3 is unavailable" {
  run "${BASH_STARTER_ARTIFACT}" --s3-bucket test-bucket example.com
  [ "$status" -eq 69 ]
  [[ "$output" == *"S3 object cannot be inspected safely"* ]]
}

@test "explicit false is accepted without a cloud operation" {
  run env INCLUDE_SUBDOMAINS=true "${BASH_STARTER_ARTIFACT}" --s3-bucket test-bucket --include-subdomains=false example.com
  [ "$status" -eq 69 ]
}

@test "invalid boolean is rejected" {
  run "${BASH_STARTER_ARTIFACT}" --s3-bucket test-bucket --upload-no-renewal=yes example.com
  [ "$status" -eq 64 ]
}

@test "configuration data cannot execute shell substitutions" {
  local temp
  temp="$(mktemp -d)"
  printf 'S3_BUCKET=$(touch %s/compromised)\n' "$temp" > "$temp/.env"
  run "${BASH_STARTER_ARTIFACT}" --config "$temp/.env" example.com
  [ "$status" -eq 64 ]
  [ ! -e "$temp/compromised" ]
  rm -rf "$temp"
}
