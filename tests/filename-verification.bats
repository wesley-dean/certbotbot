#!/usr/bin/env bats

# Executed by make test-report against every standalone artifact flavor.
setup() {
  : "${BASH_STARTER_ARTIFACT:?Artifact under test is required}"
  ROOT="$(mktemp -d)"
  mkdir -m 700 "$ROOT/bin"
  cat >"$ROOT/bin/aws" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == --no-cli-pager && "$2" == s3api ]] || exit 99
action="$3"
shift 3
bucket='' key=''
while (( $# )); do
  case "$1" in
    --bucket) bucket="$2"; shift 2 ;;
    --key) key="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s|%s|%s\n' "$action" "$bucket" "$key" >>"$FILENAME_AWS_CALLS"
exit 9
MOCK
  chmod 755 "$ROOT/bin/aws"
  export FILENAME_AWS_CALLS="$ROOT/aws-calls"
  export PATH="$ROOT/bin:$PATH"
  unset DOMAIN S3_KEY S3_KEY_TEMPLATE BACKUP_KEY_TEMPLATE S3_BUCKET
  unset ARCHIVE_ENCRYPTION ARCHIVE_MIGRATION GPG_SYMMETRIC_KEY
}

teardown() {
  rm -rf -- "$ROOT"
}

install_filename_clock() {
  export FILENAME_CLOCK_CALLS="$ROOT/date-calls"
  export FILENAME_CLOCK_FIRST=20261020
  export FILENAME_CLOCK_NEXT=20261021
  cat >"$ROOT/bin/date" <<'MOCK'
#!/usr/bin/env bash
[[ "$#" == 2 && "$1" == -u && "$2" == +%Y%m%d ]] || exit 95
if [[ -s "$FILENAME_CLOCK_CALLS" ]]; then
  printf '%s\n' "$FILENAME_CLOCK_NEXT"
else
  printf '%s\n' "$FILENAME_CLOCK_FIRST"
fi
printf 'date-read\n' >>"$FILENAME_CLOCK_CALLS"
MOCK
  chmod 755 "$ROOT/bin/date"
}

assert_zero_aws() {
  [ ! -e "$FILENAME_AWS_CALLS" ]
}

@test "default current archive key remains latest.tar.gz without a clock read" {
  install_filename_clock
  run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket example.com
  [ "$status" -eq 69 ]
  grep -Fxq 'head-object|bucket|latest.tar.gz' "$FILENAME_AWS_CALLS"
  [ "$(wc -l <"$FILENAME_AWS_CALLS")" -eq 1 ]
  [ ! -e "$FILENAME_CLOCK_CALLS" ]
}

@test "legacy literal S3 key retains braces and unusual suffix exactly" {
  install_filename_clock
  run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket \
    --s3-key 'literal-{YEAR}-{MISSING}.txt' example.com
  [ "$status" -eq 69 ]
  grep -Fxq 'head-object|bucket|literal-{YEAR}-{MISSING}.txt' "$FILENAME_AWS_CALLS"
  [ ! -e "$FILENAME_CLOCK_CALLS" ]
}

@test "current filename template uses the single frozen UTC date" {
  install_filename_clock
  run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket \
    --s3-key-template 'current-{YEAR}{MONTH}{DOM}.tar.gz' example.com
  [ "$status" -eq 69 ]
  grep -Fxq 'head-object|bucket|current-20261020.tar.gz' "$FILENAME_AWS_CALLS"
  [ "$(wc -l <"$FILENAME_CLOCK_CALLS")" -eq 1 ]
  [ "$(wc -l <"$FILENAME_AWS_CALLS")" -eq 1 ]
}

@test "explicit dated template does not authorize backup publication" {
  install_filename_clock
  run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket \
    --s3-key-template 'active-{YEAR}{MONTH}{DOM}.tar.gz' \
    --backup-key-template 'archive-{YEAR}{MONTH}{DOM}.tar.gz' example.com
  [ "$status" -eq 69 ]
  grep -Fxq 'head-object|bucket|active-20261020.tar.gz' "$FILENAME_AWS_CALLS"
  [ "$(wc -l <"$FILENAME_CLOCK_CALLS")" -eq 1 ]
  ! grep -q 'archive-20261020.tar.gz' "$FILENAME_AWS_CALLS"
  ! grep -q 'put-object' "$FILENAME_AWS_CALLS"
}

@test "file environment CLI and literal override choose their own current key" {
  install_filename_clock
  cat >"$ROOT/names.env" <<'FILE'
DOMAIN=example.com
S3_BUCKET=bucket
S3_KEY_TEMPLATE=file-{YEAR}.tar.gz
FILE
  run "$BASH_STARTER_ARTIFACT" --config "$ROOT/names.env"
  [ "$status" -eq 69 ]
  grep -Fxq 'head-object|bucket|file-2026.tar.gz' "$FILENAME_AWS_CALLS"
  : >"$FILENAME_AWS_CALLS"
  export S3_KEY_TEMPLATE='environment-{YEAR}.tar.gz'
  run "$BASH_STARTER_ARTIFACT" --config "$ROOT/names.env"
  [ "$status" -eq 69 ]
  grep -Fxq 'head-object|bucket|environment-2026.tar.gz' "$FILENAME_AWS_CALLS"
  : >"$FILENAME_AWS_CALLS"
  run "$BASH_STARTER_ARTIFACT" --config "$ROOT/names.env" \
    --s3-key-template 'cli-{YEAR}.tar.gz'
  [ "$status" -eq 69 ]
  grep -Fxq 'head-object|bucket|cli-2026.tar.gz' "$FILENAME_AWS_CALLS"
  : >"$FILENAME_AWS_CALLS"
  run "$BASH_STARTER_ARTIFACT" --config "$ROOT/names.env" \
    --s3-key literal-choice.tar.gz
  [ "$status" -eq 69 ]
  grep -Fxq 'head-object|bucket|literal-choice.tar.gz' "$FILENAME_AWS_CALLS"
  [ "$(wc -l <"$FILENAME_AWS_CALLS")" -eq 1 ]
}

@test "CLI current template masks a lower precedence literal" {
  install_filename_clock
  printf 'S3_KEY=file-literal.tar.gz\nS3_BUCKET=bucket\nDOMAIN=example.com\n' \
    >"$ROOT/names.env"
  run "$BASH_STARTER_ARTIFACT" --config "$ROOT/names.env" \
    --s3-key-template 'cli-{YEAR}.tar.gz'
  [ "$status" -eq 69 ]
  grep -Fxq 'head-object|bucket|cli-2026.tar.gz' "$FILENAME_AWS_CALLS"
}

@test "same-tier literal and template choices fail before AWS" {
  install_filename_clock
  cat >"$ROOT/names.env" <<'FILE'
DOMAIN=example.com
S3_BUCKET=bucket
S3_KEY=literal.tar.gz
S3_KEY_TEMPLATE=templated-{YEAR}.tar.gz
FILE
  run "$BASH_STARTER_ARTIFACT" --config "$ROOT/names.env"
  [ "$status" -eq 64 ]
  assert_zero_aws
  run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket \
    --s3-key literal.tar.gz --s3-key-template 'name-{YEAR}.tar.gz' example.com
  [ "$status" -eq 64 ]
  assert_zero_aws
}

@test "current and explicit backup key alias fails before any AWS call" {
  install_filename_clock
  run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket \
    --backup-key-template latest.tar.gz example.com
  [ "$status" -eq 64 ]
  assert_zero_aws
  # Reset the simulated UTC day before testing a second independent invocation.
  rm -f "$FILENAME_CLOCK_CALLS"
  run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket \
    --s3-key-template 'archive-{YEAR}{MONTH}{DOM}.tar.gz' \
    --backup-key-template archive-20261020.tar.gz example.com
  [ "$status" -eq 64 ]
  assert_zero_aws
}

@test "invalid macro syntax paths commands Unicode and unsupported formats fail closed" {
  install_filename_clock
  local template
  for template in 'archive-{year}.tar.gz' 'archive-{UNKNOWN}.tar.gz' \
    'archive-{ YEAR }.tar.gz' 'archive-${YEAR}.tar.gz' \
    'archive-{{YEAR}}.tar.gz' 'archive-{YEAR}{.tar.gz' \
    'archive-{YEAR}}.tar.gz' 'archive-$(touch unsafe).tar.gz' \
    'archive-`touch unsafe`.tar.gz' 'archive-%2f.tar.gz' \
    'archive-*.tar.gz' 'archive-{YEAR}.zip' \
    'archive-{YEAR}.tar.bz2' 'archive-é.tar.gz' \
    'folder/archive-{YEAR}.tar.gz' '..archive-{YEAR}.tar.gz' \
    '-archive-{YEAR}.tar.gz' 'archive-{YEAR}.tar.gz/' \
    'archive-{YEAR}.tar.gz.' 'archive-{YEAR}..tar.gz'; do
    run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket \
      --s3-key-template "$template" example.com
    [ "$status" -eq 64 ]
    assert_zero_aws
  done
  [ ! -e "$ROOT/unsafe" ]
}

@test "unsafe backup template is rejected before authoritative read" {
  install_filename_clock
  run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket \
    --backup-key-template 'unsafe/backup-{YEAR}.tar.gz' example.com
  [ "$status" -eq 64 ]
  assert_zero_aws
}

@test "255-byte templated key is permitted but 256-byte key is refused" {
  local valid invalid
  printf -v valid '%0248d' 0
  printf -v invalid '%0249d' 0
  run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket \
    --s3-key-template "$valid.tar.gz" example.com
  [ "$status" -eq 69 ]
  grep -Fxq "head-object|bucket|$valid.tar.gz" "$FILENAME_AWS_CALLS"
  rm -f "$FILENAME_AWS_CALLS"
  run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket \
    --s3-key-template "$invalid.tar.gz" example.com
  [ "$status" -eq 64 ]
  assert_zero_aws
}

@test "malformed UTC samples and impossible calendar days fail before AWS" {
  local sample
  for sample in 20261301 20260001 20260431 20260229 20261000 \
    00001020 abcd1020 2026102; do
    run env FILENAME_DATE_SAMPLE="$sample" bash -c '
      source "$BASH_STARTER_ARTIFACT" --help >/dev/null || exit $?
      date() { printf "%s\n" "$FILENAME_DATE_SAMPLE"; }
      certbotbot_config_resolve --s3-bucket bucket \
        --s3-key-template "archive-{YEAR}{MONTH}{DOM}.tar.gz" example.com || exit $?
      certbotbot_filename_resolve
    '
    [ "$status" -eq 64 ]
    assert_zero_aws
  done
}

@test "a valid leap day keeps the correct zero-padded date context" {
  run bash -c '
    source "$BASH_STARTER_ARTIFACT" --help >/dev/null || exit $?
    date() { printf "20240229\n"; }
    certbotbot_config_resolve --s3-bucket bucket \
      --s3-key-template "archive-{YEAR}{MONTH}{DOM}.tar.gz" example.com || exit $?
    certbotbot_filename_resolve || exit $?
    printf "%s|%s\n" "$CERTBOTBOT_S3_KEY" "$CERTBOTBOT_FILENAME_DATE"
  '
  [ "$status" -eq 0 ]
  [ "$output" = 'archive-20240229.tar.gz|20240229' ]
  assert_zero_aws
}
