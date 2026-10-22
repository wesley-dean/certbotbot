#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/certbot.bash
## @brief Provides first-party selected-only Certbot DNS-01 issuance via Route53.
## @details
## Implements ADR-024 as a bounded execution adapter. Callers must first
## download and safely restore an existing archive into a private workspace.
## The provider checks selected identity and existing-account state before
## trusting an external Certbot process with ACME and AWS credentials.
## It does not register ACME accounts, renew existing lineages, execute
## restored hooks, validate issued PEMs, or publish a new S3 archive.
##
## Only installed Certbot and certbot-dns-route53 are supported. Production
## inherits the operator's AWS credentials and selected region. MVP tests use
## a deterministic executable mock instead of live cloud/ACME accounts.

## @fn certbotbot_provider_sans()
## @brief Verifies the bounded literal selected SAN set.
## @details
## Accepts one validated primary SAN or exactly an apex and its wildcard
## complement in either order. This is intentionally narrower than an
## arbitrary Certbot domain list; complex SAN composition is deferred.
## No argument is evaluated as shell syntax. Domain strings are forwarded
## as separate positional values to the external process.
## @param ... One or two already resolved DNS SAN strings.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @returns Nothing is written to STDOUT.
## @retval 0 SAN set matches the first-release contract.
## @retval 1 SAN count, syntax, case, or pairing is invalid.
certbotbot_provider_sans() {
  local name
  if (( $# < 1 || $# > 2 )); then return 1; fi
  for name in "$@"; do
    certbotbot_dns_valid "$name" || return 1
    [[ "$name" == "${name,,}" ]] || return 1
  done
  if (( $# == 2 )); then
    [[ "$1" != "$2" ]] || return 1
    [[ "$1" == "*.$2" || "$2" == "*.$1" ]] || return 1
  fi
  return 0
}

## @fn certbotbot_provider_issue()
## @brief Issues one absent selected lineage using an existing ACME account.
## @details
## Verifies one 0700 caller-owned workspace with canonical paths, a valid
## non-wildcard selected lineage name, a constrained literal SAN set, and
## account-only restored state. Rejects any existing/partial lineage before
## spawning Certbot. The provider refuses archived cli.ini and hook scripts
## through the preflight, and sets no implicit fallback account.
##
## Creates private work and logs directories when absent. Certbot's plugin
## listing and show_account probe must succeed before certonly is attempted.
## The exact account ID is passed explicitly; all Certbot calls use
## --config-dir, --work-dir, --logs-dir, --server, --non-interactive, and
## --no-directory-hooks. Certbot output is suppressed; fixed diagnostics
## replace untrusted external text. The process may contact AWS and ACME.
##
## A zero return means that Certbot's certonly command exited successfully.
## The lifecycle must still validate the resulting PEMs, desired SANs,
## account continuity, renewal metadata, and portable archive before any
## publication. The caller owns workspace cleanup and failure rollback.
## @param workspace Canonical absolute 0700 runner workspace.
## @param selected Stable validated non-wildcard Certbot lineage name.
## @param ... One or two literal DNS SANs chosen by the identity resolver.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## A fixed safe diagnostic on failure only, without Certbot output.
## @returns Nothing is written to STDOUT.
## @retval 0 Installed Certbot reported successful selected issuance.
## @retval 64 Invalid arguments or private workspace.
## @retval 65 Missing ACME account or existing/conflicting lineage state.
## @retval 69 Missing provider, missing Route53, or unreadable Certbot account.
## @retval 74 Failed issuance or local private staging.
## @note A success code is not certificate or persistence verification.
## @par Examples
## @code
## certbotbot_provider_issue "$workspace" "$CERTBOTBOT_CERT_NAME" \
##   "${CERTBOTBOT_SANS[@]}" || exit $?
## # Verify and canonicalize complete issued state before packaging.
## @endcode
certbotbot_provider_issue() {
  local workspace selected config physical work logs directory account=''
  local entry listing
  local -a common=() domains=()
  if (( $# < 3 )); then
    printf '%s\n' 'certbotbot: invalid selected issuance arguments' >&2
    return 64
  fi
  workspace="$1"
  selected="$2"
  shift 2
  if [[ "$workspace" != /* || "$workspace" == / ||
    ! "$workspace" =~ ^/[A-Za-z0-9._/-]+$ ||
    "$workspace" == */ || ! -d "$workspace" || -L "$workspace" ||
    ! -O "$workspace" || "$selected" == *'*'* ]] ||
    ! certbotbot_dns_valid "$selected" ||
    ! certbotbot_provider_sans "$@"; then
    printf '%s\n' 'certbotbot: invalid selected issuance input' >&2
    return 64
  fi
  physical="$(cd -P -- "$workspace" && pwd -P)" || return 64
  if [[ "$physical" != "$workspace" ||
    "$(stat -c %a -- "$workspace" 2>/dev/null)" != 700 ]]; then
    printf '%s\n' 'certbotbot: unsafe Certbot workspace' >&2
    return 64
  fi
  config="$workspace/config"
  work="$workspace/work"
  logs="$workspace/logs"

  # Validate both existing and prospective paths before making directories.
  for directory in "$work" "$logs"; do
    if [[ -e "$directory" || -L "$directory" ]]; then
      if [[ ! -d "$directory" || -L "$directory" ||
        ! -O "$directory" ||
        "$(stat -c %a -- "$directory" 2>/dev/null)" != 700 ]]; then
        printf '%s\n' 'certbotbot: unsafe private Certbot directories' >&2
        return 64
      fi
    fi
  done
  if ! certbotbot_state_preflight "$config" "$selected" >/dev/null 2>&1 ||
    [[ "$CERTBOTBOT_LINEAGE_STATE" != absent ]]; then
    printf '%s\n' 'certbotbot: existing account or lineage unsuitable' >&2
    return 65
  fi

  if ! command -v certbot >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: installed Certbot is required' >&2
    return 69
  fi

  directory="$config/accounts/acme-v02.api.letsencrypt.org/directory"
  for entry in "$directory/"*; do
    [[ -d "$entry" && ! -L "$entry" ]] || continue
    account="${entry##*/}"
    break
  done
  if [[ ! "$account" =~ ^[A-Za-z0-9_-]+$ ]]; then
    printf '%s\n' 'certbotbot: unsupported ACME account identity' >&2
    return 65
  fi

  for directory in "$work" "$logs"; do
    if [[ ! -e "$directory" ]] &&
      ! (umask 077; mkdir -m 700 -- "$directory"); then
      printf '%s\n' 'certbotbot: private Certbot staging unavailable' >&2
      return 74
    fi
  done
  common=(
    --config-dir "$config"
    --work-dir "$work"
    --logs-dir "$logs"
    --server https://acme-v02.api.letsencrypt.org/directory
    --non-interactive
    --no-directory-hooks
  )

  listing="$(umask 077; mktemp "$logs/plugins.XXXXXXXX")" || {
    printf '%s\n' 'certbotbot: private Certbot staging unavailable' >&2
    return 74
  }
  if ! command certbot plugins --authenticators "${common[@]}" \
    >"$listing" 2>/dev/null; then
    rm -f -- "$listing"
    printf '%s\n' 'certbotbot: Certbot authenticator probe failed' >&2
    return 69
  fi
  if ! LC_ALL=C grep -Eq '^[[:space:]]*\*[[:space:]]+dns-route53([[:space:]]|$)' "$listing"; then
    rm -f -- "$listing"
    printf '%s\n' 'certbotbot: Certbot Route53 authenticator unavailable' >&2
    return 69
  fi
  rm -f -- "$listing"

  if ! command certbot show_account --account "$account" \
    "${common[@]}" >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: restored account is not recognized by Certbot' >&2
    return 69
  fi

  for entry in "$@"; do
    domains+=(-d "$entry")
  done
  if ! command certbot certonly --dns-route53 --preferred-challenges dns-01 \
    --account "$account" --cert-name "$selected" "${domains[@]}" \
    "${common[@]}" >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: selected certificate issuance failed' >&2
    return 74
  fi
  return 0
}
