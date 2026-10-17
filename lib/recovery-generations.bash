# shellcheck shell=bash
## @file lib/recovery-generations.bash
## @brief Durably preserves previous S3 objects before any latest-key mutation.
## @details
## ADR-047 authorizes a narrowly scoped internal, recovery-only remote write.
## It never writes or deletes common-latest or per-lineage latest objects.
## A complete ADR-046 plan is required; prior existing objects are uploaded
## without alteration to unpredictable generation-specific keys with S3
## If-None-Match '*' conditional PUTs. A manifest is committed LAST, after
## verifying every stored byte with readback. An interrupted generation
## remains incomplete and must not be used as proof of recoverability.
## No product operation or public CLI path invokes these helpers.
## @see doc/adr/ADR-047-durable-s3-recovery-generations.md

## @var CERTBOTBOT_RECOVERY_GENERATION
## @brief Complete, verified remote generation identifier, or empty.
CERTBOTBOT_RECOVERY_GENERATION=''
## @var CERTBOTBOT_RECOVERY_MANIFEST_SHA256
## @brief Out-of-band expected SHA-256 of the committed remote manifest.
CERTBOTBOT_RECOVERY_MANIFEST_SHA256=''
## @var CERTBOTBOT_RECOVERY_PENDING_GENERATION
## @brief Identifier of a possibly incomplete generation on failure.
CERTBOTBOT_RECOVERY_PENDING_GENERATION=''

## @fn certbotbot_recovery_key()
## @brief Derive an isolated backup object key from an opaque generation ID.
## @param environment Validated staging or production selector.
## @param generation Exactly 32 lowercase hexadecimal characters.
## @param part One indexed prior-object body or manifest.tsv.
## @returns The absolute S3 object key followed by a newline.
## @retval 0 The key was constructed.
## @retval 64 An input is not in the reserved recovery key grammar.
## @par STDIN
## Nothing is read from STDIN.
certbotbot_recovery_key() {
  local env=${1:-} generation=${2:-} part=${3:-} prefix=''
  (( $# == 3 )) || return 64
  certbotbot_acme_validate_environment "$env" || return 64
  [[ $generation =~ ^[a-f0-9]{32}$ ]] || return 64
  if [[ $part != manifest.tsv && ! $part =~ ^([0-9]|[12][0-9]|3[0-2])[.]prior$ ]]; then
    return 64
  fi
  [[ $env == staging ]] && prefix=staging/
  printf '%srecovery/v1/%s/%s\n' "$prefix" "$generation" "$part"
}

## @fn certbotbot_recovery_s3_put_new()
## @brief Conditionally create only a reserved generation object, never overwrite.
## @param bucket Validated bucket name.
## @param key Reserved recovery-generation key.
## @param input Private, owned local regular file.
## @retval 0 Service accepted a conditional create.
## @retval 64 Invalid endpoint, key, or source.
## @retval 69 Any AWS or S3 failure, including 409/412.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @note This is an internal adapter operation, not a public plugin surface.
certbotbot_recovery_s3_put_new() {
  local bucket=${1:-} key=${2:-} input=${3:-}
  local generation='' part='' env=${ACME_ENVIRONMENT:-production}
  local -a options=()
  (( $# == 3 )) || return 64
  [[ $key == recovery/v1/* || $key == staging/recovery/v1/* ]] ||
    return 64
  if [[ $env == staging ]]; then
    [[ $key == staging/recovery/v1/* ]] || return 64
    generation=${key#staging/recovery/v1/}
  else
    [[ $key == recovery/v1/* ]] || return 64
    generation=${key#recovery/v1/}
  fi
  part=${generation#*/}
  generation=${generation%%/*}
  [[ "$(certbotbot_recovery_key "$env" "$generation" "$part")" == "$key" ]] ||
    return 64
  [[ -f $input && ! -L $input && -O $input &&
    -s $input && "$(stat -c '%a' -- "$input")" == 600 ]] || return 64
  # Validate the bucket and endpoint through the existing trusted latest-key
  # grammar; recovery keys are intentionally separate and are checked above.
  local latest=''
  latest="$(certbotbot_acme_object_key "$env" 'common-latest.tar.gz')" ||
    return 64
  certbotbot_storage_s3_validate_target "$bucket" "$latest" || return 64
  if [[ -n ${S3_ENDPOINT_URL:-} ]]; then
    options=(--endpoint-url "$S3_ENDPOINT_URL")
  fi
  certbotbot_command_aws "${options[@]}" s3api put-object \
    --bucket "$bucket" --key "$key" --body "$input" \
    --if-none-match '*' >/dev/null 2>&1 || return 69
}

## @fn certbotbot_recovery_s3_get()
## @brief Download one existing recovery object without missing-key inference.
## @param bucket Reviewed bucket identity.
## @param key Complete validated recovery key.
## @param destination Empty private regular file owned by the caller.
## @retval 0 One nonempty remote object was received.
## @retval 64 Unsafe or incorrect file and object arguments.
## @retval 69 Missing, denied, empty, or indeterminate remote object.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_recovery_s3_get() {
  local bucket=${1:-} key=${2:-} output=${3:-}
  local env=${ACME_ENVIRONMENT:-production} generation='' part=''
  local latest='' size='' mode=''
  local -a options=()
  (( $# == 3 )) || return 64
  if [[ $env == staging ]]; then
    [[ $key == staging/recovery/v1/* ]] || return 64
    generation=${key#staging/recovery/v1/}
  else
    [[ $key == recovery/v1/* ]] || return 64
    generation=${key#recovery/v1/}
  fi
  part=${generation#*/}
  generation=${generation%%/*}
  [[ "$(certbotbot_recovery_key "$env" "$generation" "$part")" == "$key" ]] ||
    return 64
  latest="$(certbotbot_acme_object_key "$env" 'common-latest.tar.gz')" ||
    return 64
  certbotbot_storage_s3_validate_target "$bucket" "$latest" || return 64
  [[ $output == /* && -f $output && ! -L $output && -O $output ]] ||
    return 64
  mode="$(stat -c '%a' -- "$output")" || return 73
  size="$(stat -c '%s' -- "$output")" || return 73
  [[ $mode == 600 && $size == 0 ]] || return 64
  if [[ -n ${S3_ENDPOINT_URL:-} ]]; then
    options=(--endpoint-url "$S3_ENDPOINT_URL")
  fi
  if ! certbotbot_command_aws "${options[@]}" s3api get-object \
    --bucket "$bucket" --key "$key" "$output" >/dev/null 2>&1; then
    : >"$output" || return 73
    return 69
  fi
  [[ -s $output && -f $output && ! -L $output ]] || return 69
  return 0
}

## @fn certbotbot_recovery_verify()
## @brief Verify a complete committed remote generation on an independent runner.
## @details
## The caller supplies the expected manifest checksum from a trusted
## out-of-band record; remote bytes alone cannot authenticate their origin.
## This function uses only the bucket, environment, generation, checksum,
## private workspace, and AWS credentials. It needs no original candidate,
## checkpoint, or prior runner filesystem. All temporary bytes are deleted.
## @param bucket Existing S3 bucket.
## @param environment Expected ACME authority (production or staging).
## @param generation Opaque 32-hex generation returned by persistence.
## @param expected_sha256 Manifest SHA-256 received independently of S3.
## @retval 0 All committed prior objects match a trusted manifest.
## @retval 64 Invalid request, workspace, or unsafe manifest grammar.
## @retval 65 A body digest/size or manifest expectation was violated.
## @retval 69 Missing, denied, or indeterminate S3 retrieval.
## @retval 73 Temporary storage or cleanup failed.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_recovery_verify() {
  local bucket=${1:-} env=${2:-} generation=${3:-}
  local expected=${4:-} root='' manifest='' key='' file=''
  local digest='' part='' row='' tag='' index='' oldkey='' present=''
  local oldhash='' oldsize='' newhash='' newsize='' extra='' mode=''
  local count=0 i=0 result=0
  local -a rows=()
  (( $# == 4 )) || return 64
  [[ $- != *x* && $env == "${ACME_ENVIRONMENT:-production}" &&
    $generation =~ ^[a-f0-9]{32}$ &&
    $expected =~ ^[a-f0-9]{64}$ &&
    -n ${CERTBOTBOT_WORKSPACE_ROOT:-} &&
    -d $CERTBOTBOT_WORKSPACE_ROOT &&
    ! -L $CERTBOTBOT_WORKSPACE_ROOT &&
    -O $CERTBOTBOT_WORKSPACE_ROOT &&
    "$(stat -c '%a' -- "$CERTBOTBOT_WORKSPACE_ROOT")" == 700 ]] ||
    return 64
  certbotbot_acme_validate_environment "$env" || return 64
  root="$(mktemp -d -- \
    "$CERTBOTBOT_WORKSPACE_ROOT/recovery-check.XXXXXXXX")" || return 73
  manifest="$(mktemp -- "$root/object.XXXXXXXX")" || result=73
  if (( result == 0 )); then
    key="$(certbotbot_recovery_key "$env" "$generation" manifest.tsv)" ||
      result=64
  fi
  if (( result == 0 )); then
    certbotbot_recovery_s3_get "$bucket" "$key" "$manifest" ||
      result=$?
  fi
  if (( result == 0 )); then
    digest="$(certbotbot_checkpoint_hash "$manifest")" || result=$?
    [[ $digest == "$expected" ]] || result=65
  fi
  if (( result == 0 )); then
    mapfile -t rows <"$manifest" || result=73
    (( ${#rows[@]} >= 6 && ${#rows[@]} <= 37 )) || result=64
  fi
  if (( result == 0 )); then
    [[ "${rows[0]}" == $'certbotbot-prepublication-plan\t1' &&
      "${rows[1]}" == "environment"$'\t'"$env" &&
      "${rows[2]}" == "bucket"$'\t'"$bucket" ]] || result=64
    IFS=$'\t' read -r tag count extra <<<"${rows[3]}"
    [[ $tag == objects && $count =~ ^[0-9]+$ && -z $extra ]] ||
      result=64
    if (( result == 0 )); then
      (( count >= 2 && count <= 33 &&
        ${#rows[@]} == count+4 )) || result=64
    fi
  fi
  if (( result == 0 )); then
    for (( i=0; i<count; i++ )); do
      row=${rows[i+4]}
      tag='' index='' oldkey='' present='' oldhash=''
      oldsize='' newhash='' newsize='' extra=''
      IFS=$'\t' read -r tag index oldkey present oldhash \
        oldsize newhash newsize extra <<<"$row"
      if [[ $tag != object || $index != "$i" ||
        -n $extra || ! $oldsize =~ ^[0-9]+$ ||
        ! $newsize =~ ^[0-9]+$ || ! $newhash =~ ^[a-f0-9]{64}$ ]] ||
        ! certbotbot_storage_s3_validate_target "$bucket" "$oldkey"; then
        result=64
        break
      fi
      if (( i == 0 )); then
        [[ $oldkey == "common-latest.tar.gz" ||
          $oldkey == "common-latest.tar.gz.enc" ||
          $oldkey == "staging/common-latest.tar.gz" ||
          $oldkey == "staging/common-latest.tar.gz.enc" ]] || {
            result=64
            break
          }
        mode=${oldkey##*.}
      else
        [[ $oldkey == *"-latest.tar.gz" ||
          $oldkey == *"-latest.tar.gz.enc" ]] || {
            result=64
            break
          }
        [[ ${oldkey##*.} == "$mode" ]] || {
          result=64
          break
        }
      fi
      if [[ $present == 0 ]]; then
        [[ $oldhash == '-' && $oldsize == 0 ]] || {
          result=64
          break
        }
        continue
      fi
      [[ $present == 1 && $oldhash =~ ^[a-f0-9]{64}$ ]] || {
        result=64
        break
      }
      part="$i.prior"
      key="$(certbotbot_recovery_key "$env" "$generation" "$part")" || {
        result=64
        break
      }
      file="$(mktemp -- "$root/object.XXXXXXXX")" || {
        result=73
        break
      }
      certbotbot_recovery_s3_get "$bucket" "$key" "$file" || {
        result=$?
        break
      }
      digest="$(certbotbot_checkpoint_hash "$file")" || {
        result=$?
        break
      }
      if [[ $digest != "$oldhash" ||
        "$(stat -c '%s' -- "$file")" != "$oldsize" ]]; then
        result=65
        break
      fi
      rm -f -- "$file" || {
        result=73
        break
      }
    done
  fi
  rm -rf -- "$root" || return 73
  return "$result"
}

## @fn certbotbot_recovery_persist()
## @brief Persist previous objects as readback-verified, write-once S3 backups.
## @details
## The only remote writes are generation-scoped conditional PutObject calls.
## All existing previous bytes are copied before a completion manifest is
## created. Each object is read back and hashed. A failed or interrupted run
## leaves no committed result; some orphaned generation keys may remain.
## It does not upload proposed/new object bodies or modify latest aliases.
## @retval 0 One complete recovery generation was remotely verified.
## @retval 64 Missing operator authorization or inconsistent local plan.
## @retval 65 Proposed/previous bytes or readback integrity changed.
## @retval 69 Ambiguous, denied, or rejected remote upload/download.
## @retval 73 Private staging or local cleanup failure.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @note External serialization remains required by ADR-022.
certbotbot_recovery_persist() {
  local env=${ACME_ENVIRONMENT:-production} bucket='' root=''
  local generation='' file='' key='' fetched='' digest='' expected=''
  local i=0 count=0 result=0
  (( $# == 0 )) || return 64
  [[ $- != *x* && ${CERTBOTBOT_RECOVERY_WRITE_CONFIRM:-} == yes &&
    -z ${CERTBOTBOT_RECOVERY_GENERATION:-} &&
    -z ${CERTBOTBOT_RECOVERY_PENDING_GENERATION:-} &&
    -n ${CERTBOTBOT_PLAN_ROOT:-} &&
    -n ${CERTBOTBOT_PUBLICATION_BUCKET:-} ]] || return 64
  certbotbot_publication_plan_verify || return $?
  bucket=$CERTBOTBOT_PUBLICATION_BUCKET
  [[ $env == "$CERTBOTBOT_PUBLICATION_ENVIRONMENT" ]] || return 64
  count=${#CERTBOTBOT_CHECKPOINT_KEYS[@]}
  (( count >= 2 && count <= 33 )) || return 64
  [[ -r /dev/urandom ]] || return 69
  command -v od >/dev/null 2>&1 || return 69
  generation="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" || return 69
  [[ $generation =~ ^[a-f0-9]{32}$ ]] || return 69
  # An incomplete identifier is intentionally retained for operator audit.
  CERTBOTBOT_RECOVERY_PENDING_GENERATION=$generation
  root="$(mktemp -d -- \
    "$CERTBOTBOT_WORKSPACE_ROOT/recovery-write.XXXXXXXX")" || return 73
  for (( i=0; i<count; i++ )); do
    [[ ${CERTBOTBOT_CHECKPOINT_PRESENT[i]} == 1 ]] || continue
    file=${CERTBOTBOT_CHECKPOINT_FILES[i]}
    expected=${CERTBOTBOT_CHECKPOINT_SHA256[i]}
    key="$(certbotbot_recovery_key "$env" "$generation" "$i.prior")" || {
      result=64
      break
    }
    certbotbot_recovery_s3_put_new "$bucket" "$key" "$file" || {
      result=$?
      break
    }
    fetched="$(mktemp -- "$root/object.XXXXXXXX")" || {
      result=73
      break
    }
    certbotbot_recovery_s3_get "$bucket" "$key" "$fetched" || {
      result=$?
      break
    }
    digest="$(certbotbot_checkpoint_hash "$fetched")" || {
      result=$?
      break
    }
    if [[ $digest != "$expected" ]]; then
      result=65
      break
    fi
    rm -f -- "$fetched" || {
      result=73
      break
    }
  done
  if (( result == 0 )); then
    key="$(certbotbot_recovery_key "$env" "$generation" manifest.tsv)" ||
      result=64
  fi
  if (( result == 0 )); then
    certbotbot_publication_plan_verify || result=$?
  fi
  if (( result == 0 )); then
    certbotbot_recovery_s3_put_new "$bucket" "$key" \
      "$CERTBOTBOT_PLAN_MANIFEST" || result=$?
  fi
  if (( result == 0 )); then
    fetched="$(mktemp -- "$root/object.XXXXXXXX")" || result=73
  fi
  if (( result == 0 )); then
    certbotbot_recovery_s3_get "$bucket" "$key" "$fetched" || result=$?
  fi
  if (( result == 0 )); then
    digest="$(certbotbot_checkpoint_hash "$fetched")" || result=$?
    [[ $digest == "$CERTBOTBOT_PLAN_DIGEST" ]] || result=65
  fi
  if (( result == 0 )); then
    certbotbot_recovery_verify "$bucket" "$env" "$generation" \
      "$CERTBOTBOT_PLAN_DIGEST" || result=$?
  fi
  rm -rf -- "$root" || return 73
  if (( result != 0 )); then
    return "$result"
  fi
  # Only a completed and fresh-run-reverifiable generation is exposed.
  CERTBOTBOT_RECOVERY_GENERATION=$generation
  # shellcheck disable=SC2034
  CERTBOTBOT_RECOVERY_MANIFEST_SHA256=$CERTBOTBOT_PLAN_DIGEST
  CERTBOTBOT_RECOVERY_PENDING_GENERATION=''
  return 0
}
