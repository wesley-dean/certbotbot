#!/usr/bin/env bats

# Milestone 4 fixture-only black-box contract (task #47).  The public,
# checksummed producer artifact is invoked in a subprocess for every run.
# No real ACME, Route53 or S3 calls are made; tests use the existing mock
# executable boundary and local, self-signed certificate fixture.

setup() {
  : "${BASH_STARTER_ARTIFACT:?Built producer artifact is required}"
  source "$BATS_TEST_DIRNAME/helpers/lifecycle-fixture.bash"
  lifecycle_fixture_setup
  mkdir -m 700 "$ROOT/runner-a" "$ROOT/runner-b"
  # A pre-existing staging ACME account is the only initial durable state.
  mv "$ROOT/seed/accounts/acme-v02.api.letsencrypt.org" \
    "$ROOT/seed/accounts/acme-staging-v02.api.letsencrypt.org"
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/seed" .
}

teardown() {
  rm -rf -- "$ROOT"
}

run_staging() {
  local runner="$1"
  shift
  run env TMPDIR="$runner" "$BASH_STARTER_ARTIFACT" \
    --acme-environment staging --s3-bucket fixture-bucket \
    --include-subdomains true "$@" example.com
}

# The fixture's two mock providers share one bounded invocation-order trace.
# Exact comparison rejects extra/absent/reordered calls, not merely the
# presence of an expected verb somewhere in the job.
expect_trace() {
  printf '%s\n' "$@" >"$ROOT/expected-trace"
  cmp -s -- "$ROOT/expected-trace" "$LIFECYCLE_CALLS"
}

expect_staging_only() {
  [ -f "$LIFECYCLE_CONTEXTS" ] || return 1
  grep -Fq 'https://acme-staging-v02.api.letsencrypt.org/directory' \
    "$LIFECYCLE_CONTEXTS" &&
    ! grep -Fq 'https://acme-v02.api.letsencrypt.org/directory' \
      "$LIFECYCLE_CONTEXTS" &&
    ! grep -q '^certbot:register$' "$LIFECYCLE_CALLS"
}

expect_original_account() {
  # Inspect local synthetic account bytes without displaying their contents.
  tar -xOf "$LIFECYCLE_REMOTE" \
    ./accounts/acme-staging-v02.api.letsencrypt.org/directory/account-id/private_key.json |
    cmp -s - \
      "$ROOT/seed/accounts/acme-staging-v02.api.letsencrypt.org/directory/account-id/private_key.json"
}

assert_runner_context() {
  local verb="$1" runner="$2" line marker context_verb
  local config work logs name account
  line="$(grep "^certbot-context:$verb:" "$LIFECYCLE_CONTEXTS")" || return 1
  IFS=: read -r marker context_verb config work logs name account <<< "$line"
  [ "$marker" = certbot-context ] &&
    [ "$context_verb" = "$verb" ] &&
    [[ "$config" == "$runner/"* ]] &&
    [[ "$work" == "$runner/"* ]] &&
    [[ "$logs" == "$runner/"* ]] &&
    [ "$name" = example.com ] &&
    [ "$account" = account-id ]
}

@test "seeded staging issuance has exact HEAD GET Certbot and single PUT order" {
  run_staging "$ROOT/runner-a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  expect_trace \
    'aws:head-object:fixture-bucket:latest.tar.gz' \
    'aws:get-object:fixture-bucket:latest.tar.gz' \
    'certbot:plugins' \
    'certbot:show_account' \
    'certbot:certonly' \
    'aws:put-object:fixture-bucket:latest.tar.gz'
  expect_staging_only
  assert_runner_context certonly "$ROOT/runner-a"
  expect_original_account
  tar -xOf "$LIFECYCLE_REMOTE" ./renewal/example.com.conf |
    grep -Fxq 'server = https://acme-staging-v02.api.letsencrypt.org/directory'
  [ -z "$(find "$ROOT/runner-a" -mindepth 1 -print -quit)" ]
}

@test "separate runner restores original account and selected lineage for no-op" {
  run_staging "$ROOT/runner-a"
  [ "$status" -eq 0 ]
  cp "$LIFECYCLE_REMOTE" "$ROOT/published.tar.gz"
  : >"$LIFECYCLE_CALLS"
  run_staging "$ROOT/runner-b"
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=false"* ]]
  expect_trace \
    'aws:head-object:fixture-bucket:latest.tar.gz' \
    'aws:get-object:fixture-bucket:latest.tar.gz' \
    'certbot:plugins' \
    'certbot:show_account' \
    'certbot:renew'
  cmp -s "$ROOT/published.tar.gz" "$LIFECYCLE_REMOTE"
  expect_original_account
  expect_staging_only
  assert_runner_context certonly "$ROOT/runner-a"
  assert_runner_context renew "$ROOT/runner-b"
  [ -z "$(find "$ROOT/runner-a" -mindepth 1 -print -quit)" ]
  [ -z "$(find "$ROOT/runner-b" -mindepth 1 -print -quit)" ]
}

@test "mocked due renewal validates changed lineage before one same-key PUT" {
  run_staging "$ROOT/runner-a"
  [ "$status" -eq 0 ]
  tar -xOf "$LIFECYCLE_REMOTE" ./archive/example.com/cert1.pem \
    >"$ROOT/old-leaf.pem"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_MODE=renew-changed
  run_staging "$ROOT/runner-b"
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  expect_trace \
    'aws:head-object:fixture-bucket:latest.tar.gz' \
    'aws:get-object:fixture-bucket:latest.tar.gz' \
    'certbot:plugins' \
    'certbot:show_account' \
    'certbot:renew' \
    'aws:put-object:fixture-bucket:latest.tar.gz'
  expect_staging_only
  expect_original_account
  tar -xOf "$LIFECYCLE_REMOTE" ./archive/example.com/cert1.pem \
    >"$ROOT/new-leaf.pem"
  ! cmp -s "$ROOT/old-leaf.pem" "$ROOT/new-leaf.pem"
}

@test "missing current object fails before GET Certbot or publication" {
  rm -f -- "$LIFECYCLE_REMOTE"
  run_staging "$ROOT/runner-a"
  [ "$status" -eq 66 ]
  [[ "$output" != *"published=true"* ]]
  expect_trace \
    'aws:head-object:fixture-bucket:latest.tar.gz' \
    'aws:head-bucket:fixture-bucket:'
  [ -z "$(find "$ROOT/runner-a" -mindepth 1 -print -quit)" ]
}

@test "corrupt current object fails after GET but before Certbot or PUT" {
  printf '%s\n' 'not a gzip archive' >"$LIFECYCLE_REMOTE"
  cp "$LIFECYCLE_REMOTE" "$ROOT/known-good-bytes"
  run_staging "$ROOT/runner-a"
  [ "$status" -ne 0 ]
  [[ "$output" != *"published=true"* ]]
  expect_trace \
    'aws:head-object:fixture-bucket:latest.tar.gz' \
    'aws:get-object:fixture-bucket:latest.tar.gz'
  cmp -s "$ROOT/known-good-bytes" "$LIFECYCLE_REMOTE"
}

@test "failed staging Certbot stops before publication and preserves seed bytes" {
  cp "$LIFECYCLE_REMOTE" "$ROOT/known-good-bytes"
  export LIFECYCLE_MODE=certbot-failure
  run_staging "$ROOT/runner-a"
  [ "$status" -eq 74 ]
  [[ "$output" != *"published=true"* ]]
  expect_trace \
    'aws:head-object:fixture-bucket:latest.tar.gz' \
    'aws:get-object:fixture-bucket:latest.tar.gz' \
    'certbot:plugins' \
    'certbot:show_account' \
    'certbot:certonly'
  cmp -s "$ROOT/known-good-bytes" "$LIFECYCLE_REMOTE"
  expect_staging_only
}

@test "failed local candidate packaging cannot publish or change remote bytes" {
  cp "$LIFECYCLE_REMOTE" "$ROOT/known-good-bytes"
  cat >"$ROOT/bin/tar" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == --format=ustar ]]; then exit 27; fi
exec /usr/bin/tar "$@"
MOCK
  chmod 755 "$ROOT/bin/tar"
  run_staging "$ROOT/runner-a"
  [ "$status" -ne 0 ]
  [[ "$output" != *"published=true"* ]]
  expect_trace \
    'aws:head-object:fixture-bucket:latest.tar.gz' \
    'aws:get-object:fixture-bucket:latest.tar.gz' \
    'certbot:plugins' \
    'certbot:show_account' \
    'certbot:certonly'
  cmp -s "$ROOT/known-good-bytes" "$LIFECYCLE_REMOTE"
  expect_staging_only
}

@test "rejected S3 PUT propagates error without asserting publication" {
  cp "$LIFECYCLE_REMOTE" "$ROOT/known-good-bytes"
  export LIFECYCLE_MODE=put-failure
  run_staging "$ROOT/runner-a"
  [ "$status" -eq 74 ]
  [[ "$output" != *"published=true"* ]]
  expect_trace \
    'aws:head-object:fixture-bucket:latest.tar.gz' \
    'aws:get-object:fixture-bucket:latest.tar.gz' \
    'certbot:plugins' \
    'certbot:show_account' \
    'certbot:certonly' \
    'aws:put-object:fixture-bucket:latest.tar.gz'
  cmp -s "$ROOT/known-good-bytes" "$LIFECYCLE_REMOTE"
  expect_staging_only
}

@test "lost S3 PUT reply is reported uncertain, never as preserved state" {
  cp "$LIFECYCLE_REMOTE" "$ROOT/prior.tar.gz"
  export LIFECYCLE_MODE=put-after-write-failure
  run_staging "$ROOT/runner-a"
  [ "$status" -eq 74 ]
  [[ "$output" == *"remote state is uncertain"* ]]
  [[ "$output" != *"published=true"* ]]
  expect_trace \
    'aws:head-object:fixture-bucket:latest.tar.gz' \
    'aws:get-object:fixture-bucket:latest.tar.gz' \
    'certbot:plugins' \
    'certbot:show_account' \
    'certbot:certonly' \
    'aws:put-object:fixture-bucket:latest.tar.gz'
  ! cmp -s "$ROOT/prior.tar.gz" "$LIFECYCLE_REMOTE"
  expect_staging_only
}
