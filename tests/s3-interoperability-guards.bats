#!/usr/bin/env bats

## @file tests/s3-interoperability-guards.bats
## @brief Refuse all live S3 integration modes without explicit local consent.
## @details
## These credential-free guards run with every shipped standalone artifact.
## An injected AWS executable records any accidental external operation;
## a valid guard must still perform no network activity or storage mutation.
## The real-service suites are deliberately not invoked in normal Bats CI.
## @see doc/s3-interoperability.md

setup() {
  export S3_GUARD_BIN="$BATS_TEST_TMPDIR/bin"
  export S3_GUARD_CALLS="$BATS_TEST_TMPDIR/aws-called"
  export S3_GUARD_BASIC="$BATS_TEST_DIRNAME/integration/s3-backend-interoperability.bash"
  export S3_GUARD_RECOVERY="$BATS_TEST_DIRNAME/integration/s3-recovery-evidence.bash"
  mkdir -m 0700 -- "$S3_GUARD_BIN"
  cat >"$S3_GUARD_BIN/aws" <<'AWS'
#!/usr/bin/env bash
printf 'unexpected external AWS execution\n' >>"$S3_GUARD_CALLS"
exit 97
AWS
  chmod 0700 "$S3_GUARD_BIN/aws"
  export PATH="$S3_GUARD_BIN:$PATH"
  export ACME_ENVIRONMENT=staging
  export S3_ENDPOINT_URL=http://127.0.0.1:4566
  export AWS_ACCESS_KEY_ID=isolated-test-only
  export AWS_SECRET_ACCESS_KEY=isolated-test-only
  unset CERTBOTBOT_S3_INTEROP_CONFIRM || :
  unset GPG_PASSPHRASE || :
  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy || :
}

@test "both real-service harnesses reject absent authorization without AWS calls" {
  local script=''
  for script in "$S3_GUARD_BASIC" "$S3_GUARD_RECOVERY"; do
    run bash "$script" run "$CERTBOTBOT_ARTIFACT"
    [ "$status" -eq 64 ]
    run bash "$script" guard
    [ "$status" -eq 64 ]
  done
  [ ! -e "$S3_GUARD_CALLS" ]
}

@test "both guards are network-free even when explicitly authorized" {
  local script=''
  export CERTBOTBOT_S3_INTEROP_CONFIRM=yes
  for script in "$S3_GUARD_BASIC" "$S3_GUARD_RECOVERY"; do
    run bash "$script" guard
    [ "$status" -eq 0 ]
  done
  [ ! -e "$S3_GUARD_CALLS" ]
}

@test "production authority cannot be used for S3 interoperability tests" {
  local script=''
  export CERTBOTBOT_S3_INTEROP_CONFIRM=yes
  export ACME_ENVIRONMENT=production
  for script in "$S3_GUARD_BASIC" "$S3_GUARD_RECOVERY"; do
    run bash "$script" guard
    [ "$status" -eq 64 ]
  done
  [ ! -e "$S3_GUARD_CALLS" ]
}

@test "remote endpoint addresses are rejected before any AWS request" {
  local script='' endpoint=''
  export CERTBOTBOT_S3_INTEROP_CONFIRM=yes
  for endpoint in \
    https://s3.amazonaws.com \
    http://192.168.1.2:9000 \
    http://169.254.169.254:80 \
    http://127.0.0.1.evil.example:9000 \
    http://127.0.0.1:9000/path \
    http://127.0.0.1:9000@evil.example; do
    export S3_ENDPOINT_URL=$endpoint
    for script in "$S3_GUARD_BASIC" "$S3_GUARD_RECOVERY"; do
      run bash "$script" guard
      [ "$status" -eq 64 ]
    done
  done
  [ ! -e "$S3_GUARD_CALLS" ]
}

@test "proxy settings cannot redirect an otherwise loopback S3 operation" {
  local script=''
  export CERTBOTBOT_S3_INTEROP_CONFIRM=yes
  export HTTPS_PROXY=http://proxy.example.test:8080
  for script in "$S3_GUARD_BASIC" "$S3_GUARD_RECOVERY"; do
    run bash "$script" guard
    [ "$status" -eq 64 ]
  done
  [ ! -e "$S3_GUARD_CALLS" ]
}

@test "no real-service harness may inherit an archive passphrase" {
  local script=''
  export CERTBOTBOT_S3_INTEROP_CONFIRM=yes
  export GPG_PASSPHRASE='a value that must never reach AWS'
  for script in "$S3_GUARD_BASIC" "$S3_GUARD_RECOVERY"; do
    run bash "$script" guard
    [ "$status" -eq 64 ]
  done
  [ ! -e "$S3_GUARD_CALLS" ]
}

@test "test identities are required and modes cannot bypass authorization" {
  export CERTBOTBOT_S3_INTEROP_CONFIRM=yes
  unset AWS_SECRET_ACCESS_KEY
  run bash "$S3_GUARD_RECOVERY" guard
  [ "$status" -eq 64 ]
  run bash "$S3_GUARD_RECOVERY" stage "$CERTBOTBOT_ARTIFACT" \
    certbotbot-interop-test full "$BATS_TEST_TMPDIR/record"
  [ "$status" -eq 64 ]
  [ ! -e "$S3_GUARD_CALLS" ]
}

@test "public certificate issuance remains unavailable alongside interop tests" {
  run "$CERTBOTBOT_ARTIFACT" example.com
  [ "$status" -eq 69 ]
  [ ! -e "$S3_GUARD_CALLS" ]
}
