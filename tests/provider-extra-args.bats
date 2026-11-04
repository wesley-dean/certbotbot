#!/usr/bin/env bats

setup() {
  : "${BASH_STARTER_ARTIFACT:?Built producer under test is required}"
  EXTRA_TEST_DIR="$(mktemp -d)" || return 1
}

teardown() {
  rm -rf -- "$EXTRA_TEST_DIR"
}

@test "provider JSON collections resolve with CLI-over-environment replacement" {
  run bash -c '
    source "$1" --help >/dev/null || exit $?
    export AWS_EXTRA_ARGS="$2"
    certbotbot_config_resolve --s3-bucket bucket --aws-args "$3" example.com || exit $?
    printf "%s|" "${CERTBOTBOT_AWS_ARGS[@]}"
  ' _ "$BASH_STARTER_ARTIFACT" '["--cli-read-timeout","20"]' \
    '["--cli-connect-timeout","30","--cli-read-timeout","40"]'
  [ "$status" -eq 0 ]
  [ "$output" = '--cli-connect-timeout|30|--cli-read-timeout|40|' ]
}

@test "explicit empty argv collection replaces nonempty environment values" {
  run bash -c '
    source "$1" --help >/dev/null || exit $?
    export AWS_EXTRA_ARGS="$2"
    certbotbot_config_resolve --s3-bucket bucket --aws-args "[]" example.com || exit $?
    printf "%s" "${#CERTBOTBOT_AWS_ARGS[@]}"
  ' _ "$BASH_STARTER_ARTIFACT" '["--cli-read-timeout","20"]'
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]
}

@test "provider argument vectors preserve the original permitted token order" {
  run bash -c '
    source "$1" --help >/dev/null || exit $?
    certbotbot_config_resolve --s3-bucket bucket \
      --certbot-args "$2" --gpg-args "$3" example.com || exit $?
    printf "global=%s|challenge=%s|gpg=%s|original=%s" \
      "${CERTBOTBOT_CERTBOT_GLOBAL_ARGS[*]}" \
      "${CERTBOTBOT_CERTBOT_CHALLENGE_ARGS[*]}" \
      "${CERTBOTBOT_GPG_ARGS[*]}" \
      "${CERTBOTBOT_CERTBOT_ARGS[*]}"
  ' _ "$BASH_STARTER_ARTIFACT" \
    '["--max-log-backups","9","--dns-route53-propagation-seconds","30","--max-log-backups","10"]' \
    '["--compress-level","0"]'
  [ "$status" -eq 0 ]
  [ "$output" = 'global=--max-log-backups 9 --max-log-backups 10|challenge=--dns-route53-propagation-seconds 30|gpg=--compress-level 0|original=--max-log-backups 9 --dns-route53-propagation-seconds 30 --max-log-backups 10' ]
}

@test "JSON argv retains spaces and literal quotes for approved Certbot comments" {
  run bash -c '
    source "$1" --help >/dev/null || exit $?
    certbotbot_config_resolve --s3-bucket bucket \
      --certbot-args "$2" example.com || exit $?
    printf "%s" "${CERTBOTBOT_CERTBOT_GLOBAL_ARGS[1]}"
  ' _ "$BASH_STARTER_ARTIFACT" '["--user-agent-comment","QA Team \"nightly\""]'
  [ "$status" -eq 0 ]
  [ "$output" = 'QA Team "nightly"' ]

  run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket \
    --certbot-args '["--user-agent-comment","secret;bad"]' example.com
  [ "$status" -eq 64 ]
  [[ "$output" != *secret* ]]
}

@test "malformed and unauthorized provider args fail before external effects" {
  local json
  for json in \
    'broken-json' \
    '{"not":"an array"}' \
    '["--endpoint-url","https://outside.invalid"]' \
    '["--cli-read-timeout","0"]' \
    '["--cli-read-timeout"]' \
    '["--cli-read-timeout","30;touch /tmp/never-run"]' \
    '["--cli-read-timeout","30",null]'; do
    run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket \
      --aws-args "$json" example.com
    [ "$status" -eq 64 ]
    [[ "$output" != *outside.invalid* && "$output" != *never-run* ]]
  done
}

@test "unsafe Certbot and GPG control options are rejected" {
  run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket \
    --certbot-args '["--server","https://outside.invalid"]' example.com
  [ "$status" -eq 64 ]
  [[ "$output" != *outside.invalid* ]]

  run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket \
    --gpg-args '["--passphrase","do-not-log"]' example.com
  [ "$status" -eq 64 ]
  [[ "$output" != *do-not-log* ]]

  run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket \
    --gpg-args '["--no-compress","--compress-level","9"]' example.com
  [ "$status" -eq 64 ]
}

@test "explicit register rejects issuance-specific Certbot overrides" {
  run "$BASH_STARTER_ARTIFACT" register --email ops@example.com \
    --agree-tos true --s3-bucket bucket \
    --certbot-args '["--dns-route53-propagation-seconds","30"]'
  [ "$status" -eq 64 ]
}

@test "no-env ignores a malformed discovered file and application environment" {
  printf 'BAD_KEY=forbidden\n' >"$EXTRA_TEST_DIR/.env"
  run bash -c '
    source "$1" --help >/dev/null || exit $?
    cd "$2" || exit $?
    export S3_BUCKET=ambient-bucket DOMAIN=ambient.example \
      INCLUDE_SUBDOMAINS=false AWS_EXTRA_ARGS=malformed-json
    certbotbot_config_resolve --no-env --s3-bucket cli-bucket \
      --include-subdomains true example.com || exit $?
    printf "%s|%s|%s|%s" "$CERTBOTBOT_DOMAIN" "$CERTBOTBOT_S3_BUCKET" \
      "$CERTBOTBOT_INCLUDE_SUBDOMAINS" "${#CERTBOTBOT_AWS_ARGS[@]}"
  ' _ "$BASH_STARTER_ARTIFACT" "$EXTRA_TEST_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = 'example.com|cli-bucket|true|0' ]
}

@test "no-env refuses explicit config and cannot accept a GPG env secret" {
  run "$BASH_STARTER_ARTIFACT" --no-env --config "$EXTRA_TEST_DIR/missing" \
    --s3-bucket bucket example.com
  [ "$status" -eq 64 ]

  run env GPG_SYMMETRIC_KEY=private-test-sentinel \
    ARCHIVE_ENCRYPTION=gpg-ocb "$BASH_STARTER_ARTIFACT" \
    --no-env --archive-encryption gpg-ocb --s3-bucket bucket example.com
  [ "$status" -eq 64 ]
  [[ "$output" != *private-test-sentinel* ]]
}

@test "no-env applies to explicit registration without removing AWS credentials" {
  printf 'BAD_KEY=forbidden\n' >"$EXTRA_TEST_DIR/.env"
  run bash -c '
    source "$1" --help >/dev/null || exit $?
    cd "$2" || exit $?
    export EMAIL=wrong@example.org AGREE_TOS=false S3_BUCKET=ambient \
      AWS_ACCESS_KEY_ID=synthetic-key
    CERTBOTBOT_COMMAND=register
    CERTBOTBOT_GPG_SECRET=""
    certbotbot_register_config --no-env --email ops@example.org \
      --agree-tos true --s3-bucket fixture-bucket || exit $?
    printf "%s|%s|%s|%s" "$CERTBOTBOT_EMAIL" "$CERTBOTBOT_AGREE_TOS" \
      "$CERTBOTBOT_S3_BUCKET" "$AWS_ACCESS_KEY_ID"
  ' _ "$BASH_STARTER_ARTIFACT" "$EXTRA_TEST_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = 'ops@example.org|true|fixture-bucket|synthetic-key' ]
}

@test "AWS option forwarding reaches only the AWS command before the subcommand" {
  run bash -c '
    source "$1" --help >/dev/null || exit $?
    certbotbot_config_resolve --s3-bucket fixture-bucket \
      --aws-args "$3" example.com || exit $?
    LOGFILE="$2"
    aws() {
      printf "%s\n" "$*" >>"$LOGFILE"
      return 1
    }
    workspace="$(umask 077; mktemp -d)" || exit $?
    certbotbot_s3_fetch "$workspace" fixture-bucket latest.tar.gz \
      >/dev/null 2>&1 || :
    rm -rf -- "$workspace"
    grep -F -- "--no-cli-pager --cli-read-timeout 42 s3api head-object" "$2" \
      >/dev/null || exit $?
    printf forwarded
  ' _ "$BASH_STARTER_ARTIFACT" "$EXTRA_TEST_DIR/aws.log" \
    '["--cli-read-timeout","42"]'
  [ "$status" -eq 0 ]
  [ "$output" = forwarded ]
}

@test "GnuPG safe extra argv is forwarded only to encryption" {
  run bash -c '
    source "$1" --help >/dev/null || exit $?
    certbotbot_config_resolve --s3-bucket bucket \
      --gpg-args "$2" example.com || exit $?
    CERTBOTBOT_GPG_SECRET=fixture
    LOGFILE="$3/gpg.log"
    mkdir -m 700 "$3/private" || exit $?
    printf "input" >"$3/private/plaintext"
    gpg() {
      printf "%s\n" "$*" >>"$LOGFILE"
      local previous="" item
      for item in "$@"; do
        if [[ "$previous" == --output ]]; then
          printf "mock-packet" >"$item"
        fi
        previous="$item"
      done
      return 0
    }
    certbotbot_crypto_packet_valid() { return 0; }
    certbotbot_crypto_encrypt_packet "$3/private" \
      "$3/private/plaintext" "$3/private/encrypted" || exit $?
    certbotbot_crypto_decrypt_packet "$3/private" \
      "$3/private/encrypted" "$3/private/restored" || exit $?
    mapfile -t calls <"$LOGFILE"
    [[ ${#calls[@]} -eq 2 &&
       "${calls[0]}" == *--compress-level\ 3* &&
       "${calls[0]}" == *--symmetric* &&
       "${calls[1]}" == *--decrypt* &&
       "${calls[1]}" != *--compress-level* ]] || exit 1
    printf verified
  ' _ "$BASH_STARTER_ARTIFACT" '["--compress-level","3"]' "$EXTRA_TEST_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = verified ]
}

@test "Certbot extra args reach only compatible simulated subcommands" {
  run bash -c '
    source "$1" --help >/dev/null || exit $?
    certbotbot_config_resolve --s3-bucket bucket \
      --certbot-args "$2" example.com || exit $?
    local_root="$3/fixture"
    mkdir -m 700 "$local_root" || exit $?
    mkdir -p "$local_root/config/accounts/acme-v02.api.letsencrypt.org/directory/localacct" || exit $?
    CERTBOTBOT_CA_HOST=acme-v02.api.letsencrypt.org
    CERTBOTBOT_CA_SERVER=https://acme-v02.api.letsencrypt.org/directory
    certbotbot_dns_valid() { return 0; }
    certbotbot_provider_sans() { return 0; }
    certbotbot_state_preflight() {
      CERTBOTBOT_LINEAGE_STATE=absent
      return 0
    }
    certbotbot_state_canonical_all() { return 0; }
    CERTBOT_LOG="$3/certbot.log"
    export CERTBOT_LOG
    cat >"$3/certbot" <<EOF
#!/usr/bin/env bash
printf "%s\\n" "\\$*" >> "\\$CERTBOT_LOG"
if [[ "\\$1" == plugins ]]; then printf "  * dns-route53\\n"; fi
exit 0
EOF
    chmod 700 "$3/certbot" || exit $?
    PATH="$3:$PATH"
    export PATH
    certbotbot_provider_issue "$local_root" example.com example.com || exit $?
    [[ "$(grep -Fc -- "--dns-route53-propagation-seconds 27" "$CERTBOT_LOG")" -eq 1 ]] || exit 1
    grep -Eq "certonly .*--max-log-backups 11 --dns-route53-propagation-seconds 27 -d example.com" \
      "$CERTBOT_LOG" || exit $?
    [[ "$(grep -Fc -- "--max-log-backups 11" "$CERTBOT_LOG")" -eq 3 ]] || exit 1
    printf verified
  ' _ "$BASH_STARTER_ARTIFACT" \
    '["--max-log-backups","11","--dns-route53-propagation-seconds","27"]' \
    "$EXTRA_TEST_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = verified ]
}
