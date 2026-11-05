#!/usr/bin/env bats

## @file tests/jenkins-example.bats
## @brief Tests Jenkins' actual inline Bash with isolated mock dependencies.
## @details
## The named blocks are extracted from the maintained Jenkinsfile rather
## than copied into tests. No cloud, ACME, Jenkins or real certificate action
## is performed; the command under test is an isolated fake producer.

setup() {
  ROOT="$(mktemp -d)" || return 1
  export WORKSPACE="$ROOT/work" MOCK_ARGS="$ROOT/argv"
  export MOCK_ENV="$ROOT/environment" MOCK_EXIT=0
  mkdir -p "$WORKSPACE/.certbotbot-example" "$ROOT/bin"
  export PATH="$ROOT/bin:$PATH"
  cat >"$ROOT/bin/aws" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == --version ]] || exit 93
printf 'aws-cli/2.20.0\n'
MOCK
  cat >"$ROOT/bin/certbot" <<'MOCK'
#!/usr/bin/env bash
exit 96
MOCK
  cat >"$WORKSPACE/.certbotbot-example/certbotbot.bash" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$MOCK_ARGS"
printf 'DOMAIN=%s\nGPG_PRESENT=%s\n' "${DOMAIN-unset}" \
  "${GPG_SYMMETRIC_KEY+yes}" >"$MOCK_ENV"
exit "$MOCK_EXIT"
MOCK
  chmod 700 "$ROOT/bin/aws" "$ROOT/bin/certbot" \
    "$WORKSPACE/.certbotbot-example/certbotbot.bash"
  extract VALIDATE "$ROOT/validate.bash" || return 1
  extract INVOKE "$ROOT/invoke.bash" || return 1

  export CONFIRM_RUN=true DOMAIN=app.example.net
  export CERTBOTBOT_RELEASE_TAG=v1.2.3
  export CERTBOTBOT_RELEASE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export CERTBOTBOT_REVIEWED_CONFIG_FILE=/etc/certbotbot/jenkins.env
  export ADDITIONAL_SANS='' CERT_NAME='' INCLUDE_SUBDOMAINS=true
  export ACME_ENVIRONMENT=staging S3_BUCKET=example-bucket
  export CURRENT_KEY_MODE=literal S3_KEY=latest.tar.gz S3_KEY_TEMPLATE=''
  export BACKUP_KEY_TEMPLATE='archive-{YEAR}{MONTH}{DOM}.tar.gz'
  export DATED_BACKUP_ENABLED=false BACKUP_RETENTION_COUNT=0
  export UPLOAD_NO_RENEWAL=false RENEW_ALL=false REMOVE_ORPHANS=false
  export DESIRED_CERT_NAMES='' ARCHIVE_ENCRYPTION=none
  export ARCHIVE_MIGRATION=none ARCHIVE_MIGRATION_BACKUP_CONFIRMED=false
  export CONFIG_MODE=none AWS_EXTRA_ARGS='[]' GPG_EXTRA_ARGS='[]'
  export CERTBOT_EXTRA_ARGS='[]'
  unset GPG_SYMMETRIC_KEY
}

teardown() { rm -rf -- "$ROOT"; }

extract() {
  local name="$1" destination="$2"
  # Groovy triple-single strings are non-interpolating, but do decode
  # backslash escapes. Undo the single layer added for Groovy before
  # Bash parsing and executing the exact shell body Jenkins receives.
  awk -v begin="# BEGIN CERTBOTBOT_JENKINS_$name" \
    -v end="# END CERTBOTBOT_JENKINS_$name" '
    $0 == begin { on=1; found=1; next }
    $0 == end { complete=1; exit }
    on { print }
    END { if (!found || !complete) exit 1 }
  ' "$BATS_TEST_DIRNAME/../doc/examples/Jenkinsfile" |
    sed 's/\\\\/\\/g' >"$destination" || return 1
  [[ -s "$destination" ]]
}

@test "both extracted maintained Jenkins Bash bodies parse" {
  run bash -n "$ROOT/validate.bash"
  [ "$status" -eq 0 ]
  run bash -n "$ROOT/invoke.bash"
  [ "$status" -eq 0 ]
}

@test "explicit manual authorization blocks even local release retrieval" {
  export CONFIRM_RUN=false
  run bash "$ROOT/validate.bash"
  [ "$status" -eq 64 ]
  [[ "$output" == *'run confirmation'* ]]
  [ ! -e "$MOCK_ARGS" ]
}

@test "default safe settings validate without touching remote dependencies" {
  run bash "$ROOT/validate.bash"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_ARGS" ]
}

@test "ordinary invocation emits supported CLI not registration or a key" {
  run bash "$ROOT/invoke.bash"
  [ "$status" -eq 0 ]
  grep -Fxq -- '--domain' "$MOCK_ARGS"
  grep -Fxq -- '--remove-orphans' "$MOCK_ARGS"
  grep -Fxq -- '--s3-key' "$MOCK_ARGS"
  ! grep -Fxq -- 'register' "$MOCK_ARGS"
  grep -Fxq -- 'GPG_PRESENT=' "$MOCK_ENV"
}

@test "multiple SANs and provider JSON with quoted spaces stay single argv" {
  export ADDITIONAL_SANS='api.example.net,service.other.net'
  export AWS_EXTRA_ARGS='["--cli-read-timeout","45"]'
  export CERTBOT_EXTRA_ARGS='["--user-agent-comment","QA Team \"nightly\""]'
  run bash "$ROOT/validate.bash"
  [ "$status" -eq 0 ]
  run bash "$ROOT/invoke.bash"
  [ "$status" -eq 0 ]
  [ "$(grep -Fxc -- '--san' "$MOCK_ARGS")" -eq 2 ]
  grep -Fxq -- 'api.example.net' "$MOCK_ARGS"
  grep -Fxq -- 'service.other.net' "$MOCK_ARGS"
  grep -Fxq -- "$CERTBOT_EXTRA_ARGS" "$MOCK_ARGS"
  grep -Fxq -- "$AWS_EXTRA_ARGS" "$MOCK_ARGS"
}

@test "unsafe or duplicated desired membership fails before a provider" {
  export REMOVE_ORPHANS=true CERT_NAME=app.example.net
  export DESIRED_CERT_NAMES='app.example.net,app.example.net'
  run bash "$ROOT/validate.bash"
  [ "$status" -eq 64 ]
  [[ "$output" == *'duplicate desired lineage'* ]]
  export DESIRED_CERT_NAMES=other.example.net
  run bash "$ROOT/validate.bash"
  [ "$status" -eq 64 ]
  [[ "$output" == *'selected lineage absent'* ]]
  [ ! -e "$MOCK_ARGS" ]
}

@test "explicit safe desired membership reaches only literal repeated argv" {
  export REMOVE_ORPHANS=true CERT_NAME=app.example.net
  export DESIRED_CERT_NAMES='other.example.net,app.example.net'
  run bash "$ROOT/validate.bash"
  [ "$status" -eq 0 ]
  run bash "$ROOT/invoke.bash"
  [ "$status" -eq 0 ]
  [ "$(grep -Fxc -- '--desired-cert-name' "$MOCK_ARGS")" -eq 2 ]
  grep -Fxq -- 'other.example.net' "$MOCK_ARGS"
}

@test "bulk and destructive modes cannot be enabled together" {
  export RENEW_ALL=true REMOVE_ORPHANS=true
  run bash "$ROOT/validate.bash"
  [ "$status" -eq 64 ]
  [[ "$output" == *'conflicting bulk/destructive'* ]]
}

@test "domainless bulk deliberately unsets empty DOMAIN from environment" {
  export RENEW_ALL=true DOMAIN=''
  run bash "$ROOT/validate.bash"
  [ "$status" -eq 0 ]
  run bash "$ROOT/invoke.bash"
  [ "$status" -eq 0 ]
  ! grep -Fxq -- '--domain' "$MOCK_ARGS"
  grep -Fxq -- 'DOMAIN=unset' "$MOCK_ENV"
}

@test "frozen-date current key template overrides default literal key" {
  export CURRENT_KEY_MODE=template
  export S3_KEY_TEMPLATE='current-{YEAR}{MONTH}{DOM}.tar.gz'
  run bash "$ROOT/validate.bash"
  [ "$status" -eq 0 ]
  run bash "$ROOT/invoke.bash"
  [ "$status" -eq 0 ]
  grep -Fxq -- '--s3-key-template' "$MOCK_ARGS"
  ! grep -Fxq -- '--s3-key' "$MOCK_ARGS"
}

@test "malformed templates and unsafe provider options are rejected locally" {
  export CURRENT_KEY_MODE=template S3_KEY_TEMPLATE='../key.tar.gz'
  run bash "$ROOT/validate.bash"
  [ "$status" -eq 64 ]
  export CURRENT_KEY_MODE=literal S3_KEY_TEMPLATE='' AWS_EXTRA_ARGS='["--endpoint-url","https://other.invalid"]'
  run bash "$ROOT/validate.bash"
  [ "$status" -eq 64 ]
  export AWS_EXTRA_ARGS='["--cli-read-timeout","0"]'
  run bash "$ROOT/validate.bash"
  [ "$status" -eq 64 ]
  export AWS_EXTRA_ARGS='[]' GPG_EXTRA_ARGS='["--compress-level","2","--no-compress"]'
  run bash "$ROOT/validate.bash"
  [ "$status" -eq 64 ]
  [ ! -e "$MOCK_ARGS" ]
}

@test "no-env is explicit and cannot use bound GPG encryption" {
  export CONFIG_MODE=no-env
  run bash "$ROOT/validate.bash"
  [ "$status" -eq 0 ]
  run bash "$ROOT/invoke.bash"
  [ "$status" -eq 0 ]
  grep -Fxq -- '--no-env' "$MOCK_ARGS"
  export ARCHIVE_ENCRYPTION=gpg-ocb
  run bash "$ROOT/validate.bash"
  [ "$status" -eq 64 ]
}

@test "plaintext invocation discards inherited GPG secret" {
  export GPG_SYMMETRIC_KEY='fake-test-key'
  run bash "$ROOT/invoke.bash"
  [ "$status" -eq 0 ]
  grep -Fxq -- 'GPG_PRESENT=' "$MOCK_ENV"
  [[ "$output" != *'fake-test-key'* ]]
}

@test "migration requires encrypted selection and prior backup confirmation" {
  export ARCHIVE_MIGRATION=plaintext-to-gpg-ocb
  run bash "$ROOT/validate.bash"
  [ "$status" -eq 64 ]
  export ARCHIVE_ENCRYPTION=gpg-ocb
  run bash "$ROOT/validate.bash"
  [ "$status" -eq 64 ]
  export ARCHIVE_MIGRATION_BACKUP_CONFIRMED=true
  run bash "$ROOT/validate.bash"
  [ "$status" -eq 0 ]
}

@test "mocked producer nonzero status is propagated, not masked" {
  export MOCK_EXIT=74
  run bash "$ROOT/invoke.bash"
  [ "$status" -eq 74 ]
  [ -s "$MOCK_ARGS" ]
}
