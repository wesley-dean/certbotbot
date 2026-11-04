#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/config.bash
## @brief Parses literal configuration and resolves selected-lineage settings.
## @details
## Configuration is never sourced or evaluated. Values are captured by literal
## assignment and overlaid according to the public MVP configuration contract.
## Invalid configuration fails before any cloud operation is attempted.
## Legacy S3_KEY remains literal. S3_KEY_TEMPLATE and S3_KEY are mutually
## exclusive at one precedence tier; a higher-tier selection masks the
## other source's lower-tier alternative. Backup-key template configuration
## selects naming only, not publication or deletion. DATED_BACKUP_ENABLED
## independently opts into a guarded second S3 publication after success.
## BACKUP_RETENTION_COUNT is a separate default-zero destructive opt-in;
## it requires a verified current and dated backup publication (ADR-034).
## Additional SAN input follows ADR-029: repeated --san values select the
## entire CLI collection; exported ADDITIONAL_SANS replaces the literal
## file list, and file/default values are consulted only when higher sources
## are absent. Individual names are validated by certbotbot_identity_resolve.

## @var CERTBOTBOT_FILE_VALUES
## @brief Associative literal values parsed from the selected configuration.
declare -A CERTBOTBOT_FILE_VALUES=()

## @var CERTBOTBOT_AWS_ARGS
## @brief Bounded AWS CLI global argument vector, defaulting empty.
  # shellcheck disable=SC2034
  declare -a CERTBOTBOT_AWS_ARGS=()
## @var CERTBOTBOT_GPG_ARGS
## @brief Bounded authenticated encryption tuning arguments, defaulting empty.
  # shellcheck disable=SC2034
  declare -a CERTBOTBOT_GPG_ARGS=()
## @var CERTBOTBOT_CERTBOT_GLOBAL_ARGS
## @brief Safe global Certbot arguments shared across allowed subcommands.
declare -a CERTBOTBOT_CERTBOT_GLOBAL_ARGS=()
## @var CERTBOTBOT_CERTBOT_CHALLENGE_ARGS
## @brief Certbot dns-route53 options used only for selected issue and renew.
declare -a CERTBOTBOT_CERTBOT_CHALLENGE_ARGS=()

## @fn certbotbot_no_env_requested()
## @brief Detects the presence-only flag before importing any application data.
## @details Skips option values and everything following the option terminator.
## @param ... CLI tokens, optionally starting with 'register'.
## @retval 0 The explicit --no-env token was supplied.
## @retval 1 No valid standalone no-env token was found.
certbotbot_no_env_requested() {
  local -a args=("$@")
  local -i i=0
  while (( i < ${#args[@]} )); do
    case "${args[i]}" in
      --) break ;;
      --no-env) return 0 ;;
      --config|--domain|--san|--acme-environment|--include-subdomains|--cert-name|--s3-bucket|--s3-key|--s3-key-template|--backup-key-template|--dated-backup-enabled|--backup-retention-count|--upload-no-renewal|--archive-encryption|--archive-migration|--archive-migration-backup-confirmed|--email|--agree-tos|--eff-email-signup|--aws-args|--gpg-args|--certbot-args)
        (( i+=1 ))
        ;;
    esac
    (( i+=1 ))
  done
  return 1
}

## @fn certbotbot_disable_application_environment()
## @brief Excludes all producer-owned environment settings under --no-env.
## @details Deliberately retains OS environment and external AWS credentials.
certbotbot_disable_application_environment() {
  unset ACME_ENVIRONMENT DOMAIN ADDITIONAL_SANS INCLUDE_SUBDOMAINS CERT_NAME \
    S3_BUCKET S3_KEY S3_KEY_TEMPLATE BACKUP_KEY_TEMPLATE \
    DATED_BACKUP_ENABLED BACKUP_RETENTION_COUNT UPLOAD_NO_RENEWAL \
    ARCHIVE_ENCRYPTION ARCHIVE_MIGRATION ARCHIVE_MIGRATION_BACKUP_CONFIRMED \
    EMAIL AGREE_TOS EFF_EMAIL_SIGNUP GPG_SYMMETRIC_KEY \
    AWS_EXTRA_ARGS GPG_EXTRA_ARGS CERTBOT_EXTRA_ARGS
}

## @fn certbotbot_extra_args_resolve()
## @brief Decodes one bounded JSON string-array into safe provider argv tokens.
## @param kind AWS, GPG, or CERTBOT.
## @param json Entire JSON argv array; no shell evaluation.
## @retval 0 Validated provider argument vector.
## @retval 64 Malformed, unsupported, or unsafe argument collection.
## @retval 69 Missing optional decoder required for nonempty input.
certbotbot_extra_args_resolve() {
  local kind="$1" json="$2" encoded token value limit=0
  local -i i=0
  local -n output="CERTBOTBOT_${kind}_ARGS"
  output=()
  if [[ "$kind" == CERTBOT ]]; then
    CERTBOTBOT_CERTBOT_GLOBAL_ARGS=()
    CERTBOTBOT_CERTBOT_CHALLENGE_ARGS=()
  fi
  [[ -n "$json" && ${#json} -le 4096 ]] ||
    { certbotbot_error 'invalid extra provider arguments'; return 64; }
  # An empty collection is always representable without an optional decoder.
  [[ "$json" != '[]' ]] || return 0
  if ! command -v jq >/dev/null 2>&1 ||
    ! command -v base64 >/dev/null 2>&1; then
    certbotbot_error 'extra provider arguments require jq and base64'
    return 69
  fi
  if ! printf '%s' "$json" | jq -e '
    type == "array" and length <= 16
    and all(.[]; type == "string"
      and (explode | all(. >= 32 and . != 127)))
  ' >/dev/null 2>&1; then
    certbotbot_error 'invalid extra provider argument encoding'
    return 64
  fi
  # Prefix each encoded element so an empty string remains a distinct token.
  encoded="$(printf '%s' "$json" | jq -r '.[] | "X" + (@base64)' 2>/dev/null)" ||
    { certbotbot_error 'extra provider argument decoding failed'; return 64; }
  if [[ -n "$encoded" ]]; then
    while IFS= read -r token; do
      [[ "$token" == X* ]] ||
        { certbotbot_error 'invalid provider argument token'; return 64; }
      value="$(printf '%s' "${token#X}" | base64 --decode 2>/dev/null)" ||
        { certbotbot_error 'invalid provider argument token'; return 64; }
      output+=("$value")
    done <<< "$encoded"
  fi
  while (( i < ${#output[@]} )); do
    token="${output[i]}"
    case "$kind:$token" in
      AWS:--cli-connect-timeout|AWS:--cli-read-timeout)
        limit=600 ;;
      GPG:--compress-level)
        limit=9 ;;
      GPG:--no-compress)
        (( i+=1 ))
        continue ;;
      CERTBOT:--max-log-backups)
        limit=1000 ;;
      CERTBOT:--dns-route53-propagation-seconds)
        [[ "${CERTBOTBOT_COMMAND:-issue}" != register ]] ||
          { certbotbot_error 'unsupported registration provider argument'; return 64; }
        limit=300 ;;
      *)
        certbotbot_error 'unsupported or unsafe provider argument'
        return 64 ;;
    esac
    (( i+1 < ${#output[@]} )) ||
      { certbotbot_error 'provider argument requires a value'; return 64; }
    value="${output[i+1]}"
    [[ "$value" =~ ^(0|[1-9][0-9]{0,3})$ ]] ||
      { certbotbot_error 'invalid provider argument value'; return 64; }
    if [[ "$kind" != GPG && "$value" == 0 ]] ||
      (( 10#$value > limit )); then
      certbotbot_error 'provider argument value is out of range'
      return 64
    fi
    if [[ "$kind" == CERTBOT ]]; then
      case "$token" in
        --max-log-backups)
          CERTBOTBOT_CERTBOT_GLOBAL_ARGS+=("$token" "$value") ;;
        --dns-route53-propagation-seconds)
          CERTBOTBOT_CERTBOT_CHALLENGE_ARGS+=("$token" "$value") ;;
      esac
    fi
    (( i+=2 ))
  done
  if [[ "$kind" == GPG ]]; then
    local seen_level=false seen_disable=false
    for token in "${output[@]}"; do
      case "$token" in
        --compress-level) seen_level=true ;;
        --no-compress) seen_disable=true ;;
      esac
    done
    if [[ "$seen_level" == true && "$seen_disable" == true ]]; then
      certbotbot_error 'conflicting GnuPG compression options'
      return 64
    fi
  fi
}

## @fn certbotbot_extra_args_config()
## @brief Resolves independent CLI-over-environment provider argv collections.
## @param ... Three optional CLI JSON values and three presence flags.
## @retval 0 All selected provider collections have passed validation.
## @retval 64/69 Invalid collection or required decoder unavailable.
certbotbot_extra_args_config() {
  local kind name value
  local -a values=("$1" "$2" "$3")
  local -a supplied=("$4" "$5" "$6")
  local -i j=0
  for kind in AWS GPG CERTBOT; do
    name="${kind}_EXTRA_ARGS"
    if [[ "${supplied[j]}" == true ]]; then
      value="${values[j]}"
    elif [[ -n "${!name+x}" ]]; then
      value="${!name}"
    else
      value='[]'
    fi
    certbotbot_extra_args_resolve "$kind" "$value" || return $?
    (( j+=1 ))
  done
}

## @fn certbotbot_error()
## @brief Reports a non-sensitive configuration error.
## @param message Static diagnostic without user-supplied values.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## One diagnostic.
## @retval 64 Invalid configuration.
certbotbot_error() {
  printf 'certbotbot: %s\n' "$1" >&2
  return 64
}

## @fn certbotbot_read_env_file()
## @brief Reads the accepted literal KEY=VALUE grammar.
## @param file Existing configuration file path.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Static diagnostics on invalid input.
## @retval 0 All entries were parsed.
## @retval 64 Input was invalid.
certbotbot_read_env_file() {
  local file="$1" line key value
  local -A seen=()
  [[ -f "$file" && -r "$file" ]] || { certbotbot_error 'configuration file is missing or unreadable'; return 64; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "${line#"${line%%[![:space:]]*}"}" == \#* ]] && continue
    if [[ ! "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
      certbotbot_error 'invalid configuration syntax'
      return 64
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    case "$key" in
      DOMAIN|ADDITIONAL_SANS|INCLUDE_SUBDOMAINS|CERT_NAME|S3_BUCKET|S3_KEY|S3_KEY_TEMPLATE|BACKUP_KEY_TEMPLATE|DATED_BACKUP_ENABLED|BACKUP_RETENTION_COUNT|UPLOAD_NO_RENEWAL|ARCHIVE_ENCRYPTION|ARCHIVE_MIGRATION|ARCHIVE_MIGRATION_BACKUP_CONFIRMED|EMAIL|AGREE_TOS|EFF_EMAIL_SIGNUP|ACME_ENVIRONMENT) ;;
      *) certbotbot_error 'unknown configuration key'; return 64 ;;
    esac
    if [[ -n "${seen[$key]+x}" ]]; then
      certbotbot_error 'duplicate configuration key'
      return 64
    fi
    seen[$key]=1
    if [[ "$value" == \"*\" && "${#value}" -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "${#value}" -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" =~ ^[[:space:]] || "$value" =~ [[:space:]]$ ]]; then
      certbotbot_error 'invalid configuration whitespace'
      return 64
    fi
    if [[ "$value" == *\$* || "$value" == *\`* || "$value" == *\"* || "$value" == *\'* ]]; then
      certbotbot_error 'invalid configuration value syntax'
      return 64
    fi
    CERTBOTBOT_FILE_VALUES["$key"]="$value"
  done < "$file"
}

## @fn certbotbot_config_resolve()
## @brief Resolves each supported key using CLI, environment, file and defaults.
## @details
## A repeated --san NAME or --san=NAME is a collection-valued CLI setting.
## With no CLI --san, ADDITIONAL_SANS is a literal comma-delimited environment
## or .env list; an exported empty value deliberately masks the file list.
## The result is CERTBOTBOT_ADDITIONAL_SANS, an indexed Bash array. No list
## data is evaluated, interpolated or treated as shell code. The input cap is
## 99 extras, reserving the 100th name for the required primary identity.
## @param ... Command-line arguments including one DNS identity.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Static validation diagnostics.
## @retval 0 Effective settings were resolved.
## @retval 64 Invalid settings or arguments.
certbotbot_config_resolve() {
  local name key value arg config_file='' explicit_config=false no_env=false
  local -a args=("$@") san_cli=()
  local -A cli=()
  CERTBOTBOT_FILE_VALUES=()
  local -i i=0
  while (( i < ${#args[@]} )); do
    arg="${args[i]}"
    case "$arg" in
      --no-env)
        [[ "$no_env" == false ]] ||
          { certbotbot_error 'duplicate no-env option'; return 64; }
        no_env=true
        (( i+=1 ))
        continue
        ;;
      --config|--domain|--san|--acme-environment|--include-subdomains|--cert-name|--s3-bucket|--s3-key|--s3-key-template|--backup-key-template|--dated-backup-enabled|--backup-retention-count|--upload-no-renewal|--archive-encryption|--archive-migration|--archive-migration-backup-confirmed|--aws-args|--gpg-args|--certbot-args)
        (( i + 1 < ${#args[@]} )) || { certbotbot_error 'option requires a value'; return 64; }
        value="${args[i+1]}"
        (( i+=2 ))
        ;;
      --config=*|--domain=*|--san=*|--acme-environment=*|--include-subdomains=*|--cert-name=*|--s3-bucket=*|--s3-key=*|--s3-key-template=*|--backup-key-template=*|--dated-backup-enabled=*|--backup-retention-count=*|--upload-no-renewal=*|--archive-encryption=*|--archive-migration=*|--archive-migration-backup-confirmed=*|--aws-args=*|--gpg-args=*|--certbot-args=*)
        value="${arg#*=}"
        arg="${arg%%=*}"
        (( i+=1 ))
        ;;
      --)
        (( i+=1 ))
        while (( i < ${#args[@]} )); do
          [[ -z "${cli[DOMAIN]+x}" ]] || { certbotbot_error 'multiple identities'; return 64; }
          cli[DOMAIN]="${args[i]}"
          (( i+=1 ))
        done
        break
        ;;
      -*)
        certbotbot_error 'unknown option'
        return 64
        ;;
      *)
        [[ -z "${cli[DOMAIN]+x}" ]] || { certbotbot_error 'multiple identities'; return 64; }
        cli[DOMAIN]="$arg"
        (( i+=1 ))
        continue
        ;;
    esac
    if [[ "$arg" == --san ]]; then
      [[ -n "$value" ]] || { certbotbot_error 'invalid additional DNS identity'; return 64; }
      san_cli+=("$value")
      (( ${#san_cli[@]} <= 99 )) || { certbotbot_error 'too many additional DNS identities'; return 64; }
      continue
    fi
    case "$arg" in
      --config)
        [[ "$explicit_config" == false ]] || { certbotbot_error 'duplicate option'; return 64; }
        config_file="$value"
        explicit_config=true
        ;;
      --domain) key=DOMAIN ;;
      --acme-environment) key=ACME_ENVIRONMENT ;;
      --include-subdomains) key=INCLUDE_SUBDOMAINS ;;
      --cert-name) key=CERT_NAME ;;
      --s3-bucket) key=S3_BUCKET ;;
      --s3-key) key=S3_KEY ;;
      --s3-key-template) key=S3_KEY_TEMPLATE ;;
      --backup-key-template) key=BACKUP_KEY_TEMPLATE ;;
      --dated-backup-enabled) key=DATED_BACKUP_ENABLED ;;
      --backup-retention-count) key=BACKUP_RETENTION_COUNT ;;
      --upload-no-renewal) key=UPLOAD_NO_RENEWAL ;;
      --archive-encryption) key=ARCHIVE_ENCRYPTION ;;
      --archive-migration) key=ARCHIVE_MIGRATION ;;
      --archive-migration-backup-confirmed) key=ARCHIVE_MIGRATION_BACKUP_CONFIRMED ;;
      --aws-args) key=AWS_EXTRA_ARGS ;;
      --gpg-args) key=GPG_EXTRA_ARGS ;;
      --certbot-args) key=CERTBOT_EXTRA_ARGS ;;
    esac
    if [[ "$arg" != --config ]]; then
      [[ -z "${cli[$key]+x}" ]] || { certbotbot_error 'duplicate option'; return 64; }
      cli[$key]="$value"
    fi
  done
  if [[ "$no_env" == true ]]; then
    [[ "$explicit_config" == false ]] ||
      { certbotbot_error 'no-env conflicts with explicit config'; return 64; }
    certbotbot_disable_application_environment || return 64
  else
    if [[ "$explicit_config" == false && -f .env ]]; then config_file=.env; fi
    if [[ -n "$config_file" ]]; then
      certbotbot_read_env_file "$config_file" || return 64
    elif [[ "$explicit_config" == true ]]; then
      certbotbot_error 'configuration file is missing'
      return 64
    fi
  fi
  local -A defaults=([DOMAIN]='' [INCLUDE_SUBDOMAINS]=true [CERT_NAME]='' [S3_BUCKET]='' [DATED_BACKUP_ENABLED]=false [BACKUP_RETENTION_COUNT]=0 [UPLOAD_NO_RENEWAL]=false [ARCHIVE_ENCRYPTION]=auto [ARCHIVE_MIGRATION]=none [ARCHIVE_MIGRATION_BACKUP_CONFIRMED]=false [ACME_ENVIRONMENT]=production)
  for name in ACME_ENVIRONMENT DOMAIN INCLUDE_SUBDOMAINS CERT_NAME S3_BUCKET DATED_BACKUP_ENABLED BACKUP_RETENTION_COUNT UPLOAD_NO_RENEWAL ARCHIVE_ENCRYPTION ARCHIVE_MIGRATION ARCHIVE_MIGRATION_BACKUP_CONFIRMED; do
    value="${defaults[$name]}"
    if [[ -n "${CERTBOTBOT_FILE_VALUES[$name]+x}" ]]; then value="${CERTBOTBOT_FILE_VALUES[$name]}"; fi
    if [[ -n "${!name+x}" ]]; then value="${!name}"; fi
    if [[ -n "${cli[$name]+x}" ]]; then value="${cli[$name]}"; fi
    printf -v "CERTBOTBOT_$name" '%s' "$value"
  done
  case "$CERTBOTBOT_ACME_ENVIRONMENT" in
    production|staging) ;;
    *) certbotbot_error 'invalid ACME environment'; return 64 ;;
  esac
  # S3_KEY and S3_KEY_TEMPLATE are one logical choice. Do not resolve
  # independently: a higher-tier literal must mask a lower-tier template.
  CERTBOTBOT_S3_KEY_IS_TEMPLATE=false
  CERTBOTBOT_S3_KEY=latest.tar.gz
  if [[ -n "${cli[S3_KEY]+x}" || -n "${cli[S3_KEY_TEMPLATE]+x}" ]]; then
    if [[ -n "${cli[S3_KEY]+x}" && -n "${cli[S3_KEY_TEMPLATE]+x}" ]]; then
      certbotbot_error 'conflicting current archive key settings'
      return 64
    fi
    if [[ -n "${cli[S3_KEY_TEMPLATE]+x}" ]]; then
      CERTBOTBOT_S3_KEY="${cli[S3_KEY_TEMPLATE]}"
      CERTBOTBOT_S3_KEY_IS_TEMPLATE=true
    else
      CERTBOTBOT_S3_KEY="${cli[S3_KEY]}"
    fi
  elif [[ -n "${S3_KEY+x}" || -n "${S3_KEY_TEMPLATE+x}" ]]; then
    if [[ -n "${S3_KEY+x}" && -n "${S3_KEY_TEMPLATE+x}" ]]; then
      certbotbot_error 'conflicting current archive key settings'
      return 64
    fi
    if [[ -n "${S3_KEY_TEMPLATE+x}" ]]; then
      CERTBOTBOT_S3_KEY="$S3_KEY_TEMPLATE"
      CERTBOTBOT_S3_KEY_IS_TEMPLATE=true
    else
      CERTBOTBOT_S3_KEY="$S3_KEY"
    fi
  elif [[ -n "${CERTBOTBOT_FILE_VALUES[S3_KEY]+x}" ||
    -n "${CERTBOTBOT_FILE_VALUES[S3_KEY_TEMPLATE]+x}" ]]; then
    if [[ -n "${CERTBOTBOT_FILE_VALUES[S3_KEY]+x}" &&
      -n "${CERTBOTBOT_FILE_VALUES[S3_KEY_TEMPLATE]+x}" ]]; then
      certbotbot_error 'conflicting current archive key settings'
      return 64
    fi
    if [[ -n "${CERTBOTBOT_FILE_VALUES[S3_KEY_TEMPLATE]+x}" ]]; then
      CERTBOTBOT_S3_KEY="${CERTBOTBOT_FILE_VALUES[S3_KEY_TEMPLATE]}"
      CERTBOTBOT_S3_KEY_IS_TEMPLATE=true
    else
      CERTBOTBOT_S3_KEY="${CERTBOTBOT_FILE_VALUES[S3_KEY]}"
    fi
  fi
  CERTBOTBOT_BACKUP_KEY_TEMPLATE='archive-{YEAR}{MONTH}{DOM}.tar.gz'
  CERTBOTBOT_BACKUP_KEY_TEMPLATE_EXPLICIT=false
  if [[ -n "${CERTBOTBOT_FILE_VALUES[BACKUP_KEY_TEMPLATE]+x}" ]]; then
    CERTBOTBOT_BACKUP_KEY_TEMPLATE="${CERTBOTBOT_FILE_VALUES[BACKUP_KEY_TEMPLATE]}"
    CERTBOTBOT_BACKUP_KEY_TEMPLATE_EXPLICIT=true
  fi
  if [[ -n "${BACKUP_KEY_TEMPLATE+x}" ]]; then
    CERTBOTBOT_BACKUP_KEY_TEMPLATE="$BACKUP_KEY_TEMPLATE"
    CERTBOTBOT_BACKUP_KEY_TEMPLATE_EXPLICIT=true
  fi
  if [[ -n "${cli[BACKUP_KEY_TEMPLATE]+x}" ]]; then
    CERTBOTBOT_BACKUP_KEY_TEMPLATE="${cli[BACKUP_KEY_TEMPLATE]}"
    # Consumed by lib/filename.bash after config resolution.
    # shellcheck disable=SC2034
    CERTBOTBOT_BACKUP_KEY_TEMPLATE_EXPLICIT=true
  fi
  [[ -n "$CERTBOTBOT_S3_KEY" && -n "$CERTBOTBOT_BACKUP_KEY_TEMPLATE" ]] ||
    { certbotbot_error 'archive object name cannot be empty'; return 64; }
  # The SAN list has collection-level, not element-level, precedence.
  # Reject empty comma fields before read -a, which otherwise drops some.
  CERTBOTBOT_ADDITIONAL_SANS=()
  if (( ${#san_cli[@]} > 0 )); then
    CERTBOTBOT_ADDITIONAL_SANS=("${san_cli[@]}")
  else
    value=''
    if [[ -n "${CERTBOTBOT_FILE_VALUES[ADDITIONAL_SANS]+x}" ]]; then
      value="${CERTBOTBOT_FILE_VALUES[ADDITIONAL_SANS]}"
    fi
    if [[ -n "${ADDITIONAL_SANS+x}" ]]; then value="$ADDITIONAL_SANS"; fi
    if [[ -n "$value" ]]; then
      if [[ "$value" == ,* || "$value" == *, || "$value" == *,,* ||
        "$value" == *[[:cntrl:]]* ]]; then
        certbotbot_error 'invalid additional DNS identity list'
        return 64
      fi
      IFS=, read -r -a CERTBOTBOT_ADDITIONAL_SANS <<< "$value"
    fi
  fi
  if (( ${#CERTBOTBOT_ADDITIONAL_SANS[@]} > 99 )); then
    certbotbot_error 'too many additional DNS identities'
    return 64
  fi
  for name in INCLUDE_SUBDOMAINS DATED_BACKUP_ENABLED UPLOAD_NO_RENEWAL ARCHIVE_MIGRATION_BACKUP_CONFIRMED; do
    key="CERTBOTBOT_$name"
    case "${!key}" in true|false) ;; *) certbotbot_error 'invalid boolean setting'; return 64 ;; esac
  done
  # ADR-034: count is a canonical, bounded decimal, independent of
  # dated publication. Nonzero requires separately enabled backup writes.
  if [[ "$CERTBOTBOT_BACKUP_RETENTION_COUNT" != 0 ]]; then
    if [[ ! "$CERTBOTBOT_BACKUP_RETENTION_COUNT" =~ ^[1-9][0-9]*$ ||
      ${#CERTBOTBOT_BACKUP_RETENTION_COUNT} -gt 5 ]]; then
      certbotbot_error 'invalid backup retention count'
      return 64
    fi
    if (( 10#$CERTBOTBOT_BACKUP_RETENTION_COUNT > 10000 )); then
      certbotbot_error 'invalid backup retention count'
      return 64
    fi
    if [[ "$CERTBOTBOT_DATED_BACKUP_ENABLED" != true ]]; then
      certbotbot_error 'backup retention requires dated publication'
      return 64
    fi
  fi
  # GPG_SYMMETRIC_KEY is never a CLI or .env value. It is captured and
  # removed from the exported environment by the public entrypoint.
  case "$CERTBOTBOT_ARCHIVE_ENCRYPTION" in
    auto)
      if [[ -n "${CERTBOTBOT_GPG_SECRET:-}" ]]; then
        CERTBOTBOT_ARCHIVE_ENCRYPTION=gpg-ocb
      else
        CERTBOTBOT_ARCHIVE_ENCRYPTION=none
      fi
      ;;
    none)
      if [[ -n "${CERTBOTBOT_GPG_SECRET:-}" ]]; then
        certbotbot_error 'encryption key supplied with plaintext mode'
        return 64
      fi
      ;;
    gpg-ocb)
      if [[ -z "${CERTBOTBOT_GPG_SECRET:-}" ]]; then
        certbotbot_error 'encrypted mode requires a key'
        return 64
      fi
      ;;
    *) certbotbot_error 'invalid archive encryption mode'; return 64 ;;
  esac
  case "$CERTBOTBOT_ARCHIVE_MIGRATION" in
    none)
      if [[ "$CERTBOTBOT_ARCHIVE_MIGRATION_BACKUP_CONFIRMED" == true ]]; then
        certbotbot_error 'backup confirmation requires migration'
        return 64
      fi
      ;;
    plaintext-to-gpg-ocb)
      if [[ "$CERTBOTBOT_ARCHIVE_ENCRYPTION" != gpg-ocb ||
        "$CERTBOTBOT_ARCHIVE_MIGRATION_BACKUP_CONFIRMED" != true ]]; then
        certbotbot_error 'encryption migration requires key and backup confirmation'
        return 64
      fi
      ;;
    *) certbotbot_error 'invalid archive migration mode'; return 64 ;;
  esac
  if [[ "$CERTBOTBOT_ARCHIVE_ENCRYPTION" == gpg-ocb &&
    ( "$CERTBOTBOT_GPG_SECRET" == *$'\n'* ||
      "$CERTBOTBOT_GPG_SECRET" == *$'\r'* ) ]]; then
    certbotbot_error 'invalid encryption key'
    return 64
  fi
  [[ -n "$CERTBOTBOT_DOMAIN" ]] ||
    { certbotbot_error 'DNS identity is required'; return 64; }
  [[ -n "$CERTBOTBOT_S3_BUCKET" && -n "$CERTBOTBOT_S3_KEY" ]] ||
    { certbotbot_error 'S3 bucket and key are required'; return 64; }
  if [[ "$CERTBOTBOT_S3_KEY_IS_TEMPLATE" != true ]]; then
    [[ "$CERTBOTBOT_S3_KEY" != -* && "$CERTBOTBOT_S3_KEY" != */* &&
      "$CERTBOTBOT_S3_KEY" != *[[:space:]]* ]] ||
      { certbotbot_error 'invalid S3 object key'; return 64; }
  fi
  certbotbot_extra_args_config \
    "${cli[AWS_EXTRA_ARGS]-}" "${cli[GPG_EXTRA_ARGS]-}" \
    "${cli[CERTBOT_EXTRA_ARGS]-}" \
    "${cli[AWS_EXTRA_ARGS]+true}" "${cli[GPG_EXTRA_ARGS]+true}" \
    "${cli[CERTBOT_EXTRA_ARGS]+true}" || return $?
}
