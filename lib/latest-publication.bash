# shellcheck shell=bash
## @file lib/latest-publication.bash
## @brief Conditionally publish verified latest objects and restore from S3.
## @details
## ADR-050 limits remote latest-key mutation to an explicitly authorized
## internal coordinator backed by a completed ADR-047 recovery generation.
## Each PUT requires an S3 object condition captured under ADR-049. Recovery
## from a fresh process compares ALL current keys against the saved old/new
## hashes before any conditional rollback. Nothing activates Certbot.
## @see doc/adr/ADR-050-conditional-latest-publication-and-recovery.md

## @var CERTBOTBOT_LATEST_PUBLISH_OUTCOME
## @brief empty, partial, or complete, visible to the invoking internal caller.
CERTBOTBOT_LATEST_PUBLISH_OUTCOME=''
## @var CERTBOTBOT_LATEST_PROBE_PRESENT
## @brief Temporary remote probe's boolean result.
CERTBOTBOT_LATEST_PROBE_PRESENT=''
## @var CERTBOTBOT_LATEST_PROBE_ETAG
## @brief Opaque S3 ETag bound to the probed bytes, if present.
CERTBOTBOT_LATEST_PROBE_ETAG=''
## @var CERTBOTBOT_LATEST_PROBE_SHA256
## @brief SHA-256 of the raw bytes in the probed latest object.
CERTBOTBOT_LATEST_PROBE_SHA256=''
## @var CERTBOTBOT_LATEST_PROBE_SIZE
## @brief Byte count of the raw bytes in the probed latest object.
CERTBOTBOT_LATEST_PROBE_SIZE=''

## @fn certbotbot_latest_validate_key()
## @brief Require a canonical selected latest key for the current authority.
## @param bucket Validated S3 bucket.
## @param key Canonical latest-object key.
## @retval 0 Key and bucket are supported.
## @retval 64 Unsupported key or invalid destination.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_latest_validate_key() {
  local bucket=${1:-} key=${2:-} env=${ACME_ENVIRONMENT:-production}
  local prefix='' leaf='' name='' suffix=''
  (( $# == 2 )) || return 64
  certbotbot_acme_validate_environment "$env" || return 64
  certbotbot_storage_s3_validate_target "$bucket" "$key" || return 64
  [[ $env == staging ]] && prefix=staging/
  [[ $key == "$prefix"* ]] || return 64
  leaf=${key#"$prefix"}
  case "$leaf" in
    common-latest.tar.gz|common-latest.tar.gz.enc) return 0 ;;
    *-latest.tar.gz.enc) suffix=-latest.tar.gz.enc ;;
    *-latest.tar.gz) suffix=-latest.tar.gz ;;
    *) return 64 ;;
  esac
  name=${leaf%"$suffix"}
  certbotbot_validate_hostname "$name" || return 64
  [[ $name != \*.* && $name == "${name,,}" ]] || return 64
  [[ "$(certbotbot_acme_object_key "$env" "$leaf")" == "$key" ]] ||
    return 64
}

## @fn certbotbot_latest_conditional_put()
## @brief Put one exact validated body with an object-level S3 CAS condition.
## @param bucket Existing bucket.
## @param key Canonical latest key.
## @param file Owner-only verified 0600 archive body.
## @param predicate etag or absent.
## @param token Quoted ETag if predicate=etag; otherwise empty.
## @retval 0 S3 accepted the conditional PUT.
## @retval 64 Invalid key, file, or condition.
## @retval 69 All denied, conflicting, unsupported, or ambiguous write outcomes.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_latest_conditional_put() {
  local bucket=${1:-} key=${2:-} file=${3:-}
  local predicate=${4:-} token=${5:-}
  local -a options=() condition=()
  (( $# == 5 )) || return 64
  certbotbot_latest_validate_key "$bucket" "$key" || return 64
  [[ $file == /* && -f $file && ! -L $file && -O $file &&
    -s $file && "$(stat -c '%a' -- "$file")" == 600 ]] || return 64
  case "$predicate" in
    etag)
      [[ $token =~ ^\"[A-Za-z0-9_.-]{1,128}\"$ ]] || return 64
      condition=(--if-match "$token")
      ;;
    absent)
      [[ -z $token ]] || return 64
      condition=(--if-none-match '*')
      ;;
    *) return 64 ;;
  esac
  [[ -z ${S3_ENDPOINT_URL:-} ]] ||
    options=(--endpoint-url "$S3_ENDPOINT_URL")
  certbotbot_command_aws "${options[@]}" s3api put-object \
    --bucket "$bucket" --key "$key" --body "$file" \
    "${condition[@]}" >/dev/null 2>&1 || return 69
}

## @fn certbotbot_latest_conditional_delete()
## @brief Delete a newly created latest object using its exact S3 ETag.
## @param bucket Existing bucket.
## @param key Canonical latest key.
## @param token Current quoted ETag whose raw bytes were validated.
## @retval 0 Conditional deletion succeeded.
## @retval 64 Unsafe key or token.
## @retval 69 Conflict, denial, or indeterminate delete outcome.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_latest_conditional_delete() {
  local bucket=${1:-} key=${2:-} token=${3:-}
  local -a options=()
  (( $# == 3 )) || return 64
  certbotbot_latest_validate_key "$bucket" "$key" || return 64
  [[ $token =~ ^\"[A-Za-z0-9_.-]{1,128}\"$ ]] || return 64
  [[ -z ${S3_ENDPOINT_URL:-} ]] ||
    options=(--endpoint-url "$S3_ENDPOINT_URL")
  certbotbot_command_aws "${options[@]}" s3api delete-object \
    --bucket "$bucket" --key "$key" \
    --if-match "$token" >/dev/null 2>&1 || return 69
}

## @fn certbotbot_latest_probe()
## @brief Compare an exact latest object to a conditional ETag-bound read.
## @details
## The typed ADR-039 GetObject classifier distinguishes NoSuchKey from
## denied/error responses. If present, HEAD and If-Match GET must refer
## to the same body. Values are returned through probe globals rather than
## stdout and are replaced on every invocation. Caller owns the private
## directory; no remote mutations occur.
## @param bucket Validated S3 bucket.
## @param key Canonical latest key.
## @param directory Empty owner-private work directory.
## @retval 0 Current object bound to its opaque ETag, SHA-256, and size.
## @retval 10 Object was positively confirmed absent by typed GetObject.
## @retval 64 Invalid scope or unsafe directory.
## @retval 69 Indeterminate remote response, absent-after-HEAD, or conflict.
## @retval 73 Private filesystem/hash failure.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_latest_probe() {
  local bucket=${1:-} key=${2:-} root=${3:-}
  local path='' bound='' etag='' code=0 size=''
  local -a options=()
  (( $# == 3 )) || return 64
  certbotbot_latest_validate_key "$bucket" "$key" || return 64
  [[ $root == "${CERTBOTBOT_WORKSPACE_ROOT:-}"/latest-*.???????? &&
    -d $root && ! -L $root && -O $root &&
    "$(stat -c '%a' -- "$root")" == 700 &&
    -z ${CERTBOTBOT_S3_STAGE_ROOT:-} ]] || return 64
  CERTBOTBOT_LATEST_PROBE_PRESENT=''
  CERTBOTBOT_LATEST_PROBE_ETAG=''
  CERTBOTBOT_LATEST_PROBE_SHA256=''
  CERTBOTBOT_LATEST_PROBE_SIZE=''
  path="$(mktemp -- "$root/object.XXXXXXXX")" || return 73
  CERTBOTBOT_S3_STAGE_ROOT=$root
  if certbotbot_s3_get_classified "$bucket" "$key" "$path"; then
    code=0
  else
    code=$?
  fi
  CERTBOTBOT_S3_STAGE_ROOT=''
  if (( code != 0 )); then
    rm -f -- "$path" || return 73
    if (( code == 10 )); then
      CERTBOTBOT_LATEST_PROBE_PRESENT=0
    fi
    return "$code"
  fi
  if [[ -n ${S3_ENDPOINT_URL:-} ]]; then
    options=(--endpoint-url "$S3_ENDPOINT_URL")
  fi
  etag="$(certbotbot_command_aws "${options[@]}" s3api head-object \
    --bucket "$bucket" --key "$key" \
    --query ETag --output text 2>/dev/null)" || {
    rm -f -- "$path" || return 73
    return 69
  }
  if [[ ! $etag =~ ^\"[A-Za-z0-9_.-]{1,128}\"$ ]]; then
    rm -f -- "$path" || return 73
    return 69
  fi
  bound="$(mktemp -- "$root/object.XXXXXXXX")" || {
    rm -f -- "$path" || return 73
    return 73
  }
  if ! certbotbot_command_aws "${options[@]}" s3api get-object \
    --bucket "$bucket" --key "$key" --if-match "$etag" \
    "$bound" >/dev/null 2>&1; then
    rm -f -- "$path" "$bound" || return 73
    return 69
  fi
  if [[ ! -s $bound || -L $bound || ! -O $bound ||
    "$(stat -c '%a' -- "$bound")" != 600 ]]; then
    rm -f -- "$path" "$bound" || return 73
    return 69
  fi
  size="$(stat -c '%s' -- "$bound")" || {
    rm -f -- "$path" "$bound" || return 73
    return 73
  }
  CERTBOTBOT_LATEST_PROBE_SHA256="$(certbotbot_checkpoint_hash "$bound")" || {
    rm -f -- "$path" "$bound" || return 73
    return 73
  }
  rm -f -- "$path" "$bound" || return 73
  CERTBOTBOT_LATEST_PROBE_PRESENT=1
  CERTBOTBOT_LATEST_PROBE_ETAG=$etag
  CERTBOTBOT_LATEST_PROBE_SIZE=$size
  return 0
}

## @fn certbotbot_latest_publish()
## @brief Perform guarded sequential common-first publication of verified bytes.
## @details
## The caller must independently retain the completed recovery generation
## ID and manifest SHA-256 BEFORE enabling this function; an explicit
## acknowledgement binds that durable recovery token to the current plan.
## This internal entrypoint does not issue certificates or activate Certbot.
## On ambiguous or partial failure the recovery generation is retained and
## no automatic potentially unsafe rollback occurs.
## @retval 0 Every latest object was conditionally PUT and read-back checked.
## @retval 64 Missing authorization, recovery token, or stale local contract.
## @retval 65 Changed candidate/remote read-back body.
## @retval 69 Conflict or indeterminate S3 write/read.
## @retval 73 Local staging/cleanup failure.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_latest_publish() {
  local bucket='' env=${ACME_ENVIRONMENT:-production}
  local root='' key='' file='' digest='' status=0 i=0 count=0
  (( $# == 0 )) || return 64
  [[ $- != *x* && ${CERTBOTBOT_LATEST_WRITE_CONFIRM:-} == yes &&
    ${CERTBOTBOT_RECOVERY_WRITE_CONFIRM:-} == yes &&
    -z ${CERTBOTBOT_LATEST_PUBLISH_OUTCOME:-} &&
    ${CERTBOTBOT_RECOVERY_GENERATION:-} =~ ^[a-f0-9]{32}$ &&
    ${CERTBOTBOT_RECOVERY_MANIFEST_SHA256:-} =~ ^[a-f0-9]{64}$ &&
    -z ${CERTBOTBOT_RECOVERY_PENDING_GENERATION:-} &&
    ${CERTBOTBOT_LATEST_RECOVERY_ACK:-} == \
      "${CERTBOTBOT_RECOVERY_GENERATION}:${CERTBOTBOT_RECOVERY_MANIFEST_SHA256}" ]] ||
    return 64
  certbotbot_publication_plan_verify || return $?
  [[ ${CERTBOTBOT_LATEST_CONDITION_PLAN_SHA256:-} == \
    "$CERTBOTBOT_PLAN_DIGEST" ]] || return 64
  count=${#CERTBOTBOT_PUBLICATION_KEYS[@]}
  (( count >= 2 && count <= 33 &&
    ${#CERTBOTBOT_LATEST_CONDITION_KEYS[@]} == count &&
    ${#CERTBOTBOT_LATEST_CONDITION_VALUES[@]} == count &&
    ${#CERTBOTBOT_LATEST_CONDITION_KINDS[@]} == count )) || return 64
  bucket=$CERTBOTBOT_PUBLICATION_BUCKET
  certbotbot_recovery_verify "$bucket" "$env" \
    "$CERTBOTBOT_RECOVERY_GENERATION" \
    "$CERTBOTBOT_RECOVERY_MANIFEST_SHA256" || return $?
  for (( i=0; i<count; i++ )); do
    [[ "${CERTBOTBOT_LATEST_CONDITION_KEYS[i]}" == \
      "${CERTBOTBOT_PUBLICATION_KEYS[i]}" ]] || return 64
  done
  root="$(mktemp -d -- \
    "$CERTBOTBOT_WORKSPACE_ROOT/latest-write.XXXXXXXX")" || return 73
  CERTBOTBOT_LATEST_PUBLISH_OUTCOME=partial
  for (( i=0; i<count; i++ )); do
    key=${CERTBOTBOT_PUBLICATION_KEYS[i]}
    file=${CERTBOTBOT_PUBLICATION_FILES[i]}
    certbotbot_latest_conditional_put "$bucket" "$key" "$file" \
      "${CERTBOTBOT_LATEST_CONDITION_KINDS[i]}" \
      "${CERTBOTBOT_LATEST_CONDITION_VALUES[i]}" || {
        status=$?
        break
      }
    # A successful API response is not proof of durable bytes.
    certbotbot_latest_probe "$bucket" "$key" "$root" || {
      status=$?
      break
    }
    if [[ ${CERTBOTBOT_LATEST_PROBE_PRESENT:-} != 1 ||
      ${CERTBOTBOT_LATEST_PROBE_SHA256:-} != \
        "${CERTBOTBOT_PLAN_NEW_DIGESTS[i]}" ||
      ${CERTBOTBOT_LATEST_PROBE_SIZE:-} != \
        "${CERTBOTBOT_PLAN_NEW_SIZES[i]}" ]]; then
      status=65
      break
    fi
  done
  rm -rf -- "$root" || return 73
  (( status == 0 )) || return "$status"
  CERTBOTBOT_LATEST_PUBLISH_OUTCOME=complete
  return 0
}

## @fn certbotbot_latest_recover()
## @brief Safely restore a saved generation after partial latest-key writes.
## @details
## The new runner requires only a trusted generation manifest SHA-256,
## bucket/authority, and the remote ADR-047 generation. A full preflight
## examines ALL latest keys before modifying any. Each current key must
## equal either the saved old bytes (already recovered) or proposed new
## bytes (eligible for revert). Any unrelated state aborts the whole
## attempt. Actual reversions use If-Match conditions against the freshly
## verified current object, and run in reverse order (domains, then common).
## Restoring originally absent keys uses conditional DeleteObject; this
## must be explicitly permitted and supported by the selected backend.
## Uncertain outcomes leave the remote recovery generation untouched.
## @param bucket Reviewed S3 bucket.
## @param environment Exact ACME environment.
## @param generation Completed ADR-047 generation ID.
## @param expected_sha256 Trusted out-of-band recovery manifest hash.
## @retval 0 Selected latest aliases match the saved prior state.
## @retval 64 No authorization, invalid identity, or bad manifest grammar.
## @retval 65 Some remote latest object is neither prior nor proposed bytes.
## @retval 69 Denial/conflict/unknown remote write or fetch.
## @retval 73 Local temporary-file failure.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_latest_recover() {
  local bucket=${1:-} env=${2:-} generation=${3:-}
  local expected=${4:-} root='' manifest='' row='' key='' tag=''
  local number='' present='' oldhash='' oldsize='' newhash='' newsize=''
  local extra='' file='' recovery_key='' status=0 count=0 i=0
  local mode='' suffix='' prefix='' leaf='' name=''
  local -a rows=() keys=() old_present=() old_hashes=()
  local -a old_sizes=() new_hashes=() new_sizes=()
  local -a states=() etags=()
  (( $# == 4 )) || return 64
  [[ $- != *x* &&
    ${CERTBOTBOT_LATEST_ROLLBACK_CONFIRM:-} == yes &&
    $env == "${ACME_ENVIRONMENT:-production}" &&
    $generation =~ ^[a-f0-9]{32}$ &&
    $expected =~ ^[a-f0-9]{64}$ &&
    -n ${CERTBOTBOT_WORKSPACE_ROOT:-} &&
    -d $CERTBOTBOT_WORKSPACE_ROOT &&
    ! -L $CERTBOTBOT_WORKSPACE_ROOT &&
    -O $CERTBOTBOT_WORKSPACE_ROOT &&
    "$(stat -c '%a' -- "$CERTBOTBOT_WORKSPACE_ROOT")" == 700 ]] ||
    return 64
  certbotbot_acme_validate_environment "$env" || return 64
  certbotbot_recovery_verify "$bucket" "$env" "$generation" "$expected" ||
    return $?
  root="$(mktemp -d -- \
    "$CERTBOTBOT_WORKSPACE_ROOT/latest-recover.XXXXXXXX")" || return 73
  manifest="$(mktemp -- "$root/object.XXXXXXXX")" || status=73
  if (( status == 0 )); then
    recovery_key="$(certbotbot_recovery_key "$env" \
      "$generation" manifest.tsv)" || status=64
  fi
  if (( status == 0 )); then
    certbotbot_recovery_s3_get "$bucket" "$recovery_key" "$manifest" ||
      status=$?
  fi
  if (( status == 0 )); then
    [[ "$(certbotbot_checkpoint_hash "$manifest")" == "$expected" ]] ||
      status=65
  fi
  if (( status == 0 )); then
    mapfile -t rows <"$manifest" || status=73
    (( ${#rows[@]} >= 6 && ${#rows[@]} <= 37 )) || status=64
  fi
  if (( status == 0 )); then
    [[ "${rows[0]}" == $'certbotbot-prepublication-plan\t1' &&
      "${rows[1]}" == "environment"$'\t'"$env" &&
      "${rows[2]}" == "bucket"$'\t'"$bucket" ]] || status=64
    IFS=$'\t' read -r tag count extra <<<"${rows[3]}"
    [[ $tag == objects && $count =~ ^[0-9]+$ &&
      -z $extra ]] || status=64
    if (( status == 0 )); then
      (( count >= 2 && count <= 33 &&
        ${#rows[@]} == count+4 )) || status=64
    fi
  fi
  [[ $env == staging ]] && prefix=staging/
  if (( status == 0 )); then
    for (( i=0; i<count; i++ )); do
      row=${rows[i+4]}
      IFS=$'\t' read -r tag number key present oldhash \
        oldsize newhash newsize extra <<<"$row"
      if [[ $tag != object || $number != "$i" ||
        -n $extra || ! $newhash =~ ^[a-f0-9]{64}$ ||
        ! $newsize =~ ^[0-9]+$ || ! $oldsize =~ ^[0-9]+$ ||
        $key != "$prefix"* ]] ||
        ! certbotbot_latest_validate_key "$bucket" "$key"; then
        status=64
        break
      fi
      if (( i == 0 )); then
        [[ $key == "$prefix"common-latest.tar.gz ||
          $key == "$prefix"common-latest.tar.gz.enc ]] || {
          status=64
          break
        }
        suffix=${key##*.}
      else
        [[ ${key##*.} == "$suffix" ]] || {
          status=64
          break
        }
      fi
      case "$present" in
        0)
          [[ $oldhash == '-' && $oldsize == 0 ]] || {
            status=64
            break
          }
          ;;
        1)
          [[ $oldhash =~ ^[a-f0-9]{64}$ &&
            $oldsize -gt 0 ]] || {
            status=64
            break
          }
          ;;
        *)
          status=64
          break
          ;;
      esac
      keys+=("$key")
      old_present+=("$present")
      old_hashes+=("$oldhash")
      old_sizes+=("$oldsize")
      new_hashes+=("$newhash")
      new_sizes+=("$newsize")
    done
  fi
  # Full conflict preflight occurs before the first rollback operation.
  if (( status == 0 )); then
    for (( i=0; i<count; i++ )); do
      key=${keys[i]}
      if certbotbot_latest_probe "$bucket" "$key" "$root"; then
        :
      else
        status=$?
        if (( status == 10 )); then
          if [[ ${old_present[i]} == 0 ]]; then
            states+=(old)
            etags+=('')
            status=0
            continue
          fi
          status=65
        fi
        break
      fi
      if [[ ${old_present[i]} == 1 &&
        $CERTBOTBOT_LATEST_PROBE_SHA256 == \
          "${old_hashes[i]}" &&
        $CERTBOTBOT_LATEST_PROBE_SIZE == "${old_sizes[i]}" ]]; then
        states+=(old)
        etags+=('')
      elif [[ $CERTBOTBOT_LATEST_PROBE_SHA256 == \
        "${new_hashes[i]}" &&
        $CERTBOTBOT_LATEST_PROBE_SIZE == "${new_sizes[i]}" ]]; then
        states+=(new)
        etags+=("$CERTBOTBOT_LATEST_PROBE_ETAG")
      else
        status=65
        break
      fi
    done
  fi
  if (( status == 0 )); then
    for (( i=count-1; i>=0; i-- )); do
      [[ ${states[i]} == new ]] || continue
      key=${keys[i]}
      # Re-check the new ETag and body immediately before rollback. If
      # another writer replaced this key, never overwrite their change.
      if ! certbotbot_latest_probe "$bucket" "$key" "$root"; then
        status=69
        break
      fi
      if [[ $CERTBOTBOT_LATEST_PROBE_ETAG != "${etags[i]}" ||
        $CERTBOTBOT_LATEST_PROBE_SHA256 != "${new_hashes[i]}" ||
        $CERTBOTBOT_LATEST_PROBE_SIZE != "${new_sizes[i]}" ]]; then
        status=65
        break
      fi
      if [[ ${old_present[i]} == 1 ]]; then
        file="$(mktemp -- "$root/object.XXXXXXXX")" || {
          status=73
          break
        }
        recovery_key="$(certbotbot_recovery_key "$env" "$generation" \
          "$i.prior")" || {
          status=64
          break
        }
        certbotbot_recovery_s3_get "$bucket" "$recovery_key" "$file" || {
          status=$?
          break
        }
        if [[ "$(certbotbot_checkpoint_hash "$file")" != \
          "${old_hashes[i]}" ||
          "$(stat -c '%s' -- "$file")" != "${old_sizes[i]}" ]]; then
          status=65
          break
        fi
        certbotbot_latest_conditional_put "$bucket" "$key" "$file" \
          etag "${etags[i]}" || {
          status=$?
          break
        }
      else
        certbotbot_latest_conditional_delete "$bucket" "$key" \
          "${etags[i]}" || {
          status=$?
          break
        }
      fi
      # Prove the restored object or its absence, including lost responses
      # in the previous step (which are never silently treated as success).
      if certbotbot_latest_probe "$bucket" "$key" "$root"; then
        if [[ ${old_present[i]} != 1 ||
          $CERTBOTBOT_LATEST_PROBE_SHA256 != "${old_hashes[i]}" ||
          $CERTBOTBOT_LATEST_PROBE_SIZE != "${old_sizes[i]}" ]]; then
          status=65
          break
        fi
      else
        status=$?
        if (( status == 10 )) && [[ ${old_present[i]} == 0 ]]; then
          status=0
        else
          break
        fi
      fi
    done
  fi
  rm -rf -- "$root" || return 73
  return "$status"
}
