#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/reconcile.bash
## @brief Reconciles the selected Certbot lineage's apex/wildcard SAN policy.
## @details
## Implements ADR-026 without activating public S3 publication. The
## existing-lineage dispatcher uses ordinary renewal when the desired
## SAN set already matches. A controlled different same-apex set uses
## certonly --cert-name --renew-with-new-domains. All work remains in the
## caller's disposable private workspace, using the previously restored
## account; failures must never authorize a remote archive write.

## @fn certbotbot_provider_existing()
## @brief Dispatches a complete selected lineage to renewal or reconciliation.
## @details
## An unchanged exact leaf DNS SAN set follows certbotbot_provider_renew
## and retains Certbot's ordinary renewal/no-op behavior. Any mismatch
## follows certbotbot_provider_reconcile, which separately checks whether
## the original and desired SANs share the same apex/wildcard policy.
## The public executable remains unavailable until full lifecycle gating.
## @param workspace Private restored mode-0700 workspace path.
## @param selected Explicit stable non-wildcard Certbot certificate name.
## @param ... One or two exact desired literal DNS SANs.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed diagnostics only; provider output is suppressed.
## @returns Nothing is written to STDOUT.
## @retval 0 Verified selected-only renewal or SAN reconciliation.
## @retval 64 Invalid arguments or runtime workspace.
## @retval 65 Unsuitable local state, SAN policy or post-Certbot state.
## @retval 69 Missing/failed provider or ACME account recognition.
## @retval 74 External issuance or private staging failed.
## @note Success reports only local state, not S3 publication.
certbotbot_provider_existing() {
  local workspace selected
  CERTBOTBOT_RENEWAL_OCCURRED=''
  CERTBOTBOT_DURABLE_CHANGED=''
  if (( $# < 3 )); then
    printf '%s\n' 'certbotbot: invalid selected certificate arguments' >&2
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
    printf '%s\n' 'certbotbot: invalid selected certificate input' >&2
    return 64
  fi
  if [[ "$(cd -P -- "$workspace" && pwd -P)" != "$workspace" ||
    "$(stat -c %a -- "$workspace" 2>/dev/null)" != 700 ]]; then
    printf '%s\n' 'certbotbot: unsafe selected certificate workspace' >&2
    return 64
  fi
  if ! certbotbot_state_preflight "$workspace/config" "$selected" >/dev/null 2>&1 ||
    [[ "$CERTBOTBOT_LINEAGE_STATE" != present ]]; then
    printf '%s\n' 'certbotbot: selected lineage is unsuitable' >&2
    return 65
  fi
  if certbotbot_renew_sans_match "$workspace/config/live/$selected/cert.pem" "$@"; then
    certbotbot_provider_renew "$workspace" "$selected" "$@"
    return $?
  fi
  certbotbot_provider_reconcile "$workspace" "$selected" "$@"
}

## @fn certbotbot_provider_reconcile()
## @brief Updates only the existing selected lineage's supported SAN policy.
## @details
## This adapter requires a complete selected lineage and one existing ACME
## account, and refuses unknown SANs before any provider invocation.
## Both existing and desired sets must be among apex-only, wildcard-only,
## and apex-plus-wildcard for the same apex. A matching set is a regular
## renewal, not an explicit reissue; callers use provider_existing.
##
## The installed Certbot and DNS-Route53 authenticator are probed before
## any certificate mutation. The selected renewal file is mapped into the
## private config root, then certbot certonly updates exactly the selected
## --cert-name with --renew-with-new-domains and the exact desired -d SANs.
## The restored account ID is required and verified again after Certbot.
## The resulting leaf must contain the exact requested DNS SANs and must
## differ from the prior leaf or its live symlink target. The renewal path
## mapper returns stored paths to /etc/letsencrypt before success.
##
## Failures clear both result variables, and the caller must destroy the
## affected private workspace. No uploaded state is changed in this module.
## @param workspace Canonical absolute owned 0700 invocation workspace.
## @param selected Explicit selected non-wildcard certificate lineage name.
## @param ... One or two exact desired DNS SANs.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Static non-secret diagnostics; Certbot output is not forwarded.
## @returns Nothing is written to STDOUT.
## @retval 0 The selected lineage was updated with the exact desired SANs.
## @retval 64 Invalid arguments or unsafe workspace.
## @retval 65 Unsafe account, lineage, SAN policy, or post-issuance state.
## @retval 69 Unavailable Certbot, authenticator, or account probe.
## @retval 74 Certbot reissue or local staging failed.
## @par Examples
## @code
## certbotbot_provider_existing "$workspace" "$name" "${sans[@]}" || exit $?
## # Full lifecycle validation is still required before S3 publication.
## @endcode
certbotbot_provider_reconcile() {
  local workspace selected config physical cert apex wildcard account=''
  local work logs entry directory listing before_cert after_cert
  local before_link after_link before_state after_state
  local prior_known=false
  local -a common=() domains=()
  CERTBOTBOT_RENEWAL_OCCURRED=''
  CERTBOTBOT_DURABLE_CHANGED=''

  if (( $# < 3 )); then
    printf '%s\n' 'certbotbot: invalid SAN reconciliation arguments' >&2
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
    printf '%s\n' 'certbotbot: invalid SAN reconciliation input' >&2
    return 64
  fi
  physical="$(cd -P -- "$workspace" && pwd -P)" || return 64
  if [[ "$physical" != "$workspace" ||
    "$(stat -c %a -- "$workspace" 2>/dev/null)" != 700 ]]; then
    printf '%s\n' 'certbotbot: unsafe SAN reconciliation workspace' >&2
    return 64
  fi
  config="$workspace/config"
  work="$workspace/work"
  logs="$workspace/logs"
  for directory in "$work" "$logs"; do
    if [[ -e "$directory" || -L "$directory" ]]; then
      if [[ ! -d "$directory" || -L "$directory" || ! -O "$directory" ||
        "$(stat -c %a -- "$directory" 2>/dev/null)" != 700 ]]; then
        printf '%s\n' 'certbotbot: unsafe private Certbot directories' >&2
        return 64
      fi
    fi
  done

  if ! certbotbot_state_preflight "$config" "$selected" >/dev/null 2>&1 ||
    [[ "$CERTBOTBOT_LINEAGE_STATE" != present ]]; then
    printf '%s\n' 'certbotbot: selected lineage is unsuitable for SAN change' >&2
    return 65
  fi
  cert="$config/live/$selected/cert.pem"
  apex="${1#\*.}"
  wildcard="*.$apex"

  # Only the same apex's 1-name or 2-name combinations may be modified.
  if certbotbot_renew_sans_match "$cert" "$apex" ||
    certbotbot_renew_sans_match "$cert" "$wildcard" ||
    certbotbot_renew_sans_match "$cert" "$apex" "$wildcard"; then
    prior_known=true
  fi
  if [[ "$prior_known" != true ]] ||
    certbotbot_renew_sans_match "$cert" "$@"; then
    printf '%s\n' 'certbotbot: unsupported or unchanged certificate SAN policy' >&2
    return 65
  fi

  if ! command -v certbot >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: installed Certbot is required' >&2
    return 69
  fi
  if ! command -v sha256sum >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: certificate comparison tool unavailable' >&2
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
  common=(--config-dir "$config" --work-dir "$work" --logs-dir "$logs" --server https://acme-v02.api.letsencrypt.org/directory --non-interactive --no-directory-hooks)
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
    printf '%s\n' 'certbotbot: account not recognized by Certbot' >&2
    return 69
  fi

  before_link="$(readlink -- "$cert")" || return 65
  before_cert="$(sha256sum -- "$cert" 2>/dev/null)" || return 65
  before_cert="${before_cert%% *}"
  before_state="$(certbotbot_renew_fingerprint "$config")" || {
    printf '%s\n' 'certbotbot: unable to inspect existing durable state' >&2
    return 74
  }
  if ! certbotbot_renewal_map "$config" "$selected" prepare >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: private renewal path preparation failed' >&2
    return 65
  fi

  for entry in "$@"; do
    domains+=(-d "$entry")
  done
  if ! command certbot certonly --dns-route53 --preferred-challenges dns-01 \
    --renew-with-new-domains --account "$account" --cert-name "$selected" \
    "${domains[@]}" "${common[@]}" >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: selected SAN reconciliation failed' >&2
    return 74
  fi
  if ! certbotbot_state_preflight "$config" "$selected" >/dev/null 2>&1 ||
    [[ "$CERTBOTBOT_LINEAGE_STATE" != present ]]; then
    printf '%s\n' 'certbotbot: reconciled lineage failed local validation' >&2
    return 65
  fi
  if [[ ! -d "$directory/$account" ]]; then
    printf '%s\n' 'certbotbot: restored ACME account identity changed' >&2
    return 65
  fi
  if ! certbotbot_renew_sans_match "$cert" "$@"; then
    printf '%s\n' 'certbotbot: reconciled certificate SANs do not match' >&2
    return 65
  fi
  if ! certbotbot_renewal_map "$config" "$selected" finalize >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: canonical renewal mapping failed' >&2
    return 65
  fi
  after_link="$(readlink -- "$cert")" || return 65
  after_cert="$(sha256sum -- "$cert" 2>/dev/null)" || return 65
  after_cert="${after_cert%% *}"
  after_state="$(certbotbot_renew_fingerprint "$config")" || {
    printf '%s\n' 'certbotbot: unable to inspect updated durable state' >&2
    return 74
  }
  if [[ "$before_link" == "$after_link" &&
    "$before_cert" == "$after_cert" ]] ||
    [[ "$before_state" == "$after_state" ]]; then
    printf '%s\n' 'certbotbot: SAN reconciliation did not replace certificate' >&2
    return 65
  fi
  # shellcheck disable=SC2034
  CERTBOTBOT_RENEWAL_OCCURRED=true
  # shellcheck disable=SC2034
  CERTBOTBOT_DURABLE_CHANGED=true
  return 0
}
