# shellcheck shell=bash
## @file lib/publication-checkpoint.bash
## @brief Captures recoverable previous S3 object bytes before future uploads.
## @details
## This module is read-only with respect to remote storage. It requires an
## already verified ADR-042 local publication candidate and retrieves the
## exact previous object bodies for its complete common-first key set.
## Every downloaded plaintext or decrypted archive is assessed using the
## existing ADR-037/038 validators before the raw bytes become a checkpoint.
## An empty collection remains distinguishable from untrusted storage errors.
## @see doc/adr/ADR-043-recoverable-s3-publication-checkpoint.md

## @var CERTBOTBOT_CHECKPOINT_ROOT
## @brief Private workspace directory containing frozen old remote objects.
CERTBOTBOT_CHECKPOINT_ROOT=''
## @var CERTBOTBOT_CHECKPOINT_KEYS
## @brief Ordered common-first S3 keys matching the prepared candidate.
declare -a CERTBOTBOT_CHECKPOINT_KEYS=()
## @var CERTBOTBOT_CHECKPOINT_FILES
## @brief Raw old remote bytes, or empty when that key was absent.
declare -a CERTBOTBOT_CHECKPOINT_FILES=()
## @var CERTBOTBOT_CHECKPOINT_PRESENT
## @brief Parallel 1/0 flags for old remote object existence.
declare -a CERTBOTBOT_CHECKPOINT_PRESENT=()
## @var CERTBOTBOT_CHECKPOINT_SHA256
## @brief Parallel SHA-256 digests of old objects, or empty when absent.
declare -a CERTBOTBOT_CHECKPOINT_SHA256=()
## @var CERTBOTBOT_CHECKPOINT_EMPTY
## @brief True only when every old object was confirmed missing.
CERTBOTBOT_CHECKPOINT_EMPTY=false

## @fn certbotbot_checkpoint_discard()
## @brief Deletes only the currently recorded owner-private checkpoint.
## @retval 0 No checkpoint exists or its directory was successfully removed.
## @retval 73 The recorded path is unsafe or cleanup failed.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @note This is ordinary deletion, not guaranteed cryptographic erasure.
certbotbot_checkpoint_discard() {
  local root=${CERTBOTBOT_CHECKPOINT_ROOT:-} mode=''
  [[ -n $root ]] || return 0
  if [[ -z ${CERTBOTBOT_WORKSPACE_ROOT:-} ||
    $root != "$CERTBOTBOT_WORKSPACE_ROOT"/checkpoint.???????? ||
    ! ${root##*/} =~ ^checkpoint[.][a-zA-Z0-9]{8}$ ||
    ! -d $root || -L $root || ! -O $root ]]; then
    return 73
  fi
  mode="$(stat -c '%a' -- "$root")" || return 73
  [[ $mode == 700 ]] || return 73
  rm -rf -- "$root" || return 73
  CERTBOTBOT_CHECKPOINT_ROOT=''
  # These arrays are consumed by a later, separately governed coordinator.
  # shellcheck disable=SC2034
  CERTBOTBOT_CHECKPOINT_KEYS=()
  # shellcheck disable=SC2034
  CERTBOTBOT_CHECKPOINT_FILES=()
  # shellcheck disable=SC2034
  CERTBOTBOT_CHECKPOINT_PRESENT=()
  # shellcheck disable=SC2034
  CERTBOTBOT_CHECKPOINT_SHA256=()
  # shellcheck disable=SC2034
  CERTBOTBOT_CHECKPOINT_EMPTY=false
}

## @fn certbotbot_checkpoint_hash()
## @brief Computes the SHA-256 checksum of an owned private object.
## @param pathname Owner-private absolute regular file.
## @retval 0 A lowercase hexadecimal SHA-256 digest was printed.
## @retval 69 No supported SHA-256 executable is available.
## @retval 73 A local hashing command failed.
## @par STDIN
## Nothing is read from STDIN.
## @returns One hexadecimal SHA-256 digest and a trailing newline.
certbotbot_checkpoint_hash() {
  local file=${1:-} sum=''
  (( $# == 1 )) || return 64
  [[ $file == /* && -f $file && ! -L $file && -O $file ]] || return 64
  if command -v sha256sum >/dev/null 2>&1; then
    sum="$(sha256sum -- "$file")" || return 73
  elif command -v shasum >/dev/null 2>&1; then
    sum="$(shasum -a 256 -- "$file")" || return 73
  else
    return 69
  fi
  sum=${sum%% *}
  [[ $sum =~ ^[a-f0-9]{64}$ ]] || return 73
  printf '%s\n' "$sum"
}

## @fn certbotbot_checkpoint_verify()
## @brief Checks the stored private rollback bytes against captured SHA-256s.
## @retval 0 Each present checkpoint body matches its recorded digest.
## @retval 64 Incomplete or unsafe checkpoint metadata.
## @retval 65 A previously frozen object body was modified or removed.
## @note Hashes detect accidental change, not attacker-controlled metadata.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_checkpoint_verify() {
  local root=${CERTBOTBOT_CHECKPOINT_ROOT:-} file='' digest='' count=0 i=0
  [[ -n $root && -d $root && ! -L $root && -O $root ]] || return 64
  count=${#CERTBOTBOT_CHECKPOINT_KEYS[@]}
  if (( count < 2 ||
    ${#CERTBOTBOT_CHECKPOINT_FILES[@]} != count ||
    ${#CERTBOTBOT_CHECKPOINT_PRESENT[@]} != count ||
    ${#CERTBOTBOT_CHECKPOINT_SHA256[@]} != count )); then
    return 64
  fi
  for (( i=0; i<count; i++ )); do
    file=${CERTBOTBOT_CHECKPOINT_FILES[i]}
    if [[ ${CERTBOTBOT_CHECKPOINT_PRESENT[i]} == 0 ]]; then
      [[ -z $file && -z ${CERTBOTBOT_CHECKPOINT_SHA256[i]} ]] ||
        return 64
      continue
    fi
    [[ ${CERTBOTBOT_CHECKPOINT_PRESENT[i]} == 1 &&
      $file == "$root"/object.???????? &&
      -f $file && ! -L $file && -O $file ]] || return 65
    digest="$(certbotbot_checkpoint_hash "$file")" || return $?
    [[ $digest == "${CERTBOTBOT_CHECKPOINT_SHA256[i]}" ]] || return 65
  done
  return 0
}

## @fn certbotbot_publication_checkpoint()
## @brief Freeze and validate previous remote state for an approved candidate.
## @details
## Requires the candidate from certbotbot_publication_prepare() in the same
## private workspace. The exact candidate key list is used for remote lookup,
## including its selected plaintext/encrypted format. All remote reads and
## checks precede exposure of rollback bytes, and the original ciphertext
## bytes are kept intact when GPG is enabled. This function never calls PUT.
## @param bucket Selected S3 bucket for candidate and previous objects.
## @retval 0 Frozen verified baseline ready; absence flags may all be zero.
## @retval 64 Invalid candidate, environment, or active workspace.
## @retval 65 Corrupt, wrong-account, or mixed-mode previous state.
## @retval 69 Indeterminate S3 read, missing GPG, or hashing dependency.
## @retval 73 Local staging, copying, or cleanup failure.
## @note Other statuses may propagate from archive validators.
## @note A wholly empty baseline is not permission to issue certificates.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_publication_checkpoint() {
  local bucket=${1:-} env=${ACME_ENVIRONMENT:-production}
  local suffix='' key='' logical='' name='' path='' digest=''
  local root='' file='' common='' result=0 retrieval=0 i=0 count=0
  local -a names=() pairs=() oldfiles=() oldpresent=() oldhashes=()
  local -A seen=()

  if (( $# != 1 )) ||
    [[ $- == *x* ||
      -z ${CERTBOTBOT_PUBLICATION_ROOT:-} ||
      -n ${CERTBOTBOT_CHECKPOINT_ROOT:-} ||
      -n ${CERTBOTBOT_S3_STAGE_ROOT:-} ||
      -n ${CERTBOTBOT_COMMON_STAGE:-} ||
      -n ${CERTBOTBOT_RESTORE_ROOT:-} ||
      -n ${CERTBOTBOT_RENEWAL_PREVIEW:-} ]] ||
    ! certbotbot_acme_validate_environment "$env"; then
    return 64
  fi
  if [[ -n ${GPG_PASSPHRASE:-} ]]; then
    [[ $GPG_PASSPHRASE != *[[:cntrl:]]* ]] || return 64
    suffix='.enc'
  fi
  count=${#CERTBOTBOT_PUBLICATION_KEYS[@]}
  if (( count < 2 || count > 33 ||
    ${#CERTBOTBOT_PUBLICATION_FILES[@]} != count )); then
    return 64
  fi
  root=$CERTBOTBOT_PUBLICATION_ROOT
  [[ -d $root && ! -L $root && -O $root ]] || return 64
  [[ "$(stat -c '%a' -- "$root")" == 700 ]] || return 64
  [[ -z "$(find -P "$CERTBOTBOT_WORKSPACE_CONFIG" \
    -mindepth 1 -print -quit)" ]] || return 64

  for (( i=0; i<count; i++ )); do
    key=${CERTBOTBOT_PUBLICATION_KEYS[i]}
    file=${CERTBOTBOT_PUBLICATION_FILES[i]}
    if [[ $file != "$root"/object.???????? ||
      ! -f $file || -L $file || ! -O $file ||
      ! -s $file ||
      "$(stat -c '%a' -- "$file")" != 600 ]] ||
      ! certbotbot_storage_s3_validate_target "$bucket" "$key"; then
      return 64
    fi
    logical=$key
    if [[ $env == staging ]]; then
      [[ $logical == staging/* ]] || return 64
      logical=${logical#staging/}
    fi
    if (( i == 0 )); then
      [[ $logical == "common-latest.tar.gz$suffix" ]] || return 64
    else
      [[ $logical == *"-latest.tar.gz$suffix" ]] || return 64
      name=${logical%"-latest.tar.gz$suffix"}
      certbotbot_validate_hostname "$name" || return 64
      [[ $name != \*.* && $name == "${name,,}" &&
        -z ${seen[$name]+_} ]] || return 64
      seen["$name"]=1
      names+=("$name")
    fi
  done

  if certbotbot_s3_stage_collection "$bucket" "${names[@]}"; then
    retrieval=0
  else
    retrieval=$?
    (( retrieval == 10 )) || return "$retrieval"
  fi

  if (( retrieval == 0 )); then
    common=${CERTBOTBOT_S3_STAGE_PATHS[0]}
    if certbotbot_common_restore "$common"; then
      certbotbot_common_discard || result=73
    else
      result=$?
      if [[ -n ${CERTBOTBOT_COMMON_STAGE:-} ]]; then
        certbotbot_common_discard || result=73
      fi
    fi
    if (( result == 0 )); then
      for (( i=1; i<count; i++ )); do
        if [[ ${CERTBOTBOT_S3_STAGE_PRESENT[i]} == 1 ]]; then
          pairs+=("${names[i-1]}" "${CERTBOTBOT_S3_STAGE_PATHS[i]}")
        fi
      done
      if (( ${#pairs[@]} > 0 )); then
        certbotbot_import_assess_batch "$common" "$env" \
          "${pairs[@]}" || result=$?
      fi
    fi
  fi

  if (( result == 0 )); then
    root="$(mktemp -d -- \
      "$CERTBOTBOT_WORKSPACE_ROOT/checkpoint.XXXXXXXX")" || result=73
    if (( result == 0 )); then
      CERTBOTBOT_CHECKPOINT_ROOT=$root
      for (( i=0; i<count; i++ )); do
        if (( retrieval == 10 )) ||
          [[ ${CERTBOTBOT_S3_STAGE_PRESENT[i]} == 0 ]]; then
          oldfiles+=('')
          oldpresent+=(0)
          oldhashes+=('')
          continue
        fi
        path="$(mktemp -- "$root/object.XXXXXXXX")" || {
          result=73
          break
        }
        if ! (umask 077; cp -- \
          "${CERTBOTBOT_S3_STAGE_RAW_PATHS[i]}" "$path" &&
          chmod 0600 -- "$path"); then
          result=73
          break
        fi
        digest="$(certbotbot_checkpoint_hash "$path")" || {
          result=$?
          break
        }
        oldfiles+=("$path")
        oldpresent+=(1)
        oldhashes+=("$digest")
      done
    fi
  fi

  if [[ -n ${CERTBOTBOT_S3_STAGE_ROOT:-} ]]; then
    certbotbot_s3_stage_discard || result=73
  fi
  if (( result != 0 )); then
    certbotbot_checkpoint_discard || return 73
    return "$result"
  fi
  # Result metadata is visible only after every object validates.
  # shellcheck disable=SC2034
  CERTBOTBOT_CHECKPOINT_KEYS=("${CERTBOTBOT_PUBLICATION_KEYS[@]}")
  # shellcheck disable=SC2034
  CERTBOTBOT_CHECKPOINT_FILES=("${oldfiles[@]}")
  # shellcheck disable=SC2034
  CERTBOTBOT_CHECKPOINT_PRESENT=("${oldpresent[@]}")
  # shellcheck disable=SC2034
  CERTBOTBOT_CHECKPOINT_SHA256=("${oldhashes[@]}")
  # shellcheck disable=SC2034
  if (( retrieval == 10 )); then
    CERTBOTBOT_CHECKPOINT_EMPTY=true
  else
    CERTBOTBOT_CHECKPOINT_EMPTY=false
  fi
  certbotbot_checkpoint_verify || {
    result=$?
    certbotbot_checkpoint_discard || return 73
    return "$result"
  }
  return 0
}
