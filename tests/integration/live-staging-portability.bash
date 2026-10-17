#!/usr/bin/env bash
# shellcheck shell=bash
## @file tests/integration/live-staging-portability.bash
## @brief Opt-in evidence harness for genuine staging ACME account continuity.
## @details
## This is a test fixture, NOT a producer entrypoint or active importer.
## Every network-capable mode requires explicit operator consent and only
## targets Let's Encrypt staging. A disposable test-only active configuration
## is constructed after private validation of encrypted split archives.
## Staging certificates and account keys never enter unencrypted CI artifacts.
## @see doc/adr/ADR-044-opt-in-real-acme-portability-evidence.md

set -euo pipefail
umask 077

## @fn staging_abort()
## @brief Abort with a non-secret test failure message.
## @param message Diagnostic containing no key material or API response.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @retval 1 The staging harness cannot safely continue.
staging_abort() {
  printf 'staging evidence: %s\n' "$1" >&2
  exit 1
}

## @fn staging_validate_request()
## @brief Validate opt-in test identities before any Certbot or AWS operation.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @retval 0 Domain, additional DNS SAN, and pinned artifact are valid.
## @retval 64 Missing or noncanonical input.
staging_validate_request() {
  local domain=${CERTBOTBOT_STAGING_DOMAIN:-}
  local extra=${CERTBOTBOT_STAGING_EXTRA_NAME:-}
  [[ -n ${CERTBOTBOT_ARTIFACT:-} &&
    $CERTBOTBOT_ARTIFACT == /* &&
    -f $CERTBOTBOT_ARTIFACT &&
    ! -L $CERTBOTBOT_ARTIFACT ]] || return 64
  # Sourcing --version never calls issuance, DNS, or storage.
  source "$CERTBOTBOT_ARTIFACT" --version >/dev/null || return 64
  certbotbot_validate_hostname "$domain" || return 64
  certbotbot_validate_hostname "$extra" || return 64
  [[ $domain != \*.* && $domain == "${domain,,}" &&
    $extra != \*.* && $extra == "${extra,,}" &&
    $extra == *".$domain" && $extra != "$domain" ]] || return 64
}

## @fn staging_account_digest()
## @brief Identify the unique staging account private key across runners.
## @param config Private Certbot config path.
## @par STDIN
## Nothing is read from STDIN.
## @returns SHA-256 of the account private_key.json and a newline.
## @retval 0 Exactly one staging account exists.
## @retval 65 Staging account contents are incomplete or ambiguous.
staging_account_digest() {
  local config=$1 base='' key=''
  local -a keys=()
  base="$config/accounts/acme-staging-v02.api.letsencrypt.org/directory"
  [[ -d $base && ! -L $base ]] || return 65
  shopt -s nullglob
  keys=("$base"/*/private_key.json)
  shopt -u nullglob
  (( ${#keys[@]} == 1 )) || return 65
  key=${keys[0]}
  [[ -f $key && ! -L $key && -s $key ]] || return 65
  sha256sum -- "$key" | cut -d ' ' -f1
}

## @fn staging_load_private_archives()
## @brief Decrypt, validate, and install state into a disposable TEST config.
## @details
## Never used by the released producer. Import remains specifically limited
## to an explicitly consented staging-evidence run under ADR-044.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @retval 0 Test-only config contains the validated staging account/lineage.
## @note Internal validators' nonzero statuses propagate on failure.
staging_load_private_archives() {
  local input=${CERTBOTBOT_STAGING_INPUT_DIR:?}
  local domain=$CERTBOTBOT_STAGING_DOMAIN
  local root=$CERTBOTBOT_WORKSPACE_ROOT
  local common='' lineage='' common_enc='' lineage_enc='' part=''
  [[ $input == /* && -d $input && ! -L $input ]] || return 64
  common_enc="$(mktemp -- "$root/input.XXXXXXXX")"
  lineage_enc="$(mktemp -- "$root/input.XXXXXXXX")"
  common="$(mktemp -- "$root/common.XXXXXXXX")"
  lineage="$(mktemp -- "$root/lineage.XXXXXXXX")"
  cp -- "$input/common.tar.gz.enc" "$common_enc"
  cp -- "$input/domain.tar.gz.enc" "$lineage_enc"
  chmod 0600 -- "$common_enc" "$lineage_enc"
  certbotbot_gpg_decrypt_archive "$common_enc" "$common"
  certbotbot_gpg_decrypt_archive "$lineage_enc" "$lineage"
  certbotbot_common_restore "$common"
  certbotbot_restore_domain "$lineage" "$domain"
  certbotbot_renewal_policy_check "$domain" staging
  certbotbot_renewal_path_preview "$domain" staging

  # ADR-044 authorizes this copy ONLY for the disposable integration fixture.
  # The operational producer is unchanged and has no activating importer.
  for part in archive live combined; do
    cp -a -- "$CERTBOTBOT_RESTORE_ROOT/$part" \
      "$CERTBOTBOT_WORKSPACE_CONFIG/$part"
  done
  cp -a -- "$CERTBOTBOT_COMMON_STAGE/accounts" \
    "$CERTBOTBOT_WORKSPACE_CONFIG/accounts"
  mkdir -m 0700 "$CERTBOTBOT_WORKSPACE_CONFIG/renewal"
  cp -- "$CERTBOTBOT_RENEWAL_PREVIEW" \
    "$CERTBOTBOT_WORKSPACE_CONFIG/renewal/$domain.conf"
  chmod 0600 -- "$CERTBOTBOT_WORKSPACE_CONFIG/renewal/$domain.conf"
  certbotbot_renewal_preview_discard
  certbotbot_restore_discard
  certbotbot_common_discard
  rm -f -- "$common_enc" "$lineage_enc" "$common" "$lineage"
}

## @fn staging_check_lineage()
## @brief Verify live staging output with explicit staging trust anchors.
## @param expanded True when the requested extra SAN must also be present.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @retval 0 Key, chain, combined PEM, and exact SAN request are valid.
## @note Validation errors propagate from the pinned artifact.
staging_check_lineage() {
  local expanded=$1 domain=$CERTBOTBOT_STAGING_DOMAIN
  local config=$CERTBOTBOT_WORKSPACE_CONFIG
  certbotbot_pem_assemble "$config" "$domain"
  certbotbot_crypto_verify_lineage "$config" "$domain" \
    "$CERTBOTBOT_STAGING_CA_BUNDLE"
  if [[ $expanded == true ]]; then
    certbotbot_crypto_verify_sans "$config" "$domain" \
      "$domain" "*.$domain" "$CERTBOTBOT_STAGING_EXTRA_NAME"
  else
    certbotbot_crypto_verify_sans "$config" "$domain" \
      "$domain" "*.$domain"
  fi
}

## @fn staging_save_archives()
## @brief Export encrypted split-state archives without exposing plaintext.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @retval 0 Encrypted archives are ready in the approved output directory.
## @note No unencrypted archive is copied outside the private workspace.
staging_save_archives() {
  local root=$CERTBOTBOT_WORKSPACE_ROOT
  local output=${CERTBOTBOT_STAGING_OUTPUT_DIR:?}
  local config=$CERTBOTBOT_WORKSPACE_CONFIG
  local common='' lineage='' cipher=''
  [[ $output == /* && -d $output && ! -L $output ]] || return 64
  [[ "$(stat -c '%a' -- "$output")" == 700 ]] || return 64
  common="$(mktemp -- "$root/common.XXXXXXXX")"
  lineage="$(mktemp -- "$root/domain.XXXXXXXX")"
  (umask 077; tar -czf "$common" -C "$config" accounts)
  (umask 077; tar -czf "$lineage" -C "$config" \
    archive live renewal combined)
  certbotbot_common_validate "$common"
  certbotbot_archive_validate_domain "$lineage" \
    "$CERTBOTBOT_STAGING_DOMAIN"
  cipher="$(mktemp -- "$root/encrypted.XXXXXXXX")"
  certbotbot_gpg_encrypt_archive "$common" "$cipher"
  cp -- "$cipher" "$output/common.tar.gz.enc"
  : >"$cipher"
  certbotbot_gpg_encrypt_archive "$lineage" "$cipher"
  cp -- "$cipher" "$output/domain.tar.gz.enc"
  chmod 0600 -- "$output/common.tar.gz.enc" \
    "$output/domain.tar.gz.enc"
  rm -f -- "$common" "$lineage" "$cipher"
}

## @fn staging_record_identity()
## @brief Publish only non-secret SHA-256 fingerprints as job outputs.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @retval 0 Fingerprints were recorded for subsequent independent jobs.
staging_record_identity() {
  local account='' leaf=''
  account="$(staging_account_digest "$CERTBOTBOT_WORKSPACE_CONFIG")"
  leaf="$(sha256sum -- "$CERTBOTBOT_WORKSPACE_CONFIG/live/"\
"$CERTBOTBOT_STAGING_DOMAIN/cert.pem" | cut -d ' ' -f1)"
  if [[ -n ${CERTBOTBOT_EXPECTED_ACCOUNT_SHA256:-} &&
    $account != "$CERTBOTBOT_EXPECTED_ACCOUNT_SHA256" ]]; then
    staging_abort 'staging ACME account key changed across runners'
  fi
  if [[ -n ${CERTBOTBOT_EXPECTED_LEAF_SHA256:-} ]]; then
    if [[ ${CERTBOTBOT_STAGING_PHASE:-} == noop &&
      $leaf != "$CERTBOTBOT_EXPECTED_LEAF_SHA256" ]] ||
      [[ ${CERTBOTBOT_STAGING_PHASE:-} == change &&
      $leaf == "$CERTBOTBOT_EXPECTED_LEAF_SHA256" ]]; then
      staging_abort 'unexpected certificate identity across runners'
    fi
  fi
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf 'account_sha256=%s\nleaf_sha256=%s\n' \
      "$account" "$leaf" >>"$GITHUB_OUTPUT"
  fi
}

## @fn staging_cleanup()
## @brief Erase the private test workspace on exit or interrupted execution.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @retval 0 No workspace remains.
## @note Cleanup is ordinary deletion, not secure storage-media erasure.
staging_cleanup() {
  certbotbot_workspace_destroy || return 73
}

## @fn staging_main()
## @brief Execute one separately approved staging evidence phase.
## @param phase guard, issue, noop, change, or verify.
## @retval 0 Stage completed after enforcing all applicable safety checks.
## @retval 64 Invalid mode, identities, secrets, or missing consent.
## @note Real DNS/ACME is possible ONLY for issue/change after consent.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
staging_main() {
  local phase=${1:-} directory='' leaf_before=''
  (( $# == 1 )) || return 64
  case "$phase" in
    guard | issue | noop | change | verify) ;;
    *) return 64 ;;
  esac
  staging_validate_request || return 64
  [[ $phase == guard ]] && return 0
  # No implicit invocation from CI, pull requests, or a product command.
  [[ ${CERTBOTBOT_STAGING_CONFIRM:-} == yes &&
    ${CERTBOTBOT_STAGING_PHASE:-} == "$phase" &&
    ${ACME_ENVIRONMENT:-} == staging &&
    -n ${CERTBOTBOT_STAGING_EMAIL:-} &&
    -n ${GPG_PASSPHRASE:-} &&
    $GPG_PASSPHRASE != *[[:cntrl:]]* &&
    -n ${CERTBOTBOT_STAGING_CA_BUNDLE:-} &&
    -f $CERTBOTBOT_STAGING_CA_BUNDLE &&
    ! -L $CERTBOTBOT_STAGING_CA_BUNDLE &&
    -n ${CERTBOT:-} &&
    $CERTBOT == /* && -x $CERTBOT ]] || return 64
  [[ $- != *x* ]] || return 64
  export CERTBOTBOT_TMPDIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  certbotbot_workspace_create || return $?
  # All decrypted account and lineage state must be removed even if a
  # downstream Certbot call or strict validator rejects the fixture.
  trap staging_cleanup EXIT
  directory=$CERTBOTBOT_WORKSPACE_CONFIG

  if [[ $phase == issue ]]; then
    # --server always selects staging; no user-supplied ACME URL is used.
    "$CERTBOT" certonly --non-interactive --agree-tos \
      --email "$CERTBOTBOT_STAGING_EMAIL" \
      --server https://acme-staging-v02.api.letsencrypt.org/directory \
      --dns-route53 --cert-name "$CERTBOTBOT_STAGING_DOMAIN" \
      --key-type ecdsa --keep-until-expiring \
      -d "$CERTBOTBOT_STAGING_DOMAIN" \
      -d "*.$CERTBOTBOT_STAGING_DOMAIN" \
      --config-dir "$directory" \
      --work-dir "$CERTBOTBOT_WORKSPACE_WORK" \
      --logs-dir "$CERTBOTBOT_WORKSPACE_LOGS" \
      >"$CERTBOTBOT_WORKSPACE_ROOT/issue.log" 2>&1 ||
      staging_abort 'staging DNS-01 issuance failed (private runner log)'
    staging_check_lineage false
  else
    staging_load_private_archives
    if [[ $phase == noop ]]; then
      leaf_before="$(sha256sum -- \
        "$directory/live/$CERTBOTBOT_STAGING_DOMAIN/cert.pem" |
        cut -d ' ' -f1)"
      "$CERTBOT" renew --non-interactive \
        --no-directory-hooks --no-random-sleep-on-renew \
        --cert-name "$CERTBOTBOT_STAGING_DOMAIN" \
        --config-dir "$directory" \
        --work-dir "$CERTBOTBOT_WORKSPACE_WORK" \
        --logs-dir "$CERTBOTBOT_WORKSPACE_LOGS" \
        >"$CERTBOTBOT_WORKSPACE_ROOT/noop.log" 2>&1 ||
        staging_abort 'staging no-op renewal failed (private runner log)'
      [[ "$(sha256sum -- \
        "$directory/live/$CERTBOTBOT_STAGING_DOMAIN/cert.pem" |
        cut -d ' ' -f1)" == "$leaf_before" ]] ||
        staging_abort 'unexpected certificate renewal in no-op phase'
      staging_check_lineage false
    elif [[ $phase == change ]]; then
      "$CERTBOT" certonly --non-interactive \
        --agree-tos --email "$CERTBOTBOT_STAGING_EMAIL" \
        --server https://acme-staging-v02.api.letsencrypt.org/directory \
        --dns-route53 --cert-name "$CERTBOTBOT_STAGING_DOMAIN" \
        --key-type ecdsa --keep-until-expiring \
        --renew-with-new-domains \
        -d "$CERTBOTBOT_STAGING_DOMAIN" \
        -d "*.$CERTBOTBOT_STAGING_DOMAIN" \
        -d "$CERTBOTBOT_STAGING_EXTRA_NAME" \
        --config-dir "$directory" \
        --work-dir "$CERTBOTBOT_WORKSPACE_WORK" \
        --logs-dir "$CERTBOTBOT_WORKSPACE_LOGS" \
        >"$CERTBOTBOT_WORKSPACE_ROOT/change.log" 2>&1 ||
        staging_abort 'staging SAN-change issuance failed (private runner log)'
      staging_check_lineage true
    else
      staging_check_lineage true
    fi
  fi

  staging_record_identity
  if [[ $phase != verify ]]; then
    staging_save_archives
  fi
  certbotbot_workspace_destroy
  printf 'staging evidence phase %s completed\n' "$phase"
}

staging_main "$@"
