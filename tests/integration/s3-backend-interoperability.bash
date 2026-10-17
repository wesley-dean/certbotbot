#!/usr/bin/env bash
## @file tests/integration/s3-backend-interoperability.bash
## @brief Exercise S3-compatible storage only with explicit loopback consent.
## @details
## This opt-in integration harness verifies that the bundled AWS CLI adapter
## handles conditional creation, ETag-bound replacement, and deletion against
## an actual S3-compatible HTTP API. It never contacts a public S3 endpoint.
## It creates and deletes only a uniquely named temporary test bucket.
## No ACME calls, DNS changes, or valid TLS private keys are involved.
## @see doc/adr/ADR-050-conditional-latest-publication-and-recovery.md

set -e -o pipefail
umask 077

## @fn interop_guard()
## @brief Refuse absent consent, production authority, or a non-loopback URL.
## @retval 0 Explicit disposable-local-test boundaries are satisfied.
## @retval 64 Inputs could authorize an unintended network operation.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
interop_guard() {
  [[ ${CERTBOTBOT_S3_INTEROP_CONFIRM:-} == yes &&
    ${ACME_ENVIRONMENT:-} == staging &&
    ${S3_ENDPOINT_URL:-} =~ ^http://(127[.]0[.]0[.]1|localhost):[0-9]{2,5}$ &&
    -n ${AWS_ACCESS_KEY_ID:-} &&
    -n ${AWS_SECRET_ACCESS_KEY:-} &&
    -z ${GPG_PASSPHRASE:-} &&
    -z ${HTTP_PROXY:-} && -z ${HTTPS_PROXY:-} &&
    -z ${ALL_PROXY:-} && -z ${http_proxy:-} &&
    -z ${https_proxy:-} && -z ${all_proxy:-} ]] || return 64
  command -v aws >/dev/null 2>&1 || return 64
}

## @fn interop_aws()
## @brief Invoke the S3 CLI with a previously validated loopback endpoint.
## @param args AWS CLI S3 arguments.
## @retval 0 The requested operation succeeded.
## @note Other AWS CLI statuses propagate.
## @par STDIN
## Nothing is read from STDIN.
## @returns Output belongs to AWS CLI.
interop_aws() {
  command aws --endpoint-url "$S3_ENDPOINT_URL" --region us-east-1 "$@"
}

## @fn interop_assert_file()
## @brief Compare a downloaded object with its expected exact local bytes.
## @param bucket Disposable bucket name.
## @param key Validated test object key.
## @param expected Local expected body filename.
## @param workspace Private temporary workspace.
## @retval 0 Exact bytes matched.
## @retval 65 The read-back data differed.
## @note Other statuses propagate from the AWS CLI.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
interop_assert_file() {
  local bucket=$1 key=$2 expected=$3 workspace=$4
  local retrieved=''
  retrieved="$(mktemp -- "$workspace/readback.XXXXXXXX")"
  interop_aws s3api get-object --bucket "$bucket" --key "$key" \
    "$retrieved" >/dev/null
  cmp -s -- "$expected" "$retrieved" || return 65
}

## @fn interop_main()
## @brief Run real conditional-object S3 tests against an isolated service.
## @details
## The endpoint is restricted to loopback and the bucket is disposable.
## The test exercises the public AWS CLI wire protocol invoked by the internal
## certbotbot storage modules. It does NOT prove full publication recovery,
## backend portability across providers, or release-readiness.
## @retval 0 Every conditional operation passed.
## @retval 64 The run was not authorized.
## @retval 65 An observable object-body invariant failed.
## @note Storage cleanup failures are reported as failures.
## @par STDIN
## Nothing is read from STDIN.
## @returns A single success status line.
interop_main() {
  local work='' bucket='' key=staging/interop-latest.tar.gz
  local etag='' status=0 response=''
  interop_guard || return 64
  work="$(mktemp -d -- "${TMPDIR:-/tmp}/certbotbot-interop.XXXXXXXX")"
  bucket="certbotbot-interop-$(date +%s)-$RANDOM-$RANDOM"
  printf 'first synthetic body\n' >"$work/first"
  printf 'second synthetic body\n' >"$work/second"
  if ! interop_aws s3api create-bucket --bucket "$bucket" >/dev/null; then
    rm -rf -- "$work"
    return 69
  fi
  if ! interop_aws s3api put-object --bucket "$bucket" --key "$key" \
    --body "$work/first" --if-none-match '*' >/dev/null; then
    status=69
  fi
  if (( status == 0 )); then
    interop_assert_file "$bucket" "$key" "$work/first" "$work" || status=$?
  fi
  if (( status == 0 )); then
    if interop_aws s3api put-object --bucket "$bucket" --key "$key" \
      --body "$work/second" --if-none-match '*' >/dev/null 2>&1; then
      status=65
    fi
  fi
  if (( status == 0 )); then
    etag="$(interop_aws s3api head-object --bucket "$bucket" --key "$key" \
      --query ETag --output text)"
    [[ $etag =~ ^\"[A-Za-z0-9_.-]{1,128}\"$ ]] || status=65
  fi
  if (( status == 0 )); then
    interop_aws s3api put-object --bucket "$bucket" --key "$key" \
      --body "$work/second" --if-match "$etag" >/dev/null || status=69
  fi
  if (( status == 0 )); then
    interop_assert_file "$bucket" "$key" "$work/second" "$work" || status=$?
  fi
  if (( status == 0 )); then
    if interop_aws s3api put-object --bucket "$bucket" --key "$key" \
      --body "$work/first" --if-match "$etag" >/dev/null 2>&1; then
      status=65
    fi
  fi
  if (( status == 0 )); then
    etag="$(interop_aws s3api head-object --bucket "$bucket" --key "$key" \
      --query ETag --output text)"
    interop_aws s3api delete-object --bucket "$bucket" --key "$key" \
      --if-match "$etag" >/dev/null || status=69
  fi
  if (( status == 0 )); then
    if interop_aws s3api get-object --bucket "$bucket" --key "$key" \
      "$work/missing" >/dev/null 2>&1; then
      status=65
    fi
  fi
  interop_aws s3 rb "s3://$bucket" --force >/dev/null 2>&1 || status=69
  rm -rf -- "$work" || status=73
  (( status == 0 )) && printf 'S3 loopback conditionals: verified\n'
  return "$status"
}

case ${1:-} in
  guard)
    (( $# == 1 )) || exit 64
    interop_guard || exit 64
    ;;
  run)
    (( $# == 1 )) || exit 64
    interop_main || exit $?
    ;;
  *)
    printf 'usage: %s guard|run\n' "$0" >&2
    exit 64
    ;;
esac
