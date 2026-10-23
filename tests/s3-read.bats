#!/usr/bin/env bats

setup() {
  : "${BASH_STARTER_ARTIFACT:?Artifact path must be selected}"
  TEST_ROOT="$(mktemp -d)"
  TEST_WORKSPACE="$TEST_ROOT/workspace"
  mkdir -m 700 "$TEST_WORKSPACE" "$TEST_ROOT/bin"
  export MOCK_CALLS="$TEST_ROOT/aws-calls"
  export MOCK_SCENARIO=present
  export MOCK_CONTENT="seeded-archive-bytes"
  PATH="$TEST_ROOT/bin:$PATH"
  export PATH
  cat >"$TEST_ROOT/bin/aws" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == --no-cli-pager ]]; then shift; fi
[[ "${1:-}" == s3api ]] || exit 90
shift
action="${1:-}"
shift
printf '%s' "$action" >>"$MOCK_CALLS"
printf ' <%s>' "$@" >>"$MOCK_CALLS"
printf '\n' >>"$MOCK_CALLS"
case "$action" in
  head-object)
    case "$MOCK_SCENARIO" in
      missing|missing-bucket)
        printf '%s\n' 'An error occurred (404) when calling the HeadObject operation' >&2
        exit 255
        ;;
      denied)
        printf '%s\n' 'An error occurred (403) when calling the HeadObject operation' >&2
        exit 255
        ;;
      expired)
        printf '%s\n' 'An error occurred (ExpiredToken)' >&2
        exit 255
        ;;
      timeout)
        printf '%s\n' 'Connect timeout on endpoint URL' >&2
        exit 255
        ;;
    esac
    ;;
  head-bucket)
    if [[ "$MOCK_SCENARIO" == missing-bucket ]]; then
      printf '%s\n' 'An error occurred (403)' >&2
      exit 255
    fi
    ;;
  get-object)
    destination="${@: -1}"
    case "$MOCK_SCENARIO" in
      partial)
        printf '%s' "truncated" >"$destination"
        printf '%s\n' 'read interrupted' >&2
        exit 255
        ;;
      empty)
        : >"$destination"
        ;;
      *) printf '%s' "$MOCK_CONTENT" >"$destination" ;;
    esac
    ;;
  *) exit 91 ;;
esac
MOCK
  chmod 755 "$TEST_ROOT/bin/aws"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

run_s3_fetch() {
  run bash -c '
    source lib/s3.bash
    certbotbot_s3_fetch "$1" "$2" "$3"
  ' _ "$TEST_WORKSPACE" "${1:-sample-bucket}" "${2:-latest.tar.gz}"
}

@test "S3 module is assembled into each executable flavor" {
  grep -q 'certbotbot_s3_fetch' "$BASH_STARTER_ARTIFACT"
}

@test "retrieves only the selected seeded object into a private workspace" {
  run_s3_fetch
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$TEST_WORKSPACE/downloaded.tar.gz")" = "$MOCK_CONTENT" ]
  [ "$(grep -c '^head-object ' "$MOCK_CALLS")" -eq 1 ]
  [ "$(grep -c '^get-object ' "$MOCK_CALLS")" -eq 1 ]
  ! grep -q 'head-bucket' "$MOCK_CALLS"
  grep -Fq '<chosen.tar.gz>' "$MOCK_CALLS" && return 1
  grep -Fq '<latest.tar.gz>' "$MOCK_CALLS"
}

@test "reads an explicitly configured key without prefix discovery" {
  run_s3_fetch custom-bucket archive.tar.gz
  [ "$status" -eq 0 ]
  grep -Fq '<archive.tar.gz>' "$MOCK_CALLS"
  ! grep -q '<latest.tar.gz>' "$MOCK_CALLS"
}

@test "a confirmed absent object fails without downloading or creating state" {
  export MOCK_SCENARIO=missing
  run_s3_fetch
  [ "$status" -eq 66 ]
  [[ "$output" == *"existing S3 archive was not found"* ]]
  [ ! -e "$TEST_WORKSPACE/downloaded.tar.gz" ]
  [ "$(grep -c '^head-bucket ' "$MOCK_CALLS")" -eq 1 ]
  ! grep -q '^get-object ' "$MOCK_CALLS"
}

@test "a nonexistent or inaccessible bucket cannot be classified as missing key" {
  export MOCK_SCENARIO=missing-bucket
  run_s3_fetch
  [ "$status" -eq 69 ]
  [ ! -e "$TEST_WORKSPACE/downloaded.tar.gz" ]
}

@test "denied access, expired credentials and network failure fail closed" {
  local scenario
  for scenario in denied expired timeout; do
    : >"$MOCK_CALLS"
    export MOCK_SCENARIO="$scenario"
    run_s3_fetch
    [ "$status" -eq 69 ]
    [ ! -e "$TEST_WORKSPACE/downloaded.tar.gz" ]
    ! grep -q '^get-object ' "$MOCK_CALLS"
  done
}

@test "failed partial and successful empty downloads leave no accepted archive" {
  local scenario
  for scenario in partial empty; do
    export MOCK_SCENARIO="$scenario"
    run_s3_fetch
    [ "$status" -eq 74 ]
    [ ! -e "$TEST_WORKSPACE/downloaded.tar.gz" ]
    [ -z "$(find "$TEST_WORKSPACE" -mindepth 1 -print)" ]
  done
}

@test "an existing downloaded archive is never silently overwritten" {
  printf '%s' 'previous-state' >"$TEST_WORKSPACE/downloaded.tar.gz"
  run_s3_fetch
  [ "$status" -eq 64 ]
  [ "$(cat "$TEST_WORKSPACE/downloaded.tar.gz")" = previous-state ]
  [ ! -s "$MOCK_CALLS" ]
}

@test "an unsafe workspace is rejected before calling AWS" {
  chmod 755 "$TEST_WORKSPACE"
  run_s3_fetch
  [ "$status" -eq 64 ]
  [ ! -s "$MOCK_CALLS" ]
}

@test "AWS errors are not echoed with sensitive diagnostic contents" {
  export MOCK_SCENARIO=expired
  run_s3_fetch
  [ "$status" -eq 69 ]
  [[ "$output" != *ExpiredToken* ]]
  [[ "$output" != *'endpoint URL'* ]]
}

@test "public CLI refuses to activate an unvalidated seeded S3 archive" {
  run "$BASH_STARTER_ARTIFACT" --s3-bucket sample-bucket example.com
  [ "$status" -ne 0 ]
  grep -q '^head-object ' "$MOCK_CALLS"
  grep -q '^get-object ' "$MOCK_CALLS"
  ! grep -q '^put-object ' "$MOCK_CALLS"
}
