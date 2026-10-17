# shellcheck shell=bash
## @file lib/publication-precondition.bash
## @brief Rechecks remote latest-object bytes against a frozen local checkpoint.
## @details
## A completed ADR-042 candidate, ADR-043 prior-state checkpoint, and
## ADR-046 publication manifest identify the selected current S3 keys.
## This non-mutating boundary performs a NEW typed S3 read of every selected
## latest key immediately before any separately governed future publication.
## Changes, additions, removals, format mismatches, or ambiguous reads reject
## the proposed work. It does not create a distributed lock, guarantee a
## consistent multi-key snapshot, or protect against writes after checking.
## @see doc/adr/ADR-048-remote-latest-drift-preflight.md

## @fn certbotbot_publication_precondition_check()
## @brief Reject remote state changed since the validated prior checkpoint.
## @details
## The original snapshots and manifest are revalidated before the new read.
## Expected object names are reconstructed and checked using the selected
## authority, encryption mode, and built-in S3 key grammar. The S3 retrieval
## helper handles NoSuchKey distinctly from errors and detects opposite-mode
## objects without using their bytes. Present objects must match the exact
## as-downloaded prior body SHA-256 and byte count. All remote staging is
## discarded before return, whether state is stable or rejected.
##
## This function does not call PutObject or Certbot and never writes latest
## aliases. A successful check is an instantaneous *observation*, not
## permission to publish: another writer may change the collection before
## or during a later write. ADR-022 still requires external serialization.
## @retval 0 All selected remote objects match their checkpoint or absence.
## @retval 64 Incomplete plan, unsafe workspace, or invalid object identity.
## @retval 65 Presence, selected archive mode, or object bytes have drifted.
## @retval 69 Authorization, service, transport, or ambiguous read failure.
## @retval 73 Local stage, metadata, or cleanup failure.
## @note Error statuses from existing verified input stages may propagate.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_publication_precondition_check() {
  local environment=${ACME_ENVIRONMENT:-production} bucket=''
  local suffix='' prefix='' tail='' key='' logical='' name=''
  local count=0 i=0 status=0 result=0 digest='' size='' file=''
  local -a names=()
  local -A seen=()

  (( $# == 0 )) || return 64
  [[ $- != *x* && -z ${CERTBOTBOT_S3_STAGE_ROOT:-} &&
    -z ${CERTBOTBOT_COMMON_STAGE:-} &&
    -z ${CERTBOTBOT_RESTORE_ROOT:-} &&
    -z ${CERTBOTBOT_RENEWAL_PREVIEW:-} &&
    -n ${CERTBOTBOT_PUBLICATION_BUCKET:-} &&
    -n ${CERTBOTBOT_PUBLICATION_ENVIRONMENT:-} &&
    $environment == "$CERTBOTBOT_PUBLICATION_ENVIRONMENT" &&
    -n ${CERTBOTBOT_WORKSPACE_CONFIG:-} &&
    -d $CERTBOTBOT_WORKSPACE_CONFIG &&
    ! -L $CERTBOTBOT_WORKSPACE_CONFIG &&
    -O $CERTBOTBOT_WORKSPACE_CONFIG &&
    "$(stat -c '%a' -- "$CERTBOTBOT_WORKSPACE_CONFIG")" == 700 ]] ||
    return 64
  [[ -z "$(find -P "$CERTBOTBOT_WORKSPACE_CONFIG" \
    -mindepth 1 -print -quit)" ]] || return 64
  if [[ -n ${GPG_PASSPHRASE:-} ]]; then
    [[ $GPG_PASSPHRASE != *[[:cntrl:]]* ]] || return 64
    suffix='.enc'
  fi
  certbotbot_publication_plan_verify || return $?
  bucket=$CERTBOTBOT_PUBLICATION_BUCKET
  count=${#CERTBOTBOT_PUBLICATION_KEYS[@]}
  (( count >= 2 && count <= 33 &&
    ${#CERTBOTBOT_CHECKPOINT_KEYS[@]} == count &&
    ${#CERTBOTBOT_CHECKPOINT_PRESENT[@]} == count &&
    ${#CERTBOTBOT_CHECKPOINT_FILES[@]} == count &&
    ${#CERTBOTBOT_CHECKPOINT_SHA256[@]} == count )) || return 64
  [[ $environment == staging ]] && prefix='staging/'
  tail="-latest.tar.gz$suffix"
  key="$(certbotbot_acme_object_key "$environment" \
    "common-latest.tar.gz$suffix")" || return 64
  [[ "${CERTBOTBOT_PUBLICATION_KEYS[0]}" == "$key" &&
    "${CERTBOTBOT_CHECKPOINT_KEYS[0]}" == "$key" ]] || return 64
  certbotbot_storage_s3_validate_target "$bucket" "$key" || return 64
  for (( i=1; i<count; i++ )); do
    key=${CERTBOTBOT_PUBLICATION_KEYS[i]}
    [[ $key == "${CERTBOTBOT_CHECKPOINT_KEYS[i]}" &&
      $key == "$prefix"*"$tail" ]] || return 64
    logical=${key#"$prefix"}
    name=${logical%"$tail"}
    if ! certbotbot_validate_hostname "$name" ||
      [[ $name == \*.* || $name != "${name,,}" ||
        -n ${seen[$name]+_} ]] ||
      [[ "$(certbotbot_acme_object_key "$environment" \
        "$name-latest.tar.gz$suffix")" != "$key" ]]; then
      return 64
    fi
    certbotbot_storage_s3_validate_target "$bucket" "$key" || return 64
    names+=("$name")
    seen["$name"]=1
  done

  if certbotbot_s3_stage_collection "$bucket" "${names[@]}"; then
    status=0
  else
    status=$?
    # All objects may legitimately have been absent in the original
    # checkpoint, but only exact NoSuchKey results establish absence.
    if (( status == 10 )); then
      for (( i=0; i<count; i++ )); do
        [[ ${CERTBOTBOT_CHECKPOINT_PRESENT[i]} == 0 ]] || return 65
      done
      return 0
    fi
    return "$status"
  fi

  if (( ${#CERTBOTBOT_S3_STAGE_PRESENT[@]} != count ||
    ${#CERTBOTBOT_S3_STAGE_RAW_PATHS[@]} != count )); then
    result=65
  fi
  if (( result == 0 )); then
    for (( i=0; i<count; i++ )); do
      if [[ ${CERTBOTBOT_CHECKPOINT_PRESENT[i]} != \
        "${CERTBOTBOT_S3_STAGE_PRESENT[i]}" ]]; then
        result=65
        break
      fi
      if [[ ${CERTBOTBOT_CHECKPOINT_PRESENT[i]} == 0 ]]; then
        [[ -z ${CERTBOTBOT_S3_STAGE_RAW_PATHS[i]} ]] || {
          result=65
          break
        }
        continue
      fi
      file=${CERTBOTBOT_S3_STAGE_RAW_PATHS[i]}
      if [[ $file != "$CERTBOTBOT_S3_STAGE_ROOT"/object.???????? ||
        ! -f $file || -L $file || ! -O $file ||
        "$(stat -c '%a' -- "$file")" != 600 ]]; then
        result=65
        break
      fi
      size="$(stat -c '%s' -- "$file")" || {
        result=73
        break
      }
      [[ $size == "$(stat -c '%s' -- \
        "${CERTBOTBOT_CHECKPOINT_FILES[i]}")" ]] || {
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
    done
  fi
  certbotbot_s3_stage_discard || return 73
  return "$result"
}
