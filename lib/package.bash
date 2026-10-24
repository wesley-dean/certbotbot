#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/package.bash
## @brief Builds and validates one private portable Certbot archive candidate.
## @details
## Implements ADR-027: only a complete selected lineage, safe existing
## production ACME account, and all canonical renewal configurations can enter
## the candidate stage. Source state is never rewritten to validate paths.
## GNU tar/gzip serializes config contents, and the existing bounded
## archive validator checks the exact bytes before the candidate appears.
##
## The builder does not execute Certbot, use S3, authorize publication, or
## decide whether a successful no-op must be uploaded. The lifecycle owns
## the private workspace, verifies certificate cryptography separately,
## and removes all local candidate material after the operation.

## @fn certbotbot_archive_package()
## @brief Builds one validated gzip tar candidate from selected durable state.
## @details
## Requires a canonical owned mode-0700 workspace with a complete
## WORKSPACE/config tree and an absent WORKSPACE/candidate.tar.gz. The
## account/lineage preflight must find the selected lineage present, while
## permitting other complete lineages. Every archived lineage is validated
## canonically before serializing the full unchanged configuration tree. The existing
## renewal parser's verify mode requires the five persisted path values
## to refer to canonical /etc/letsencrypt, and rejects unsupported
## metadata without modifying any source file. Selected private-key PEMs
## may not be readable by anyone other than the owner.
##
## GNU tar writes to an owned mode-0600 staging file using ustar headers,
## sorted member order and fixed numeric ownership. Only relative
## configuration contents are archived, retaining live PEM symlinks,
## versioned keys, account data and renewal configuration. Unsupported
## tar names, member types or permissions fail the shared pre-extraction
## validator. The temporary file is removed on failure; after successful
## validation it is renamed into the single fixed candidate path.
##
## The final candidate has not been cryptographically validated as a
## certificate and has not been uploaded. Consumers must separately
## prove usable certificate material and enforce the single-key
## publication policy and remote error semantics.
## @param workspace Canonical absolute caller-owned mode-0700 workspace.
## @param selected Stable selected non-wildcard certificate lineage name.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed non-sensitive diagnostics; no archive contents or tool output.
## @returns Nothing is written to STDOUT.
## @retval 0 One verified private candidate is present.
## @retval 64 Invalid workspace, name, or occupied candidate path.
## @retval 65 Unsafe source account, lineage, metadata, or candidate format.
## @retval 74 Local private staging or tar/gzip operation failed.
## @note The caller owns workspace cleanup and must serialize writers.
## @par Examples
## @code
## certbotbot_archive_package "$workspace" "$CERTBOTBOT_CERT_NAME" ||
##   exit $?
## # Verify certificate/key and upload policy before any S3 mutation.
## @endcode
certbotbot_archive_package() {
  local workspace selected config physical candidate staged='' unsafe
  if (( $# != 2 )); then
    printf '%s\n' 'certbotbot: invalid archive packaging arguments' >&2
    return 64
  fi
  workspace="$1"
  selected="$2"
  if [[ "$workspace" != /* || "$workspace" == / ||
    "$workspace" == */ || ! "$workspace" =~ ^/[A-Za-z0-9._/-]+$ ||
    ! -d "$workspace" || -L "$workspace" || ! -O "$workspace" ||
    "$selected" == *'*'* ]] ||
    ! certbotbot_dns_valid "$selected"; then
    printf '%s\n' 'certbotbot: invalid archive packaging input' >&2
    return 64
  fi
  physical="$(cd -P -- "$workspace" && pwd -P)" || return 64
  if [[ "$physical" != "$workspace" ||
    "$(stat -c %a -- "$workspace" 2>/dev/null)" != 700 ]]; then
    printf '%s\n' 'certbotbot: unsafe archive packaging workspace' >&2
    return 64
  fi
  candidate="$workspace/candidate.tar.gz"
  if [[ -e "$candidate" || -L "$candidate" ]]; then
    printf '%s\n' 'certbotbot: archive candidate already exists' >&2
    return 64
  fi
  config="$workspace/config"
  if ! certbotbot_state_preflight "$config" "$selected" >/dev/null 2>&1 ||
    [[ "$CERTBOTBOT_LINEAGE_STATE" != present ]] ||
    ! certbotbot_renewal_map "$config" "$selected" verify >/dev/null 2>&1 ||
    ! certbotbot_state_canonical_all "$config" "$selected" >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: selected archive state is unsuitable' >&2
    return 65
  fi

  # Verify private source data without altering its permissions or bytes.
  unsafe="$(find "$config" -type d -perm /022 -print -quit 2>/dev/null)" ||
    unsafe='unsafe'
  if [[ -z "$unsafe" ]]; then
    unsafe="$(find "$config" -type f -perm /022 -print -quit 2>/dev/null)" ||
      unsafe='unsafe'
  fi
  if [[ -z "$unsafe" ]]; then
    unsafe="$(find "$config/archive/$selected" -maxdepth 1 -type f \
      -name 'privkey[0-9]*.pem' -perm /077 -print -quit 2>/dev/null)" ||
      unsafe='unsafe'
  fi
  if [[ -n "$unsafe" ]]; then
    printf '%s\n' 'certbotbot: certificate state permissions are unsafe' >&2
    return 65
  fi
  if ! command -v tar >/dev/null 2>&1 ||
    ! command -v gzip >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: archive tooling unavailable' >&2
    return 74
  fi
  staged="$(umask 077; mktemp "$workspace/.candidate.XXXXXXXX")" || {
    printf '%s\n' 'certbotbot: archive staging unavailable' >&2
    return 74
  }
  if ! (umask 077; tar --format=ustar --sort=name --owner=0 \
    --group=0 --numeric-owner --gzip --create --file "$staged" \
    --directory "$config" . >/dev/null 2>&1); then
    rm -f -- "$staged"
    printf '%s\n' 'certbotbot: archive serialization failed' >&2
    return 74
  fi
  if ! certbotbot_archive_validate "$staged" >/dev/null 2>&1; then
    rm -f -- "$staged"
    printf '%s\n' 'certbotbot: archive candidate failed validation' >&2
    return 65
  fi
  if ! chmod 600 -- "$staged" ||
    [[ -e "$candidate" || -L "$candidate" ]] ||
    ! mv -T -- "$staged" "$candidate"; then
    rm -f -- "$staged"
    printf '%s\n' 'certbotbot: cannot install validated archive candidate' >&2
    return 74
  fi
  return 0
}
