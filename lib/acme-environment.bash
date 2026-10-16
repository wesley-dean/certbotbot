# shellcheck shell=bash
## @file lib/acme-environment.bash
## @brief Defines the supported Let's Encrypt environments and archive identities.
## @details
## Production remains the existing default, using unprefixed archive keys.
## Staging is an explicit opt-in which selects Let's Encrypt's fixed staging
## ACME directory and a staging/ object-key prefix.  This prefix applies
## to the common archive and every domain lineage equally, and is enforced
## at the S3 adapter boundary as well as the higher-level key builder.
##
## The two fixed URLs cannot be replaced by user-provided ACME endpoints.
## Staging certificates are intentionally untrusted by ordinary client
## trust stores.  Cryptographic verification requires a controlled staging
## CA bundle, provided separately to the future issuance workflow.
## @see doc/adr/ADR-030-isolated-letsencrypt-environments.md

## @fn certbotbot_acme_validate_environment()
## @brief Accepts exactly production or staging.
## @param environment Requested Let's Encrypt ACME environment.
## @retval 0 Supported environment.
## @retval 64 Unknown, missing, or additional arguments.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_acme_validate_environment() {
  if (( $# != 1 )); then
    return 64
  fi
  case "$1" in
    production | staging) return 0 ;;
    *) return 64 ;;
  esac
}

## @fn certbotbot_acme_directory()
## @brief Prints the fixed ACME directory URL for one supported environment.
## @param environment production or staging.
## @retval 0 The fixed URL was printed.
## @retval 64 Invalid selection.
## @par STDIN
## Nothing is read from STDIN.
## @returns One URL followed by a newline on STDOUT.
certbotbot_acme_directory() {
  local environment=${1:-}
  certbotbot_acme_validate_environment "$@" || return 64
  case "$environment" in
    production)
      printf '%s\n' 'https://acme-v02.api.letsencrypt.org/directory'
      ;;
    staging)
      printf '%s\n' 'https://acme-staging-v02.api.letsencrypt.org/directory'
      ;;
  esac
}

## @fn certbotbot_acme_object_key()
## @brief Derives one storage key with strict staging/production separation.
## @param environment production or staging.
## @param logical_key A single unprefixed common or domain latest archive name.
## @retval 0 The canonical storage key was printed.
## @retval 64 Unsafe archive name or unsupported environment.
## @par STDIN
## Nothing is read from STDIN.
## @returns One S3 object key followed by a newline on STDOUT.
## @note Existing production archive names intentionally remain unchanged.
certbotbot_acme_object_key() {
  local LC_ALL=C
  local environment=${1:-} logical_key=${2:-}
  if (( $# != 2 )) ||
    ! certbotbot_acme_validate_environment "$environment" ||
    [[ ! $logical_key =~ ^[a-z0-9][a-z0-9.-]*-latest[.]tar[.]gz([.]enc)?$ ||
      $logical_key == *..* ]]; then
    return 64
  fi
  if [[ $environment == staging ]]; then
    printf 'staging/%s\n' "$logical_key"
  else
    printf '%s\n' "$logical_key"
  fi
}
