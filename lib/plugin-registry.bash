# shellcheck shell=bash
## @file lib/plugin-registry.bash
## @brief Registers built-in DNS and storage adapters by typed provider name.
## @details
## Provider source files are discovered only by Make during artifact assembly.
## They register fixed names here when the generated executable is loaded.
## Registration does not source external files, inspect runtime directories, or
## authorize consumers to install arbitrary plugins.  Backend implementations
## run in the producer's Bash process and inherit its authority.  Keys are
## constrained before associative-array use to avoid Bash subscript hazards.

declare -A CERTBOTBOT_PROVIDER_HANDLERS=()
declare -a CERTBOTBOT_PROVIDER_NAMES=()

## @fn certbotbot_provider_register()
## @brief Registers a reviewed, statically included provider implementation.
## @param category One of dns or storage.
## @param name Stable lowercase built-in provider identifier.
## @param handler Existing Bash function name for the provider.
## @retval 0 Provider was registered.
## @retval 64 The identifier or handler was invalid or registered already.
## @par Standard Output
## Nothing is written to STDOUT.
## @par Examples
## @code
## certbotbot_provider_register dns route53 certbotbot_dns_route53_run
## @endcode
certbotbot_provider_register() {
  local category=${1:-} name=${2:-} handler=${3:-} key

  if (( $# != 3 )) || [[ ! ${category} =~ ^(dns|storage)$ ]] ||
    [[ ! ${name} =~ ^[a-z][a-z0-9_-]*$ ]] ||
    [[ ! ${handler} =~ ^[a-zA-Z_][a-zA-Z_0-9]*$ ]]; then
    printf '%s\n' 'invalid built-in provider registration' >&2
    return 64
  fi

  if ! declare -F "${handler}" >/dev/null; then
    printf 'provider handler missing: %s\n' "${handler}" >&2
    return 64
  fi

  key="${category}:${name}"
  if [[ -n ${CERTBOTBOT_PROVIDER_HANDLERS[${key}]+_} ]]; then
    printf 'duplicate built-in provider: %s\n' "${key}" >&2
    return 64
  fi

  CERTBOTBOT_PROVIDER_HANDLERS["${key}"]="${handler}"
  CERTBOTBOT_PROVIDER_NAMES+=("${key}")
}

## @fn certbotbot_provider_exists()
## @brief Checks a registered category/name pair without evaluating it.
## @param category Provider category.
## @param name Provider identifier.
## @retval 0 The provider exists in this release artifact.
## @retval 1 The requested provider is absent or its identifier is invalid.
## @par Standard Output
## Nothing is written to STDOUT.
certbotbot_provider_exists() {
  local category=${1:-} name=${2:-} key
  if (( $# != 2 )) || [[ ! ${category} =~ ^(dns|storage)$ ]] ||
    [[ ! ${name} =~ ^[a-z][a-z0-9_-]*$ ]]; then
    return 1
  fi
  key="${category}:${name}"
  [[ -n ${CERTBOTBOT_PROVIDER_HANDLERS[${key}]+_} ]]
}
