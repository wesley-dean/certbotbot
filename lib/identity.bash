#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/identity.bash
## @brief Validates one primary DNS identity and constructs the selected SANs.
## @details
## All input is checked before calling external tools. Derived names and
## certificate identities are deterministic across independent workspaces.
## Names from SANs are checked for safe non-wildcard lineage usage before S3
## retrieval or issuance; lexical ties are resolved using ASCII ordering.

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

## @fn certbotbot_identity_shortest()
## @brief Chooses one safe, shortest textual Certbot lineage from canonical SANs.
## @details
## Compares full SAN lengths, including the wildcard prefix, using an ASCII
## lexical tie-break independent of the invoking process's locale.  This is an
## internal selector, not an additional-SAN public interface.  It rejects a
## wildcard-only derived lineage instead of passing a wildcard to Certbot.
## @param ... One or more canonical DNS SAN candidates.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @returns Selected lineage in REPLY on success; empty on failure.
## @retval 0 A safe non-wildcard lineage was selected.
## @retval 1 No candidates, malformed SAN, or derived wildcard lineage.
certbotbot_identity_shortest() {
  local candidate selected=''
  # Explicitly override inherited LC_ALL; Bash [[ < ]] is locale-sensitive.
  local LC_ALL=C
  REPLY=''
  (( $# > 0 )) || return 1
  for candidate in "$@"; do
    if ! certbotbot_dns_valid "$candidate"; then
      return 1
    fi
    if [[ -z "$selected" ]] ||
      (( ${#candidate} < ${#selected} )) ||
      { (( ${#candidate} == ${#selected} )) &&
        [[ "$candidate" < "$selected" ]]; }; then
      selected="$candidate"
    fi
  done
  [[ "$selected" != *\** ]] || return 1
  REPLY="$selected"
  return 0
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
  if [[ -n "$CERTBOTBOT_CERT_NAME" ]]; then
    if [[ "$CERTBOTBOT_CERT_NAME" == *\** ]] ||
      ! certbotbot_dns_valid "$CERTBOTBOT_CERT_NAME"; then
      certbotbot_error 'invalid certificate name'
      return 64
    fi
  else
    if ! certbotbot_identity_shortest "${CERTBOTBOT_SANS[@]}"; then
      certbotbot_error 'invalid derived certificate name'
      return 64
    fi
    CERTBOTBOT_CERT_NAME="$REPLY"
  fi
}
