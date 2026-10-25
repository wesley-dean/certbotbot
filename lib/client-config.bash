#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/client-config.bash
## @brief Resolves literal read-only client configuration.
## @details
## CLI > exported environment > literal .env > defaults. The client accepts
## the producer's nonsecret file keys for file sharing, but activates only
## S3 bucket and current key. It never executes config file content.

## @var CERTBOTBOT_CLIENT_FILE_VALUES
## @brief Parsed literal configuration.
declare -A CERTBOTBOT_CLIENT_FILE_VALUES=()

## @fn certbotbot_client_error()
## @brief Reports a fixed, nonsecret error.
## @param message Static diagnostic.
## @param status Nonzero exit status.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @retval 64 Invalid CLI or configuration.
certbotbot_client_error() {
  printf 'certbotbot-client: %s\n' "$1" >&2
  return "${2:-64}"
}

## @fn certbotbot_client_read_file()
## @brief Parses literal KEY=VALUE configuration without shell evaluation.
## @param path Existing config file.
## @par STDIN
## Nothing is read from STDIN.
## @returns Parsed values in CERTBOTBOT_CLIENT_FILE_VALUES.
## @retval 0 File accepted.
## @retval 64 Invalid file.
certbotbot_client_read_file() {
  local path="$1" line key value
  local -A seen=()
  [[ -f "$path" && ! -L "$path" && -r "$path" ]] ||
    { certbotbot_client_error 'configuration file missing or unreadable'; return 64; }
  CERTBOTBOT_CLIENT_FILE_VALUES=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "${line#"${line%%[![:space:]]*}"}" == \#* ]] && continue
    if [[ ! "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
      certbotbot_client_error 'invalid configuration syntax'
      return 64
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    case "$key" in
      S3_BUCKET|S3_KEY|S3_KEY_TEMPLATE|DOMAIN|ADDITIONAL_SANS|INCLUDE_SUBDOMAINS|CERT_NAME|BACKUP_KEY_TEMPLATE|DATED_BACKUP_ENABLED|BACKUP_RETENTION_COUNT|UPLOAD_NO_RENEWAL|ARCHIVE_ENCRYPTION|ARCHIVE_MIGRATION|ARCHIVE_MIGRATION_BACKUP_CONFIRMED) ;;
      *) certbotbot_client_error 'unknown or unsupported configuration key'; return 64 ;;
    esac
    [[ -z "${seen[$key]+x}" ]] ||
      { certbotbot_client_error 'duplicate configuration key'; return 64; }
    seen[$key]=1
    if [[ "$value" == \"*\" && "${#value}" -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "${#value}" -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" =~ ^[[:space:]] || "$value" =~ [[:space:]]$ ]]; then
      certbotbot_client_error 'invalid configuration whitespace'
      return 64
    fi
    if [[ "$value" == *\$* || "$value" == *\`* ||
      "$value" == *\"* || "$value" == *\'* ]]; then
      certbotbot_client_error 'invalid configuration value syntax'
      return 64
    fi
    CERTBOTBOT_CLIENT_FILE_VALUES["$key"]="$value"
  done < "$path"
}

## @fn certbotbot_client_config_resolve()
## @brief Resolves client CLI, environment and literal file settings.
## @param ... Client options; destination is CLI-only.
## @par STDIN
## Nothing is read from STDIN.
## @returns CERTBOTBOT_CLIENT_DESTINATION and frozen CERTBOTBOT_S3_BUCKET/S3_KEY.
## @retval 0 All settings accepted.
## @retval 64 Invalid input.
certbotbot_client_config_resolve() {
  local arg value key config_file=''
  local -A cli=()
  local -a args=("$@")
  local -i i=0
  CERTBOTBOT_CLIENT_FILE_VALUES=()
  while (( i < ${#args[@]} )); do
    arg="${args[i]}"
    case "$arg" in
      --destination|--config|--s3-bucket|--s3-key|--s3-key-template)
        (( i + 1 < ${#args[@]} )) ||
          { certbotbot_client_error 'option requires a value'; return 64; }
        value="${args[i+1]}"
        (( i+=2 ))
        ;;
      --destination=*|--config=*|--s3-bucket=*|--s3-key=*|--s3-key-template=*)
        value="${arg#*=}"
        arg="${arg%%=*}"
        (( i+=1 ))
        ;;
      *)
        certbotbot_client_error 'unsupported option or positional argument'
        return 64
        ;;
    esac
    case "$arg" in
      --destination) key=DESTINATION ;;
      --config) key=CONFIG ;;
      --s3-bucket) key=S3_BUCKET ;;
      --s3-key) key=S3_KEY ;;
      --s3-key-template) key=S3_KEY_TEMPLATE ;;
    esac
    [[ -z "${cli[$key]+x}" ]] ||
      { certbotbot_client_error 'duplicate option'; return 64; }
    [[ -n "$value" ]] ||
      { certbotbot_client_error 'empty option value'; return 64; }
    cli[$key]="$value"
  done
  [[ -n "${cli[DESTINATION]+x}" ]] ||
    { certbotbot_client_error 'destination is required'; return 64; }
  CERTBOTBOT_CLIENT_DESTINATION="${cli[DESTINATION]}"
  if [[ -n "${cli[CONFIG]+x}" ]]; then
    config_file="${cli[CONFIG]}"
  elif [[ -f .env || -L .env ]]; then
    config_file=.env
  fi
  if [[ -n "$config_file" ]]; then
    certbotbot_client_read_file "$config_file" || return 64
  fi

  CERTBOTBOT_S3_BUCKET=''
  if [[ -n "${CERTBOTBOT_CLIENT_FILE_VALUES[S3_BUCKET]+x}" ]]; then
    CERTBOTBOT_S3_BUCKET="${CERTBOTBOT_CLIENT_FILE_VALUES[S3_BUCKET]}"
  fi
  if [[ -n "${S3_BUCKET+x}" ]]; then CERTBOTBOT_S3_BUCKET="$S3_BUCKET"; fi
  if [[ -n "${cli[S3_BUCKET]+x}" ]]; then
    CERTBOTBOT_S3_BUCKET="${cli[S3_BUCKET]}"
  fi

  CERTBOTBOT_S3_KEY=latest.tar.gz
  CERTBOTBOT_S3_KEY_IS_TEMPLATE=false
  if [[ -n "${cli[S3_KEY]+x}" || -n "${cli[S3_KEY_TEMPLATE]+x}" ]]; then
    [[ -z "${cli[S3_KEY]+x}" || -z "${cli[S3_KEY_TEMPLATE]+x}" ]] ||
      { certbotbot_client_error 'conflicting current archive keys'; return 64; }
    if [[ -n "${cli[S3_KEY_TEMPLATE]+x}" ]]; then
      CERTBOTBOT_S3_KEY="${cli[S3_KEY_TEMPLATE]}"
      CERTBOTBOT_S3_KEY_IS_TEMPLATE=true
    else
      CERTBOTBOT_S3_KEY="${cli[S3_KEY]}"
    fi
  elif [[ -n "${S3_KEY+x}" || -n "${S3_KEY_TEMPLATE+x}" ]]; then
    [[ -z "${S3_KEY+x}" || -z "${S3_KEY_TEMPLATE+x}" ]] ||
      { certbotbot_client_error 'conflicting current archive keys'; return 64; }
    if [[ -n "${S3_KEY_TEMPLATE+x}" ]]; then
      CERTBOTBOT_S3_KEY="$S3_KEY_TEMPLATE"
      CERTBOTBOT_S3_KEY_IS_TEMPLATE=true
    else
      CERTBOTBOT_S3_KEY="$S3_KEY"
    fi
  elif [[ -n "${CERTBOTBOT_CLIENT_FILE_VALUES[S3_KEY]+x}" ||
    -n "${CERTBOTBOT_CLIENT_FILE_VALUES[S3_KEY_TEMPLATE]+x}" ]]; then
    [[ -z "${CERTBOTBOT_CLIENT_FILE_VALUES[S3_KEY]+x}" ||
      -z "${CERTBOTBOT_CLIENT_FILE_VALUES[S3_KEY_TEMPLATE]+x}" ]] ||
      { certbotbot_client_error 'conflicting current archive keys'; return 64; }
    if [[ -n "${CERTBOTBOT_CLIENT_FILE_VALUES[S3_KEY_TEMPLATE]+x}" ]]; then
      CERTBOTBOT_S3_KEY="${CERTBOTBOT_CLIENT_FILE_VALUES[S3_KEY_TEMPLATE]}"
      CERTBOTBOT_S3_KEY_IS_TEMPLATE=true
    else
      CERTBOTBOT_S3_KEY="${CERTBOTBOT_CLIENT_FILE_VALUES[S3_KEY]}"
    fi
  fi
  [[ -n "$CERTBOTBOT_S3_BUCKET" && -n "$CERTBOTBOT_S3_KEY" ]] ||
    { certbotbot_client_error 'S3 bucket/key required'; return 64; }
  [[ "$CERTBOTBOT_S3_BUCKET" != -* && "$CERTBOTBOT_S3_BUCKET" != *[[:space:]]* &&
    "$CERTBOTBOT_S3_BUCKET" != */* ]] ||
    { certbotbot_client_error 'invalid S3 bucket'; return 64; }
  if [[ "$CERTBOTBOT_S3_KEY_IS_TEMPLATE" != true ]]; then
    [[ "$CERTBOTBOT_S3_KEY" != -* && "$CERTBOTBOT_S3_KEY" != */* &&
      "$CERTBOTBOT_S3_KEY" != *[[:space:]]* ]] ||
      { certbotbot_client_error 'invalid S3 object key'; return 64; }
  fi
  CERTBOTBOT_BACKUP_KEY_TEMPLATE_EXPLICIT=false
  CERTBOTBOT_DATED_BACKUP_ENABLED=false
  certbotbot_filename_resolve || return 64
}
