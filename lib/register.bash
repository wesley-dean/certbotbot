#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/register.bash
## @brief Safely registers one Let's Encrypt account into one S3 archive.
## @details
## This registration-only workflow follows ADR-041.  Ordinary issue/renew
## never invoke these functions.  Private native Certbot account bytes are
## validated before a conditional single-object S3 write.  The separate
## ordinary selected-lineage packaging and publishing gates are unchanged.

## @fn certbotbot_register_fetch()
## @brief Stages an existing ETag-bound S3 object or confirms its absence.
## @details
## A 404 is accepted only after successful HeadBucket confirmation.  A
## matched GetObject binds downloaded bytes to the ETag later passed to the
## conditional update.  External diagnostics are discarded, not replayed.
## @param workspace Fresh private workspace owned by the caller.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @retval 0 Existing object staged or confirmed absent.
## @retval 69 AWS unavailable, invalid ETag, or ambiguous S3 read.
## @retval 74 Download or private staging failed.
certbotbot_register_fetch() {
  local workspace="$1" bucket="$CERTBOTBOT_S3_BUCKET" key="$CERTBOTBOT_S3_KEY"
  local error_file="$workspace/.s3-error"
  local target="$workspace/downloaded.tar.gz" observed
  CERTBOTBOT_REG_MISSING=false
  CERTBOTBOT_REG_ETAG=''
  command -v aws >/dev/null 2>&1 ||
    { certbotbot_error 'AWS CLI unavailable'; return 69; }
  if ! observed="$(aws --no-cli-pager s3api head-object \
    --bucket "$bucket" --key "$key" --query ETag --output text \
    2>"$error_file")"; then
    if grep -Eq '\((404|NoSuchKey)\)' "$error_file" &&
      aws --no-cli-pager s3api head-bucket --bucket "$bucket" \
        --output json >/dev/null 2>"$error_file"; then
      CERTBOTBOT_REG_MISSING=true
      rm -f -- "$error_file"
      return 0
    fi
    rm -f -- "$error_file"
    certbotbot_error 'S3 object state unavailable'
    return 69
  fi
  rm -f -- "$error_file"
  [[ "$observed" =~ ^\"[0-9a-fA-F]{32}(-[0-9]+)?\"$ ]] ||
    { certbotbot_error 'unsupported S3 object identity'; return 69; }
  CERTBOTBOT_REG_ETAG="$observed"
  if ! (umask 077; aws --no-cli-pager s3api get-object \
    --bucket "$bucket" --key "$key" --if-match "$observed" \
    --output json "$target" >/dev/null 2>"$error_file") ||
    [[ ! -s "$target" || -L "$target" ]]; then
    rm -f -- "$error_file" "$target"
    certbotbot_error 'matched S3 archive download failed'
    return 74
  fi
  rm -f -- "$error_file"
}

## @fn certbotbot_register_account_check()
## @brief Requires one recognized private Certbot account with matching email.
## @details
## Competing account IDs, foreign endpoint directories, unsafe metadata,
## and mismatched contact addresses fail before publication.  Installed
## Certbot is the authoritative local parser for its native account files;
## the bounded literal contact check is not a general-purpose JSON parser.
## @param config Isolated private Certbot configuration directory.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @retval 0 One recognized account matches the selected CA and contact.
## @retval 65 Missing, conflicting, or invalid account state.
certbotbot_register_account_check() {
  local config="$1" host="$1/accounts/$CERTBOTBOT_REG_HOST"
  local directory="$host/directory" account='' entry file count=0
  [[ -d "$directory" && ! -L "$directory" && -O "$directory" ]] ||
    return 65
  for entry in "$config/accounts/"*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    [[ "$entry" == "$host" && -d "$entry" && ! -L "$entry" ]] ||
      return 65
  done
  for entry in "$host/"*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    [[ "$entry" == "$directory" && -d "$entry" && ! -L "$entry" ]] ||
      return 65
  done
  for entry in "$directory/"*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    [[ -d "$entry" && ! -L "$entry" && -O "$entry" ]] || return 65
    count=$((count+1))
    (( count == 1 )) || return 65
    account="$entry"
  done
  (( count == 1 )) || return 65
  for file in private_key.json regr.json meta.json; do
    entry="$account/$file"
    [[ -f "$entry" && ! -L "$entry" && -s "$entry" &&
      -O "$entry" && -r "$entry" ]] || return 65
    if [[ "$file" == private_key.json ]]; then
      [[ -z "$(find "$entry" -perm /077 -print -quit 2>/dev/null)" ]] ||
        return 65
    else
      [[ -z "$(find "$entry" -perm /022 -print -quit 2>/dev/null)" ]] ||
        return 65
    fi
  done
  for entry in "$account/"*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    case "${entry##*/}" in
      private_key.json|regr.json|meta.json) ;;
      *) return 65 ;;
    esac
  done
  grep -Fq -- "\"mailto:$CERTBOTBOT_EMAIL\"" "$account/regr.json" ||
    return 65
  certbot --config-dir "$config" --work-dir "$CERTBOTBOT_REG_WORK" \
    --logs-dir "$CERTBOTBOT_REG_LOGS" --server "$CERTBOTBOT_REG_SERVER" \
    --non-interactive --no-directory-hooks show_account \
    --account "${account##*/}" >/dev/null 2>&1 || return 65
}

## @fn certbotbot_register_preflight()
## @brief Distinguishes a safe existing account from an accountless archive.
## @details
## Certbot's ordinary renewal parser is production-bound.  Production account
## archives may preserve multiple complete and canonical lineages.  Staging
## archives with renewal state are refused until separate issuer CA governance.
## A missing account with any lineage is never auto-associated with a new one.
## @param config Private configuration directory.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @retval 0 Safe archive and classified registration presence.
## @retval 65 Unsafe or unsupported account or certificate state.
certbotbot_register_preflight() {
  local config="$1" entry
  CERTBOTBOT_REG_PRESENT=false
  [[ "$config" == /* && -d "$config" && ! -L "$config" && -O "$config" &&
    "$(stat -c %a -- "$config" 2>/dev/null)" == 700 ]] || return 65
  certbotbot_state_hooks "$config" || return 65
  certbotbot_state_lineage "$config" "example.com" || return 65
  if [[ -e "$config/accounts" || -L "$config/accounts" ]]; then
    [[ -d "$config/accounts" && ! -L "$config/accounts" ]] || return 65
    for entry in "$config/accounts/"*; do
      [[ -e "$entry" || -L "$entry" ]] || continue
      [[ -d "$entry" && ! -L "$entry" &&
        "$entry" == "$config/accounts/$CERTBOTBOT_REG_HOST" ]] || return 65
      CERTBOTBOT_REG_PRESENT=true
    done
  fi
  if [[ "$CERTBOTBOT_REG_PRESENT" == true ]]; then
    certbotbot_register_account_check "$config" || return 65
    if [[ "$CERTBOTBOT_REG_HOST" == acme-v02.api.letsencrypt.org ]]; then
      certbotbot_state_canonical_all "$config" example.com || return 65
    else
      for entry in "$config/renewal/"*.conf; do
        [[ -e "$entry" || -L "$entry" ]] && return 65
      done
    fi
  else
    for entry in "$config/renewal/"*.conf; do
      [[ -e "$entry" || -L "$entry" ]] && return 65
    done
  fi
  return 0
}

## @fn certbotbot_register_package()
## @brief Serializes registered account state into the supported gzip tar.
## @details
## This registration-only packager does not weaken the selected certificate
## prerequisite of the ordinary issuer's separate archive packager.
## @param workspace Private workspace containing config and newly registered account.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @retval 0 Candidate passed the normal archive format gate.
## @retval 65 Unsafe account state or candidate.
## @retval 74 Local archive serialization unavailable.
certbotbot_register_package() {
  local workspace="$1" config="$1/config" staged
  local candidate="$1/candidate.tar.gz" unsafe
  [[ ! -e "$candidate" && ! -L "$candidate" ]] || return 65
  certbotbot_register_preflight "$config" ||
    { certbotbot_error 'account state failed final preflight'; return 65; }
  [[ "$CERTBOTBOT_REG_PRESENT" == true ]] || return 65
  unsafe="$(find "$config" -type d -perm /022 -print -quit 2>/dev/null)" ||
    return 65
  [[ -z "$unsafe" ]] || return 65
  unsafe="$(find "$config" -type f -perm /022 -print -quit 2>/dev/null)" ||
    return 65
  [[ -z "$unsafe" ]] || return 65
  command -v tar >/dev/null 2>&1 || return 74
  staged="$(umask 077; mktemp "$workspace/.candidate.XXXXXXXX")" || return 74
  if ! (umask 077; tar --format=ustar --sort=name --owner=0 \
    --group=0 --numeric-owner --gzip --create --file "$staged" \
    --directory "$config" . >/dev/null 2>&1) ||
    ! certbotbot_archive_validate "$staged" >/dev/null 2>&1 ||
    ! chmod 600 -- "$staged" || ! mv -T -- "$staged" "$candidate"; then
    rm -f -- "$staged"
    certbotbot_error 'account archive packaging failed'
    return 65
  fi
}

## @fn certbotbot_register_execute()
## @brief Registers or reuses one account and conditionally persists its state.
## @details
## Existing matching accounts never trigger a remote write.  New accounts
## must pass all local validators before conditional first-write or update.
## Failed S3 PUT results are uncertain and never reported as success.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Fixed nonsecret result status.
## @retval 0 Account reused or newly published.
## @retval 65 Unsafe account or archive state.
## @retval 69 Missing provider or ambiguous read.
## @retval 74 Certbot, local staging or S3 transfer failure.
certbotbot_register_execute() {
  local workspace config eff content body
  workspace="$(certbotbot_workspace_create)" || return $?
  CERTBOTBOT_ACTIVE_WORKSPACE="$workspace"
  trap 'rm -rf -- "$CERTBOTBOT_ACTIVE_WORKSPACE"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  CERTBOTBOT_REG_WORK="$workspace/work"
  CERTBOTBOT_REG_LOGS="$workspace/logs"
  if ! mkdir -m 700 -- "$CERTBOTBOT_REG_WORK" "$CERTBOTBOT_REG_LOGS"; then
    certbotbot_error 'private Certbot workspace unavailable'
    return 74
  fi
  if [[ "$CERTBOTBOT_ARCHIVE_ENCRYPTION" == gpg-ocb ]]; then
    certbotbot_crypto_require "$workspace" || return $?
  fi
  certbotbot_register_fetch "$workspace" || return $?
  if [[ "$CERTBOTBOT_REG_MISSING" == true ]]; then
    config="$workspace/config"
    if ! mkdir -m 700 -- "$config"; then
      certbotbot_error 'private account directory unavailable'
      return 74
    fi
  else
    certbotbot_crypto_unwrap "$workspace" || return $?
    certbotbot_archive_restore "$workspace/downloaded.tar.gz" "$workspace" ||
      return $?
    config="$workspace/config"
  fi
  if ! command -v certbot >/dev/null 2>&1; then
    certbotbot_error 'Certbot unavailable'
    return 69
  fi
  if ! certbotbot_register_preflight "$config"; then
    certbotbot_error 'unsupported existing account or certificate state'
    return 65
  fi
  if [[ "$CERTBOTBOT_REG_PRESENT" == true ]]; then
    printf '%s\n' 'certbotbot: existing ACME account reused; published=false'
    return 0
  fi
  if [[ "$CERTBOTBOT_EFF_EMAIL_SIGNUP" == true ]]; then
    eff=--eff-email
  else
    eff=--no-eff-email
  fi
  if ! certbot register --non-interactive --no-directory-hooks \
    --config-dir "$config" --work-dir "$CERTBOTBOT_REG_WORK" \
    --logs-dir "$CERTBOTBOT_REG_LOGS" \
    --server "$CERTBOTBOT_REG_SERVER" \
    --email "$CERTBOTBOT_EMAIL" --agree-tos "$eff" \
    >/dev/null 2>&1; then
    certbotbot_error 'ACME registration failed'
    return 74
  fi
  certbotbot_register_package "$workspace" || return $?
  body="$workspace/candidate.tar.gz"
  content=application/gzip
  if [[ "$CERTBOTBOT_ARCHIVE_ENCRYPTION" == gpg-ocb ]]; then
    certbotbot_crypto_wrap "$workspace" || return $?
    body="$workspace/candidate.tar.gz.enc"
    content=application/octet-stream
  fi
  if [[ "$CERTBOTBOT_REG_MISSING" == true ]]; then
    if ! aws --no-cli-pager s3api put-object \
      --bucket "$CERTBOTBOT_S3_BUCKET" --key "$CERTBOTBOT_S3_KEY" \
      --body "$body" --checksum-algorithm SHA256 \
      --content-type "$content" --if-none-match '*' \
      --output json >/dev/null 2>&1; then
      certbotbot_error 'conditional S3 publication failed; remote state uncertain'
      return 74
    fi
  else
    if ! aws --no-cli-pager s3api put-object \
      --bucket "$CERTBOTBOT_S3_BUCKET" --key "$CERTBOTBOT_S3_KEY" \
      --body "$body" --checksum-algorithm SHA256 \
      --content-type "$content" --if-match "$CERTBOTBOT_REG_ETAG" \
      --output json >/dev/null 2>&1; then
      certbotbot_error 'conditional S3 publication failed; remote state uncertain'
      return 74
    fi
  fi
  printf '%s\n' 'certbotbot: ACME account registered; published=true'
}

## @fn certbotbot_register_main()
## @brief Dispatches explicit registration without ordinary issuance.
## @param ... Registration-only options.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Usage or result status.
## @retval 0 Successful operation.
## @retval 64 Invalid invocation.
## @note Other failure codes propagate from the registration stages.
certbotbot_register_main() {
  case "${1:-}" in
    --help|-h|help) certbotbot_register_usage; return 0 ;;
  esac
  certbotbot_register_config "$@" || return $?
  certbotbot_register_execute
}
