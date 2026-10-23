#!/usr/bin/env bats

setup() {
  : "${BASH_STARTER_ARTIFACT:?Artifact under test is required}"
  TEST_CONFIG_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_CONFIG_DIR"
}

@test "explicit config overrides discovered .env and environment overrides file" {
  printf 'S3_BUCKET=from-discovery\n' >"$TEST_CONFIG_DIR/.env"
  printf 'S3_BUCKET=from-file\nDOMAIN=from-file.example\n' >"$TEST_CONFIG_DIR/chosen"
  run bash -c '
    source lib/config.bash
    cd "$1"
    S3_BUCKET=from-environment
    export S3_BUCKET
    certbotbot_config_resolve --config "$2" --s3-bucket from-cli --domain cli.example || exit $?
    printf "%s|%s|%s" "$CERTBOTBOT_S3_BUCKET" "$CERTBOTBOT_DOMAIN" "$CERTBOTBOT_S3_KEY"
  ' _ "$TEST_CONFIG_DIR" "$TEST_CONFIG_DIR/chosen"
  if [ "$status" -ne 0 ] || [ "$output" != 'from-cli|cli.example|latest.tar.gz' ]; then
    printf 'precedence: status=%s output=%s\n' "$status" "$output" >&3
    return 1
  fi
}

@test "literal .env values and explicit false survive resolution" {
  printf 'S3_BUCKET="bucket with spaces"\nINCLUDE_SUBDOMAINS=false\nUPLOAD_NO_RENEWAL=true\nDOMAIN=EXAMPLE.COM\n' >"$TEST_CONFIG_DIR/.env"
  run bash -c '
    source lib/config.bash
    source lib/identity.bash
    cd "$1"
    certbotbot_config_resolve --include-subdomains false || exit $?
    certbotbot_identity_resolve || exit $?
    printf "%s|%s|%s|%s" "$CERTBOTBOT_S3_BUCKET" "$CERTBOTBOT_INCLUDE_SUBDOMAINS" "$CERTBOTBOT_CERT_NAME" "${CERTBOTBOT_SANS[*]}"
  ' _ "$TEST_CONFIG_DIR"
  if [ "$status" -ne 0 ] || [ "$output" != 'bucket with spaces|false|example.com|example.com' ]; then
    printf 'literal file: status=%s output=%s\n' "$status" "$output" >&3
    return 1
  fi
}

@test "wildcard and apex inputs select the same shortest lineage name" {
  run bash -c '
    source lib/config.bash
    source lib/identity.bash
    CERTBOTBOT_DOMAIN="*.example.com"
    CERTBOTBOT_INCLUDE_SUBDOMAINS=true
    CERTBOTBOT_CERT_NAME=""
    certbotbot_identity_resolve
    printf "%s|%s" "$CERTBOTBOT_CERT_NAME" "${CERTBOTBOT_SANS[*]}"
  '
  [ "$status" -eq 0 ]
  [ "$output" = 'example.com|*.example.com example.com' ]
}

@test "explicit certificate name is honored without changing archive key" {
  run bash -c '
    source lib/config.bash
    source lib/identity.bash
    certbotbot_config_resolve --s3-bucket bucket --cert-name issued.example.com example.com
    certbotbot_identity_resolve
    printf "%s|%s" "$CERTBOTBOT_CERT_NAME" "$CERTBOTBOT_S3_KEY"
  '
  [ "$status" -eq 0 ]
  [ "$output" = 'issued.example.com|latest.tar.gz' ]
}

@test "reject malformed DNS labels including trailing dots" {
  local name
  for name in example.com. .example.com example..com 'a*.example.com' '-a.example.com' 'a-.example.com'; do
    run "${BASH_STARTER_ARTIFACT}" --s3-bucket bucket "$name"
    [ "$status" -eq 64 ]
  done
}

@test "reject duplicate configuration keys without disclosing contents" {
  printf 'S3_BUCKET=SECRET123\nS3_BUCKET=SECRET456\n' >"$TEST_CONFIG_DIR/.env"
  run "${BASH_STARTER_ARTIFACT}" --config "$TEST_CONFIG_DIR/.env" example.com
  [ "$status" -eq 64 ]
  [[ "$output" != *SECRET123* && "$output" != *SECRET456* ]]
}

@test "reject duplicate --config before any cloud operations" {
  touch "$TEST_CONFIG_DIR/a" "$TEST_CONFIG_DIR/b"
  run "${BASH_STARTER_ARTIFACT}" --config "$TEST_CONFIG_DIR/a" --config "$TEST_CONFIG_DIR/b" --s3-bucket bucket example.com
  [ "$status" -eq 64 ]
}

@test "reject unknown configuration key and nonliteral data" {
  printf 'INVENTED_KEY=anything\n' >"$TEST_CONFIG_DIR/.env"
  run "${BASH_STARTER_ARTIFACT}" --config "$TEST_CONFIG_DIR/.env" --s3-bucket bucket example.com
  [ "$status" -eq 64 ]
  printf 'S3_BUCKET=\x60touch compromised\x60\n' >"$TEST_CONFIG_DIR/.env"
  run "${BASH_STARTER_ARTIFACT}" --config "$TEST_CONFIG_DIR/.env" example.com
  [ "$status" -eq 64 ]
}

@test "missing selected configuration and conflicting DNS arguments fail closed" {
  run "${BASH_STARTER_ARTIFACT}" --config "$TEST_CONFIG_DIR/missing" --s3-bucket bucket example.com
  [ "$status" -eq 64 ]
  run "${BASH_STARTER_ARTIFACT}" --s3-bucket bucket --domain example.com other.example
  [ "$status" -eq 64 ]
}

@test "invalid certificate identifier fails before lifecycle" {
  run "${BASH_STARTER_ARTIFACT}" --s3-bucket bucket --cert-name '*.example.com' example.com
  [ "$status" -eq 64 ]
}


@test "derived wildcard-only lineage is refused before external tooling" {
  run "${BASH_STARTER_ARTIFACT}" --s3-bucket bucket \
    --include-subdomains=false '*.example.com'
  [ "$status" -eq 64 ]
  [[ "$output" == *"invalid derived certificate name"* ]]
}

@test "explicit safe lineage allows wildcard-only SAN without changing SAN input" {
  run bash -c '
    source lib/config.bash
    source lib/identity.bash
    certbotbot_config_resolve --s3-bucket bucket \
      --include-subdomains=false --cert-name issued.example.com \
      "*.example.com" || exit $?
    certbotbot_identity_resolve || exit $?
    printf "%s|%s|%s" "$CERTBOTBOT_CERT_NAME" \
      "${CERTBOTBOT_SANS[*]}" "$CERTBOTBOT_S3_KEY"
  '
  [ "$status" -eq 0 ]
  [ "$output" = 'issued.example.com|*.example.com|latest.tar.gz' ]
}

@test "shortest SAN selector uses ASCII lexical ordering independent of order" {
  run bash -c '
    source lib/config.bash
    source lib/identity.bash
    certbotbot_identity_shortest beta.example.com alfa.example.com || exit $?
    first="$REPLY"
    certbotbot_identity_shortest alfa.example.com beta.example.com || exit $?
    printf "%s|%s" "$first" "$REPLY"
  '
  [ "$status" -eq 0 ]
  [ "$output" = 'alfa.example.com|alfa.example.com' ]
}

@test "shortest SAN selector rejects a derived wildcard name and unsafe input" {
  run bash -c '
    source lib/config.bash
    source lib/identity.bash
    certbotbot_identity_shortest "*.example.com" && exit 90
    certbotbot_identity_shortest /tmp/traversal.example && exit 91
    certbotbot_identity_shortest example.com "*.example.com" || exit $?
    printf "%s" "$REPLY"
  '
  [ "$status" -eq 0 ]
  [ "$output" = example.com ]
}

@test "each unrelated additional DNS name receives one complement and no recursion" {
  run bash -c '
    source lib/config.bash
    source lib/identity.bash
    certbotbot_config_resolve --s3-bucket bucket --san api.example.net \\
      --san service.other.org example.com || exit $?
    certbotbot_identity_resolve || exit $?
    printf "%s|%s" "$CERTBOTBOT_CERT_NAME" "${CERTBOTBOT_SANS[*]}"
  '
  [ "$status" -eq 0 ]
  [ "$output" = 'example.com|example.com *.example.com api.example.net *.api.example.net service.other.org *.service.other.org' ]
}

@test "mixed wildcard inputs deduplicate explicit and derived identities" {
  run bash -c '
    source lib/config.bash
    source lib/identity.bash
    certbotbot_config_resolve --s3-bucket bucket --san "*.api.other.org" \\
      --san api.other.org --san EXAMPLE.COM --domain example.com || exit $?
    certbotbot_identity_resolve || exit $?
    printf "%s" "${CERTBOTBOT_SANS[*]}"
  '
  [ "$status" -eq 0 ]
  [ "$output" = 'example.com *.example.com *.api.other.org api.other.org' ]
}

@test "INCLUDE_SUBDOMAINS=false retains only explicit distinct names" {
  run bash -c '
    source lib/config.bash
    source lib/identity.bash
    certbotbot_config_resolve --s3-bucket bucket --include-subdomains=false \\
      --san "*.api.other.org" --san example.com example.com || exit $?
    certbotbot_identity_resolve || exit $?
    printf "%s" "${CERTBOTBOT_SANS[*]}"
  '
  [ "$status" -eq 0 ]
  [ "$output" = 'example.com *.api.other.org' ]
}

@test "CLI additional SANs replace exported and literal file collections" {
  printf 'DOMAIN=example.com\nS3_BUCKET=bucket\nADDITIONAL_SANS=file.example.net\n' >"$TEST_CONFIG_DIR/extras"
  run bash -c '
    source lib/config.bash
    source lib/identity.bash
    ADDITIONAL_SANS=env.example.net; export ADDITIONAL_SANS
    certbotbot_config_resolve --config "$1" --san cli.example.org || exit $?
    certbotbot_identity_resolve || exit $?
    printf "%s" "${CERTBOTBOT_SANS[*]}"
  ' _ "$TEST_CONFIG_DIR/extras"
  [ "$status" -eq 0 ]
  [ "$output" = 'example.com *.example.com cli.example.org *.cli.example.org' ]
}

@test "exported empty additional list masks file extras" {
  printf 'DOMAIN=example.com\nS3_BUCKET=bucket\nADDITIONAL_SANS=file.example.net\n' >"$TEST_CONFIG_DIR/extras"
  run bash -c '
    source lib/config.bash
    source lib/identity.bash
    ADDITIONAL_SANS=""; export ADDITIONAL_SANS
    certbotbot_config_resolve --config "$1" || exit $?
    certbotbot_identity_resolve || exit $?
    printf "%s" "${CERTBOTBOT_SANS[*]}"
  ' _ "$TEST_CONFIG_DIR/extras"
  [ "$status" -eq 0 ]
  [ "$output" = 'example.com *.example.com' ]
}

@test "literal additional list parses comma-delimited unrelated zones" {
  printf 'DOMAIN=example.com\nS3_BUCKET=bucket\nADDITIONAL_SANS=first.net,*.second.org\n' >"$TEST_CONFIG_DIR/extras"
  run bash -c '
    source lib/config.bash
    source lib/identity.bash
    certbotbot_config_resolve --config "$1" || exit $?
    certbotbot_identity_resolve || exit $?
    printf "%s" "${CERTBOTBOT_SANS[*]}"
  ' _ "$TEST_CONFIG_DIR/extras"
  [ "$status" -eq 0 ]
  [ "$output" = 'example.com *.example.com first.net *.first.net *.second.org second.org' ]
}

@test "malformed extra SAN list and invalid primary fail before AWS calls" {
  printf 'DOMAIN=example.com\nS3_BUCKET=bucket\nADDITIONAL_SANS=a.net,,b.org\n' >"$TEST_CONFIG_DIR/extras"
  run "${BASH_STARTER_ARTIFACT}" --config "$TEST_CONFIG_DIR/extras"
  [ "$status" -eq 64 ]
  run "${BASH_STARTER_ARTIFACT}" --s3-bucket bucket --san 'bad,other.net' example.com
  [ "$status" -eq 64 ]
  run "${BASH_STARTER_ARTIFACT}" --s3-bucket bucket --san 'evil;true' example.com
  [ "$status" -eq 64 ]
}

@test "input cap and expanded set cap reject oversized SAN requests" {
  run bash -c '
    source lib/config.bash
    source lib/identity.bash
    args=(--s3-bucket bucket --domain example.com)
    for (( i=1; i<=50; i++ )); do args+=(--san "dns$i.example.org"); done
    certbotbot_config_resolve "${args[@]}" || exit $?
    certbotbot_identity_resolve
  '
  [ "$status" -eq 64 ]
  run bash -c '
    source lib/config.bash
    args=(--s3-bucket bucket --domain example.com)
    for (( i=1; i<=100; i++ )); do args+=(--san "dns$i.example.org"); done
    certbotbot_config_resolve "${args[@]}"
  '
  [ "$status" -eq 64 ]
}
