#!/usr/bin/env bats

setup() {
  : "${BASH_STARTER_ARTIFACT:?Artifact under test is required}"
  WORKDIR="$(mktemp -d)"
  mkdir -m 700 "$WORKDIR/bin"
  # Public argument rejection must not get as far as cloud mutation.
  cat >"$WORKDIR/bin/aws" <<'MOCK'
#!/usr/bin/env bash
printf 'AWS_INVOKED\n' >>"$AWS_CALLS"
exit 90
MOCK
  chmod 755 "$WORKDIR/bin/aws"
  export AWS_CALLS="$WORKDIR/aws-calls"
  export PATH="$WORKDIR/bin:$PATH"
}

teardown() {
  rm -rf -- "$WORKDIR"
}

@test "every standalone artifact contains the published mktext library" {
  run bash -c '
    source "$BASH_STARTER_ARTIFACT" --help >/dev/null || exit $?
    declare -F mktext >/dev/null || exit 96
    mktext --version
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"mktext 0.0.17"* ]]
}

@test "legacy literal S3 key preserves braces and does not read the clock" {
  run bash -c '
    source "$BASH_STARTER_ARTIFACT" --help >/dev/null || exit $?
    date() { exit 94; }
    certbotbot_config_resolve --s3-bucket bucket --s3-key "literal-{YEAR}.txt" example.com || exit $?
    certbotbot_filename_resolve || exit $?
    printf "%s|%s" "$CERTBOTBOT_S3_KEY" "$CERTBOTBOT_BACKUP_KEY"
  '
  [ "$status" -eq 0 ]
  [ "$output" = 'literal-{YEAR}.txt|' ]
}

@test "current and backup templates use the same frozen UTC calendar date" {
  run bash -c '
    source "$BASH_STARTER_ARTIFACT" --help >/dev/null || exit $?
    date() { printf "20261020\n"; }
    certbotbot_config_resolve --s3-bucket bucket \
      --s3-key-template "current-{YEAR}-{MONTH}-{DOM}.tar.gz" \
      --backup-key-template "archive-{YEAR}{MONTH}{DOM}.tar.gz" example.com || exit $?
    certbotbot_filename_resolve || exit $?
    printf "%s|%s|%s" "$CERTBOTBOT_S3_KEY" \
      "$CERTBOTBOT_BACKUP_KEY" "$CERTBOTBOT_FILENAME_DATE"
  '
  [ "$status" -eq 0 ]
  [ "$output" = 'current-2026-10-20.tar.gz|archive-20261020.tar.gz|20261020' ]
}

@test "CLI literal overrides a lower-precedence environment template" {
  run bash -c '
    source "$BASH_STARTER_ARTIFACT" --help >/dev/null || exit $?
    export S3_KEY_TEMPLATE="old-{YEAR}.tar.gz"
    certbotbot_config_resolve --s3-bucket bucket --s3-key custom.tar.gz example.com || exit $?
    certbotbot_filename_resolve || exit $?
    printf "%s|%s" "$CERTBOTBOT_S3_KEY" "$CERTBOTBOT_S3_KEY_IS_TEMPLATE"
  '
  [ "$status" -eq 0 ]
  [ "$output" = 'custom.tar.gz|false' ]
}

@test "CLI template overrides a lower-precedence environment literal key" {
  run bash -c '
    source "$BASH_STARTER_ARTIFACT" --help >/dev/null || exit $?
    export S3_KEY=old.tar.gz
    date() { printf "20260102\n"; }
    certbotbot_config_resolve --s3-bucket bucket \
      --s3-key-template "current-{YEAR}{MONTH}{DOM}.tar.gz" example.com || exit $?
    certbotbot_filename_resolve || exit $?
    printf "%s" "$CERTBOTBOT_S3_KEY"
  '
  [ "$status" -eq 0 ]
  [ "$output" = current-20260102.tar.gz ]
}

@test "literal and template at the same source tier are rejected before AWS" {
  run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket \
    --s3-key "literal.tar.gz" --s3-key-template "current-{YEAR}.tar.gz" example.com
  [ "$status" -eq 64 ]
  [ ! -e "$AWS_CALLS" ]
}

@test "unresolved macros and shell-like names fail before AWS" {
  local template
  for template in 'bad-{UNKNOWN}.tar.gz' 'bad-$(touch x).tar.gz' \
    'bad-{ year }.tar.gz' '../archive.tar.gz' 'name/{YEAR}.tar.gz' \
    'archive-{YEAR}.zip' 'archive-{{YEAR}}.tar.gz'; do
    run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket \
      --s3-key-template "$template" example.com
    [ "$status" -eq 64 ]
    [ ! -e "$AWS_CALLS" ]
  done
}

@test "colliding current and backup key templates are refused before AWS" {
  run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket \
    --s3-key-template 'archive-{YEAR}{MONTH}{DOM}.tar.gz' \
    --backup-key-template 'archive-{YEAR}{MONTH}{DOM}.tar.gz' example.com
  [ "$status" -eq 64 ]
  [ ! -e "$AWS_CALLS" ]
}

@test "invalid clock snapshot is refused before AWS" {
  run bash -c '
    source "$BASH_STARTER_ARTIFACT" --help >/dev/null || exit $?
    date() { printf "20260230\n"; }
    certbotbot_config_resolve --s3-bucket bucket \
      --s3-key-template "current-{YEAR}.tar.gz" example.com || exit $?
    certbotbot_filename_resolve
  '
  [ "$status" -eq 64 ]
  [ ! -e "$AWS_CALLS" ]
}
