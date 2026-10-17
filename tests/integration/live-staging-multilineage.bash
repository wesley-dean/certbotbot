#!/usr/bin/env bash
# shellcheck shell=bash
## @file tests/integration/live-staging-multilineage.bash
## @brief Opt-in, real staging evidence for two separately archived lineages.
## @details
## This additional ADR-053 evidence stage reuses ADR-044's encrypted common
## account and first lineage, issues an independent second lineage under the
## same genuine staging account, and exports three disjoint ciphertext blobs.
## A different runner assembles both as a non-activating ADR-045 candidate
## and cryptographically checks both certificates. This is NOT production
## active-state import and cannot run in ordinary CI.
## @see doc/adr/ADR-053-two-real-lineage-staging-evidence.md

set -euo pipefail
umask 077

# Source reviewed ADR-044 staging utilities without invoking staging_main.
# shellcheck source=tests/integration/live-staging-portability.bash
source "$(dirname -- "${BASH_SOURCE[0]}")/live-staging-portability.bash"

## @fn staging_multi_validate()
## @brief Validate exact lineage identities, artifact, and selected phase.
## @param phase guard, issue-second, or verify-two.
## @retval 0 Canonical, distinct, subordinate names are selected.
## @retval 64 Invalid target, artifact, or phase.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
staging_multi_validate() {
  local phase=${1:-} second=${CERTBOTBOT_STAGING_SECOND_NAME:-}
  case $phase in
    guard | issue-second | verify-two) ;;
    *) return 64 ;;
  esac
  staging_validate_request || return 64
  certbotbot_validate_hostname "$second" || return 64
  [[ $second != '*.'* && $second == "${second,,}" &&
    $second == *".$CERTBOTBOT_STAGING_DOMAIN" &&
    $second != "$CERTBOTBOT_STAGING_EXTRA_NAME" &&
    $second != "$CERTBOTBOT_STAGING_DOMAIN" ]] || return 64
}

## @fn staging_multi_authorize()
## @brief Refuse all sensitive phases without explicit staging-only consent.
## @param phase Selected permitted integration mode.
## @retval 0 Scope is deliberately approved for the selected phase.
## @retval 64 Failed consent, GPG, CA, or environment boundaries.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
staging_multi_authorize() {
  local phase=$1
  [[ ${CERTBOTBOT_STAGING_CONFIRM:-} == yes &&
    ${CERTBOTBOT_STAGING_PHASE:-} == "$phase" &&
    ${ACME_ENVIRONMENT:-} == staging &&
    -n ${GPG_PASSPHRASE:-} &&
    $GPG_PASSPHRASE != *[[:cntrl:]]* &&
    -n ${CERTBOTBOT_STAGING_CA_BUNDLE:-} &&
    -f $CERTBOTBOT_STAGING_CA_BUNDLE &&
    ! -L $CERTBOTBOT_STAGING_CA_BUNDLE &&
    -n ${CERTBOTBOT_STAGING_INPUT_DIR:-} &&
    $CERTBOTBOT_STAGING_INPUT_DIR == /* &&
    -d $CERTBOTBOT_STAGING_INPUT_DIR &&
    ! -L $CERTBOTBOT_STAGING_INPUT_DIR &&
    $- != *x* ]] || return 64
  if [[ $phase == verify-two ]]; then
    [[ -n ${CERTBOTBOT_EXPECTED_SECOND_LEAF_SHA256:-} ]] || return 64
  fi
  if [[ $phase == issue-second ]]; then
    [[ -n ${CERTBOT:-} && $CERTBOT == /* && -x $CERTBOT &&
      -n ${CERTBOTBOT_STAGING_EMAIL:-} &&
      -n ${CERTBOTBOT_STAGING_OUTPUT_DIR:-} &&
      $CERTBOTBOT_STAGING_OUTPUT_DIR == /* &&
      -d $CERTBOTBOT_STAGING_OUTPUT_DIR &&
      ! -L $CERTBOTBOT_STAGING_OUTPUT_DIR ]] || return 64
    [[ "$(stat -c '%a' -- "$CERTBOTBOT_STAGING_OUTPUT_DIR")" == 700 ]] ||
      return 64
  fi
}

## @fn staging_multi_hash()
## @brief Return the exact leaf certificate body fingerprint for one lineage.
## @param config Private Certbot-style config tree.
## @param name Canonical selected lineage.
## @retval 0 File was readable and hashed.
## @returns One SHA-256 fingerprint and newline.
## @par STDIN
## Nothing is read from STDIN.
staging_multi_hash() {
  local path="$1/live/$2/cert.pem"
  [[ -f $path && ! -L $path ]] || return 65
  sha256sum -- "$path" | cut -d ' ' -f1
}

## @fn staging_multi_check()
## @brief Verify exact single-SAN second lineage with pinned staging CA.
## @param config Private selected config.
## @retval 0 PEM, chain, key, and sole SAN all validate.
## @note Other crypto-validator statuses propagate.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
staging_multi_check() {
  local config=$1 name=$CERTBOTBOT_STAGING_SECOND_NAME
  certbotbot_pem_assemble "$config" "$name"
  certbotbot_crypto_verify_lineage "$config" "$name" \
    "$CERTBOTBOT_STAGING_CA_BUNDLE"
  certbotbot_crypto_verify_sans "$config" "$name" "$name"
}

## @fn staging_multi_pack_domain()
## @brief Export exactly one lineage into a separately valid domain archive.
## @param config Owner-private staging config.
## @param name Canonical requested lineage.
## @param archive Empty owner-private archive path.
## @retval 0 Strict domain archive validated, no other lineage is present.
## @note No raw Certbot README files or unrelated lineages are exported.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
staging_multi_pack_domain() {
  local config=$1 name=$2 archive=$3 root=''
  root="$(mktemp -d -- "$CERTBOTBOT_WORKSPACE_ROOT/lineage.XXXXXXXX")"
  mkdir -m 0700 -- "$root/archive" "$root/live" "$root/renewal" \
    "$root/combined"
  cp -a -- "$config/archive/$name" "$root/archive/$name"
  cp -a -- "$config/live/$name" "$root/live/$name"
  cp -p -- "$config/renewal/$name.conf" "$root/renewal/$name.conf"
  cp -p -- "$config/combined/$name.pem" "$root/combined/$name.pem"
  # The informational README is neither a credential nor part of the
  # strict single-lineage archive contract. No other files are excluded.
  (umask 077; tar -czf "$archive" -C "$root" \
    --exclude='*/README' archive live renewal combined)
  certbotbot_archive_validate_domain "$archive" "$name"
  rm -rf -- "$root"
}

## @fn staging_multi_export()
## @brief Persist separately encrypted common and two lineage archives.
## @retval 0 Every plaintext archive validated before ciphertext export.
## @note No plaintext is written to an inter-job artifact location.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
staging_multi_export() {
  local root=$CERTBOTBOT_WORKSPACE_ROOT
  local out=$CERTBOTBOT_STAGING_OUTPUT_DIR
  local config=$CERTBOTBOT_WORKSPACE_CONFIG
  local common='' base='' second='' cipher='' name=''
  [[ $out == /* && -d $out && ! -L $out &&
    "$(stat -c '%a' -- "$out")" == 700 ]] || return 64
  common="$(mktemp -- "$root/common.XXXXXXXX")"
  base="$(mktemp -- "$root/lineage.XXXXXXXX")"
  second="$(mktemp -- "$root/lineage.XXXXXXXX")"
  cipher="$(mktemp -- "$root/cipher.XXXXXXXX")"
  (umask 077; tar -czf "$common" -C "$config" accounts)
  certbotbot_common_validate "$common"
  staging_multi_pack_domain "$config" "$CERTBOTBOT_STAGING_DOMAIN" "$base"
  staging_multi_pack_domain "$config" "$CERTBOTBOT_STAGING_SECOND_NAME" \
    "$second"
  local -a sources=("$common" "$base" "$second")
  local -a names=(common domain second)
  local i
  for (( i=0; i<3; i++ )); do
    : >"$cipher"
    certbotbot_gpg_encrypt_archive "${sources[i]}" "$cipher"
    cp -- "$cipher" "$out/${names[i]}.tar.gz.enc"
    chmod 0600 -- "$out/${names[i]}.tar.gz.enc"
  done
  rm -f -- "$common" "$base" "$second" "$cipher"
}

## @fn staging_multi_check_fingerprints()
## @brief Confirm both leaf identities and the one durable ACME account.
## @param config Freshly reconstructed private Certbot config.
## @retval 0 All supplied independent-runner comparisons match.
## @retval 65 Account or leaf identity changed unexpectedly.
## @par STDIN
## Nothing is read from STDIN.
## @returns Only designated non-secret job-output digests when configured.
staging_multi_check_fingerprints() {
  local config=$1 account='' base='' second=''
  account="$(staging_account_digest "$config")"
  base="$(staging_multi_hash "$config" "$CERTBOTBOT_STAGING_DOMAIN")"
  second="$(staging_multi_hash "$config" "$CERTBOTBOT_STAGING_SECOND_NAME")"
  [[ -n ${CERTBOTBOT_EXPECTED_ACCOUNT_SHA256:-} &&
    $account == "$CERTBOTBOT_EXPECTED_ACCOUNT_SHA256" &&
    -n ${CERTBOTBOT_EXPECTED_LEAF_SHA256:-} &&
    $base == "$CERTBOTBOT_EXPECTED_LEAF_SHA256" ]] || return 65
  if [[ -n ${CERTBOTBOT_EXPECTED_SECOND_LEAF_SHA256:-} ]]; then
    [[ $second == "$CERTBOTBOT_EXPECTED_SECOND_LEAF_SHA256" ]] || return 65
  fi
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf 'second_leaf_sha256=%s\n' "$second" >>"$GITHUB_OUTPUT"
  fi
}

## @fn staging_multi_issue_second()
## @brief Issue a real, distinct second staging lineage after restoring state.
## @retval 0 Same account, unchanged first leaf, valid second SAN, encrypted outputs.
## @note Staging Certbot network/DNS is allowed only after separate consent.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
staging_multi_issue_second() {
  local config=$CERTBOTBOT_WORKSPACE_CONFIG name=$CERTBOTBOT_STAGING_SECOND_NAME
  staging_load_private_archives
  staging_check_lineage true
  # Check restored account and first lineage before touching Route53.
  [[ -n ${CERTBOTBOT_EXPECTED_ACCOUNT_SHA256:-} &&
    "$(staging_account_digest "$config")" ==
      "$CERTBOTBOT_EXPECTED_ACCOUNT_SHA256" &&
    -n ${CERTBOTBOT_EXPECTED_LEAF_SHA256:-} &&
    "$(staging_multi_hash "$config" "$CERTBOTBOT_STAGING_DOMAIN")" ==
      "$CERTBOTBOT_EXPECTED_LEAF_SHA256" ]] || return 65
  "$CERTBOT" certonly --non-interactive --agree-tos \
    --email "$CERTBOTBOT_STAGING_EMAIL" \
    --server https://acme-staging-v02.api.letsencrypt.org/directory \
    --dns-route53 --cert-name "$name" \
    --key-type ecdsa --keep-until-expiring \
    -d "$name" \
    --config-dir "$config" \
    --work-dir "$CERTBOTBOT_WORKSPACE_WORK" \
    --logs-dir "$CERTBOTBOT_WORKSPACE_LOGS" \
    >"$CERTBOTBOT_WORKSPACE_ROOT/second.log" 2>&1 ||
    staging_abort 'second lineage staging issuance failed (private runner log)'
  staging_check_lineage true
  staging_multi_check "$config"
  staging_multi_check_fingerprints "$config" || return 65
  staging_multi_export
}

## @fn staging_multi_verify_two()
## @brief Restore two encrypted domains to an entirely inactive candidate.
## @details
## Uses ADR-045 batch assembly; the private candidate is NEVER installed into
## active Certbot state or passed to Certbot. No network or DNS occurs.
## @retval 0 Both lineages, account, leaf identity, and disjoint paths verified.
## @note Other validation statuses propagate.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
staging_multi_verify_two() {
  local root=$CERTBOTBOT_WORKSPACE_ROOT input=$CERTBOTBOT_STAGING_INPUT_DIR
  local common='' base='' second='' cipher='' part='' candidate=''
  local -a names=(common domain second)
  local -a plains=()
  [[ $input == /* && -d $input && ! -L $input ]] || return 64
  for part in "${names[@]}"; do
    cipher="$(mktemp -- "$root/cipher.XXXXXXXX")"
    cp -- "$input/$part.tar.gz.enc" "$cipher"
    chmod 0600 -- "$cipher"
    plains+=("$(mktemp -- "$root/plain.XXXXXXXX")")
    certbotbot_gpg_decrypt_archive "$cipher" "${plains[${#plains[@]}-1]}"
    rm -f -- "$cipher"
  done
  certbotbot_import_candidate_prepare "${plains[0]}" staging \
    "$CERTBOTBOT_STAGING_DOMAIN" "${plains[1]}" \
    "$CERTBOTBOT_STAGING_SECOND_NAME" "${plains[2]}"
  candidate=$CERTBOTBOT_IMPORT_CANDIDATE_CONFIG
  # A candidate is private and not the recorded active workspace config.
  [[ -d $candidate && $candidate != "$CERTBOTBOT_WORKSPACE_CONFIG" &&
    -z ${CERTBOTBOT_WORKSPACE_CONFIG##*/config} ]] || return 65
  CERTBOTBOT_WORKSPACE_CONFIG="$candidate" staging_check_lineage true
  staging_multi_check "$candidate"
  staging_multi_check_fingerprints "$candidate" || return 65
  certbotbot_import_candidate_discard
  rm -f -- "${plains[@]}"
}

## @fn staging_multi_main()
## @brief Run one authorized staging evidence phase on a distinct fresh runner.
## @param phase guard, issue-second, or verify-two.
## @retval 0 Selected evidence phase passed its complete checks.
## @retval 64 Invalid phase, missing consent, or unsafe input.
## @note Unrecognized phases cannot execute Certbot.
## @par STDIN
## Nothing is read from STDIN.
## @returns A terse success message with no credentials or account material.
staging_multi_main() {
  local phase=${1:-}
  (( $# == 1 )) || return 64
  staging_multi_validate "$phase" || return 64
  [[ $phase == guard ]] && return 0
  staging_multi_authorize "$phase" || return 64
  export CERTBOTBOT_TMPDIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  certbotbot_workspace_create
  trap staging_cleanup EXIT
  case $phase in
    issue-second) staging_multi_issue_second ;;
    verify-two) staging_multi_verify_two ;;
  esac
  certbotbot_workspace_destroy
  printf 'multi-lineage staging phase %s completed\n' "$phase"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  staging_multi_main "$@"
fi
