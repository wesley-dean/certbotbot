#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/backup.bash
## @brief Performs guarded, opt-in dated S3 backup publication.
## @details
## Implements ADR-033. The selected existing archive remains authoritative.
## This module verifies managed metadata, conditions every backup PUT on the
## exact destination's prior identity, and confirms the resulting object size
## and metadata through HEAD. It never lists, deletes or migrates objects.
## S3 metadata is untrusted; IAM protections and externally serialized writers
## are essential. No two-object transaction is promised.

## @fn certbotbot_backup_error()
## @brief Report a static backup failure without exposing AWS or secret data.
## @param message Fixed nonsecret diagnostic text.
## @param status 64 for local settings, 69 for inspection, 74 for partial PUT.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed diagnostic text.
## @retval 64 Local configuration error.
## @retval 69 Uncertain remote preflight.
## @retval 74 Current accepted but backup failed/uncertain.
certbotbot_backup_error() {
  printf 'certbotbot: %s\n' "$1" >&2
  return "$2"
}

## @fn certbotbot_backup_scope()
## @brief Build nonsecret v1 metadata binding the current key and UTC date.
## @param current Frozen authoritative object key.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed error if SHA256 is unavailable.
## @returns CERTBOTBOT_BACKUP_METADATA and the expected current-key digest.
## @retval 0 Complete metadata prepared.
## @retval 64 Invalid identity or missing trusted hashing tool.
certbotbot_backup_scope() {
  local current="$1" digest
  [[ -n "$current" && "${CERTBOTBOT_FILENAME_DATE:-}" =~ ^[0-9]{8}$ ]] ||
    { certbotbot_backup_error 'dated backup identity unavailable' 64; return 64; }
  case "$CERTBOTBOT_ARCHIVE_ENCRYPTION" in
    none|gpg-ocb) CERTBOTBOT_BACKUP_ENCRYPTION="$CERTBOTBOT_ARCHIVE_ENCRYPTION" ;;
    *) certbotbot_backup_error 'unsupported backup encryption mode' 64; return 64 ;;
  esac
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s' "$current" | sha256sum)" || return 64
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s' "$current" | shasum -a 256)" || return 64
  else
    certbotbot_backup_error 'SHA-256 tooling unavailable for backup scope' 64
    return 64
  fi
  digest="${digest%% *}"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] ||
    { certbotbot_backup_error 'invalid backup scope digest' 64; return 64; }
  CERTBOTBOT_BACKUP_KEY_HASH="$digest"
  CERTBOTBOT_BACKUP_METADATA="certbotbot-backup-schema=v1,certbotbot-utc-date=$CERTBOTBOT_FILENAME_DATE,certbotbot-current-key-sha256=$digest,certbotbot-archive-format=tar.gz,certbotbot-encryption=$CERTBOTBOT_BACKUP_ENCRYPTION"
}

## @fn certbotbot_backup_head()
## @brief Inspect one exact key and return seven bounded tab-delimited fields.
## @details
## Uses a fixed JMESPath query over S3 metadata, never eval or shell parsing
## of untrusted expressions. A 404 is available privately to the caller;
## unknown, malformed or multi-line responses must not authorize mutation.
## @param workspace Existing private workspace.
## @param bucket Exact selected bucket.
## @param key Exact resolved backup key.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## AWS stderr stays in private workspace, never exposed.
## @returns REPLY is the parsed text row on success.
## @retval 0 One bounded nonempty row.
## @retval 1 HeadObject failed, private stderr contains reason.
## @retval 2 Invalid output or occupied private paths.
certbotbot_backup_head() {
  local workspace="$1" bucket="$2" key="$3" row
  [[ ! -e "$workspace/.backup-head" && ! -L "$workspace/.backup-head" &&
    ! -e "$workspace/.backup-error" && ! -L "$workspace/.backup-error" ]] || return 2
  if ! (umask 077; : >"$workspace/.backup-head" &&
    : >"$workspace/.backup-error"); then return 2; fi
  if ! aws --no-cli-pager s3api head-object --bucket "$bucket" --key "$key" \
    --query '[ETag,ContentLength,Metadata."certbotbot-backup-schema",Metadata."certbotbot-utc-date",Metadata."certbotbot-current-key-sha256",Metadata."certbotbot-archive-format",Metadata."certbotbot-encryption"]' \
    --output text >"$workspace/.backup-head" 2>"$workspace/.backup-error"; then
    return 1
  fi
  row="$(cat -- "$workspace/.backup-head")" || return 2
  [[ -n "$row" && "$row" != *$'\n'* && "$row" != *$'\r'* &&
    "${#row}" -le 700 ]] || return 2
  REPLY="$row"
}

## @fn certbotbot_backup_head_valid()
## @brief Validate the S3 v1 managed-object identity and payload length.
## @param row Untrusted AWS metadata row.
## @param expected_size 0 for positive-size preflight or exact post-PUT size.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @returns CERTBOTBOT_BACKUP_ETAG for conditional replacement.
## @retval 0 Identity, nonzero size, and safe ETag are confirmed.
## @retval 1 Unverified, mismatched or malformed fields.
certbotbot_backup_head_valid() {
  local row="$1" expected_size="$2"
  local etag size schema utc hash format encryption
  IFS=$'\t' read -r etag size schema utc hash format encryption <<< "$row"
  [[ "$etag" =~ ^\"[A-Za-z0-9_-]{1,128}\"$ &&
    "$size" =~ ^[1-9][0-9]*$ &&
    ( "$expected_size" == 0 || "$size" == "$expected_size" ) &&
    "$schema" == v1 && "$utc" == "$CERTBOTBOT_FILENAME_DATE" &&
    "$hash" == "$CERTBOTBOT_BACKUP_KEY_HASH" &&
    "$format" == tar.gz &&
    "$encryption" == "$CERTBOTBOT_BACKUP_ENCRYPTION" ]] || return 1
  CERTBOTBOT_BACKUP_ETAG="$etag"
}

## @fn certbotbot_backup_prepare()
## @brief Validate destination and conditional-write capability before current PUT.
## @details
## A 404 plus HeadBucket success authorizes only conditional creation.
## Present same-date managed metadata authorizes only ETag-conditional
## replacement. All other identities, CLI capabilities or AWS errors fail
## before the authoritative current object is modified.
## @param workspace Private workspace.
## @param bucket Current/backup bucket.
## @param current Authoritative exact key.
## @param backup Validated dated key.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Static diagnostics only.
## @retval 0 Guarded backup conditions prepared.
## @retval 64 Invalid local values.
## @retval 69 Missing capability or uncertain destination.
certbotbot_backup_prepare() {
  local workspace="$1" bucket="$2" current="$3" backup="$4" skeleton result
  CERTBOTBOT_BACKUP_PRECONDITION=''
  CERTBOTBOT_BACKUP_ETAG=''
  [[ -n "$bucket" && -n "$current" && -n "$backup" &&
    "$current" != "$backup" ]] ||
    { certbotbot_backup_error 'invalid dated backup destination' 64; return 64; }
  certbotbot_backup_scope "$current" || return $?
  skeleton="$(aws --no-cli-pager s3api put-object \
    --generate-cli-skeleton input 2>/dev/null)" || {
    certbotbot_backup_error 'conditional backup PUT unsupported by AWS CLI' 69
    return 69
  }
  [[ "$skeleton" == *'"IfMatch"'* &&
    "$skeleton" == *'"IfNoneMatch"'* ]] || {
    certbotbot_backup_error 'conditional backup PUT unsupported by AWS CLI' 69
    return 69
  }
  if certbotbot_backup_head "$workspace" "$bucket" "$backup"; then
    result="$REPLY"
    if ! certbotbot_backup_head_valid "$result" 0; then
      rm -f -- "$workspace/.backup-head" "$workspace/.backup-error"
      certbotbot_backup_error 'dated backup object is not safely managed' 69
      return 69
    fi
    CERTBOTBOT_BACKUP_PRECONDITION=match
  else
    if [[ ! -f "$workspace/.backup-error" ]] ||
      ! grep -Eq '\((404|NoSuchKey)\)' "$workspace/.backup-error" ||
      ! aws --no-cli-pager s3api head-bucket --bucket "$bucket" \
        --output json >/dev/null 2>/dev/null; then
      rm -f -- "$workspace/.backup-head" "$workspace/.backup-error"
      certbotbot_backup_error 'dated backup object cannot be inspected' 69
      return 69
    fi
    CERTBOTBOT_BACKUP_PRECONDITION=absent
  fi
  rm -f -- "$workspace/.backup-head" "$workspace/.backup-error"
}

## @fn certbotbot_backup_publish()
## @brief Write and verify the identical validated current candidate.
## @details
## The current authoritative PUT must already have succeeded. A failed PUT,
## lost response, conflicting conditional request, missing or uncertain HEAD
## results in a nonzero partial-success outcome and stops all later work.
## @param workspace Caller-owned private workspace.
## @param bucket Selected existing S3 bucket.
## @param backup Frozen dated key.
## @param candidate Exact locally verified candidate file.
## @param content_type Existing publisher's matching MIME type.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed, nonsecret partial-success diagnostic.
## @retval 0 Accepted backup PUT and matching HEAD metadata/size.
## @retval 74 Accepted current but failed or uncertain backup publication.
certbotbot_backup_publish() {
  local workspace="$1" bucket="$2" backup="$3" candidate="$4" content_type="$5"
  local row size
  local -a condition=()
  case "$CERTBOTBOT_BACKUP_PRECONDITION" in
    absent) condition=(--if-none-match '*') ;;
    match) condition=(--if-match "$CERTBOTBOT_BACKUP_ETAG") ;;
    *) certbotbot_backup_error 'current accepted; backup precondition unavailable' 74; return 74 ;;
  esac
  size="$(stat -c %s -- "$candidate" 2>/dev/null)" || return 74
  if ! aws --no-cli-pager s3api put-object --bucket "$bucket" --key "$backup" \
    --body "$candidate" --checksum-algorithm SHA256 \
    --content-type "$content_type" --metadata "$CERTBOTBOT_BACKUP_METADATA" \
    "${condition[@]}" --output json >/dev/null 2>&1; then
    certbotbot_backup_error 'current accepted; dated backup write failed or uncertain' 74
    return 74
  fi
  if ! certbotbot_backup_head "$workspace" "$bucket" "$backup"; then
    rm -f -- "$workspace/.backup-head" "$workspace/.backup-error"
    certbotbot_backup_error 'current accepted; dated backup confirmation failed' 74
    return 74
  fi
  row="$REPLY"
  rm -f -- "$workspace/.backup-head" "$workspace/.backup-error"
  if ! certbotbot_backup_head_valid "$row" "$size"; then
    certbotbot_backup_error 'current accepted; dated backup identity unverified' 74
    return 74
  fi
}
