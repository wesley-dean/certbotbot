#!/usr/bin/env bats

# Task #96: focused implementation tests against the assembled public producer.
# Task #97 separately owns complete three-flavor, fresh-runner acceptance.

setup() {
  source "$BATS_TEST_DIRNAME/helpers/lifecycle-fixture.bash"
  lifecycle_fixture_setup
  unset RENEW_ALL REMOVE_ORPHANS DESIRED_CERT_NAMES
}

teardown() {
  rm -rf -- "$ROOT"
}

orphan_run() {
  local runner="${LIFECYCLE_RUNNER_TMPDIR:-$ROOT/runner-temp}"
  run env TMPDIR="$runner" "$BASH_STARTER_ARTIFACT" \
    --s3-bucket fixture-bucket "$@"
}

orphan_seed_two() {
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
  orphan_run example.com
  [ "$status" -eq 0 ] || return 1
  export LIFECYCLE_EXPECTED_CERT_NAME=other.org
  orphan_run --cert-name other.org other.org
  [ "$status" -eq 0 ] || return 1
  tar -tzf "$LIFECYCLE_REMOTE" |
    grep -Fxq './renewal/example.com.conf' || return 1
  tar -tzf "$LIFECYCLE_REMOTE" |
    grep -Fxq './renewal/other.org.conf'
}

orphan_no_provider() {
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS" &&
    ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
}

@test "default false and optional desired collection preserve every other lineage" {
  orphan_seed_two
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  : >"$LIFECYCLE_CALLS"
  orphan_run --remove-orphans false \
    --desired-cert-name example.com example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=false'* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
}

@test "opt-in deletes only explicitly excluded complete archived lineage" {
  orphan_seed_two
  mkdir -m 700 "$ROOT/before"
  tar -xzf "$LIFECYCLE_REMOTE" -C "$ROOT/before"
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
  : >"$LIFECYCLE_CALLS"
  orphan_run --remove-orphans true \
    --desired-cert-name example.com example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'orphan desired=1; removed=1; published=true'* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  mkdir -m 700 "$ROOT/after"
  tar -xzf "$LIFECYCLE_REMOTE" -C "$ROOT/after"
  [ -f "$ROOT/after/renewal/example.com.conf" ]
  [ ! -e "$ROOT/after/renewal/other.org.conf" ]
  [ ! -e "$ROOT/after/live/other.org" ]
  [ ! -e "$ROOT/after/archive/other.org" ]
  diff -qr "$ROOT/before/accounts" "$ROOT/after/accounts" >/dev/null
  diff -qr "$ROOT/before/archive/example.com" \
    "$ROOT/after/archive/example.com" >/dev/null
  cmp -s "$ROOT/before/renewal/example.com.conf" \
    "$ROOT/after/renewal/example.com.conf"
}

@test "complete desired set retains every archived lineage and no-op skips PUT" {
  orphan_seed_two
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  : >"$LIFECYCLE_CALLS"
  orphan_run --remove-orphans true \
    --desired-cert-name other.org \
    --desired-cert-name example.com example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'orphan desired=2; removed=0; published=false'* ]]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
}

@test "deliberate orphan opt-in without complete desired set fails before S3" {
  orphan_run --remove-orphans true example.com
  [ "$status" -eq 64 ]
  orphan_run --remove-orphans true --desired-cert-name '' example.com
  [ "$status" -eq 64 ]
  orphan_run --remove-orphans true --desired-cert-name other.org example.com
  [ "$status" -eq 64 ]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
  orphan_no_provider
}

@test "duplicate malformed or wildcard desired names fail before any S3 access" {
  orphan_run --remove-orphans true --desired-cert-name example.com \
    --desired-cert-name example.com example.com
  [ "$status" -eq 64 ]
  orphan_run --remove-orphans true --desired-cert-name '*.example.com' \
    example.com
  [ "$status" -eq 64 ]
  orphan_run --remove-orphans true --desired-cert-name Example.com \
    example.com
  [ "$status" -eq 64 ]
  export DESIRED_CERT_NAMES='example.com,,other.org'
  orphan_run --remove-orphans true example.com
  [ "$status" -eq 64 ]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
  orphan_no_provider
}

@test "unknown independent desired name fails before Certbot and PutObject" {
  orphan_seed_two
  : >"$LIFECYCLE_CALLS"
  orphan_run --remove-orphans true --desired-cert-name example.com \
    --desired-cert-name missing.org example.com
  [ "$status" -ne 0 ]
  orphan_no_provider
  tar -tzf "$LIFECYCLE_REMOTE" |
    grep -Fxq './renewal/other.org.conf'
}

@test "corrupt excluded lineage must not be treated as a removable orphan" {
  orphan_seed_two
  mkdir -m 700 "$ROOT/corrupt"
  tar -xzf "$LIFECYCLE_REMOTE" -C "$ROOT/corrupt"
  rm -f -- "$ROOT/corrupt/live/other.org/privkey.pem"
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/corrupt" .
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/corrupt-before.tar.gz"
  : >"$LIFECYCLE_CALLS"
  orphan_run --remove-orphans true --desired-cert-name example.com \
    example.com
  [ "$status" -ne 0 ]
  orphan_no_provider
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/corrupt-before.tar.gz"
}

@test "a failed selected renewal does not prune or publish any archived lineage" {
  orphan_seed_two
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_MODE=certbot-failure
  orphan_run --remove-orphans true --desired-cert-name example.com \
    example.com
  [ "$status" -ne 0 ]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
}

@test "account-only restored archive allows explicitly selected issuance" {
  : >"$LIFECYCLE_CALLS"
  orphan_run --remove-orphans true \
    --desired-cert-name example.com example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'orphan desired=1; removed=0; published=true'* ]]
  [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
  tar -tzf "$LIFECYCLE_REMOTE" |
    grep -Fxq './renewal/example.com.conf'
}

@test "RENEW_ALL and REMOVE_ORPHANS cannot jointly request mutation" {
  orphan_run --remove-orphans true --desired-cert-name example.com \
    --renew-all true example.com
  [ "$status" -eq 64 ]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
  orphan_no_provider
}

@test "whole desired set honors file environment and CLI precedence" {
  orphan_seed_two
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
  printf 'REMOVE_ORPHANS=true\nDESIRED_CERT_NAMES=example.com,other.org\n' \
    >"$ROOT/orphans.env"
  : >"$LIFECYCLE_CALLS"
  orphan_run --config "$ROOT/orphans.env" example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'desired=2; removed=0; published=false'* ]]
  export DESIRED_CERT_NAMES=example.com
  orphan_run --config "$ROOT/orphans.env" example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'desired=1; removed=1; published=true'* ]]
  unset DESIRED_CERT_NAMES
  : >"$LIFECYCLE_CALLS"
  orphan_run --config "$ROOT/orphans.env" \
    --desired-cert-name example.com example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'desired=1; removed=0; published=false'* ]]
}

@test "no-env drops exported destructive opt-in but honors explicit CLI" {
  orphan_seed_two
  export REMOVE_ORPHANS=true DESIRED_CERT_NAMES=example.com
  : >"$LIFECYCLE_CALLS"
  orphan_run --no-env example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=false'* ]]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  orphan_run --no-env --remove-orphans true \
    --desired-cert-name example.com example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'desired=1; removed=1; published=true'* ]]
}

@test "unchanged complete desired set obeys explicit republish override" {
  orphan_seed_two
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
  : >"$LIFECYCLE_CALLS"
  orphan_run --remove-orphans true --desired-cert-name example.com \
    --desired-cert-name other.org --upload-no-renewal true example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'desired=2; removed=0; published=true'* ]]
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
}
