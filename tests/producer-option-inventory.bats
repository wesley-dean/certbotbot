#!/usr/bin/env bats

## @file tests/producer-option-inventory.bats
## @brief Verifies public no-network help and bounded option-routing contracts.
## @details
## Task #290 audits every public producer and registrar option without
## changing implementation. Tests guard the documented command surface for
## all three assembled producer variants. No AWS, Route53 or ACME operation
## is authorized by any test.

setup() {
  : "${BASH_STARTER_ARTIFACT:?verified producer artifact required}"
}

@test "public ordinary help exposes all implemented named producer settings" {
  local flag
  run "$BASH_STARTER_ARTIFACT" --help
  [ "$status" -eq 0 ]
  for flag in \
    --config --no-env --aws-args --gpg-args --certbot-args \
    --domain --acme-environment --san --include-subdomains \
    --cert-name --s3-bucket --s3-key --s3-key-template \
    --backup-key-template --dated-backup-enabled \
    --backup-retention-count --renew-all --remove-orphans \
    --desired-cert-name --upload-no-renewal --archive-encryption \
    --archive-migration --archive-migration-backup-confirmed \
    --help --version; do
    [[ "$output" == *"$flag"* ]] || {
      printf 'missing producer help flag: %s\n' "$flag" >&3
      return 1
    }
  done
}

@test "registration first-argument help exposes registrar-only and shared flags" {
  local flag
  run "$BASH_STARTER_ARTIFACT" register --help
  [ "$status" -eq 0 ]
  for flag in \
    --email --agree-tos --eff-email-signup --acme-environment \
    --s3-bucket --s3-key --s3-key-template --archive-encryption \
    --config --no-env --aws-args --gpg-args --certbot-args; do
    [[ "$output" == *"$flag"* ]] || {
      printf 'missing registration help flag: %s\n' "$flag" >&3
      return 1
    }
  done
  [[ "$output" != *--remove-orphans* ]]
  [[ "$output" != *--renew-all* ]]
  [[ "$output" != *--san* ]]
}

@test "registrar refuses issuer-only flags before any provider execution" {
  local flag
  for flag in --renew-all --remove-orphans --san --domain; do
    run "$BASH_STARTER_ARTIFACT" register --no-env "$flag" true
    [ "$status" -eq 64 ]
    [[ "$output" == *'unknown registration option'* ]]
  done
}

@test "repeatable desired names are parsed as collection rather than scalars" {
  run "$BASH_STARTER_ARTIFACT" --no-env --remove-orphans true \
    --desired-cert-name example.com --desired-cert-name alias.net \
    example.com
  [ "$status" -eq 64 ]
  # The only failure here is the deliberately absent S3 bucket; duplicated
  # scalar rejection would precede this diagnostic.
  [[ "$output" == *'S3 bucket and key are required'* ]]
  [[ "$output" != *duplicate* ]]
}

@test "register version is not an option while top-level version works" {
  run "$BASH_STARTER_ARTIFACT" register --version
  [ "$status" -eq 64 ]
  [[ "$output" == *'unknown registration option'* ]]
  run "$BASH_STARTER_ARTIFACT" --version
  [ "$status" -eq 0 ]
}
