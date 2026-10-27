#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/register-config.bash
## @brief Resolves the explicit account registration CLI under ADR-041.
## @details
## This parser is isolated from the ordinary issuer parser.  It shares the
## literal nonexecuting .env reader and safe S3 filename renderer, but never
## treats a domain or certificate flag as authorization to register an account.

## @fn certbotbot_register_usage()
## @brief Displays the separate registration command syntax.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Registration usage and recognized flags.
## @retval 0 Usage was printed.
certbotbot_register_usage() {
  cat <<'EOF'
Usage: certbotbot register [options]
  --email ADDRESS                   Required contact address
  --agree-tos true|false            Explicit consent; defaults false
  --eff-email-signup true|false     EFF signup; defaults true
  --acme-environment production|staging  Defaults production
  --s3-bucket BUCKET                Existing S3 bucket (required)
  --s3-key KEY                      Current archive key (latest.tar.gz)
  --s3-key-template TEMPLATE        Optional current key template
  --archive-encryption MODE         auto | none | gpg-ocb
  --config FILE                     Literal configuration file
EOF
}

## @fn certbotbot_register_config()
## @brief Validates consent, email, CA, S3 and encryption configuration.
## @details
## Values resolve CLI, exported environment, .env and default, in that order.
## The current S3 key and key-template are one mutually exclusive setting
## at each tier.  Missing or false TOS blocks any registration or S3 request.
## EFF signup is true unless the operator explicitly chooses false.
## @param ... Registration-only option tokens.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Static diagnostics only.
## @retval 0 All selected settings are usable.
## @retval 64 Invalid invocation or missing affirmative consent.
certbotbot_register_config() {
  local arg key name value file='' explicit=false tier
  local -a args=("$@")
  local -A cli=() defaults=([EMAIL]='' [AGREE_TOS]=false
    [EFF_EMAIL_SIGNUP]=true [ACME_ENVIRONMENT]=production
    [S3_BUCKET]='' [ARCHIVE_ENCRYPTION]=auto)
  local -i i=0
  CERTBOTBOT_FILE_VALUES=()
  while (( i < ${#args[@]} )); do
    arg="${args[i]}"
    case "$arg" in
      --email|--agree-tos|--eff-email-signup|--acme-environment|--s3-bucket|--s3-key|--s3-key-template|--archive-encryption|--config)
        (( i + 1 < ${#args[@]} )) ||
          { certbotbot_error 'registration option requires a value'; return 64; }
        value="${args[i+1]}"
        (( i+=2 ))
        ;;
      --email=*|--agree-tos=*|--eff-email-signup=*|--acme-environment=*|--s3-bucket=*|--s3-key=*|--s3-key-template=*|--archive-encryption=*|--config=*)
        value="${arg#*=}"
        arg="${arg%%=*}"
        (( i+=1 ))
        ;;
      *)
        certbotbot_error 'unknown registration option'
        return 64
        ;;
    esac
    case "$arg" in
      --email) key=EMAIL ;;
      --agree-tos) key=AGREE_TOS ;;
      --eff-email-signup) key=EFF_EMAIL_SIGNUP ;;
      --acme-environment) key=ACME_ENVIRONMENT ;;
      --s3-bucket) key=S3_BUCKET ;;
      --s3-key) key=S3_KEY ;;
      --s3-key-template) key=S3_KEY_TEMPLATE ;;
      --archive-encryption) key=ARCHIVE_ENCRYPTION ;;
      --config)
        [[ "$explicit" == false && -n "$value" ]] ||
          { certbotbot_error 'invalid registration config path'; return 64; }
        file="$value"
        explicit=true
        continue
        ;;
    esac
    [[ -n "$value" && -z "${cli[$key]+x}" ]] ||
      { certbotbot_error 'duplicate or empty registration option'; return 64; }
    cli["$key"]="$value"
  done
  if [[ "$explicit" == false && -f .env ]]; then file=.env; fi
  if [[ -n "$file" ]]; then
    certbotbot_read_env_file "$file" || return 64
    for key in "${!CERTBOTBOT_FILE_VALUES[@]}"; do
      case "$key" in
        EMAIL|AGREE_TOS|EFF_EMAIL_SIGNUP|ACME_ENVIRONMENT|S3_BUCKET|S3_KEY|S3_KEY_TEMPLATE|ARCHIVE_ENCRYPTION) ;;
        *) certbotbot_error 'issuer-only setting in registration file'; return 64 ;;
      esac
    done
  fi
  for name in EMAIL AGREE_TOS EFF_EMAIL_SIGNUP ACME_ENVIRONMENT S3_BUCKET ARCHIVE_ENCRYPTION; do
    value="${defaults[$name]}"
    if [[ -n "${CERTBOTBOT_FILE_VALUES[$name]+x}" ]]; then
      value="${CERTBOTBOT_FILE_VALUES[$name]}"
    fi
    if [[ -n "${!name+x}" ]]; then value="${!name}"; fi
    if [[ -n "${cli[$name]+x}" ]]; then value="${cli[$name]}"; fi
    printf -v "CERTBOTBOT_$name" '%s' "$value"
  done

  CERTBOTBOT_S3_KEY_IS_TEMPLATE=false
  CERTBOTBOT_S3_KEY=latest.tar.gz
  # Each higher precedence tier replaces the entire current-key choice.
  for tier in file environment cli; do
    case "$tier" in
      file)
        if [[ -n "${CERTBOTBOT_FILE_VALUES[S3_KEY]+x}" ||
          -n "${CERTBOTBOT_FILE_VALUES[S3_KEY_TEMPLATE]+x}" ]]; then
          [[ -z "${CERTBOTBOT_FILE_VALUES[S3_KEY]+x}" ||
            -z "${CERTBOTBOT_FILE_VALUES[S3_KEY_TEMPLATE]+x}" ]] ||
            { certbotbot_error 'conflicting current archive keys'; return 64; }
          if [[ -n "${CERTBOTBOT_FILE_VALUES[S3_KEY_TEMPLATE]+x}" ]]; then
            CERTBOTBOT_S3_KEY="${CERTBOTBOT_FILE_VALUES[S3_KEY_TEMPLATE]}"
            CERTBOTBOT_S3_KEY_IS_TEMPLATE=true
          else
            CERTBOTBOT_S3_KEY="${CERTBOTBOT_FILE_VALUES[S3_KEY]}"
            CERTBOTBOT_S3_KEY_IS_TEMPLATE=false
          fi
        fi
        ;;
      environment)
        if [[ -n "${S3_KEY+x}" || -n "${S3_KEY_TEMPLATE+x}" ]]; then
          [[ -z "${S3_KEY+x}" || -z "${S3_KEY_TEMPLATE+x}" ]] ||
            { certbotbot_error 'conflicting current archive keys'; return 64; }
          if [[ -n "${S3_KEY_TEMPLATE+x}" ]]; then
            CERTBOTBOT_S3_KEY="$S3_KEY_TEMPLATE"
            CERTBOTBOT_S3_KEY_IS_TEMPLATE=true
          else
            CERTBOTBOT_S3_KEY="$S3_KEY"
            CERTBOTBOT_S3_KEY_IS_TEMPLATE=false
          fi
        fi
        ;;
      cli)
        if [[ -n "${cli[S3_KEY]+x}" || -n "${cli[S3_KEY_TEMPLATE]+x}" ]]; then
          [[ -z "${cli[S3_KEY]+x}" || -z "${cli[S3_KEY_TEMPLATE]+x}" ]] ||
            { certbotbot_error 'conflicting current archive keys'; return 64; }
          if [[ -n "${cli[S3_KEY_TEMPLATE]+x}" ]]; then
            CERTBOTBOT_S3_KEY="${cli[S3_KEY_TEMPLATE]}"
            CERTBOTBOT_S3_KEY_IS_TEMPLATE=true
          else
            CERTBOTBOT_S3_KEY="${cli[S3_KEY]}"
            CERTBOTBOT_S3_KEY_IS_TEMPLATE=false
          fi
        fi
        ;;
    esac
  done

  [[ "$CERTBOTBOT_AGREE_TOS" == true ]] ||
    { certbotbot_error 'explicit terms agreement is required'; return 64; }
  [[ "$CERTBOTBOT_EFF_EMAIL_SIGNUP" == true ||
    "$CERTBOTBOT_EFF_EMAIL_SIGNUP" == false ]] ||
    { certbotbot_error 'invalid EFF signup preference'; return 64; }
  [[ "$CERTBOTBOT_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ &&
    "$CERTBOTBOT_EMAIL" != *..* && ${#CERTBOTBOT_EMAIL} -le 254 ]] ||
    { certbotbot_error 'invalid account contact email'; return 64; }
  case "$CERTBOTBOT_ACME_ENVIRONMENT" in
    production) CERTBOTBOT_REG_HOST=acme-v02.api.letsencrypt.org ;;
    staging) CERTBOTBOT_REG_HOST=acme-staging-v02.api.letsencrypt.org ;;
    *) certbotbot_error 'invalid ACME environment'; return 64 ;;
  esac
  CERTBOTBOT_REG_SERVER="https://$CERTBOTBOT_REG_HOST/directory"
  [[ "$CERTBOTBOT_S3_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] ||
    { certbotbot_error 'invalid S3 bucket'; return 64; }
  CERTBOTBOT_BACKUP_KEY_TEMPLATE_EXPLICIT=false
  CERTBOTBOT_DATED_BACKUP_ENABLED=false
  [[ -n "$CERTBOTBOT_S3_KEY" ]] ||
    { certbotbot_error 'invalid archive object key'; return 64; }
  certbotbot_filename_resolve || return 64
  [[ -n "$CERTBOTBOT_S3_KEY" && "$CERTBOTBOT_S3_KEY" != -* &&
    "$CERTBOTBOT_S3_KEY" != */* &&
    "$CERTBOTBOT_S3_KEY" != *[[:space:]]* ]] ||
    { certbotbot_error 'invalid archive object key'; return 64; }

  case "$CERTBOTBOT_ARCHIVE_ENCRYPTION" in
    auto)
      if [[ -n "${CERTBOTBOT_GPG_SECRET:-}" ]]; then
        CERTBOTBOT_ARCHIVE_ENCRYPTION=gpg-ocb
      else
        CERTBOTBOT_ARCHIVE_ENCRYPTION=none
      fi
      ;;
    none)
      [[ -z "${CERTBOTBOT_GPG_SECRET:-}" ]] ||
        { certbotbot_error 'key supplied with plaintext mode'; return 64; }
      ;;
    gpg-ocb)
      [[ -n "${CERTBOTBOT_GPG_SECRET:-}" ]] ||
        { certbotbot_error 'encrypted registration requires a key'; return 64; }
      ;;
    *) certbotbot_error 'invalid registration encryption mode'; return 64 ;;
  esac
  [[ "${CERTBOTBOT_GPG_SECRET:-}" != *$'\n'* &&
    "${CERTBOTBOT_GPG_SECRET:-}" != *$'\r'* ]] ||
    { certbotbot_error 'invalid encryption key'; return 64; }
  CERTBOTBOT_ARCHIVE_MIGRATION=none
  CERTBOTBOT_ARCHIVE_MIGRATION_BACKUP_CONFIRMED=false
}
