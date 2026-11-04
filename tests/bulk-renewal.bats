#!/usr/bin/env bats

# Task #99 implementation smoke/negative coverage. Task #100 independently
# expands the full acceptance and cross-runner matrix.
setup() {
  source "$BATS_TEST_DIRNAME/helpers/lifecycle-fixture.bash"
  lifecycle_fixture_setup
  # This is application config, not an inherited host/provisioner secret.
  unset RENEW_ALL REMOVE_ORPHANS
}

teardown() {
  rm -rf -- "$ROOT"
}

invoke_bulk() {
  local runner="${LIFECYCLE_RUNNER_TMPDIR:-$ROOT/runner-temp}"
  run env TMPDIR="$runner" "$BASH_STARTER_ARTIFACT" \
    --s3-bucket fixture-bucket "$@"
}

seed_two_lineages() {
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
  invoke_bulk example.com
  [ "$status" -eq 0 ] || return 1
  export LIFECYCLE_EXPECTED_CERT_NAME=other.org
  invoke_bulk --cert-name other.org other.org
  [ "$status" -eq 0 ] || return 1
  tar -tzf "$LIFECYCLE_REMOTE" |
    grep -Fxq './renewal/example.com.conf' || return 1
  tar -tzf "$LIFECYCLE_REMOTE" |
    grep -Fxq './renewal/other.org.conf'
}

@test "RENEW_ALL default and explicit false retain the required selected DNS identity" {
  invoke_bulk
  [ "$status" -eq 64 ]
  invoke_bulk --renew-all false
  [ "$status" -eq 64 ]
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
}

@test "domainless bulk on account-only archive refuses before Certbot or upload" {
  invoke_bulk --renew-all true
  [ "$status" -eq 65 ]
  [[ "$output" == *"bulk renewal requires archived certificates"* ]]
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
}

@test "one-lineage domainless bulk checks and verifies unchanged state without PUT" {
  invoke_bulk example.com
  [ "$status" -eq 0 ]
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  : >"$LIFECYCLE_CALLS"
  invoke_bulk --renew-all true
  [ "$status" -eq 0 ]
  [[ "$output" == *"bulk checked=1; renewed=0; metadata-only=0; unchanged=1; issued=0; published=false"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
}

@test "domainless bulk renews both independent archived lineages exactly once" {
  seed_two_lineages
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
  invoke_bulk --renew-all true
  [ "$status" -eq 0 ]
  [[ "$output" == *"bulk checked=2; renewed=0; metadata-only=0; unchanged=2; issued=0; published=false"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 2 ]
  [ "$(grep -c '^certbot-context:renew:.*:example.com:account-id$' "$LIFECYCLE_CONTEXTS")" -eq 1 ]
  [ "$(grep -c '^certbot-context:renew:.*:other.org:account-id$' "$LIFECYCLE_CONTEXTS")" -eq 1 ]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
}

@test "explicit archived selection receives only one action during bulk pass" {
  seed_two_lineages
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
  invoke_bulk --renew-all true example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"bulk checked=2; renewed=0; metadata-only=0; unchanged=2; issued=0; published=false"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 2 ]
  [ "$(grep -c '^certbot-context:renew:.*:example.com:account-id$' "$LIFECYCLE_CONTEXTS")" -eq 1 ]
  [ "$(grep -c '^certbot-context:renew:.*:other.org:account-id$' "$LIFECYCLE_CONTEXTS")" -eq 1 ]
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
}

@test "explicitly issued third selected lineage is not bulk-renewed again" {
  seed_two_lineages
  export LIFECYCLE_EXPECTED_CERT_NAME=third.org
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
  invoke_bulk --renew-all true --cert-name third.org third.org
  [ "$status" -eq 0 ]
  [[ "$output" == *"bulk checked=2; renewed=0; metadata-only=0; unchanged=2; issued=1; published=true"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 2 ]
  [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^certbot-context:certonly:.*:third.org:account-id$' "$LIFECYCLE_CONTEXTS")" -eq 1 ]
  ! grep -q '^certbot-context:renew:.*:third.org:account-id$' "$LIFECYCLE_CONTEXTS"
  tar -tzf "$LIFECYCLE_REMOTE" | grep -Fxq './renewal/third.org.conf'
}

@test "failed bulk renewal cannot publish a partially changed archive" {
  seed_two_lineages
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_MODE=renew-partial-failure
  invoke_bulk --renew-all true
  [ "$status" -ne 0 ]
  [[ "$output" != *"bulk checked="* ]]
  [[ "$output" != *"published=true"* ]]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
}

@test "strict boolean, partial identity, and contradictory removal fail before S3" {
  invoke_bulk --renew-all yes
  [ "$status" -eq 64 ]
  invoke_bulk --renew-all true --cert-name example.com
  [ "$status" -eq 64 ]
  invoke_bulk --renew-all true --san '*.example.com'
  [ "$status" -eq 64 ]
  invoke_bulk --renew-all true --domain=''
  [ "$status" -eq 64 ]
  export REMOVE_ORPHANS=true
  invoke_bulk --renew-all true
  [ "$status" -eq 64 ]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
}

@test "no-env drops exported RENEW_ALL while explicit CLI opt-in still works" {
  invoke_bulk example.com
  [ "$status" -eq 0 ]
  : >"$LIFECYCLE_CALLS"
  export RENEW_ALL=true
  invoke_bulk --no-env
  [ "$status" -eq 64 ]
  invoke_bulk --no-env --renew-all true
  [ "$status" -eq 0 ]
  [[ "$output" == *"bulk checked=1"* ]]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
}

@test "unchanged bulk state honors verified forced-upload override" {
  invoke_bulk example.com
  [ "$status" -eq 0 ]
  : >"$LIFECYCLE_CALLS"
  invoke_bulk --renew-all true --upload-no-renewal true
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
}
