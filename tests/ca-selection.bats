#!/usr/bin/env bats

setup() {
  : "${BASH_STARTER_ARTIFACT:?Built producer artifact is required}"
  source "$BATS_TEST_DIRNAME/helpers/lifecycle-fixture.bash"
  lifecycle_fixture_setup
}

teardown() {
  rm -rf -- "$ROOT"
}

staging_seed() {
  mv "$ROOT/seed/accounts/acme-v02.api.letsencrypt.org" \
    "$ROOT/seed/accounts/acme-staging-v02.api.letsencrypt.org"
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/seed" .
}

staging_run() {
  run env TMPDIR="$ROOT/runner-temp" "$BASH_STARTER_ARTIFACT" \
    --s3-bucket fixture-bucket --acme-environment staging "$@" example.com
}

no_provider_or_upload() {
  ! grep -Eq '^certbot:|^aws:put-object:' "$LIFECYCLE_CALLS" 2>/dev/null
}

only_staging_certbot() {
  ! grep -Fq 'https://acme-v02.api.letsencrypt.org/directory' \
    "$LIFECYCLE_CONTEXTS"
}

@test "explicit staging selection issues a selected public certificate and publishes staging metadata" {
  staging_seed
  staging_run
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=true'* ]]
  grep -Fxq 'certbot-server:certonly:https://acme-staging-v02.api.letsencrypt.org/directory' \
    "$LIFECYCLE_CONTEXTS"
  grep -Fxq 'certbot-server:show_account:https://acme-staging-v02.api.letsencrypt.org/directory' \
    "$LIFECYCLE_CONTEXTS"
  only_staging_certbot
  tar -xOf "$LIFECYCLE_REMOTE" ./renewal/example.com.conf |
    grep -Fxq 'server = https://acme-staging-v02.api.letsencrypt.org/directory'
  tar -tzf "$LIFECYCLE_REMOTE" |
    grep -Fq './accounts/acme-staging-v02.api.letsencrypt.org/directory/account-id/'
}

@test "second independent staging runner reuses account and observes real mock no-op behavior" {
  staging_seed
  staging_run
  [ "$status" -eq 0 ]
  cp "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
  staging_run
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=false'* ]]
  cmp -s "$ROOT/before.tar.gz" "$LIFECYCLE_REMOTE"
  grep -Fxq 'certbot-server:renew:https://acme-staging-v02.api.letsencrypt.org/directory' \
    "$LIFECYCLE_CONTEXTS"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  only_staging_certbot
}

@test "staging selected renewal can publish changed selected state without a CA switch" {
  staging_seed
  staging_run
  [ "$status" -eq 0 ]
  : >"$LIFECYCLE_CONTEXTS"
  export LIFECYCLE_MODE=renew-changed
  staging_run
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=true'* ]]
  grep -Fxq 'certbot-server:renew:https://acme-staging-v02.api.letsencrypt.org/directory' \
    "$LIFECYCLE_CONTEXTS"
  only_staging_certbot
}

@test "staging selection rejects a production-only account without Certbot or S3 publication" {
  staging_run
  [ "$status" -ne 0 ]
  no_provider_or_upload
}

@test "default production selector rejects a staging-only account before invoking Certbot" {
  staging_seed
  run env TMPDIR="$ROOT/runner-temp" "$BASH_STARTER_ARTIFACT" \
    --s3-bucket fixture-bucket example.com
  [ "$status" -ne 0 ]
  no_provider_or_upload
}

@test "mixed CA account archive fails closed for both selected environments" {
  mkdir -p "$ROOT/seed/accounts/acme-staging-v02.api.letsencrypt.org"
  cp -a "$ROOT/seed/accounts/acme-v02.api.letsencrypt.org/directory" \
    "$ROOT/seed/accounts/acme-staging-v02.api.letsencrypt.org/"
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/seed" .
  staging_run
  [ "$status" -ne 0 ]
  no_provider_or_upload
  run env TMPDIR="$ROOT/runner-temp" "$BASH_STARTER_ARTIFACT" \
    --s3-bucket fixture-bucket example.com
  [ "$status" -ne 0 ]
  no_provider_or_upload
}

@test "staging rejects production-bound renewal metadata before provider execution" {
  staging_seed
  staging_run
  [ "$status" -eq 0 ]
  mkdir -m 700 "$ROOT/unpacked"
  tar -xzf "$LIFECYCLE_REMOTE" -C "$ROOT/unpacked"
  sed -i 's@https://acme-staging-v02.api.letsencrypt.org/directory@https://acme-v02.api.letsencrypt.org/directory@' \
    "$ROOT/unpacked/renewal/example.com.conf"
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/unpacked" .
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
  staging_run
  [ "$status" -ne 0 ]
  no_provider_or_upload
}

@test "failed staging Certbot cannot fall back to production or publish" {
  staging_seed
  export LIFECYCLE_MODE=certbot-failure
  staging_run
  [ "$status" -ne 0 ]
  only_staging_certbot
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  ! grep -q '^certbot:register' "$LIFECYCLE_CALLS"
}

@test "unsupported, empty or duplicate CA selectors fail before remote calls" {
  run env TMPDIR="$ROOT/runner-temp" "$BASH_STARTER_ARTIFACT" \
    --s3-bucket fixture-bucket --acme-environment arbitrary example.com
  [ "$status" -eq 64 ]
  [ ! -s "$LIFECYCLE_CALLS" ]
  run env TMPDIR="$ROOT/runner-temp" "$BASH_STARTER_ARTIFACT" \
    --s3-bucket fixture-bucket --acme-environment '' example.com
  [ "$status" -eq 64 ]
  [ ! -s "$LIFECYCLE_CALLS" ]
  run env TMPDIR="$ROOT/runner-temp" "$BASH_STARTER_ARTIFACT" \
    --s3-bucket fixture-bucket --acme-environment staging \
    --acme-environment production example.com
  [ "$status" -eq 64 ]
  [ ! -s "$LIFECYCLE_CALLS" ]
}

@test "explicit CLI staging overrides exported production and literal file value" {
  staging_seed
  printf '%s\n' 'ACME_ENVIRONMENT=production' >"$ROOT/ca.env"
  export ACME_ENVIRONMENT=production
  run env TMPDIR="$ROOT/runner-temp" "$BASH_STARTER_ARTIFACT" \
    --config "$ROOT/ca.env" --s3-bucket fixture-bucket \
    --acme-environment=staging example.com
  [ "$status" -eq 0 ]
  only_staging_certbot
}

@test "exported staging overrides literal production without changing default" {
  staging_seed
  printf '%s\n' 'ACME_ENVIRONMENT=production' >"$ROOT/ca.env"
  export ACME_ENVIRONMENT=staging
  run env TMPDIR="$ROOT/runner-temp" "$BASH_STARTER_ARTIFACT" \
    --config "$ROOT/ca.env" --s3-bucket fixture-bucket example.com
  [ "$status" -eq 0 ]
  only_staging_certbot
}
