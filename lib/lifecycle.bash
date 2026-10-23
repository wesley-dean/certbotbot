#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/lifecycle.bash
## @brief Executes the bounded selected-certificate public MVP lifecycle.
## @details
## ADR-029 connects the already validated configuration, seeded S3 read,
## bounded private restore, existing-account selected Certbot operations,
## post-Certbot cryptographic assertions and single-key S3 publisher.
## The fresh workspace is removed on success, failure or handled signal.
## No source archive is read from host /etc/letsencrypt and no account
## registration, global renewal or second S3 key is authorized.
##
## A trusted installed OpenSSL binary checks local leaf/key usability.
## It does not prove CA trust, revocation, DNS authorization or remote
## S3 replication. AWS/Certbot errors and PEM/key bytes are not forwarded.

## @fn certbotbot_certificate_verify()
## @brief Requires a usable locally consistent selected X.509 certificate.
## @details
## Requires a complete selected lineage, canonical renewal metadata,
## exact approved DNS SANs, current validity window, a readable key that
## corresponds to the leaf's public key, parseable chain/fullchain, and
## byte-identical DER leaf as the first fullchain certificate. OpenSSL
## writes only public-key and leaf DER data to private owned temporary
## files and never prints account or secret data to the user.
##
## This is intentionally not a certificate trust-path or revocation audit;
## Certbot and the configured ACME provider own issuance authority. The
## selected certificate is separately checked for content consistency
## prior to any publication. All failure cases clean private staging.
## @param config Canonical private Certbot configuration root.
## @param selected Stable selected lineage name.
## @param ... Exactly the desired one/two literal DNS SANs.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## One static failure diagnostic without external OpenSSL output.
## @returns Nothing is written to STDOUT.
## @retval 0 Selected certificate, key and fullchain are locally consistent.
## @retval 65 Certificate, dates, SANs or key/chain unsuitable.
## @retval 69 Required OpenSSL or date tool unavailable.
## @retval 74 Private verification staging unavailable.
## @note Does not assert remote ACME registration or trusted CA path.
certbotbot_certificate_verify() {
  local config selected root cert key chain fullchain scratch=''
  local start_date start_epoch now_epoch rc=65
  if (( $# < 3 )); then
    printf '%s\n' 'certbotbot: invalid certificate verification arguments' >&2
    return 65
  fi
  config="$1"
  selected="$2"
  shift 2
  if ! certbotbot_provider_sans "$@" ||
    ! certbotbot_state_preflight "$config" "$selected" >/dev/null 2>&1 ||
    [[ "$CERTBOTBOT_LINEAGE_STATE" != present ]] ||
    ! certbotbot_renewal_map "$config" "$selected" verify >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: selected certificate state is unsuitable' >&2
    return 65
  fi
  if ! command -v openssl >/dev/null 2>&1 ||
    ! command -v date >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: OpenSSL and date are required' >&2
    return 69
  fi
  root="$config/live/$selected"
  cert="$root/cert.pem"
  key="$root/privkey.pem"
  chain="$root/chain.pem"
  fullchain="$root/fullchain.pem"
  if [[ ! -f "$cert" || ! -r "$cert" || ! -f "$key" || ! -r "$key" ||
    ! -f "$chain" || ! -r "$chain" ||
    ! -f "$fullchain" || ! -r "$fullchain" ]] ||
    [[ -n "$(find -L "$key" -perm /077 -print -quit 2>/dev/null)" ]]; then
    printf '%s\n' 'certbotbot: certificate material is unsuitable' >&2
    return 65
  fi
  if ! certbotbot_renew_sans_match "$cert" "$@" ||
    ! openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: selected certificate SAN or validity failed' >&2
    return 65
  fi
  start_date="$(openssl x509 -in "$cert" -noout -startdate 2>/dev/null)" ||
    return 65
  [[ "$start_date" == notBefore=* ]] || return 65
  start_epoch="$(LC_ALL=C date -u -d "${start_date#notBefore=}" +%s 2>/dev/null)" ||
    return 65
  now_epoch="$(date -u +%s)" || return 65
  if (( start_epoch > now_epoch )); then
    printf '%s\n' 'certbotbot: selected certificate is not yet valid' >&2
    return 65
  fi
  scratch="$(umask 077; mktemp -d "${config%/config}/verify.XXXXXXXX")" || {
    printf '%s\n' 'certbotbot: private certificate verification unavailable' >&2
    return 74
  }
  if openssl x509 -in "$cert" -pubkey -noout \
       >"$scratch/certificate.pub" 2>/dev/null &&
    openssl pkey -in "$key" -passin pass: -pubout \
      >"$scratch/private-key.pub" 2>/dev/null &&
    cmp -s -- "$scratch/certificate.pub" "$scratch/private-key.pub" &&
    openssl x509 -in "$cert" -outform DER \
      >"$scratch/certificate.der" 2>/dev/null &&
    openssl x509 -in "$fullchain" -outform DER \
      >"$scratch/fullchain-first.der" 2>/dev/null &&
    cmp -s -- "$scratch/certificate.der" "$scratch/fullchain-first.der" &&
    openssl x509 -in "$chain" -noout >/dev/null 2>&1; then
    rc=0
  fi
  rm -rf -- "$scratch"
  if (( rc != 0 )); then
    printf '%s\n' 'certbotbot: selected certificate key or chain failed' >&2
  fi
  return "$rc"
}

## @fn certbotbot_lifecycle_worker()
## @brief Runs the trusted five-step lifecycle inside one allocated workspace.
## @details
## Caller supplies only pre-resolved, validated configuration and one
## disposable workspace. The exact bucket/key pair is shared by both S3
## calls without mutation; the selected cert name is forwarded unchanged
## through restored preflight, Certbot, verification and publication.
## The first-issue path always marks durable state changed only after
## canonicalization and certificate verification have succeeded.
##
## This function does not own workspace cleanup; the public wrapper runs
## it in a child shell with a guaranteed owned-workspace EXIT trap.
## @param workspace Newly allocated, private invocation workspace.
## @param selected Stable resolved Certbot certificate name.
## @param bucket Existing selected S3 bucket from configuration.
## @param key Existing selected object key from configuration.
## @param override Literal resolved UPLOAD_NO_RENEWAL Boolean.
## @param ... One or two exact desired SANs.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## On success only, selected object and uploaded/unchanged disposition.
## @par STDERR
## Static stage-specific failure diagnostics from owned adapters.
## @returns Nothing else is written to STDOUT.
## @retval 0 All selected steps succeeded or legitimate no-op skipped.
## @retval 64 Invalid operation input.
## @retval 65 Unusable remote account, lineage, certificate or candidate.
## @retval 66 Mandatory seeded object is missing.
## @retval 69 Installed provider unavailable or account unreadable.
## @retval 74 Extraction, local packaging or remote upload failed.
certbotbot_lifecycle_worker() {
  local workspace="$1" selected="$2" bucket="$3" key="$4" override="$5"
  local changed account_dir account_before account_after entry
  shift 5
  certbotbot_s3_fetch "$workspace" "$bucket" "$key" || return $?
  certbotbot_archive_restore "$workspace/downloaded.tar.gz" "$workspace" ||
    return $?
  certbotbot_state_preflight "$workspace/config" "$selected" || return $?
  account_dir="$workspace/config/accounts/acme-v02.api.letsencrypt.org/directory"
  account_before=''
  for entry in "$account_dir/"*; do
    [[ -d "$entry" && ! -L "$entry" ]] || continue
    account_before="${entry##*/}"
  done
  if [[ -z "$account_before" ]]; then
    printf '%s\n' 'certbotbot: selected ACME account is missing' >&2
    return 65
  fi

  if [[ "$CERTBOTBOT_LINEAGE_STATE" == absent ]]; then
    certbotbot_provider_issue "$workspace" "$selected" "$@" || return $?
    certbotbot_renewal_map "$workspace/config" "$selected" finalize ||
      return $?
    changed=true
  else
    certbotbot_provider_existing "$workspace" "$selected" "$@" || return $?
    changed="$CERTBOTBOT_DURABLE_CHANGED"
    [[ "$changed" == true || "$changed" == false ]] || return 65
  fi

  certbotbot_state_preflight "$workspace/config" "$selected" || return $?
  [[ "$CERTBOTBOT_LINEAGE_STATE" == present ]] || return 65
  account_after=''
  for entry in "$account_dir/"*; do
    [[ -d "$entry" && ! -L "$entry" ]] || continue
    account_after="${entry##*/}"
  done
  if [[ "$account_after" != "$account_before" ]]; then
    printf '%s\n' 'certbotbot: selected ACME account identity changed' >&2
    return 65
  fi
  certbotbot_certificate_verify "$workspace/config" "$selected" "$@" ||
    return $?
  certbotbot_s3_publish "$workspace" "$selected" "$bucket" "$key" \
    "$changed" "$override" || return $?
  if [[ "$CERTBOTBOT_S3_PUBLISHED" == true ]]; then
    printf 'certbotbot: %s/%s uploaded\n' "$bucket" "$key"
  else
    printf 'certbotbot: %s/%s unchanged\n' "$bucket" "$key"
  fi
  return 0
}

## @fn certbotbot_lifecycle_execute()
## @brief Allocates and removes one isolated workspace around a lifecycle.
## @details
## Creates an owned private directory and delegates to a child Bash subshell.
## All normal, error, INT and TERM exits remove that *specific* newly
## allocated directory. The caller's shell traps are not modified.
## No existing/user-specified workspace is ever removed by this wrapper.
## The runtime passes the resolved bucket/key and SANs as separate literals.
## @param selected Stable validated certificate identity.
## @param bucket Existing configured S3 bucket name.
## @param key Existing configured object key.
## @param override Literal configured UPLOAD_NO_RENEWAL value.
## @param ... One or two validated SAN strings.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Selected bucket/key with uploaded/unchanged result on success.
## @par STDERR
## Fixed non-secret diagnostics from underlying adapters.
## @returns The result of the delegated selected lifecycle.
## @retval 0 Selected lifecycle completed and cleanup ran.
## @retval 64 Invalid inputs before provider invocation.
## @retval 65 Local or restored state failed verification.
## @retval 66 Seeded archive confirmed absent.
## @retval 69 Required provider or account unavailable.
## @retval 74 Transfer, staging, Certbot or archive publication failed.
certbotbot_lifecycle_execute() {
  local workspace
  workspace="$(certbotbot_workspace_create)" || return $?
  (trap 'rm -rf -- "$workspace"' EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; umask 077; certbotbot_lifecycle_worker "$workspace" "$@")
}
