#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/retention.bash
## @brief Applies ADR-034 retention only to fully proven managed S3 copies.
## @details
## This implementation has no scheduled or automatic deletion authority.
## A positive, separately validated count opts into conditional deletion only
## following an acknowledged current PUT and a confirmed dated-backup PUT.
## Enumerating an entire S3 bucket, adopting an old template, deleting the
## current key, and deleting version IDs are explicitly forbidden.
##
## ListObjectsV2 uses fixed JMESPath to encode one page into a bounded scalar
## line with explicit fields. URL-encoded keys containing any percent-escape
## are rejected instead of decoded, preventing unsafe delimiters in Bash.
## Every listed candidate is structurally checked, then independently HEAD
## verified before a *single* deletion is issued. Metadata and S3 ETags do
## not authenticate a writer; externally coordinated IAM permissions remain
## a required boundary. This module never logs raw S3 output or object keys.

## @fn certbotbot_retention_error()
## @brief Emit a fixed retention-stage diagnostic.
## @param status Defined nonzero exit status, 64 or 74.
## @param message Static error description without untrusted object data.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## One nonsecret diagnostic.
## @retval 64 Invalid retention configuration before remote work.
## @retval 74 Current/backup confirmed but retention failed or is uncertain.
certbotbot_retention_error() {
  printf 'certbotbot: %s\n' "$2" >&2
  return "$1"
}

## @fn certbotbot_retention_date_valid()
## @brief Validate a candidate eight-digit Gregorian UTC date without clock IO.
## @param date Eight byte YYYYMMDD string from an untrusted S3 key.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @retval 0 The date is Gregorian-valid, including leap years.
## @retval 1 The date is incomplete, nondecimal or impossible.
certbotbot_retention_date_valid() {
  local value="$1" year month day maxday
  [[ "$value" =~ ^[0-9]{8}$ ]] || return 1
  year=$((10#${value:0:4}))
  month=$((10#${value:4:2}))
  day=$((10#${value:6:2}))
  (( year > 0 && month > 0 && month < 13 && day > 0 )) || return 1
  case "$month" in
    4|6|9|11) maxday=30 ;;
    2)
      maxday=28
      if (( year % 400 == 0 || (year % 4 == 0 && year % 100 != 0) )); then
        maxday=29
      fi
      ;;
    *) maxday=31 ;;
  esac
  (( day <= maxday ))
}

## @fn certbotbot_retention_preflight()
## @brief Validate destructive scope and AWS CLI capabilities before S3 IO.
## @details
## A count of zero does nothing. Positive retention requires a single
## contiguous {YEAR}{MONTH}{DOM}, a >=4 byte anchored literal prefix
## ending in - or _, and a single literal safe tar.gz suffix. Filename
## publication under ADR-032 intentionally permits a wider template set;
## that freedom does not grant the right to enumerate or delete old objects.
## The exact selected date/name must match this namespace and be different
## from the authoritative current key. AWS skeleton feature probes are local:
## unsupported conditional deletion fails before any S3 read or write.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Static configuration error on failure.
## @returns Frozen CERTBOTBOT_RETENTION_PREFIX and _SUFFIX.
## @retval 0 A zero count or bounded eligible namespace.
## @retval 64 Invalid count, template, backend or CLI capabilities.
certbotbot_retention_preflight() {
  local marker='{YEAR}{MONTH}{DOM}' template prefix suffix skeleton
  if [[ "${CERTBOTBOT_BACKUP_RETENTION_COUNT:-0}" == 0 ]]; then return 0; fi
  [[ "$CERTBOTBOT_DATED_BACKUP_ENABLED" == true &&
    "$CERTBOTBOT_BACKUP_RETENTION_COUNT" =~ ^[1-9][0-9]*$ &&
    ${#CERTBOTBOT_BACKUP_RETENTION_COUNT} -le 5 ]] ||
    { certbotbot_retention_error 64 'invalid retention opt-in'; return 64; }
  (( 10#$CERTBOTBOT_BACKUP_RETENTION_COUNT <= 10000 )) ||
    { certbotbot_retention_error 64 'retention count exceeds limit'; return 64; }
  template="$CERTBOTBOT_BACKUP_KEY_TEMPLATE"
  [[ "$template" == *"$marker"* ]] ||
    { certbotbot_retention_error 64 'retention template is not safely scoped'; return 64; }
  prefix="${template%%"$marker"*}"
  suffix="${template#*"$marker"}"
  if [[ ! "$prefix" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{2,}[-_]$ ||
    ! "$suffix" =~ ^[A-Za-z0-9._-]*\.tar\.gz$ ||
    "$suffix" == *..* ||
    "$suffix" == *'{'* || "$suffix" == *'}'* ||
    "$CERTBOTBOT_BACKUP_KEY" != "$prefix$CERTBOTBOT_FILENAME_DATE$suffix" ||
    "$CERTBOTBOT_BACKUP_KEY" == "$CERTBOTBOT_S3_KEY" ]] ||
    ! certbotbot_retention_date_valid "$CERTBOTBOT_FILENAME_DATE"; then
    certbotbot_retention_error 64 'retention template is not safely scoped'
    return 64
  fi
  [[ "$CERTBOTBOT_ARCHIVE_ENCRYPTION" == none ||
    "$CERTBOTBOT_ARCHIVE_ENCRYPTION" == gpg-ocb ]] ||
    { certbotbot_retention_error 64 'unsupported retention archive mode'; return 64; }
  if ! command -v aws >/dev/null 2>&1; then
    certbotbot_retention_error 64 'retention requires compatible AWS CLI'
    return 64
  fi
  skeleton="$(aws --no-cli-pager s3api delete-object \
    --generate-cli-skeleton input 2>/dev/null)" || {
    certbotbot_retention_error 64 'conditional S3 deletion unavailable'
    return 64
  }
  [[ "$skeleton" == *'"IfMatch"'* ]] || {
    certbotbot_retention_error 64 'conditional S3 deletion unavailable'
    return 64
  }
  skeleton="$(aws --no-cli-pager s3api list-objects-v2 \
    --generate-cli-skeleton input 2>/dev/null)" || {
    certbotbot_retention_error 64 'scoped S3 listing unavailable'
    return 64
  }
  [[ "$skeleton" == *'"ContinuationToken"'* &&
    "$skeleton" == *'"EncodingType"'* ]] || {
    certbotbot_retention_error 64 'scoped S3 listing unavailable'
    return 64
  }
  CERTBOTBOT_RETENTION_PREFIX="$prefix"
  CERTBOTBOT_RETENTION_SUFFIX="$suffix"
}

## @fn certbotbot_retention_apply()
## @brief Validate complete listing, HEAD all matches, then conditionally prune.
## @details
## The existing AWS CLI renders one JMESPath scalar with five separators:
## truncated | token | page key count | encoding | prefix | comma keys.
## Requesting URL encoding ensures troublesome delimiter characters inside
## S3 keys are percent-encoded. Such keys fail the entire preflight, rather
## than being unescaped, split or accidentally adopted. A fixed query,
## explicit --no-paginate, strict schema, token-cycle detection and byte
## limits prevent incomplete or ambiguous pages from leading to deletion.
##
## After the entire listing is checked, verify every exact date-shaped key
## through an independent managed v1 HeadObject, retaining its ETag. Sort
## verified copies by name-encoded UTC date, preserve newest N and this
## invocation's confirmed backup, and delete provisional old keys *oldest*
## first using the captured ETag as an S3 IfMatch precondition. An accepted
## DeleteObject must subsequently be confirmed absent by exact-key HEAD.
## Any uncertain result stops further mutation with no rollback.
## @param workspace Caller-owned absolute private mode-0700 workspace.
## @param bucket Existing selected S3 bucket; never list globally.
## @param current Frozen exact authoritative key, protected from deletion.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed nonsecret partial-success diagnostics only.
## @returns CERTBOTBOT_RETENTION_DELETED confirmed deletion count.
## @retval 0 No retention requested, or full guarded cleanup succeeded.
## @retval 74 After current/backup confirmed, cleanup failed or is uncertain.
certbotbot_retention_apply() {
  local workspace="$1" bucket="$2" current="$3" key date middle
  local row truncated next count encoding listed_prefix csv pipes
  local token='' pages=0 total=0 page_count confirmed=false
  local published_etag="$CERTBOTBOT_BACKUP_ETAG" size field record
  local -a args=() keys=() matches=() sorted_keys=() sorted_etags=()
  local -a ordered=() targets=() target_etags=()
  local -A seen=() seen_tokens=() seen_dates=()
  CERTBOTBOT_RETENTION_DELETED=0
  if [[ "${CERTBOTBOT_BACKUP_RETENTION_COUNT:-0}" == 0 ]]; then return 0; fi
  if [[ "$CERTBOTBOT_S3_PUBLISHED" != true ||
    "$CERTBOTBOT_S3_BACKUP_STATUS" != confirmed ||
    -z "$CERTBOTBOT_BACKUP_KEY" ||
    "$CERTBOTBOT_BACKUP_KEY" == "$current" ||
    -z "$CERTBOTBOT_RETENTION_PREFIX" ||
    -z "$CERTBOTBOT_RETENTION_SUFFIX" ||
    -z "$CERTBOTBOT_BACKUP_KEY_HASH" ||
    -z "$published_etag" ]]; then
    certbotbot_retention_error 74 'current accepted; backup confirmed; retention gate unavailable'
    return 74
  fi
  # Every destination is private and newly allocated. No symlink may replace
  # the plan or sorted view used by a process holding destructive authority.
  for field in .retention-plan .retention-sorted; do
    [[ ! -e "$workspace/$field" && ! -L "$workspace/$field" ]] || {
      certbotbot_retention_error 74 'current accepted; backup confirmed; retention workspace unsafe'
      return 74
    }
  done
  if ! (umask 077; : >"$workspace/.retention-plan" &&
    : >"$workspace/.retention-sorted"); then
    certbotbot_retention_error 74 'current accepted; backup confirmed; retention workspace unavailable'
    return 74
  fi

  # AWS CLI is the only runtime parser dependency. The JMESPath expression
  # always emits one scalar, never JSON or delimiter-unsafe raw keys.
  while :; do
    (( pages < 1000 )) || {
      certbotbot_retention_error 74 'current accepted; backup confirmed; retention listing exceeded limits'
      return 74
    }
    (( pages+=1 ))
    args=()
    if [[ -n "$token" ]]; then args=(--continuation-token "$token"); fi
    if ! row="$(aws --no-cli-pager s3api list-objects-v2 \
      --bucket "$bucket" --prefix "$CERTBOTBOT_RETENTION_PREFIX" \
      --encoding-type url --max-keys 1000 --no-paginate \
      "${args[@]}" \
      --query "join('|', [to_string(IsTruncated), to_string(NextContinuationToken), to_string(KeyCount), to_string(EncodingType), to_string(Prefix), join(',', not_null(Contents[].Key, \`[]\`))])" \
      --output text 2>/dev/null)"; then
      certbotbot_retention_error 74 'current accepted; backup confirmed; retention listing failed'
      return 74
    fi
    pipes="${row//[^|]/}"
    if (( ${#row} > 270000 || ${#pipes} != 5 )) ||
      [[ "$row" == *$'\n'* || "$row" == *$'\r'* ]]; then
      certbotbot_retention_error 74 'current accepted; backup confirmed; retention listing is ambiguous'
      return 74
    fi
    IFS='|' read -r truncated next count encoding listed_prefix csv <<< "$row"
    if [[ "$encoding" != url ||
      "$listed_prefix" != "$CERTBOTBOT_RETENTION_PREFIX" ||
      ! "$count" =~ ^(0|[1-9][0-9]{0,3})$ ]] ||
      (( 10#$count > 1000 )) ||
      [[ "$truncated" != true && "$truncated" != false ]]; then
      certbotbot_retention_error 74 'current accepted; backup confirmed; retention listing is malformed'
      return 74
    fi
    keys=()
    if [[ -n "$csv" ]]; then
      if [[ "$csv" == ,* || "$csv" == *, || "$csv" == *,,* ]]; then
        certbotbot_retention_error 74 'current accepted; backup confirmed; retention keys are malformed'
        return 74
      fi
      IFS=, read -r -a keys <<< "$csv"
    fi
    page_count=${#keys[@]}
    if (( page_count != 10#$count || total + page_count > 100000 )); then
      certbotbot_retention_error 74 'current accepted; backup confirmed; retention listing is incomplete'
      return 74
    fi
    (( total+=page_count ))
    for key in "${keys[@]}"; do
      # URL encoding prevents delimiter injection, but any escaped/unusual
      # key conservatively aborts instead of allowing a lossy comparison.
      if [[ ! "$key" =~ ^[A-Za-z0-9._-]+$ ||
        "$key" != "$CERTBOTBOT_RETENTION_PREFIX"* ||
        -n "${seen[$key]+x}" ]]; then
        certbotbot_retention_error 74 'current accepted; backup confirmed; retention namespace is ambiguous'
        return 74
      fi
      seen[$key]=1
      # Other names in the restricted prefix are not part of the policy.
      [[ "$key" == "$CERTBOTBOT_RETENTION_PREFIX"*"$CERTBOTBOT_RETENTION_SUFFIX" ]] ||
        continue
      middle="${key#"$CERTBOTBOT_RETENTION_PREFIX"}"
      middle="${middle%"$CERTBOTBOT_RETENTION_SUFFIX"}"
      [[ "$middle" =~ ^[0-9]{8}$ ]] || continue
      if [[ "$key" == "$current" ]] ||
        ! certbotbot_retention_date_valid "$middle" ||
        [[ "$middle" > "$CERTBOTBOT_FILENAME_DATE" ||
          -n "${seen_dates[$middle]+x}" ]]; then
        certbotbot_retention_error 74 'current accepted; backup confirmed; retention date is ambiguous'
        return 74
      fi
      seen_dates[$middle]=1
      matches+=("$key")
    done
    if [[ "$truncated" == false ]]; then
      if [[ "$next" != null && "$next" != None ]]; then
        certbotbot_retention_error 74 'current accepted; backup confirmed; unexpected continuation'
        return 74
      fi
      break
    fi
    if [[ ! "$next" =~ ^[A-Za-z0-9+/=_-]{1,1024}$ ||
      "$next" == null || "$next" == None ||
      -n "${seen_tokens[$next]+x}" ]]; then
      certbotbot_retention_error 74 'current accepted; backup confirmed; invalid continuation'
      return 74
    fi
    seen_tokens[$next]=1
    token="$next"
  done

  # The complete listing is now frozen. No deletions until *all* HEAD
  # responses and all ownership/size/ETag fields have been checked.
  local etag
  for key in "${matches[@]}"; do
    middle="${key#"$CERTBOTBOT_RETENTION_PREFIX"}"
    date="${middle%"$CERTBOTBOT_RETENTION_SUFFIX"}"
    if ! certbotbot_backup_head "$workspace" "$bucket" "$key"; then
      rm -f -- "$workspace/.backup-head" "$workspace/.backup-error"
      certbotbot_retention_error 74 'current accepted; backup confirmed; retention HEAD failed'
      return 74
    fi
    row="$REPLY"
    rm -f -- "$workspace/.backup-head" "$workspace/.backup-error"
    if ! certbotbot_backup_head_valid "$row" 0 "$date"; then
      certbotbot_retention_error 74 'current accepted; backup confirmed; retention object identity unverified'
      return 74
    fi
    etag="$CERTBOTBOT_BACKUP_ETAG"
    if [[ "$key" == "$CERTBOTBOT_BACKUP_KEY" ]]; then
      if [[ "$etag" != "$published_etag" ||
        "$date" != "$CERTBOTBOT_FILENAME_DATE" ]]; then
        certbotbot_retention_error 74 'current accepted; backup confirmed; newest recovery identity changed'
        return 74
      fi
      confirmed=true
    fi
    printf '%s\t%s\t%s\n' "$date" "$key" "$etag" \
      >>"$workspace/.retention-plan" || return 74
  done
  if [[ "$confirmed" != true ]]; then
    certbotbot_retention_error 74 'current accepted; backup confirmed; newest recovery key missing'
    return 74
  fi
  if ! LC_ALL=C sort -r -T "$workspace" \
    "$workspace/.retention-plan" >"$workspace/.retention-sorted"; then
    certbotbot_retention_error 74 'current accepted; backup confirmed; retention ordering failed'
    return 74
  fi
  local index=0 fresh_kept=false
  while IFS=$'\t' read -r date key etag; do
    [[ -n "$date" && -n "$key" && -n "$etag" ]] || {
      certbotbot_retention_error 74 'current accepted; backup confirmed; retention plan malformed'
      return 74
    }
    if (( index < 10#$CERTBOTBOT_BACKUP_RETENTION_COUNT )); then
      if [[ "$key" == "$CERTBOTBOT_BACKUP_KEY" ]]; then fresh_kept=true; fi
    else
      targets+=("$key")
      target_etags+=("$etag")
    fi
    (( index+=1 ))
  done <"$workspace/.retention-sorted"
  if (( index != ${#matches[@]} )) || [[ "$fresh_kept" != true ]]; then
    certbotbot_retention_error 74 'current accepted; backup confirmed; retention plan not trusted'
    return 74
  fi

  # Oldest-first, exact key and stored ETag. Never retry on uncertainty
  # and never re-HEAD a changed object to choose a *new* precondition.
  local offset
  for (( offset=${#targets[@]}-1; offset >= 0; offset-- )); do
    key="${targets[$offset]}"
    etag="${target_etags[$offset]}"
    if [[ "$key" == "$current" || "$key" == "$CERTBOTBOT_BACKUP_KEY" ||
      "$etag" == '*' || -z "$etag" ]]; then
      certbotbot_retention_error 74 'current accepted; backup confirmed; retention target unsafe'
      return 74
    fi
    if ! aws --no-cli-pager s3api delete-object --bucket "$bucket" \
      --key "$key" --if-match "$etag" --output json \
      >/dev/null 2>/dev/null; then
      certbotbot_retention_error 74 'current accepted; backup confirmed; retention delete failed or uncertain'
      return 74
    fi
    if certbotbot_backup_head "$workspace" "$bucket" "$key"; then
      rm -f -- "$workspace/.backup-head" "$workspace/.backup-error"
      certbotbot_retention_error 74 'current accepted; backup confirmed; retention deletion unconfirmed'
      return 74
    fi
    if [[ ! -f "$workspace/.backup-error" ]] ||
      ! grep -Eq '\((404|NoSuchKey)\)' "$workspace/.backup-error" ||
      ! aws --no-cli-pager s3api head-bucket --bucket "$bucket" \
        --output json >/dev/null 2>/dev/null; then
      rm -f -- "$workspace/.backup-head" "$workspace/.backup-error"
      certbotbot_retention_error 74 'current accepted; backup confirmed; retention deletion uncertain'
      return 74
    fi
    rm -f -- "$workspace/.backup-head" "$workspace/.backup-error"
    (( CERTBOTBOT_RETENTION_DELETED+=1 ))
  done
  return 0
}
