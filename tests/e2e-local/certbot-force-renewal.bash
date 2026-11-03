#!/usr/bin/env bash
# shellcheck shell=bash
## @file tests/e2e-local/certbot-force-renewal.bash
## @brief Delegates to real Certbot, authorizing one isolated selected renewal.
## @details
## Test-only PATH adapter in the separately built local E2E runner, never in the
## public certbotbot distribution or release image. A private one-shot marker
## permits appending --force-renewal to exactly one canonical staging renewal.
## All normal Certbot operations are delegated unchanged; no ACME response,
## provider result, certificate or renewal config is synthesized. ADR-049.
## Marker/receipt live only in the runner's own mode-0700 tmpfs directory.

set -euo pipefail
umask 077

readonly REAL_CERTBOT=/usr/bin/certbot
readonly STATE=/tmp/.certbotbot-e2e-renewal
readonly INTENT="$STATE/intent"
readonly RECEIPT="$STATE/receipt"
readonly SELECTED=test.e2e.test
readonly STAGING=https://acme-staging-v02.api.letsencrypt.org/directory

## @fn refuse()
## @brief Refuses an unsafe attempted test-only force request.
## @retval 65 No real Certbot operation is executed.
refuse() {
  printf '%s\n' 'local-certbot-adapter: rejected isolated renewal request' >&2
  return 65
}

## @fn authorized_selected_renew()
## @brief Checks exact immutable producer renew argument shape and private state.
## @param ... Exact real-Certbot argv from certbotbot's selected renewal path.
## @retval 0 The one selected staging command shape is authorized.
## @retval 65 The request differs from the reviewed test-only contract.
authorized_selected_renew() {
  local account='' config='' work='' logs='' parent=''
  (( $# == 15 )) || return 65
  [[ "$1" == renew && "$2" == --cert-name && "$3" == "$SELECTED" &&
    "$4" == --account && "$6" == --config-dir &&
    "$8" == --work-dir && "${10}" == --logs-dir &&
    "${12}" == --server && "${13}" == "$STAGING" &&
    "${14}" == --non-interactive && "${15}" == --no-directory-hooks ]] ||
    return 65
  account="$5"
  config="$7"
  work="$9"
  logs="${11}"
  [[ "$account" =~ ^[A-Za-z0-9_-]+$ ]] || return 65
  # Certbot's private workspace is allocated by the unchanged producer.
  [[ "$config" =~ ^/tmp/[A-Za-z0-9._/-]+/config$ ]] || return 65
  parent="${config%/config}"
  [[ "$work" == "$parent/work" && "$logs" == "$parent/logs" ]] || return 65
  [[ -d "$parent" && -O "$parent" && ! -L "$parent" &&
    -d "$config" && ! -L "$config" && -O "$config" ]] || return 65
  [[ "$(stat -c %a -- "$parent" 2>/dev/null)" == 700 ]] || return 65
  return 0
}

## @fn main()
## @brief Consumes one private marker and execs installed Certbot without mocks.
## @param ... Real Certbot CLI arguments.
main() {
  [[ -x "$REAL_CERTBOT" ]] || return 69
  # A plain test runner has no marker: every existing registration, issuance,
  # plugin probe, show_account and normal no-op works exactly as installed.
  if [[ ! -e "$INTENT" && ! -e "$RECEIPT" ]]; then
    exec "$REAL_CERTBOT" "$@"
  fi
  [[ -d "$STATE" && ! -L "$STATE" && -O "$STATE" &&
    "$(stat -c %a -- "$STATE" 2>/dev/null)" == 700 ]] || refuse || return 65
  if [[ "${1-}" != renew ]]; then
    # certbotbot probes plugins/show_account before calling selected renew.
    exec "$REAL_CERTBOT" "$@"
  fi
  [[ ! -e "$RECEIPT" && -f "$INTENT" && ! -L "$INTENT" &&
    -O "$INTENT" && "$(stat -c %a -- "$INTENT" 2>/dev/null)" == 600 &&
    "$(cat -- "$INTENT" 2>/dev/null)" == "certbotbot-e2e-task-248" ]] ||
    refuse || return 65
  authorized_selected_renew "$@" || refuse || return 65
  # One-shot consumption is done before any network contact; failure does
  # not imply a remote action was rolled back.
  rm -f -- "$INTENT" || return 65
  printf '%s\n' "real-certbot-selected-renewal-forced" >"$RECEIPT" || return 65
  chmod 600 -- "$RECEIPT" || return 65
  exec "$REAL_CERTBOT" "$@" --force-renewal
}

main "$@"
