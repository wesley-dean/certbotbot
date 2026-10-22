#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/identity.bash
## @brief Validates one primary DNS identity and constructs the selected SANs.
## @details
## All input is checked before calling external tools. Derived names and
## certificate identities are deterministic across independent workspaces.

## @fn certbotbot_dns_valid()
## @brief Validates canonical ASCII DNS names, optionally wildcard-prefixed.
## @param name Primary name or SAN.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @retval 0 The DNS name is valid.
## @retval 1 The DNS name is invalid.
certbotbot_dns_valid() {
  local name="$1" label
  [[ "$name" != *. && "$name" != .* && "$name" != *..* ]] || return 1
  [[ "$name" == \*.* ]] && name="${name#\*.}"
  [[ "${#name}" -le 253 && "$name" == *.* && "$name" != *\** ]] || return 1
  [[ "$name" == "${name,,}" ]] || return 1
  [[ "$name" =~ ^[a-z0-9.-]+$ ]] || return 1
  local -a labels=()
  IFS=. read -r -a labels <<< "$name"
  (("${#labels[@]}" >= 2)) || return 1
  for label in "${labels[@]}"; do
    [[ "${#label}" -ge 1 && "${#label}" -le 63 &&
       "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

## @fn certbotbot_identity_resolve()
## @brief Computes requested SANs and stable Certbot lineage identifier.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Non-sensitive diagnostics.
## @retval 0 Selected identity is valid.
## @retval 64 Identity or certificate name is invalid.
certbotbot_identity_resolve() {
  CERTBOTBOT_DOMAIN="${CERTBOTBOT_DOMAIN,,}"
  if ! certbotbot_dns_valid "$CERTBOTBOT_DOMAIN"; then
    certbotbot_error 'invalid primary DNS identity'
    return 64
  fi
  CERTBOTBOT_SANS=("$CERTBOTBOT_DOMAIN")
  if [[ "$CERTBOTBOT_INCLUDE_SUBDOMAINS" == true ]]; then
    if [[ "$CERTBOTBOT_DOMAIN" == \*.* ]]; then
      CERTBOTBOT_SANS+=("${CERTBOTBOT_DOMAIN#\*.}")
    else
      CERTBOTBOT_SANS+=("*.$CERTBOTBOT_DOMAIN")
    fi
  fi
  local candidate
  if [[ -n "$CERTBOTBOT_CERT_NAME" ]]; then
    if [[ "$CERTBOTBOT_CERT_NAME" == *\** ]] || ! certbotbot_dns_valid "$CERTBOTBOT_CERT_NAME"; then
      certbotbot_error 'invalid certificate name'
      return 64
    fi
  else
    CERTBOTBOT_CERT_NAME="${CERTBOTBOT_SANS[0]}"
    for candidate in "${CERTBOTBOT_SANS[@]:1}"; do
      if (( ${#candidate} < ${#CERTBOTBOT_CERT_NAME} )) ||
         { (( ${#candidate} == ${#CERTBOTBOT_CERT_NAME} )) &&
           [[ "$candidate" < "$CERTBOTBOT_CERT_NAME" ]]; }; then
        CERTBOTBOT_CERT_NAME="$candidate"
      fi
    done
  fi
}
