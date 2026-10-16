#!/usr/bin/env bats

## Issue #11: production remains the default; staging uses a fixed ACME
## directory and segregated S3 archive namespace.  PATH fakes verify argv.

setup() {
  : "${CERTBOTBOT_ARTIFACT:?An artifact is required}"
  unset ACME_ENVIRONMENT CERTIFICATES
  export ACME_TEST_AWS_ARGS="$BATS_TEST_TMPDIR/aws-args"
  export ACME_TEST_CERTBOT_ARGS="$BATS_TEST_TMPDIR/certbot-args"
  local binaries="$BATS_TEST_TMPDIR/fake-bin"
  mkdir -p "$binaries"
  cat >"$binaries/aws" <<'FAKE'
#!/usr/bin/env bash
printf '<%s>\n' "$@" >"$ACME_TEST_AWS_ARGS"
exit 0
FAKE
  cat >"$binaries/certbot" <<'FAKE'
#!/usr/bin/env bash
printf '<%s>\n' "$@" >"$ACME_TEST_CERTBOT_ARGS"
exit 0
FAKE
  chmod 0700 "$binaries/aws" "$binaries/certbot"
  export PATH="$binaries:$PATH"
}

@test "the default production environment accepts normal preflight" {
  run "$CERTBOTBOT_ARTIFACT" --validate example.com
  [ "$status" -eq 0 ]
  [ "$output" = $'example.com\texample.com *.example.com' ]
  [ ! -f "$ACME_TEST_CERTBOT_ARGS" ]
  [ ! -f "$ACME_TEST_AWS_ARGS" ]
}

@test "the --staging option accepts the same certificate intent" {
  run "$CERTBOTBOT_ARTIFACT" --staging --validate example.com
  [ "$status" -eq 0 ]
  [ "$output" = $'example.com\texample.com *.example.com' ]
  [ ! -f "$ACME_TEST_CERTBOT_ARGS" ]
  [ ! -f "$ACME_TEST_AWS_ARGS" ]
}

@test "explicit staging environment flag and env variable both work" {
  run "$CERTBOTBOT_ARTIFACT" --acme-environment staging --validate example.com
  [ "$status" -eq 0 ]
  run env ACME_ENVIRONMENT=staging "$CERTBOTBOT_ARTIFACT" --validate example.com
  [ "$status" -eq 0 ]
}

@test "explicit production can override a staging environment variable" {
  run env ACME_ENVIRONMENT=staging "$CERTBOTBOT_ARTIFACT" \
    --acme-environment production --validate example.com
  [ "$status" -eq 0 ]
}

@test "unsupported environment and missing value are rejected" {
  run env ACME_ENVIRONMENT=qa "$CERTBOTBOT_ARTIFACT" --validate example.com
  [ "$status" -eq 64 ]
  run "$CERTBOTBOT_ARTIFACT" --acme-environment qa --validate example.com
  [ "$status" -eq 64 ]
  run "$CERTBOTBOT_ARTIFACT" --acme-environment
  [ "$status" -eq 64 ]
  [ ! -f "$ACME_TEST_AWS_ARGS" ]
}

@test "contradictory mode flags are rejected instead of last one winning" {
  run "$CERTBOTBOT_ARTIFACT" --staging \
    --acme-environment production --validate example.com
  [ "$status" -eq 64 ]
  [ ! -f "$ACME_TEST_CERTBOT_ARGS" ]
}

@test "only two fixed ACME directory URLs are available" {
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_acme_directory production
    certbotbot_acme_directory staging
  ' _ "$CERTBOTBOT_ARTIFACT"
  [ "$status" -eq 0 ]
  [ "$output" = $'https://acme-v02.api.letsencrypt.org/directory\nhttps://acme-staging-v02.api.letsencrypt.org/directory' ]
}

@test "production archive names remain backward-compatible and staging names are prefixed" {
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_acme_object_key production common-latest.tar.gz
    certbotbot_acme_object_key production example.com-latest.tar.gz.enc
    certbotbot_acme_object_key staging common-latest.tar.gz
    certbotbot_acme_object_key staging example.com-latest.tar.gz.enc
  ' _ "$CERTBOTBOT_ARTIFACT"
  [ "$status" -eq 0 ]
  [ "$output" = $'common-latest.tar.gz\nexample.com-latest.tar.gz.enc\nstaging/common-latest.tar.gz\nstaging/example.com-latest.tar.gz.enc' ]
}

@test "untrusted storage object identifiers are rejected" {
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_acme_object_key staging ../../common-latest.tar.gz
  ' _ "$CERTBOTBOT_ARTIFACT"
  [ "$status" -eq 64 ]
}

@test "a staging S3 upload writes only a staging-prefixed key" {
  local source="$BATS_TEST_TMPDIR/source.tar.gz"
  printf 'placeholder\n' >"$source"
  run env ACME_ENVIRONMENT=staging bash -c '
    source "$1" --version >/dev/null
    certbotbot_storage_s3_put archive-bucket staging/example.com-latest.tar.gz "$2"
  ' _ "$CERTBOTBOT_ARTIFACT" "$source"
  [ "$status" -eq 0 ]
  grep -Fx '<staging/example.com-latest.tar.gz>' "$ACME_TEST_AWS_ARGS"
}

@test "staging mode cannot upload to the production archive key" {
  local source="$BATS_TEST_TMPDIR/source.tar.gz"
  printf 'placeholder\n' >"$source"
  run env ACME_ENVIRONMENT=staging bash -c '
    source "$1" --version >/dev/null
    certbotbot_storage_s3_put archive-bucket example.com-latest.tar.gz "$2"
  ' _ "$CERTBOTBOT_ARTIFACT" "$source"
  [ "$status" -eq 64 ]
  [ ! -f "$ACME_TEST_AWS_ARGS" ]
}

@test "production mode cannot access staging archive keys" {
  local target="$BATS_TEST_TMPDIR/target.tar.gz"
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_storage_s3_get archive-bucket staging/common-latest.tar.gz "$2"
  ' _ "$CERTBOTBOT_ARTIFACT" "$target"
  [ "$status" -eq 64 ]
  [ ! -f "$ACME_TEST_AWS_ARGS" ]
}

@test "the built-in Route53 adapter selects the staging ACME URL" {
  local config="$BATS_TEST_TMPDIR/config" work="$BATS_TEST_TMPDIR/work"
  local logs="$BATS_TEST_TMPDIR/logs"
  mkdir -p "$config" "$work" "$logs"
  chmod 0700 "$config" "$work" "$logs"
  run env ACME_ENVIRONMENT=staging bash -c '
    source "$1" --version >/dev/null
    certbotbot_dns_route53_issue example.com "$2" "$3" "$4" \
      admin@example.com example.com "*.example.com"
  ' _ "$CERTBOTBOT_ARTIFACT" "$config" "$work" "$logs"
  [ "$status" -eq 0 ]
  grep -Fx '<https://acme-staging-v02.api.letsencrypt.org/directory>' "$ACME_TEST_CERTBOT_ARGS"
  ! grep -Fx '<https://acme-v02.api.letsencrypt.org/directory>' "$ACME_TEST_CERTBOT_ARGS"
  [ ! -f "$ACME_TEST_AWS_ARGS" ]
}

@test "invalid ACME mode never starts a Certbot issuer subprocess" {
  local config="$BATS_TEST_TMPDIR/config" work="$BATS_TEST_TMPDIR/work"
  local logs="$BATS_TEST_TMPDIR/logs"
  mkdir -p "$config" "$work" "$logs"
  chmod 0700 "$config" "$work" "$logs"
  run env ACME_ENVIRONMENT='https://malicious.example/directory' bash -c '
    source "$1" --version >/dev/null
    certbotbot_dns_route53_issue example.com "$2" "$3" "$4" \
      admin@example.com example.com "*.example.com"
  ' _ "$CERTBOTBOT_ARTIFACT" "$config" "$work" "$logs"
  [ "$status" -eq 64 ]
  [ ! -f "$ACME_TEST_CERTBOT_ARGS" ]
}

@test "staging flag does not activate unfinished certificate issuance" {
  run "$CERTBOTBOT_ARTIFACT" --staging example.com
  [ "$status" -eq 69 ]
  [ ! -f "$ACME_TEST_CERTBOT_ARGS" ]
  [ ! -f "$ACME_TEST_AWS_ARGS" ]
}
