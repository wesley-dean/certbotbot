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
## selects naming only, not publication or deletion.
## Additional SAN input follows ADR-029: repeated --san values select the
## entire CLI collection; exported ADDITIONAL_SANS replaces the literal
## file list, and file/default values are consulted only when higher sources
## are absent. Individual names are validated by certbotbot_identity_resolve.

## @var CERTBOTBOT_FILE_VALUES
## @brief Associative literal values parsed from the selected configuration.
declare -A CERTBOTBOT_FILE_VALUES=()

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
      DOMAIN|ADDITIONAL_SANS|INCLUDE_SUBDOMAINS|CERT_NAME|S3_BUCKET|S3_KEY|S3_KEY_TEMPLATE|BACKUP_KEY_TEMPLATE|UPLOAD_NO_RENEWAL|ARCHIVE_ENCRYPTION|ARCHIVE_MIGRATION|ARCHIVE_MIGRATION_BACKUP_CONFIRMED) ;;
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
  local name key value arg config_file='' explicit_config=false
  local -a args=("$@") san_cli=()
  local -A cli=()
  CERTBOTBOT_FILE_VALUES=()
  local -i i=0
  while (( i < ${#args[@]} )); do
    arg="${args[i]}"
    case "$arg" in
      --config|--domain|--san|--include-subdomains|--cert-name|--s3-bucket|--s3-key|--s3-key-template|--backup-key-template|--upload-no-renewal|--archive-encryption|--archive-migration|--archive-migration-backup-confirmed)
        (( i + 1 < ${#args[@]} )) || { certbotbot_error 'option requires a value'; return 64; }
        value="${args[i+1]}"
        (( i+=2 ))
        ;;
      --config=*|--domain=*|--san=*|--include-subdomains=*|--cert-name=*|--s3-bucket=*|--s3-key=*|--s3-key-template=*|--backup-key-template=*|--upload-no-renewal=*|--archive-encryption=*|--archive-migration=*|--archive-migration-backup-confirmed=*)
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
      --include-subdomains) key=INCLUDE_SUBDOMAINS ;;
      --cert-name) key=CERT_NAME ;;
      --s3-bucket) key=S3_BUCKET ;;
      --s3-key) key=S3_KEY ;;
      --s3-key-template) key=S3_KEY_TEMPLATE ;;
      --backup-key-template) key=BACKUP_KEY_TEMPLATE ;;
      --upload-no-renewal) key=UPLOAD_NO_RENEWAL ;;
      --archive-encryption) key=ARCHIVE_ENCRYPTION ;;
      --archive-migration) key=ARCHIVE_MIGRATION ;;
      --archive-migration-backup-confirmed) key=ARCHIVE_MIGRATION_BACKUP_CONFIRMED ;;
    esac
    if [[ "$arg" != --config ]]; then
      [[ -z "${cli[$key]+x}" ]] || { certbotbot_error 'duplicate option'; return 64; }
      cli[$key]="$value"
    fi
  done
  if [[ "$explicit_config" == false && -f .env ]]; then config_file=.env; fi
  if [[ -n "$config_file" ]]; then
    certbotbot_read_env_file "$config_file" || return 64
  elif [[ "$explicit_config" == true ]]; then
    certbotbot_error 'configuration file is missing'
    return 64
  fi
  local -A defaults=([DOMAIN]='' [INCLUDE_SUBDOMAINS]=true [CERT_NAME]='' [S3_BUCKET]='' [UPLOAD_NO_RENEWAL]=false [ARCHIVE_ENCRYPTION]=auto [ARCHIVE_MIGRATION]=none [ARCHIVE_MIGRATION_BACKUP_CONFIRMED]=false)
  for name in DOMAIN INCLUDE_SUBDOMAINS CERT_NAME S3_BUCKET UPLOAD_NO_RENEWAL ARCHIVE_ENCRYPTION ARCHIVE_MIGRATION ARCHIVE_MIGRATION_BACKUP_CONFIRMED; do
    value="${defaults[$name]}"
    if [[ -n "${CERTBOTBOT_FILE_VALUES[$name]+x}" ]]; then value="${CERTBOTBOT_FILE_VALUES[$name]}"; fi
    if [[ -n "${!name+x}" ]]; then value="${!name}"; fi
    if [[ -n "${cli[$name]+x}" ]]; then value="${cli[$name]}"; fi
    printf -v "CERTBOTBOT_$name" '%s' "$value"
  done
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
  for name in INCLUDE_SUBDOMAINS UPLOAD_NO_RENEWAL ARCHIVE_MIGRATION_BACKUP_CONFIRMED; do
    key="CERTBOTBOT_$name"
    case "${!key}" in true|false) ;; *) certbotbot_error 'invalid boolean setting'; return 64 ;; esac
  done
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
}
