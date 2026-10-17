# shellcheck shell=bash
## @file lib/publication-plan.bash
## @brief Creates a read-only, checksummed publication/recovery manifest.
## @details
## This module records a proposed latest-object replacement and a complete
## validated ADR-043 previous-state checkpoint. The manifest is local only:
## no backup generation is persisted remotely, no S3 mutation is authorized,
## and no caller may infer transactionality or recovery after a runner crash.
## @see doc/adr/ADR-046-local-prepublication-recovery-manifest.md

## @var CERTBOTBOT_PLAN_ROOT
## @brief Owner-private local directory containing the completed manifest.
CERTBOTBOT_PLAN_ROOT=''
## @var CERTBOTBOT_PLAN_MANIFEST
## @brief Complete immutable-by-contract TSV record, mode 0600.
CERTBOTBOT_PLAN_MANIFEST=''
## @var CERTBOTBOT_PLAN_DIGEST
## @brief SHA-256 of the manifest bytes, for local integrity checking.
CERTBOTBOT_PLAN_DIGEST=''
## @var CERTBOTBOT_PLAN_NEW_DIGESTS
## @brief Parallel new-object SHA-256 digests, in common-first key order.
declare -a CERTBOTBOT_PLAN_NEW_DIGESTS=()
## @var CERTBOTBOT_PLAN_NEW_SIZES
## @brief Parallel new-object byte counts.
declare -a CERTBOTBOT_PLAN_NEW_SIZES=()

## @fn certbotbot_publication_plan_discard()
## @brief Delete only this invocation's recorded private manifest directory.
## @retval 0 No plan exists or cleanup succeeded.
## @retval 73 Unsafe owned path, permission, or cleanup failure.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @note Ordinary deletion is not guaranteed secure erasure.
certbotbot_publication_plan_discard() {
  local root=${CERTBOTBOT_PLAN_ROOT:-} mode=''
  [[ -n $root ]] || return 0
  if [[ -z ${CERTBOTBOT_WORKSPACE_ROOT:-} ||
    $root != "$CERTBOTBOT_WORKSPACE_ROOT"/plan.???????? ||
    ! ${root##*/} =~ ^plan[.][a-zA-Z0-9]{8}$ ||
    ! -d $root || -L $root || ! -O $root ||
    ${CERTBOTBOT_PLAN_MANIFEST:-} != "$root/manifest.tsv" ]]; then
    return 73
  fi
  mode="$(stat -c '%a' -- "$root")" || return 73
  [[ $mode == 700 ]] || return 73
  rm -rf -- "$root" || return 73
  CERTBOTBOT_PLAN_ROOT=''
  # shellcheck disable=SC2034
  CERTBOTBOT_PLAN_MANIFEST=''
  # shellcheck disable=SC2034
  CERTBOTBOT_PLAN_DIGEST=''
  # shellcheck disable=SC2034
  CERTBOTBOT_PLAN_NEW_DIGESTS=()
  # shellcheck disable=SC2034
  CERTBOTBOT_PLAN_NEW_SIZES=()
}

## @fn certbotbot_publication_plan_write()
## @brief Render the full validated local object map as deterministic TSV.
## @param destination Absolute private file to replace with manifest contents.
## @retval 0 All normalized records were written.
## @retval 73 File write or metadata operation failed.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @note Internal helper requires the already validated candidate/checkpoint.
certbotbot_publication_plan_write() {
  local dest=${1:-} i=0 count=${#CERTBOTBOT_PUBLICATION_KEYS[@]}
  local oldsize=0
  (( $# == 1 )) || return 64
  {
    printf 'certbotbot-prepublication-plan\t1\n'
    printf 'environment\t%s\n' "$CERTBOTBOT_PUBLICATION_ENVIRONMENT"
    printf 'bucket\t%s\n' "$CERTBOTBOT_PUBLICATION_BUCKET"
    printf 'objects\t%d\n' "$count"
    for (( i=0; i<count; i++ )); do
      oldsize=0
      if [[ ${CERTBOTBOT_CHECKPOINT_PRESENT[i]} == 1 ]]; then
        oldsize="$(stat -c '%s' -- \
          "${CERTBOTBOT_CHECKPOINT_FILES[i]}")" || return 73
      fi
      printf 'object\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$i" "${CERTBOTBOT_PUBLICATION_KEYS[i]}" \
        "${CERTBOTBOT_CHECKPOINT_PRESENT[i]}" \
        "${CERTBOTBOT_CHECKPOINT_SHA256[i]:--}" \
        "$oldsize" "${CERTBOTBOT_PLAN_NEW_DIGESTS[i]}" \
        "${CERTBOTBOT_PLAN_NEW_SIZES[i]}"
    done
  } >"$dest" || return 73
}

## @fn certbotbot_publication_plan_verify()
## @brief Reverify local manifest and unchanged proposed/previous bytes.
## @retval 0 All frozen local records still match current candidate/checkpoint.
## @retval 64 Incomplete, unsafe, or inconsistent plan metadata.
## @retval 65 Modified prior or proposed bytes, or altered manifest contents.
## @retval 73 Filesystem or hashing failure.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @note A checksum is not an authenticated signature or distributed lock.
certbotbot_publication_plan_verify() {
  local root=${CERTBOTBOT_PLAN_ROOT:-} manifest=${CERTBOTBOT_PLAN_MANIFEST:-}
  local digest='' next='' size='' i=0 count=0
  [[ -n $root && -n $manifest &&
    $root == "${CERTBOTBOT_WORKSPACE_ROOT:-}"/plan.???????? &&
    $manifest == "$root/manifest.tsv" &&
    -d $root && ! -L $root && -O $root &&
    -f $manifest && ! -L $manifest && -O $manifest &&
    "$(stat -c '%a' -- "$root")" == 700 &&
    "$(stat -c '%a' -- "$manifest")" == 600 ]] || return 64
  count=${#CERTBOTBOT_PUBLICATION_KEYS[@]}
  (( count >= 2 && count <= 33 &&
    ${#CERTBOTBOT_PLAN_NEW_DIGESTS[@]} == count &&
    ${#CERTBOTBOT_PLAN_NEW_SIZES[@]} == count &&
    ${#CERTBOTBOT_PUBLICATION_FILES[@]} == count &&
    ${#CERTBOTBOT_CHECKPOINT_KEYS[@]} == count )) || return 64
  certbotbot_checkpoint_verify || return $?
  for (( i=0; i<count; i++ )); do
    [[ "${CERTBOTBOT_PUBLICATION_KEYS[i]}" == \
      "${CERTBOTBOT_CHECKPOINT_KEYS[i]}" ]] || return 64
    next=${CERTBOTBOT_PUBLICATION_FILES[i]}
    [[ -f $next && ! -L $next && -O $next &&
      "$(stat -c '%a' -- "$next")" == 600 ]] || return 65
    size="$(stat -c '%s' -- "$next")" || return 73
    [[ $size == "${CERTBOTBOT_PLAN_NEW_SIZES[i]}" ]] || return 65
    digest="$(certbotbot_checkpoint_hash "$next")" || return $?
    [[ $digest == "${CERTBOTBOT_PLAN_NEW_DIGESTS[i]}" ]] || return 65
  done
  digest="$(certbotbot_checkpoint_hash "$manifest")" || return $?
  [[ $digest == "${CERTBOTBOT_PLAN_DIGEST:-}" ]] || return 65
  return 0
}

## @fn certbotbot_publication_plan_prepare()
## @brief Prepare one full local manifest from verified proposed and old state.
## @details
## Checks candidate/checkpoint ownership, bucket, environment, key ordering,
## original bytes, permissions, and presence flags before exposing any plan.
## Does not discover missing keys independently or trust caller-supplied
## absence values: only the completed ADR-043 checkpoint supplies them.
## No AWS, GPG, DNS, or Certbot operation occurs through this module.
## @retval 0 Completed manifest is available through caller-facing variables.
## @retval 64 Missing, unsafe, or inconsistent validation context.
## @retval 65 A frozen candidate/checkpoint object changed during preparation.
## @retval 73 Local creation, writing, hashing, or cleanup failure.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_publication_plan_prepare() {
  local root='' file='' key='' digest='' size='' result=0 i=0 count=0
  local suffix='' environment=${ACME_ENVIRONMENT:-production}
  local -a newhashes=() newsizes=()
  (( $# == 0 )) || return 64
  if [[ $- == *x* ||
    -n ${CERTBOTBOT_PLAN_ROOT:-} ||
    -n ${CERTBOTBOT_PLAN_MANIFEST:-} ||
    -z ${CERTBOTBOT_PUBLICATION_ROOT:-} ||
    -z ${CERTBOTBOT_CHECKPOINT_ROOT:-} ||
    -z ${CERTBOTBOT_WORKSPACE_ROOT:-} ||
    -z ${CERTBOTBOT_WORKSPACE_CONFIG:-} ||
    ${CERTBOTBOT_PUBLICATION_ENVIRONMENT:-} != "$environment" ]] ||
    ! certbotbot_acme_validate_environment "$environment"; then
    return 64
  fi
  [[ -z "$(find -P "$CERTBOTBOT_WORKSPACE_CONFIG" \
    -mindepth 1 -print -quit)" ]] || return 64
  if [[ -n ${GPG_PASSPHRASE:-} ]]; then
    [[ $GPG_PASSPHRASE != *[[:cntrl:]]* ]] || return 64
    suffix=.enc
  fi
  count=${#CERTBOTBOT_PUBLICATION_KEYS[@]}
  (( count >= 2 && count <= 33 &&
    ${#CERTBOTBOT_PUBLICATION_FILES[@]} == count &&
    ${#CERTBOTBOT_CHECKPOINT_KEYS[@]} == count &&
    ${#CERTBOTBOT_CHECKPOINT_PRESENT[@]} == count &&
    ${#CERTBOTBOT_CHECKPOINT_FILES[@]} == count &&
    ${#CERTBOTBOT_CHECKPOINT_SHA256[@]} == count )) || return 64
  [[ -d $CERTBOTBOT_PUBLICATION_ROOT &&
    ! -L $CERTBOTBOT_PUBLICATION_ROOT &&
    -O $CERTBOTBOT_PUBLICATION_ROOT &&
    "$(stat -c '%a' -- "$CERTBOTBOT_PUBLICATION_ROOT")" == 700 ]] ||
    return 64
  certbotbot_checkpoint_verify || return $?
  for (( i=0; i<count; i++ )); do
    key=${CERTBOTBOT_PUBLICATION_KEYS[i]}
    file=${CERTBOTBOT_PUBLICATION_FILES[i]}
    [[ $key == "${CERTBOTBOT_CHECKPOINT_KEYS[i]}" ]] || return 64
    certbotbot_storage_s3_validate_target \
      "$CERTBOTBOT_PUBLICATION_BUCKET" "$key" || return 64
    if (( i == 0 )); then
      [[ $key == "common-latest.tar.gz$suffix" ||
        $key == "staging/common-latest.tar.gz$suffix" ]] || return 64
    else
      [[ $key == *"-latest.tar.gz$suffix" ]] || return 64
    fi
    [[ $file == "$CERTBOTBOT_PUBLICATION_ROOT"/object.???????? &&
      -f $file && ! -L $file && -O $file &&
      "$(stat -c '%a' -- "$file")" == 600 ]] || return 64
    size="$(stat -c '%s' -- "$file")" || return 73
    [[ $size =~ ^[0-9]+$ ]] && (( size > 0 )) || return 64
    digest="$(certbotbot_checkpoint_hash "$file")" || return $?
    newhashes+=("$digest")
    newsizes+=("$size")
  done
  root="$(mktemp -d -- \
    "$CERTBOTBOT_WORKSPACE_ROOT/plan.XXXXXXXX")" || return 73
  # Mark the plan as owned immediately so all failure paths use one
  # bounded cleanup function, never a broad workspace deletion.
  CERTBOTBOT_PLAN_ROOT=$root
  # shellcheck disable=SC2034
  CERTBOTBOT_PLAN_MANIFEST="$root/manifest.tsv"
  # shellcheck disable=SC2034
  CERTBOTBOT_PLAN_NEW_DIGESTS=("${newhashes[@]}")
  # shellcheck disable=SC2034
  CERTBOTBOT_PLAN_NEW_SIZES=("${newsizes[@]}")
  if ! (umask 077; : >"$CERTBOTBOT_PLAN_MANIFEST" &&
    chmod 0600 -- "$CERTBOTBOT_PLAN_MANIFEST"); then
    result=73
  fi
  if (( result == 0 )); then
    certbotbot_publication_plan_write "$CERTBOTBOT_PLAN_MANIFEST" ||
      result=73
  fi
  if (( result == 0 )); then
    digest="$(certbotbot_checkpoint_hash "$CERTBOTBOT_PLAN_MANIFEST")" ||
      result=$?
    # shellcheck disable=SC2034
    CERTBOTBOT_PLAN_DIGEST=$digest
  fi
  if (( result == 0 )); then
    certbotbot_publication_plan_verify || result=$?
  fi
  if (( result != 0 )); then
    certbotbot_publication_plan_discard || return 73
    return "$result"
  fi
  return 0
}
