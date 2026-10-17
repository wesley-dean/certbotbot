# shellcheck shell=bash
## @file lib/s3-retrieval.bash
## @brief Retrieves a selected S3 state collection into private staging.
## @details
## ADR-039 distinguishes a confirmed GetObject NoSuchKey from ambiguous
## missing, unauthorized, transport, and local filesystem failures.
## The selected format is determined only by GPG_PASSPHRASE. An absent
## selected-mode key is checked for the opposite suffix and fails closed on
## a mode mismatch. Encrypted downloads are decrypted privately before the
## existing archive validators inspect them. No plaintext fallback occurs.
## The state remains staged without extraction or active Certbot use.
## @see doc/adr/ADR-039-typed-s3-state-retrieval.md

## @var CERTBOTBOT_S3_STAGE_ROOT
## @brief Private staging directory owned by this module.
CERTBOTBOT_S3_STAGE_ROOT=''
## @var CERTBOTBOT_S3_STAGE_PATHS
## @brief Ordered local paths (index zero is common); absent entries are empty.
declare -a CERTBOTBOT_S3_STAGE_PATHS=()
## @var CERTBOTBOT_S3_STAGE_RAW_PATHS
## @brief Exact downloaded body paths, index-matched to validation paths.
## @note When encrypted, these retain ciphertext for recovery, not tar use.
declare -a CERTBOTBOT_S3_STAGE_RAW_PATHS=()
## @var CERTBOTBOT_S3_STAGE_PRESENT
## @brief Presence flags corresponding to staged paths (1 or 0).
declare -a CERTBOTBOT_S3_STAGE_PRESENT=()

## @fn certbotbot_s3_stage_discard()
## @brief Removes only the recorded owner-private collection stage.
## @retval 0 Staging was absent or safely deleted.
## @retval 73 Unsafe recorded stage or failed cleanup.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_s3_stage_discard() {
  local root=${CERTBOTBOT_S3_STAGE_ROOT:-} mode=''
  [[ -n $root ]] || return 0
  if [[ -z ${CERTBOTBOT_WORKSPACE_ROOT:-} ||
    $root != "$CERTBOTBOT_WORKSPACE_ROOT"/s3-state.???????? ||
    ! ${root##*/} =~ ^s3-state[.][a-zA-Z0-9]{8}$ ||
    ! -d $root || -L $root || ! -O $root ]]; then
    return 73
  fi
  mode="$(stat -c '%a' -- "$root")" || return 73
  [[ $mode == 700 ]] || return 73
  rm -rf -- "$root" || return 73
  CERTBOTBOT_S3_STAGE_ROOT=''
  CERTBOTBOT_S3_STAGE_PATHS=()
  # shellcheck disable=SC2034
  CERTBOTBOT_S3_STAGE_RAW_PATHS=()
  CERTBOTBOT_S3_STAGE_PRESENT=()
}

## @fn certbotbot_s3_get_classified()
## @brief Downloads into an empty private file, classifying GetObject failures.
## @param bucket Selected S3 bucket.
## @param key Validated latest archive object key.
## @param destination Empty owner-private file created by the caller.
## @retval 0 Nonempty object fetched successfully.
## @retval 10 Exact AWS CLI GetObject NoSuchKey service error.
## @retval 64 Invalid arguments or destination.
## @retval 69 Any other service/transport error or empty object.
## @retval 73 Local error-file or cleanup failure.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @note AWS CLI stderr is kept private and never echoed as a diagnostic.
certbotbot_s3_get_classified() {
  local bucket=${1:-} key=${2:-} dest=${3:-} err='' code=0 result=0
  local mode='' size=''
  if (( $# != 3 )) ||
    [[ -z ${CERTBOTBOT_S3_STAGE_ROOT:-} ||
      $dest != "$CERTBOTBOT_S3_STAGE_ROOT"/object.???????? ||
      ! ${dest##*/} =~ ^object[.][a-zA-Z0-9]{8}$ ||
      ! -f $dest || -L $dest || ! -O $dest ]] ||
    ! certbotbot_storage_s3_validate_target "$bucket" "$key"; then
    return 64
  fi
  mode="$(stat -c '%a' -- "$dest")" || return 73
  size="$(stat -c '%s' -- "$dest")" || return 73
  [[ $mode == 600 && $size == 0 ]] || return 64
  err="$(mktemp -- "$CERTBOTBOT_S3_STAGE_ROOT/.error.XXXXXXXX")" ||
    return 73
  if certbotbot_storage_s3_get "$bucket" "$key" "$dest" 2>"$err"; then
    [[ -s $dest && -f $dest && ! -L $dest ]] || result=69
  else
    code=$?
    if (( code == 254 )) && LC_ALL=C grep -Eq \
      '^An error occurred \(NoSuchKey\) when calling the GetObject operation:' \
      "$err"; then
      result=10
    else
      result=69
    fi
  fi
  rm -f -- "$err" || return 73
  if (( result != 0 )); then
    : >"$dest" || return 73
  fi
  return "$result"
}

## @fn certbotbot_s3_stage_collection()
## @brief Fetches common plus named lineages with typed absent/error results.
## @param bucket Target S3 bucket.
## @param names One or more distinct canonical lineage names.
## @retval 0 Common exists; selected domain entries may be missing.
## @retval 10 All requested objects were confirmed absent.
## @retval 64 Bad input, selected environment, or active workspace.
## @retval 65 Inconsistent account, mixed archive mode, or GPG failure.
## @retval 69 Unknown, denied, transport, or empty-object failure.
## @retval 73 Local stage failure or cleanup error.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @note Status 10 alone never authorizes ACME account registration.
## @note A successful stage requires an explicit discard by its caller.
certbotbot_s3_stage_collection() {
  local bucket=${1:-} env=${ACME_ENVIRONMENT:-production}
  local mode='' item='' name='' key='' dest='' root='' status=0 result=0
  local probe='' probe_key='' probe_status=0 plaintext='' suffix=''
  local common_found=false domain_found=false encrypted=false
  local -a names=() keys=()
  local -A seen=()

  if (( $# < 2 || $# > 33 )) ||
    [[ -n ${CERTBOTBOT_S3_STAGE_ROOT:-} ||
      -z ${CERTBOTBOT_WORKSPACE_ROOT:-} ||
      -z ${CERTBOTBOT_WORKSPACE_CONFIG:-} ]] ||
    ! certbotbot_acme_validate_environment "$env"; then
    return 64
  fi
  # Refuse xtrace before looking at any secret-bearing environment value.
  if [[ $- == *x* ]]; then
    return 64
  fi
  if [[ -n ${GPG_PASSPHRASE:-} ]]; then
    # A line-oriented GPG passphrase channel cannot encode control bytes.
    if [[ $GPG_PASSPHRASE == *[[:cntrl:]]* ]]; then
      return 64
    fi
    if ! command -v gpg >/dev/null 2>&1; then
      return 69
    fi
    encrypted=true
    suffix='.enc'
  fi
  shift
  names=("$@")
  for name in "${names[@]}"; do
    if ! certbotbot_validate_hostname "$name" ||
      [[ $name == \*.* || $name != "${name,,}" ||
        -n ${seen[$name]+_} ]]; then
      return 64
    fi
    seen["$name"]=1
  done
  key="$(certbotbot_acme_object_key "$env" "common-latest.tar.gz$suffix")" ||
    return 64
  keys=("$key")
  for name in "${names[@]}"; do
    key="$(certbotbot_acme_object_key "$env" "$name-latest.tar.gz$suffix")" ||
      return 64
    keys+=("$key")
  done
  for key in "${keys[@]}"; do
    certbotbot_storage_s3_validate_target "$bucket" "$key" || return 64
  done
  if [[ ! -d $CERTBOTBOT_WORKSPACE_ROOT ||
    -L $CERTBOTBOT_WORKSPACE_ROOT ||
    ! -O $CERTBOTBOT_WORKSPACE_ROOT ||
    ! -d $CERTBOTBOT_WORKSPACE_CONFIG ||
    -L $CERTBOTBOT_WORKSPACE_CONFIG ||
    ! -O $CERTBOTBOT_WORKSPACE_CONFIG ]]; then
    return 64
  fi
  mode="$(stat -c '%a' -- "$CERTBOTBOT_WORKSPACE_ROOT")" || return 73
  [[ $mode == 700 ]] || return 64
  mode="$(stat -c '%a' -- "$CERTBOTBOT_WORKSPACE_CONFIG")" || return 73
  [[ $mode == 700 ]] || return 64
  item="$(find -P "$CERTBOTBOT_WORKSPACE_CONFIG" \
    -mindepth 1 -print -quit)" || return 73
  [[ -z $item ]] || return 64

  root="$(mktemp -d -- \
    "$CERTBOTBOT_WORKSPACE_ROOT/s3-state.XXXXXXXX")" || return 73
  CERTBOTBOT_S3_STAGE_ROOT=$root
  CERTBOTBOT_S3_STAGE_PATHS=()
  # shellcheck disable=SC2034
  CERTBOTBOT_S3_STAGE_RAW_PATHS=()
  CERTBOTBOT_S3_STAGE_PRESENT=()
  for key in "${keys[@]}"; do
    dest="$(mktemp -- "$root/object.XXXXXXXX")" || {
      result=73
      break
    }
    if certbotbot_s3_get_classified "$bucket" "$key" "$dest"; then
      # Retain exact remote bytes even when validators need plaintext.
      # shellcheck disable=SC2034
      CERTBOTBOT_S3_STAGE_RAW_PATHS+=("$dest")
      if [[ $encrypted == true ]]; then
        plaintext="$(mktemp -- "$root/object.XXXXXXXX")" || {
          result=73
          break
        }
        if certbotbot_gpg_decrypt_archive "$dest" "$plaintext"; then
          # Keep ciphertext private; only plaintext reaches the validators.
          dest=$plaintext
        else
          result=$?
          break
        fi
      fi
      CERTBOTBOT_S3_STAGE_PATHS+=("$dest")
      CERTBOTBOT_S3_STAGE_PRESENT+=(1)
      if [[ $key == "${keys[0]}" ]]; then
        common_found=true
      else
        domain_found=true
      fi
    else
      status=$?
      if (( status == 10 )); then
        # Probe the other suffix solely to detect mixed-format collections.
        # Never validate or use bytes from the non-selected mode.
        if [[ $encrypted == true ]]; then
          probe_key=${key%.enc}
        else
          probe_key=$key.enc
        fi
        probe="$(mktemp -- "$root/object.XXXXXXXX")" || {
          result=73
          break
        }
        if certbotbot_s3_get_classified "$bucket" "$probe_key" "$probe"; then
          result=65
        else
          probe_status=$?
          if (( probe_status != 10 )); then
            result=$probe_status
          fi
        fi
        if ! rm -f -- "$dest" "$probe"; then
          result=73
          break
        fi
        if (( result != 0 )); then
          break
        fi
        CERTBOTBOT_S3_STAGE_PATHS+=('')
        # shellcheck disable=SC2034
        CERTBOTBOT_S3_STAGE_RAW_PATHS+=('')
        CERTBOTBOT_S3_STAGE_PRESENT+=(0)
      else
        result=$status
        break
      fi
    fi
  done
  if (( result == 0 )) && [[ $common_found == false ]]; then
    if [[ $domain_found == true ]]; then
      result=65
    else
      result=10
    fi
  fi
  if (( result != 0 )); then
    certbotbot_s3_stage_discard || return 73
  fi
  return "$result"
}
