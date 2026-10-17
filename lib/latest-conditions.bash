# shellcheck shell=bash
## @file lib/latest-conditions.bash
## @brief Capture conditional S3 latest-object tokens tied to checked prior bytes.
## @details
## ADR-049 extends the ADR-048 read-only drift test.  HEAD retrieves the
## server's opaque ETag, and a GET with If-Match of exactly that ETag must
## reproduce the previously verified ADR-043 body.  These preconditions
## do not authorize a write or provide a distributed lock.
## @see doc/adr/ADR-049-etag-bound-publication-conditions.md

## @var CERTBOTBOT_LATEST_CONDITION_KEYS
## @brief Ordered common-first latest-object keys.
declare -a CERTBOTBOT_LATEST_CONDITION_KEYS=()
## @var CERTBOTBOT_LATEST_CONDITION_KINDS
## @brief Parallel "etag" or "absent" conditional predicates.
declare -a CERTBOTBOT_LATEST_CONDITION_KINDS=()
## @var CERTBOTBOT_LATEST_CONDITION_VALUES
## @brief Parallel opaque quoted ETags, or empty for absent keys.
declare -a CERTBOTBOT_LATEST_CONDITION_VALUES=()
## @var CERTBOTBOT_LATEST_CONDITION_PLAN_SHA256
## @brief SHA-256 of the local plan used for these predicates.
CERTBOTBOT_LATEST_CONDITION_PLAN_SHA256=''

## @fn certbotbot_latest_conditions_discard()
## @brief Clear captured predicates and their plan identity.
## @retval 0 Captured state is now empty.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_latest_conditions_discard() {
  # shellcheck disable=SC2034
  CERTBOTBOT_LATEST_CONDITION_KEYS=()
  # shellcheck disable=SC2034
  CERTBOTBOT_LATEST_CONDITION_KINDS=()
  # shellcheck disable=SC2034
  CERTBOTBOT_LATEST_CONDITION_VALUES=()
  # shellcheck disable=SC2034
  CERTBOTBOT_LATEST_CONDITION_PLAN_SHA256=''
}

## @fn certbotbot_latest_conditions_capture()
## @brief Recheck remote state and capture checked per-object ETag tokens.
## @details
## First verify the ADR-046 local plan and ADR-048 remote drift.  For each
## previously present key, HEAD provides a current opaque ETag and a
## conditional GET with that ETag must return the exact previous body.
## Absence is represented only by the original confirmed absence plus
## the fresh ADR-048 typed read.  Results are committed to caller-visible
## arrays only once every object has passed.  All temporary bytes are
## discarded; no AWS upload, delete, or Certbot invocation is possible.
## @retval 0 Complete, validated predicates.
## @retval 64 Unsafe or already-owned state.
## @retval 65 Remote body differs from the checkpoint.
## @retval 69 S3, ETag, or conditional-read failure.
## @retval 73 Local staging or cleanup failure.
## @note A later writer MUST use real per-PUT conditional headers.  These
## predicates may go stale and do not provide a multi-object transaction.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_latest_conditions_capture() {
  local bucket='' key='' etag='' digest='' size='' prior=''
  local root='' file='' result=0 i=0 count=0
  local -a options=() keys=() kinds=() values=()
  (( $# == 0 )) || return 64
  [[ $- != *x* &&
    -z ${CERTBOTBOT_LATEST_CONDITION_PLAN_SHA256:-} &&
    ${#CERTBOTBOT_LATEST_CONDITION_KEYS[@]} == 0 &&
    ${#CERTBOTBOT_LATEST_CONDITION_KINDS[@]} == 0 &&
    ${#CERTBOTBOT_LATEST_CONDITION_VALUES[@]} == 0 &&
    -z ${CERTBOTBOT_S3_STAGE_ROOT:-} &&
    -n ${CERTBOTBOT_WORKSPACE_ROOT:-} &&
    -d $CERTBOTBOT_WORKSPACE_ROOT &&
    ! -L $CERTBOTBOT_WORKSPACE_ROOT &&
    -O $CERTBOTBOT_WORKSPACE_ROOT &&
    "$(stat -c '%a' -- "$CERTBOTBOT_WORKSPACE_ROOT")" == 700 ]] ||
    return 64
  certbotbot_publication_plan_verify || return $?
  certbotbot_publication_precondition_check || return $?
  certbotbot_publication_plan_verify || return $?
  bucket=${CERTBOTBOT_PUBLICATION_BUCKET:-}
  count=${#CERTBOTBOT_PUBLICATION_KEYS[@]}
  (( count >= 2 && count <= 33 &&
    ${#CERTBOTBOT_CHECKPOINT_PRESENT[@]} == count &&
    ${#CERTBOTBOT_CHECKPOINT_SHA256[@]} == count &&
    ${#CERTBOTBOT_CHECKPOINT_FILES[@]} == count )) || return 64
  if [[ -n ${S3_ENDPOINT_URL:-} ]]; then
    options=(--endpoint-url "$S3_ENDPOINT_URL")
  fi
  root="$(mktemp -d -- \
    "$CERTBOTBOT_WORKSPACE_ROOT/etag-read.XXXXXXXX")" || return 73
  for (( i=0; i<count; i++ )); do
    key=${CERTBOTBOT_PUBLICATION_KEYS[i]}
    keys+=("$key")
    if ! certbotbot_storage_s3_validate_target "$bucket" "$key"; then
      result=64
      break
    fi
    if [[ ${CERTBOTBOT_CHECKPOINT_PRESENT[i]} == 0 ]]; then
      kinds+=(absent)
      values+=('')
      continue
    fi
    etag="$(certbotbot_command_aws "${options[@]}" s3api head-object \
      --bucket "$bucket" --key "$key" \
      --query ETag --output text 2>/dev/null)" || {
      result=69
      break
    }
    # Preserve the original quotes: If-Match expects the service ETag, not
    # a guessed SHA/MD5 checksum.  Arbitrary output is never shell-evaluated.
    if [[ ! $etag =~ ^\"[A-Za-z0-9_.-]{1,128}\"$ ]]; then
      result=69
      break
    fi
    file="$(mktemp -- "$root/object.XXXXXXXX")" || {
      result=73
      break
    }
    if ! certbotbot_command_aws "${options[@]}" s3api get-object \
      --bucket "$bucket" --key "$key" --if-match "$etag" \
      "$file" >/dev/null 2>&1; then
      result=69
      break
    fi
    [[ -f $file && ! -L $file && -O $file &&
      "$(stat -c '%a' -- "$file")" == 600 ]] || {
      result=65
      break
    }
    size="$(stat -c '%s' -- "$file")" || {
      result=73
      break
    }
    prior="$(stat -c '%s' -- \
      "${CERTBOTBOT_CHECKPOINT_FILES[i]}")" || {
      result=73
      break
    }
    [[ $size == "$prior" ]] || {
      result=65
      break
    }
    digest="$(certbotbot_checkpoint_hash "$file")" || {
      result=$?
      break
    }
    [[ $digest == "${CERTBOTBOT_CHECKPOINT_SHA256[i]}" ]] || {
      result=65
      break
    }
    kinds+=(etag)
    values+=("$etag")
    rm -f -- "$file" || {
      result=73
      break
    }
  done
  rm -rf -- "$root" || return 73
  (( result == 0 )) || return "$result"
  certbotbot_publication_plan_verify || return $?
  # Expose no incomplete result if a later selected key fails.
  # shellcheck disable=SC2034
  CERTBOTBOT_LATEST_CONDITION_KEYS=("${keys[@]}")
  # shellcheck disable=SC2034
  CERTBOTBOT_LATEST_CONDITION_KINDS=("${kinds[@]}")
  # shellcheck disable=SC2034
  CERTBOTBOT_LATEST_CONDITION_VALUES=("${values[@]}")
  # shellcheck disable=SC2034
  CERTBOTBOT_LATEST_CONDITION_PLAN_SHA256=$CERTBOTBOT_PLAN_DIGEST
  return 0
}
