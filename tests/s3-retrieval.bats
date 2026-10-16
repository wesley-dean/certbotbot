#!/usr/bin/env bats

## @file tests/s3-retrieval.bats
## @brief Tests typed storage reads without AWS, DNS, or ACME credentials.
## @details
## A PATH-injected fake AWS CLI implements only get-object, including service
## error signatures and intentionally partial output. Each test is run on
## every standalone artifact and must never activate issuance or publication.

setup() {
  : "${CERTBOTBOT_ARTIFACT:?A standalone artifact is required}"
  export CERTBOTBOT_TMPDIR="$BATS_TEST_TMPDIR/work"
  export S3_FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  export S3_FAKE_STORE="$BATS_TEST_TMPDIR/object-store"
  export S3_FAKE_LOG="$BATS_TEST_TMPDIR/aws-called"
  export S3_FAKE_MODE=normal
  mkdir -m 0700 "$CERTBOTBOT_TMPDIR" "$S3_FAKE_BIN" "$S3_FAKE_STORE"
  cat >"$S3_FAKE_BIN/aws" <<'AWS'
#!/usr/bin/env bash
set -u
if [[ ${1:-} == --endpoint-url ]]; then
  shift 2
fi
[[ ${1:-} == s3api && ${2:-} == get-object ]] || exit 88
shift 2
bucket='' key='' destination=''
while (( $# > 0 )); do
  case "$1" in
    --bucket) bucket=$2; shift 2 ;;
    --key) key=$2; shift 2 ;;
    *) destination=$1; shift ;;
  esac
done
[[ $bucket == valid-bucket && -n $key && $destination == /* ]] || exit 88
printf '%s\n' "$key" >>"$S3_FAKE_LOG"
case "${S3_FAKE_MODE:-normal}" in
  denied)
    printf 'An error occurred (AccessDenied) when calling the GetObject operation: Denied\n' >&2
    exit 254
    ;;
  generic404)
    printf 'An error occurred (404) when calling the GetObject operation: Unknown\n' >&2
    exit 254
    ;;
  timeout)
    printf 'AWS request could not reach endpoint\n' >&2
    exit 255
    ;;
  partial)
    printf 'partial untrusted bytes' >"$destination"
    printf 'An error occurred (InternalError) when calling the GetObject operation: Failed\n' >&2
    exit 254
    ;;
esac
if [[ ! -f "$S3_FAKE_STORE/$key" ]]; then
  printf 'An error occurred (NoSuchKey) when calling the GetObject operation: Missing\n' >&2
  exit 254
fi
cp -- "$S3_FAKE_STORE/$key" "$destination" || exit 73
AWS
  chmod 0700 "$S3_FAKE_BIN/aws"
}

create_state() {
  printf 'common-account-fixture\n' >"$S3_FAKE_STORE/common-latest.tar.gz"
  printf 'domain-alpha-fixture\n' >"$S3_FAKE_STORE/example.com-latest.tar.gz"
  printf 'domain-beta-fixture\n' >"$S3_FAKE_STORE/example.net-latest.tar.gz"
}

run_stage() {
  local mode=${1:-production}
  shift
  run env PATH="$S3_FAKE_BIN:$PATH" ACME_ENVIRONMENT="$mode" \
    S3_FAKE_MODE="$S3_FAKE_MODE" \
    bash -c '
      source "$1" --version >/dev/null
      certbotbot_workspace_create || exit 99
      certbotbot_s3_stage_collection valid-bucket "${@:2}"
      result=$?
      printf "result=%s\n" "$result"
      if (( result == 0 )); then
        [[ "${CERTBOTBOT_S3_STAGE_PRESENT[0]}" == 1 ]] || exit 91
        [[ -f "${CERTBOTBOT_S3_STAGE_PATHS[0]}" ]] || exit 92
        printf "common=%s\n" \
          "$(cat "${CERTBOTBOT_S3_STAGE_PATHS[0]}")"
        for (( n=1; n<${#CERTBOTBOT_S3_STAGE_PRESENT[@]}; n++ )); do
          printf "present-%s=%s\n" "$n" \
            "${CERTBOTBOT_S3_STAGE_PRESENT[n]}"
          if [[ ${CERTBOTBOT_S3_STAGE_PRESENT[n]} == 1 ]]; then
            [[ -f ${CERTBOTBOT_S3_STAGE_PATHS[n]} ]] || exit 93
            [[ "$(stat -c "%a" "${CERTBOTBOT_S3_STAGE_PATHS[n]}")" == 600 ]] ||
              exit 94
          else
            [[ -z ${CERTBOTBOT_S3_STAGE_PATHS[n]} ]] || exit 95
          fi
        done
        [[ "$(stat -c "%a" "$CERTBOTBOT_S3_STAGE_ROOT")" == 700 ]] ||
          exit 96
        certbotbot_s3_stage_discard || exit 97
      else
        [[ -z "$CERTBOTBOT_S3_STAGE_ROOT" ]] || exit 98
      fi
      [[ -z "$(find "$CERTBOTBOT_WORKSPACE_ROOT" \
        -mindepth 1 -maxdepth 1 ! -name config ! -name work \
        ! -name logs -print -quit)" ]] || exit 90
      certbotbot_workspace_destroy || exit 89
    ' _ "$CERTBOTBOT_ARTIFACT" "$@"
}

@test "common and two selected domains are privately downloaded and discarded" {
  create_state
  run_stage production example.com example.net
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=0'* ]]
  [[ "$output" == *'common=common-account-fixture'* ]]
  [[ "$output" == *'present-1=1'* && "$output" == *'present-2=1'* ]]
  [ "$(wc -l < "$S3_FAKE_LOG")" -eq 3 ]
}

@test "existing common plus absent new domain preserves typed absence" {
  create_state
  rm "$S3_FAKE_STORE/example.net-latest.tar.gz"
  run_stage production example.com example.net
  [ "$status" -eq 0 ]
  [[ "$output" == *'present-1=1'* && "$output" == *'present-2=0'* ]]
}

@test "completely empty collection is distinguished from errors" {
  run_stage production example.com example.net
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=10'* ]]
}

@test "existing lineage with missing common account fails closed" {
  create_state
  rm "$S3_FAKE_STORE/common-latest.tar.gz"
  run_stage production example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=65'* ]]
}

@test "access denied is fatal rather than evidence of a new collection" {
  S3_FAKE_MODE=denied
  run_stage production example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=69'* ]]
}

@test "ambiguous HTTP 404 is never treated as confirmed NoSuchKey" {
  S3_FAKE_MODE=generic404
  run_stage production example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=69'* ]]
}

@test "transport outage does not trigger first-run state" {
  S3_FAKE_MODE=timeout
  run_stage production example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=69'* ]]
}

@test "partial download is discarded with the rest of the stage" {
  create_state
  S3_FAKE_MODE=partial
  run_stage production example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=69'* ]]
  [[ "$output" != *'partial untrusted bytes'* ]]
}

@test "empty remote object is not accepted as a valid archive" {
  create_state
  : >"$S3_FAKE_STORE/common-latest.tar.gz"
  run_stage production example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=69'* ]]
}

@test "staging reads use only staging-prefixed object names" {
  mkdir -p "$S3_FAKE_STORE/staging"
  printf 'staging-account\n' >"$S3_FAKE_STORE/staging/common-latest.tar.gz"
  printf 'staging-lineage\n' >"$S3_FAKE_STORE/staging/example.com-latest.tar.gz"
  run_stage staging example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=0'* && "$output" == *'common=staging-account'* ]]
  grep -Fxq 'staging/common-latest.tar.gz' "$S3_FAKE_LOG"
  grep -Fxq 'staging/example.com-latest.tar.gz' "$S3_FAKE_LOG"
  ! grep -Fxq 'common-latest.tar.gz' "$S3_FAKE_LOG"
}

@test "invalid duplicate requests never reach AWS" {
  create_state
  run_stage production example.com example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=64'* ]]
  [ ! -e "$S3_FAKE_LOG" ]
}

@test "invalid lineage identity never reaches AWS" {
  create_state
  run_stage production '*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=64'* ]]
  [ ! -e "$S3_FAKE_LOG" ]
}

@test "preexisting active files remain untouched on rejected retrieval" {
  create_state
  run env PATH="$S3_FAKE_BIN:$PATH" bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    printf "untouched\n" >"$CERTBOTBOT_WORKSPACE_CONFIG/.marker"
    certbotbot_s3_stage_collection valid-bucket example.com
    result=$?
    [[ $result -eq 64 ]] || exit 1
    [[ "$(cat "$CERTBOTBOT_WORKSPACE_CONFIG/.marker")" == untouched ]] ||
      exit 1
    [[ -z "$CERTBOTBOT_S3_STAGE_ROOT" ]] || exit 1
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT"
  [ "$status" -eq 0 ]
  [ ! -e "$S3_FAKE_LOG" ]
}

@test "public certificate issuance remains unavailable" {
  run "$CERTBOTBOT_ARTIFACT" example.com
  [ "$status" -eq 69 ]
}
