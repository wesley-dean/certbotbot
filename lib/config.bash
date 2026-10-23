#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/config.bash
## @brief Parses literal configuration and resolves selected-lineage settings.
## @details
## Configuration is never sourced or evaluated. Values are captured by literal
## assignment and overlaid according to the public MVP configuration contract.
## Invalid configuration fails before any cloud operation is attempted.
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
      DOMAIN|ADDITIONAL_SANS|INCLUDE_SUBDOMAINS|CERT_NAME|S3_BUCKET|S3_KEY|UPLOAD_NO_RENEWAL) ;;
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
      --config|--domain|--san|--include-subdomains|--cert-name|--s3-bucket|--s3-key|--upload-no-renewal)
        (( i + 1 < ${#args[@]} )) || { certbotbot_error 'option requires a value'; return 64; }
        value="${args[i+1]}"
        (( i+=2 ))
        ;;
      --config=*|--domain=*|--san=*|--include-subdomains=*|--cert-name=*|--s3-bucket=*|--s3-key=*|--upload-no-renewal=*)
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
      --upload-no-renewal) key=UPLOAD_NO_RENEWAL ;;
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
  local -A defaults=([DOMAIN]='' [INCLUDE_SUBDOMAINS]=true [CERT_NAME]='' [S3_BUCKET]='' [S3_KEY]=latest.tar.gz [UPLOAD_NO_RENEWAL]=false)
  for name in DOMAIN INCLUDE_SUBDOMAINS CERT_NAME S3_BUCKET S3_KEY UPLOAD_NO_RENEWAL; do
    value="${defaults[$name]}"
    if [[ -n "${CERTBOTBOT_FILE_VALUES[$name]+x}" ]]; then value="${CERTBOTBOT_FILE_VALUES[$name]}"; fi
    if [[ -n "${!name+x}" ]]; then value="${!name}"; fi
    if [[ -n "${cli[$name]+x}" ]]; then value="${cli[$name]}"; fi
    printf -v "CERTBOTBOT_$name" '%s' "$value"
  done
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
  for name in INCLUDE_SUBDOMAINS UPLOAD_NO_RENEWAL; do
    key="CERTBOTBOT_$name"
    case "${!key}" in true|false) ;; *) certbotbot_error 'invalid boolean setting'; return 64 ;; esac
  done
  [[ -n "$CERTBOTBOT_DOMAIN" ]] || { certbotbot_error 'DNS identity is required'; return 64; }
  [[ -n "$CERTBOTBOT_S3_BUCKET" && -n "$CERTBOTBOT_S3_KEY" ]] || { certbotbot_error 'S3 bucket and key are required'; return 64; }
  [[ "$CERTBOTBOT_S3_KEY" != -* && "$CERTBOTBOT_S3_KEY" != */* && "$CERTBOTBOT_S3_KEY" != *[[:space:]]* ]] || { certbotbot_error 'invalid S3 object key'; return 64; }
}
