#!/usr/bin/env bats

setup() {
  CASE_ROOT="$(mktemp -d)"
  mkdir -p "$CASE_ROOT/private" "$CASE_ROOT/bin"
  CLIENT="$CASE_ROOT/client.bash"
  {
    cat "$BATS_TEST_DIRNAME/../lib/client-config.bash"
    cat "$BATS_TEST_DIRNAME/../lib/filename.bash"
    # Test-only one-pass renderer. The released mktext is embedded at build
    # time by task #54; tests do not source vendor at runtime.
    cat <<'RENDERER'
mktext() {
  [[ "$1" == render ]] || return 1
  local -n ctx="$2"
  local value
  IFS= read -r value || :
  value="${value//\{YEAR\}/${ctx[YEAR]}}"
  value="${value//\{MONTH\}/${ctx[MONTH]}}"
  value="${value//\{DOM\}/${ctx[DOM]}}"
  printf '%s' "$value"
}
RENDERER
    cat "$BATS_TEST_DIRNAME/../lib/client-s3.bash"
    cat "$BATS_TEST_DIRNAME/../src/client.bash"
  } > "$CLIENT"
  chmod 0755 "$CLIENT"
  cat > "$CASE_ROOT/bin/aws" <<'AWS'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1-}" == --version ]]; then
  printf 'aws-cli/2.22.0 Python/3.12\n'
  exit 0
fi
[[ "${1-}" == --no-cli-pager && "${2-}" == s3api ]] || exit 91
op="$3"
printf '%s|%s\n' "$op" "$*" >> "$MOCK_CALLS"
case "$op" in
  head-object)
    case "${MOCK_S3_MODE:-success}" in
      absent|bucketmissing) printf 'An error occurred (404) when calling HeadObject\n' >&2; exit 254 ;;
      denied) printf 'An error occurred (403) SENSITIVE_TOKEN\n' >&2; exit 254 ;;
      transport) printf 'TLS failed SENSITIVE_TOKEN\n' >&2; exit 255 ;;
    esac
    ;;
  head-bucket)
    [[ "${MOCK_S3_MODE:-success}" == absent ]] || exit 254
    ;;
  get-object)
    case "${MOCK_S3_MODE:-success}" in
      getdenied) printf 'AccessDenied SENSITIVE_TOKEN\n' >&2; exit 254 ;;
      empty) : > "${@: -1}" ;;
      *) printf 'PRIVATE_KEY_SENTINEL' > "${@: -1}" ;;
    esac
    stat -c 'staged:%a:%u' "${@: -1}" >> "$MOCK_CALLS"
    ;;
  *) exit 99 ;;
esac
AWS
  chmod 0755 "$CASE_ROOT/bin/aws"
  cat > "$CASE_ROOT/bin/date" <<'DATE'
#!/usr/bin/env bash
[[ "$*" == '-u +%Y%m%d' ]] || exit 1
printf '20261024\n'
DATE
  chmod 0755 "$CASE_ROOT/bin/date"
}

teardown() {
  rm -rf -- "$CASE_ROOT"
}

invoke() {
  run env -u S3_BUCKET -u S3_KEY -u S3_KEY_TEMPLATE \
    PATH="$CASE_ROOT/bin:$PATH" MOCK_CALLS="$CASE_ROOT/aws.log" \
    MOCK_S3_MODE="${MOCK_S3_MODE:-success}" \
    bash "$CLIENT" --destination "$CASE_ROOT/private/certs" "$@"
}

@test "client source assembles as Bash with no runtime vendor, Certbot, or Route53" {
  run bash -n "$CLIENT"
  [ "$status" -eq 0 ]
  run env PATH="$CASE_ROOT/bin:$PATH" bash "$CLIENT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *'--destination'* ]]
  [ ! -e "$CASE_ROOT/aws.log" ]
}

@test "read-only success stages private bytes then fails closed until extraction exists" {
  invoke --s3-bucket fixture-bucket
  [ "$status" -eq 65 ]
  [[ "$output" != *PRIVATE_KEY_SENTINEL* ]]
  [[ "$output" != *SENSITIVE_TOKEN* ]]
  [ ! -e "$CASE_ROOT/private/certs" ]
  [ "$(find "$CASE_ROOT/private" -mindepth 1 | wc -l)" -eq 0 ]
  [ "$(grep -c '^head-object|' "$CASE_ROOT/aws.log")" -eq 1 ]
  [ "$(grep -c '^get-object|' "$CASE_ROOT/aws.log")" -eq 1 ]
  [ "$(grep -c '^staged:600:' "$CASE_ROOT/aws.log")" -eq 1 ]
  # Match operation records, not user-controlled paths: private staging
  # legitimately contains the name .certbotbot-client.* in GetObject args.
  ! grep -Ev '^(head-object|head-bucket|get-object)\||^staged:[0-7]{3,4}:[0-9]+
}

@test "missing object is 66 only after successful head-bucket corroboration" {
  MOCK_S3_MODE=absent invoke --s3-bucket fixture-bucket
  [ "$status" -eq 66 ]
  grep -q '^head-bucket|' "$CASE_ROOT/aws.log"
  ! grep -q '^get-object|' "$CASE_ROOT/aws.log"
  [ ! -e "$CASE_ROOT/private/certs" ]
}

@test "access denied and unknown bucket cannot be mistaken for missing object" {
  MOCK_S3_MODE=denied invoke --s3-bucket fixture-bucket
  [ "$status" -eq 69 ]
  [[ "$output" != *SENSITIVE_TOKEN* ]]
  rm -f "$CASE_ROOT/aws.log"
  MOCK_S3_MODE=bucketmissing invoke --s3-bucket fixture-bucket
  [ "$status" -eq 69 ]
}

@test "transport and GetObject authorization failures are remote uncertainty" {
  MOCK_S3_MODE=transport invoke --s3-bucket fixture-bucket
  [ "$status" -eq 69 ]
  rm -f "$CASE_ROOT/aws.log"
  MOCK_S3_MODE=getdenied invoke --s3-bucket fixture-bucket
  [ "$status" -eq 69 ]
  [[ "$output" != *SENSITIVE_TOKEN* ]]
  [ ! -e "$CASE_ROOT/private/certs" ]
}

@test "empty GetObject is a local staging failure without destination output" {
  MOCK_S3_MODE=empty invoke --s3-bucket fixture-bucket
  [ "$status" -eq 74 ]
  [ ! -e "$CASE_ROOT/private/certs" ]
}

@test "invalid or existing destination rejected before AWS invocation" {
  printf 'original\n' > "$CASE_ROOT/private/certs"
  invoke --s3-bucket fixture-bucket
  [ "$status" -eq 73 ]
  [ "$(cat "$CASE_ROOT/private/certs")" == original ]
  [ ! -e "$CASE_ROOT/aws.log" ]
  rm "$CASE_ROOT/private/certs"
  ln -s missing "$CASE_ROOT/private/certs"
  invoke --s3-bucket fixture-bucket
  [ "$status" -eq 73 ]
  [ -L "$CASE_ROOT/private/certs" ]
  [ ! -e "$CASE_ROOT/aws.log" ]
}

@test "unsafe writable parent rejected before AWS invocation" {
  chmod 0777 "$CASE_ROOT/private"
  invoke --s3-bucket fixture-bucket
  [ "$status" -eq 73 ]
  [ ! -e "$CASE_ROOT/aws.log" ]
}

@test "invalid CLI, duplicate options, missing bucket and conflicting keys reject" {
  invoke --s3-bucket fixture-bucket --s3-bucket duplicate
  [ "$status" -eq 64 ]
  invoke --s3-key a --s3-key-template b --s3-bucket fixture-bucket
  [ "$status" -eq 64 ]
  invoke --domain example.com --s3-bucket fixture-bucket
  [ "$status" -eq 64 ]
  invoke
  [ "$status" -eq 64 ]
  [ ! -e "$CASE_ROOT/aws.log" ]
}

@test "literal file values and CLI override file bucket and key" {
  printf 'S3_BUCKET=file-bucket\nS3_KEY=file.tar.gz\nDOMAIN=example.com\n' > "$CASE_ROOT/client.env"
  invoke --config "$CASE_ROOT/client.env" --s3-bucket cli-bucket --s3-key cli.tar.gz
  [ "$status" -eq 65 ]
  grep -Fq -- '--bucket cli-bucket --key cli.tar.gz' "$CASE_ROOT/aws.log"
  ! grep -Fq 'file-bucket' "$CASE_ROOT/aws.log"
}

@test "highest tier key masks lower template and selected template freezes one UTC date" {
  printf 'S3_BUCKET=file-bucket\nS3_KEY_TEMPLATE=file-{YEAR}{MONTH}{DOM}.tar.gz\n' > "$CASE_ROOT/client.env"
  invoke --config "$CASE_ROOT/client.env" --s3-key literal.tar.gz
  [ "$status" -eq 65 ]
  grep -Fq -- '--key literal.tar.gz' "$CASE_ROOT/aws.log"
  rm -f "$CASE_ROOT/aws.log"
  invoke --config "$CASE_ROOT/client.env"
  [ "$status" -eq 65 ]
  grep -Fq -- '--key file-20261024.tar.gz' "$CASE_ROOT/aws.log"
}

@test "malicious config syntax rejected without shell execution" {
  printf 'S3_BUCKET=fixture\nS3_KEY=$(touch bad)\n' > "$CASE_ROOT/client.env"
  invoke --config "$CASE_ROOT/client.env"
  [ "$status" -eq 64 ]
  [ ! -e "$CASE_ROOT/bad" ]
  [ ! -e "$CASE_ROOT/aws.log" ]
}

@test "unknown config keys and duplicate keys fail before S3 access" {
  printf 'S3_BUCKET=a\nS3_BUCKET=b\n' > "$CASE_ROOT/client.env"
  invoke --config "$CASE_ROOT/client.env"
  [ "$status" -eq 64 ]
  printf 'S3_BUCKET=a\nGPG_SYMMETRIC_KEY=secret\n' > "$CASE_ROOT/client.env"
  invoke --config "$CASE_ROOT/client.env"
  [ "$status" -eq 64 ]
  [ ! -e "$CASE_ROOT/aws.log" ]
}

@test "exported environment settings override file while CLI overrides environment" {
  printf 'S3_BUCKET=file-bucket\nS3_KEY=file.tar.gz\n' > "$CASE_ROOT/client.env"
  run env PATH="$CASE_ROOT/bin:$PATH" MOCK_CALLS="$CASE_ROOT/aws.log" \
    S3_BUCKET=env-bucket S3_KEY=env.tar.gz \
    bash "$CLIENT" --destination "$CASE_ROOT/private/certs" \
      --config "$CASE_ROOT/client.env"
  [ "$status" -eq 65 ]
  grep -Fq -- '--bucket env-bucket --key env.tar.gz' "$CASE_ROOT/aws.log"
  rm "$CASE_ROOT/aws.log"
  run env PATH="$CASE_ROOT/bin:$PATH" MOCK_CALLS="$CASE_ROOT/aws.log" \
    S3_BUCKET=env-bucket S3_KEY=env.tar.gz \
    bash "$CLIENT" --destination "$CASE_ROOT/private/certs" \
      --config "$CASE_ROOT/client.env" --s3-bucket cli-bucket --s3-key cli.tar.gz
  [ "$status" -eq 65 ]
  grep -Fq -- '--bucket cli-bucket --key cli.tar.gz' "$CASE_ROOT/aws.log"
}

@test "implicit caller-working-directory .env selects bucket and current key" {
  printf 'S3_BUCKET=implicit-bucket\nS3_KEY=implicit.tar.gz\n' > "$CASE_ROOT/.env"
  run env -u S3_BUCKET -u S3_KEY -u S3_KEY_TEMPLATE \
    PATH="$CASE_ROOT/bin:$PATH" MOCK_CALLS="$CASE_ROOT/aws.log" \
    bash -c 'cd "$1" && exec bash "$2" --destination "$3"' -- \
      "$CASE_ROOT" "$CLIENT" "$CASE_ROOT/private/certs"
  [ "$status" -eq 65 ]
  grep -Fq -- '--bucket implicit-bucket --key implicit.tar.gz' "$CASE_ROOT/aws.log"
}

@test "same winning-tier environment key and template conflict fails closed" {
  run env PATH="$CASE_ROOT/bin:$PATH" MOCK_CALLS="$CASE_ROOT/aws.log" \
    S3_BUCKET=fixture-bucket S3_KEY=literal.tar.gz \
    S3_KEY_TEMPLATE='dated-{YEAR}.tar.gz' \
    bash "$CLIENT" --destination "$CASE_ROOT/private/certs"
  [ "$status" -eq 64 ]
  [ ! -e "$CASE_ROOT/aws.log" ]
}
