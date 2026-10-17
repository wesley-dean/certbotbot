#!/usr/bin/env bash
## @file tests/integration/s3-recovery-evidence.bash
## @brief Exercise certbotbot recovery across independent processes and real S3.
## @details
## This opt-in harness uses synthetic, explicitly non-certificate bytes and
## a loopback-only S3-compatible endpoint. It calls the actual ADR-047/050
## recovery and conditional latest-key implementations in every release flavor.
## A completed remote manifest and its checksum are recorded outside the
## first worker before simulated interruption. The second worker starts with
## a new private workspace and no predecessor filesystem.
##
## A deliberately conflicting object must abort rollback before mutation.
## No real AWS, DNS, ACME, consumer plugins, or production issuer is enabled.
## @see doc/s3-interoperability.md

set -e -o pipefail
umask 077

## @fn evidence_guard()
## @brief Refuse execution outside an explicitly authorized loopback test.
## @retval 0 The isolated test identity and endpoint are configured.
## @retval 64 Authorization, endpoint, or required CLI is invalid.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
evidence_guard() {
  [[ ${CERTBOTBOT_S3_INTEROP_CONFIRM:-} == yes &&
    ${ACME_ENVIRONMENT:-} == staging &&
    ${S3_ENDPOINT_URL:-} =~ ^http://127[.]0[.]0[.]1:[0-9]{2,5}$ &&
    -n ${AWS_ACCESS_KEY_ID:-} && -n ${AWS_SECRET_ACCESS_KEY:-} &&
    -z ${GPG_PASSPHRASE:-} ]] || return 64
  command -v aws >/dev/null 2>&1 || return 64
}

## @fn evidence_aws()
## @brief Invoke the external AWS CLI against the guarded test-only service.
## @param args S3 API operation with separate argument vector elements.
## @retval 0 The service confirmed the request.
## @note Other CLI statuses propagate.
## @par STDIN
## Nothing is read from STDIN.
## @returns The underlying AWS CLI owns STDOUT.
evidence_aws() {
  command aws --endpoint-url "$S3_ENDPOINT_URL" --region us-east-1 "$@"
}

## @fn evidence_hash()
## @brief Return SHA-256 of one local synthetic body.
## @param file Owner-private file.
## @retval 0 Hashing succeeded.
## @returns Exactly one lowercase SHA-256 value.
## @par STDIN
## Nothing is read from STDIN.
evidence_hash() {
  sha256sum -- "$1" | cut -d ' ' -f 1
}

## @fn evidence_fixture()
## @brief Recreate the same fixture bodies without transferring private state.
## @param root Current independent producer workspace.
## @retval 0 Private fixture files were written.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
evidence_fixture() {
  local root=$1
  printf 'original common state - synthetic\n' >"$root/old-common"
  printf 'original domain state - synthetic\n' >"$root/old-domain"
  printf 'proposed common state - synthetic\n' >"$root/new-common"
  printf 'proposed domain state - synthetic\n' >"$root/new-domain"
  printf 'unrelated writer bytes - synthetic\n' >"$root/foreign"
}

## @fn evidence_put_and_check()
## @brief Conditionally write an object and verify its exact remote bytes.
## @param bucket Disposable test bucket.
## @param key Canonical staging latest key.
## @param file Expected body.
## @param stage Owner-private probe directory.
## @retval 0 Remote body matched the input exactly.
## @retval 65 Remote result did not match the input.
## @note Other statuses are propagated from the internal adapter.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
evidence_put_and_check() {
  local bucket=$1 key=$2 file=$3 stage=$4
  local kind='' token='' code=0
  if certbotbot_latest_probe "$bucket" "$key" "$stage"; then
    kind=etag
    token=$CERTBOTBOT_LATEST_PROBE_ETAG
  else
    code=$?
    (( code == 10 )) || return "$code"
    kind=absent
  fi
  certbotbot_latest_conditional_put "$bucket" "$key" "$file" \
    "$kind" "$token" || return $?
  certbotbot_latest_probe "$bucket" "$key" "$stage" || return $?
  [[ $CERTBOTBOT_LATEST_PROBE_SHA256 == "$(evidence_hash "$file")" &&
    $CERTBOTBOT_LATEST_PROBE_SIZE == "$(stat -c '%s' -- "$file")" ]] ||
    return 65
}

## @fn evidence_stage()
## @brief Store a complete recovery generation before simulating a writer.
## @details
## A synthetic manifest uses the exact ADR-046 grammar; the internal remote
## verifier checks every stored prior body. This intentionally bypasses
## certificate validation, which is tested separately by the product suite.
## @param artifact Absolute path to the standalone release.
## @param bucket Newly created disposable S3 bucket.
## @param scenario full, partial, absent, conflict, or crash.
## @param record Private out-of-process generation and manifest record.
## @retval 0 The intended remote state was staged and verified.
## @note The crash scenario sends SIGKILL to this child after the common PUT.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
evidence_stage() {
  local artifact=$1 bucket=$2 scenario=$3 record=$4
  local root='' probe='' manifest='' generation='' digest=''
  local common=staging/common-latest.tar.gz
  local domain=staging/example.com-latest.tar.gz
  local oldcommon='-' olddomain='-' oldcs=0 oldds=0 present=0
  # shellcheck disable=SC1090
  source "$artifact" --version >/dev/null
  certbotbot_workspace_create
  root=$CERTBOTBOT_WORKSPACE_ROOT
  evidence_fixture "$root"
  probe="$(mktemp -d -- "$root/latest-probe.XXXXXXXX")"
  generation="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  [[ $generation =~ ^[a-f0-9]{32}$ ]] || return 65
  if [[ $scenario != absent ]]; then
    evidence_put_and_check "$bucket" "$common" "$root/old-common" "$probe"
    evidence_put_and_check "$bucket" "$domain" "$root/old-domain" "$probe"
    oldcommon="$(evidence_hash "$root/old-common")"
    olddomain="$(evidence_hash "$root/old-domain")"
    oldcs="$(stat -c '%s' -- "$root/old-common")"
    oldds="$(stat -c '%s' -- "$root/old-domain")"
    present=1
    certbotbot_recovery_s3_put_new "$bucket" \
      "$(certbotbot_recovery_key staging "$generation" 0.prior)" \
      "$root/old-common"
    certbotbot_recovery_s3_put_new "$bucket" \
      "$(certbotbot_recovery_key staging "$generation" 1.prior)" \
      "$root/old-domain"
  fi
  manifest="$root/manifest.tsv"
  {
    printf 'certbotbot-prepublication-plan\t1\n'
    printf 'environment\tstaging\n'
    printf 'bucket\t%s\n' "$bucket"
    printf 'objects\t2\n'
    printf 'object\t0\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$common" "$present" "$oldcommon" "$oldcs" \
      "$(evidence_hash "$root/new-common")" \
      "$(stat -c '%s' -- "$root/new-common")"
    printf 'object\t1\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$domain" "$present" "$olddomain" "$oldds" \
      "$(evidence_hash "$root/new-domain")" \
      "$(stat -c '%s' -- "$root/new-domain")"
  } >"$manifest"
  digest="$(evidence_hash "$manifest")"
  certbotbot_recovery_s3_put_new "$bucket" \
    "$(certbotbot_recovery_key staging "$generation" manifest.tsv)" \
    "$manifest"
  certbotbot_recovery_verify "$bucket" staging "$generation" "$digest"
  printf '%s %s\n' "$generation" "$digest" >"$record"
  evidence_put_and_check "$bucket" "$common" "$root/new-common" "$probe"
  if [[ $scenario == crash ]]; then
    # The persisted out-of-workspace recovery record must predate the crash.
    kill -KILL "$BASHPID"
  fi
  if [[ $scenario != partial ]]; then
    evidence_put_and_check "$bucket" "$domain" "$root/new-domain" "$probe"
  fi
  certbotbot_workspace_destroy
}

## @fn evidence_recover()
## @brief Run ADR-050 rollback from an independent empty producer.
## @param artifact Selected standalone artifact.
## @param bucket Disposable test bucket.
## @param scenario Required original state or conflicting writer.
## @param record Independently retained generation/checksum record.
## @retval 0 Recovery, idempotence, and selected body bytes were verified.
## @retval 65 The actual remote state violated expectations.
## @note Other statuses propagate from the implementation.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
evidence_recover() {
  local artifact=$1 bucket=$2 scenario=$3 record=$4
  local generation='' digest='' root='' probe='' code=0
  local common=staging/common-latest.tar.gz
  local domain=staging/example.com-latest.tar.gz
  local key='' expected=''
  read -r generation digest <"$record"
  [[ $generation =~ ^[a-f0-9]{32}$ &&
    $digest =~ ^[a-f0-9]{64}$ ]] || return 64
  # shellcheck disable=SC1090
  source "$artifact" --version >/dev/null
  certbotbot_workspace_create
  root=$CERTBOTBOT_WORKSPACE_ROOT
  evidence_fixture "$root"
  probe="$(mktemp -d -- "$root/latest-probe.XXXXXXXX")"
  if [[ $scenario == conflict ]]; then
    evidence_put_and_check "$bucket" "$domain" "$root/foreign" "$probe"
  fi
  if certbotbot_latest_recover "$bucket" staging "$generation" "$digest"; then
    code=0
  else
    code=$?
  fi
  if [[ $scenario == conflict ]]; then
    (( code == 65 )) || return 65
    certbotbot_latest_probe "$bucket" "$common" "$probe"
    [[ $CERTBOTBOT_LATEST_PROBE_SHA256 ==
      "$(evidence_hash "$root/new-common")" ]] || return 65
    certbotbot_latest_probe "$bucket" "$domain" "$probe"
    [[ $CERTBOTBOT_LATEST_PROBE_SHA256 ==
      "$(evidence_hash "$root/foreign")" ]] || return 65
  else
    (( code == 0 )) || return "$code"
    # Recovery can be restarted when old keys are already restored.
    certbotbot_latest_recover "$bucket" staging "$generation" "$digest"
    for key in "$common" "$domain"; do
      if [[ $scenario == absent ]]; then
        if certbotbot_latest_probe "$bucket" "$key" "$probe"; then
          return 65
        else
          code=$?
        fi
        (( code == 10 )) || return 65
      else
        expected=$root/old-common
        [[ $key == "$domain" ]] && expected=$root/old-domain
        certbotbot_latest_probe "$bucket" "$key" "$probe"
        [[ $CERTBOTBOT_LATEST_PROBE_SHA256 ==
          "$(evidence_hash "$expected")" &&
          $CERTBOTBOT_LATEST_PROBE_SIZE ==
          "$(stat -c '%s' -- "$expected")" ]] || return 65
      fi
    done
  fi
  # Even after recovering latest keys, the completed remote generation remains.
  certbotbot_recovery_verify "$bucket" staging "$generation" "$digest"
  certbotbot_workspace_destroy
}

## @fn evidence_run()
## @brief Orchestrate isolated bucket tests for one standalone artifact.
## @param artifact Absolute path of the built artifact under test.
## @retval 0 All expected success, crash, and conflict scenarios passed.
## @retval 64 Invalid artifact or authorization.
## @note A failed cleanup is reported rather than silently ignored.
## @par STDIN
## Nothing is read from STDIN.
## @returns A status summary for each scenario.
evidence_run() {
  local artifact=$1 root='' bucket='' scenario='' result=0 child=0
  [[ $# == 1 && $artifact == /* && -f $artifact ]] || return 64
  root="$(mktemp -d -- "${TMPDIR:-/tmp}/certbotbot-s3-recovery.XXXXXXXX")"
  mkdir -m 0700 -- "$root/work"
  for scenario in full partial absent conflict crash; do
    bucket="certbotbot-interop-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
    if ! evidence_aws s3api create-bucket --bucket "$bucket" >/dev/null; then
      result=69
      break
    fi
    if CERTBOTBOT_TMPDIR="$root/work" \
      bash "$0" stage "$artifact" "$bucket" "$scenario" \
      "$root/$scenario.record"; then
      child=0
    else
      child=$?
    fi
    if [[ $scenario == crash ]]; then
      (( child == 137 )) || result=65
    else
      (( child == 0 )) || result=65
    fi
    # Drop the old runner's local tree even when SIGKILL prevented its trap.
    rm -rf -- "$root/work" || result=73
    mkdir -m 0700 -- "$root/work" || result=73
    if (( result == 0 )); then
      if ! CERTBOTBOT_TMPDIR="$root/work" \
        CERTBOTBOT_LATEST_ROLLBACK_CONFIRM=yes \
        bash "$0" recover "$artifact" "$bucket" "$scenario" \
        "$root/$scenario.record"; then
        result=65
      fi
    fi
    # Only the random bucket this test created may be deleted.
    evidence_aws s3 rb "s3://$bucket" --force >/dev/null 2>&1 ||
      result=69
    (( result == 0 )) || break
    printf 'S3 recovery scenario %s: verified\n' "$scenario"
  done
  rm -rf -- "$root" || return 73
  return "$result"
}

case ${1:-} in
  guard)
    (( $# == 1 )) || exit 64
    evidence_guard || exit 64
    ;;
  stage|recover)
    mode=$1
    shift
    (( $# == 4 )) || exit 64
    evidence_guard || exit 64
    [[ $2 == certbotbot-interop-* &&
      ${CERTBOTBOT_TMPDIR:-} == /* ]] || exit 64
    if [[ $mode == stage ]]; then
      evidence_stage "$@"
    else
      evidence_recover "$@"
    fi
    ;;
  run)
    shift
    (( $# == 1 )) || exit 64
    evidence_guard || exit 64
    evidence_run "$@" || exit $?
    ;;
  *)
    printf 'usage: %s guard|run ARTIFACT\n' "$0" >&2
    exit 64
    ;;
esac
