#!/usr/bin/env bats

## @file tests/register-continuity.bats
## @brief Proves mock-only account continuity across separate producer runs.
## @details
## The actual selected standalone producer invokes an opt-in AWS/Certbot
## process fixture.  Each operation owns a fresh TMPDIR while one local file
## represents the durable S3 object.  GNU tar/gzip and OpenSSL perform the
## real local format and self-signed-certificate operations.  No remote
## endpoint is contacted, and no live ACME account is represented here.

setup() {
  : "${BASH_STARTER_ARTIFACT:?built producer artifact is required}"
  source "$BATS_TEST_DIRNAME/helpers/lifecycle-fixture.bash"
  lifecycle_fixture_setup
  export LIFECYCLE_REGISTRATION_MOCK=true
  export LIFECYCLE_PUT_MODE=ok
  rm -f -- "$LIFECYCLE_REMOTE"
  mkdir -m 700 "$ROOT/register-runner" "$ROOT/issue-runner"
  ACCOUNT_MEMBER='./accounts/acme-v02.api.letsencrypt.org/directory/account-id'
}

teardown() {
  rm -rf -- "$ROOT"
}

register_account() {
  run env LIFECYCLE_REGISTER_CALL=true TMPDIR="$ROOT/register-runner" \
    "$BASH_STARTER_ARTIFACT" register --email operator@example.org \
    --agree-tos true --s3-bucket fixture-bucket "$@"
}

issue_certificate() {
  run env TMPDIR="$ROOT/issue-runner" \
    "$BASH_STARTER_ARTIFACT" --s3-bucket fixture-bucket example.com
}

assert_unmodified() {
  cmp -s -- "$ROOT/before.tar.gz" "$LIFECYCLE_REMOTE"
}

assert_registration_not_invoked() {
  ! grep -q '^certbot:register$' "$LIFECYCLE_CALLS" 2>/dev/null
}

assert_no_remote_write() {
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS" 2>/dev/null
}

save_account_key() {
  tar -xOf "$LIFECYCLE_REMOTE" "$ACCOUNT_MEMBER/private_key.json" \
    >"$ROOT/original-account-key.json"
}

assert_account_key_unchanged() {
  tar -xOf "$LIFECYCLE_REMOTE" "$ACCOUNT_MEMBER/private_key.json" \
    >"$ROOT/final-account-key.json" &&
    cmp -s "$ROOT/original-account-key.json" \
      "$ROOT/final-account-key.json"
}

seed_accountless_archive() {
  mkdir -m 700 "$ROOT/accountless"
  mkdir -m 700 "$ROOT/accountless/renewal-hooks"
  tar --format=ustar --gzip --create --file "$LIFECYCLE_REMOTE" \
    --directory "$ROOT/accountless" .
}

@test "new registration can be issued and renewed on independent runners" {
  register_account
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=true'* ]]
  [ -s "$LIFECYCLE_REMOTE" ]
  save_account_key
  tar -xOf "$LIFECYCLE_REMOTE" "$ACCOUNT_MEMBER/regr.json" \
    >"$ROOT/original-registration.json"
  [ -z "$(find "$ROOT/register-runner" -mindepth 1 -print)" ]
  [ "$(grep -c '^certbot:register$' "$LIFECYCLE_CALLS")" -eq 1 ]

  : >"$LIFECYCLE_CALLS"
  issue_certificate
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=true'* ]]
  assert_registration_not_invoked
  [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
  grep -q '^certbot-context:certonly:.*:account-id$' "$LIFECYCLE_CONTEXTS"
  assert_account_key_unchanged
  tar -xOf "$LIFECYCLE_REMOTE" "$ACCOUNT_MEMBER/regr.json" \
    >"$ROOT/final-registration.json"
  cmp -s "$ROOT/original-registration.json" \
    "$ROOT/final-registration.json"
  [ -z "$(find "$ROOT/issue-runner" -mindepth 1 -print)" ]

  : >"$LIFECYCLE_CALLS"
  issue_certificate
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=false'* ]]
  assert_registration_not_invoked
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  assert_no_remote_write
  assert_account_key_unchanged
}

@test "repeating registration reuses original account and preserves issued lineage" {
  register_account
  [ "$status" -eq 0 ]
  issue_certificate
  [ "$status" -eq 0 ]
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  : >"$LIFECYCLE_CALLS"
  register_account
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=false'* ]]
  assert_unmodified
  assert_registration_not_invoked
  assert_no_remote_write
  tar -tzf "$LIFECYCLE_REMOTE" | grep -q \
    './renewal/example.com.conf'
}

@test "production registration is isolated from staging registration and issuance" {
  register_account
  [ "$status" -eq 0 ]
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  : >"$LIFECYCLE_CALLS"
  register_account --acme-environment staging
  [ "$status" -eq 65 ]
  assert_unmodified
  assert_registration_not_invoked
  assert_no_remote_write

  rm -f -- "$LIFECYCLE_REMOTE"
  : >"$LIFECYCLE_CALLS"
  register_account --acme-environment staging
  [ "$status" -eq 0 ]
  tar -tzf "$LIFECYCLE_REMOTE" | grep -q \
    'accounts/acme-staging-v02.api.letsencrypt.org/directory/account-id'
  : >"$LIFECYCLE_CALLS"
  issue_certificate
  [ "$status" -eq 65 ]
  assert_registration_not_invoked
  assert_no_remote_write
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
}

@test "existing accountless archive updates under matching ETag" {
  seed_accountless_archive
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  register_account
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=true'* ]]
  tar -tzf "$LIFECYCLE_REMOTE" | grep -q \
    './renewal-hooks/'
  tar -tzf "$LIFECYCLE_REMOTE" | grep -q \
    "$ACCOUNT_MEMBER/private_key.json"
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
}

@test "duplicate account in a valid archive is refused without publication" {
  register_account
  [ "$status" -eq 0 ]
  mkdir -m 700 "$ROOT/expanded"
  tar -xzf "$LIFECYCLE_REMOTE" -C "$ROOT/expanded"
  cp -a -- "$ROOT/expanded/accounts/acme-v02.api.letsencrypt.org/directory/account-id" \
    "$ROOT/expanded/accounts/acme-v02.api.letsencrypt.org/directory/another-id"
  tar --format=ustar --gzip --create --file "$LIFECYCLE_REMOTE" \
    --directory "$ROOT/expanded" .
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  : >"$LIFECYCLE_CALLS"
  register_account
  [ "$status" -eq 65 ]
  assert_unmodified
  assert_registration_not_invoked
  assert_no_remote_write
}

@test "unknown account contact fails closed without silently rewriting it" {
  register_account
  [ "$status" -eq 0 ]
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  : >"$LIFECYCLE_CALLS"
  run env LIFECYCLE_REGISTER_CALL=true TMPDIR="$ROOT/register-runner" \
    "$BASH_STARTER_ARTIFACT" register --email other@example.org \
    --agree-tos true --s3-bucket fixture-bucket
  [ "$status" -eq 65 ]
  assert_unmodified
  assert_registration_not_invoked
  assert_no_remote_write
}

@test "invalid archived bytes cannot reach Certbot or S3 publication" {
  printf '%s\n' 'malformed compressed archive' >"$LIFECYCLE_REMOTE"
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  register_account
  [ "$status" -ne 0 ]
  assert_unmodified
  assert_registration_not_invoked
  assert_no_remote_write
  [[ "$output" != *'published=true'* ]]
}

@test "no preexisting account never triggers implicit issuer registration" {
  seed_accountless_archive
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  issue_certificate
  [ "$status" -eq 65 ]
  assert_unmodified
  assert_registration_not_invoked
  assert_no_remote_write
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"

  rm -f -- "$LIFECYCLE_REMOTE"
  : >"$LIFECYCLE_CALLS"
  issue_certificate
  [ "$status" -eq 66 ]
  assert_registration_not_invoked
  assert_no_remote_write
}

@test "ambiguous and unauthorized S3 reads do not create ACME accounts" {
  local failure
  for failure in head-denied head-transport head-ambiguous-missing; do
    export LIFECYCLE_MODE="$failure"
    : >"$LIFECYCLE_CALLS"
    register_account
    [ "$status" -eq 69 ]
    assert_registration_not_invoked
    assert_no_remote_write
    [ ! -e "$LIFECYCLE_REMOTE" ]
    [[ "$output" != *'private-token-DO-NOT-LOG'* ]]
  done
}

@test "partial registration and rejected conditional writes do not claim success" {
  local failure
  for failure in register-failure register-partial-failure; do
    export LIFECYCLE_MODE="$failure"
    : >"$LIFECYCLE_CALLS"
    register_account
    [ "$status" -eq 74 ]
    assert_no_remote_write
    [ ! -e "$LIFECYCLE_REMOTE" ]
    [[ "$output" != *'published=true'* ]]
  done

  export LIFECYCLE_MODE=ok
  export LIFECYCLE_PUT_MODE=conditional-conflict
  : >"$LIFECYCLE_CALLS"
  register_account
  [ "$status" -eq 74 ]
  [[ "$output" == *'remote state uncertain'* ]]
  [ ! -e "$LIFECYCLE_REMOTE" ]
}

@test "lost S3 response is reported uncertain without private data in output" {
  export LIFECYCLE_PUT_MODE=put-after-write-failure
  register_account
  [ "$status" -eq 74 ]
  [[ "$output" == *'remote state uncertain'* ]]
  [[ "$output" != *'synthetic-private-DO-NOT-LOG'* ]]
  [[ "$output" != *'operator@example.org'* ]]
  [[ "$output" != *'mock-private-PUT-TOKEN'* ]]
  [ -s "$LIFECYCLE_REMOTE" ]
}

@test "failed registration does not replace an existing accountless archive" {
  seed_accountless_archive
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  export LIFECYCLE_MODE=register-failure
  register_account
  [ "$status" -eq 74 ]
  assert_unmodified
  assert_no_remote_write
  [[ "$output" != *'published=true'* ]]
}
