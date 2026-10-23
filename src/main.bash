#!/usr/bin/env bash
# shellcheck shell=bash
## @file src/main.bash
## @brief Executes the selected-certificate MVP lifecycle from public CLI.
## @details
## This is the only public lifecycle dispatcher.  It resolves an identity once,
## reads one mandatory seeded S3 object, restores it into an ephemeral private
## workspace, selects either first issuance or selected-lineage renewal, and
## verifies certificate material before the existing single-key publisher runs.
## All remote write authority is conditioned on successful local verification.
## Each invocation owns and destroys only its freshly allocated workspace.
##
## The underlying adapters follow ADR-020 through ADR-028.  External Certbot,
## Route53, AWS CLI, OpenSSL and the private runner are trusted operational
## dependencies; this orchestration is not a sandbox or distributed transaction.

## @fn certbotbot_usage()
## @brief Prints the selected-certificate command syntax.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Supported options and usage.
## @par STDERR
## Nothing is written to STDERR.
## @returns Supported public command invocation syntax.
## @retval 0 Help was printed.
certbotbot_usage() {
  cat <<'EOF'
Usage: certbotbot [options] DNS_NAME
Options:
  --config FILE                    Read selected literal .env file
  --domain NAME                    Supply primary DNS name
  --include-subdomains true|false  Add complementary apex/wildcard SAN
  --cert-name NAME                 Set stable Certbot lineage name
  --s3-bucket BUCKET               Existing S3 bucket (required)
  --s3-key KEY                     Existing archive key (latest.tar.gz)
  --upload-no-renewal true|false   Republish successful unchanged archive
  --help                           Show help
  --version                        Show build provenance
EOF
}

## @fn certbotbot_version()
## @brief Prints the embedded build metadata.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Version, build date and revision.
## @par STDERR
## Nothing is written to STDERR.
## @returns Embedded build metadata.
## @retval 0 Version was printed.
certbotbot_version() {
  printf 'version: %s\n' "$BASH_STARTER_VERSION"
  printf 'build-date: %s\n' "$BASH_STARTER_BUILD_DATE"
  printf 'build-commit: %s\n' "$BASH_STARTER_BUILD_COMMIT"
}

## @fn certbotbot_verify_material()
## @brief Verifies selected certificate, matching key, chain and requested SANs.
## @details
## Requires a restored and completed selected lineage, owned by the current
## isolated workspace.  Preflight and canonical renewal mapping must succeed
## before this helper runs.  OpenSSL parses the certificate and chain,
## including the fullchain,
## requires that the leaf has not expired, matches exact requested DNS SANs,
## and confirms the leaf/public-key correspondence to the private key.
## The first certificate in fullchain must have the same DER bytes as the leaf.
## Chain trust, remote issuance legitimacy and future revocation status are
## outside this local assertion; authorized staging tests address those claims.
##
## Temporary DER and public-key comparisons are held only within WORKSPACE;
## every exit path removes them.  No key or OpenSSL error output is printed.
## @param workspace Fresh canonical mode-0700 invocation workspace.
## @param selected Non-wildcard selected Certbot lineage name.
## @param ... Exact resolved DNS SANs to assert.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## One static non-sensitive diagnostic on failed verification.
## @returns Nothing is written to STDOUT.
## @retval 0 All local certificate assertions passed.
## @retval 65 Local certificate, chain, SAN or key is unsuitable.
## @retval 69 OpenSSL or comparison tooling is unavailable.
certbotbot_verify_material() {
  local workspace="$1" selected="$2" root
  local pub_cert pub_key leaf_der full_der status=0
  shift 2
  root="$workspace/config/live/$selected"

  if ! command -v openssl >/dev/null 2>&1 ||
    ! command -v cmp >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: certificate verification tooling unavailable' >&2
    return 69
  fi
  if ! certbotbot_state_preflight "$workspace/config" "$selected" \
    >/dev/null 2>&1 ||
    [[ "$CERTBOTBOT_LINEAGE_STATE" != present ]] ||
    ! certbotbot_renewal_map "$workspace/config" "$selected" verify \
      >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: selected certificate state is unsuitable' >&2
    return 65
  fi
  if ! certbotbot_renew_sans_match "$root/cert.pem" "$@" ||
    ! openssl x509 -in "$root/cert.pem" -checkend 0 -noout \
      >/dev/null 2>&1 ||
    ! openssl x509 -in "$root/chain.pem" -noout >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: selected certificate or chain is unusable' >&2
    return 65
  fi
  pub_cert="$workspace/.leaf-public.pem"
  pub_key="$workspace/.key-public.pem"
  leaf_der="$workspace/.leaf.der"
  full_der="$workspace/.fullchain-leaf.der"
  if [[ -e "$pub_cert" || -L "$pub_cert" ||
    -e "$pub_key" || -L "$pub_key" ||
    -e "$leaf_der" || -L "$leaf_der" ||
    -e "$full_der" || -L "$full_der" ]]; then
    printf '%s\n' 'certbotbot: occupied certificate verification workspace' >&2
    return 65
  fi
  if ! (umask 077
    openssl x509 -in "$root/cert.pem" -pubkey -noout >"$pub_cert" 2>/dev/null &&
    openssl pkey -in "$root/privkey.pem" -pubout >"$pub_key" 2>/dev/null &&
    openssl x509 -in "$root/cert.pem" -outform DER >"$leaf_der" 2>/dev/null &&
    openssl x509 -in "$root/fullchain.pem" -outform DER >"$full_der" 2>/dev/null
  ) || ! cmp -s -- "$pub_cert" "$pub_key" ||
    ! cmp -s -- "$leaf_der" "$full_der"; then
    status=65
  fi
  rm -f -- "$pub_cert" "$pub_key" "$leaf_der" "$full_der"
  if (( status != 0 )); then
    printf '%s\n' \
      'certbotbot: certificate and private key verification failed' >&2
  fi
  return "$status"
}

## @fn certbotbot_lifecycle_execute()
## @brief Runs exactly one seeded-archive selected-certificate lifecycle.
## @details
## Runs as a conventional Bash function so the pinned release minifier can
## serialize it safely.  The public executable invokes it only after resolving
## identity and S3 parameters, then exits.  Its process-level EXIT trap owns
## cleanup of the freshly allocated workspace on every exit or failure,
## including handled termination signals.  This function is not a sourced
## library API: callers must not rely on preserving their EXIT trap.
##
## Missing or unsafe S3 state never triggers account registration or host
## fallback.  An absent selected lineage is issued using the restored account;
## an existing one is renewed or reconciled only as explicitly authorized.
## First issuance requires canonical renewal path finalization before it can
## pass the same certificate and archive gates as an existing lineage.
## Publisher input uses the identical bucket/key used by the fetch adapter.
## No publication follows any nonzero provider or verification status.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## One non-secret status describing the selected S3 object on success.
## @par STDERR
## Fixed diagnostics from the failing stage; no external tool output.
## @returns Completed selected-certificate lifecycle and publication status.
## @retval 0 Successful issuance/renewal plus publication, or verified no-op.
## @retval 64 Invalid runtime arguments or private workspace.
## @retval 65 Unsafe state, metadata, or certificate validation.
## @retval 66 Mandatory seeded S3 object was confirmed absent.
## @retval 69 Required external provider or S3 service is unavailable.
## @retval 74 Local staging, Certbot or S3 transfer failed.
## @note The exact nonzero stage status is propagated unchanged.
certbotbot_lifecycle_execute() {
  local workspace='' config account_dir account_before='' entry
  local changed='' outcome=''
  workspace="$(certbotbot_workspace_create)" || return $?
  trap 'rm -rf -- "$workspace"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  certbotbot_s3_fetch "$workspace" "$CERTBOTBOT_S3_BUCKET" \
    "$CERTBOTBOT_S3_KEY" || return $?
  certbotbot_archive_restore "$workspace/downloaded.tar.gz" "$workspace" ||
    return $?
  config="$workspace/config"
  certbotbot_state_preflight "$config" "$CERTBOTBOT_CERT_NAME" ||
    return $?

  account_dir="$config/accounts/acme-v02.api.letsencrypt.org/directory"
  for entry in "$account_dir/"*; do
    [[ -d "$entry" && ! -L "$entry" ]] || continue
    account_before="${entry##*/}"
    break
  done
  [[ -n "$account_before" ]] || {
    printf '%s\n' 'certbotbot: restored ACME account is unavailable' >&2
    return 65
  }

  case "$CERTBOTBOT_LINEAGE_STATE" in
    absent)
      certbotbot_provider_issue "$workspace" "$CERTBOTBOT_CERT_NAME" \
        "${CERTBOTBOT_SANS[@]}" || return $?
      certbotbot_state_preflight "$config" "$CERTBOTBOT_CERT_NAME" ||
        return $?
      [[ "$CERTBOTBOT_LINEAGE_STATE" == present ]] || {
        printf '%s\n' 'certbotbot: newly issued lineage is incomplete' >&2
        return 65
      }
      certbotbot_renewal_map "$config" "$CERTBOTBOT_CERT_NAME" finalize ||
        return $?
      changed=true
      outcome=issued
      ;;
    present)
      certbotbot_provider_existing "$workspace" "$CERTBOTBOT_CERT_NAME" \
        "${CERTBOTBOT_SANS[@]}" || return $?
      changed="$CERTBOTBOT_DURABLE_CHANGED"
      outcome=checked
      ;;
    *)
      printf '%s\n' 'certbotbot: selected lineage is ambiguous' >&2
      return 65
      ;;
  esac

  if [[ ! -d "$account_dir/$account_before" ||
    -L "$account_dir/$account_before" ]]; then
    printf '%s\n' 'certbotbot: restored ACME account identity changed' >&2
    return 65
  fi
  certbotbot_verify_material "$workspace" "$CERTBOTBOT_CERT_NAME" \
    "${CERTBOTBOT_SANS[@]}" || return $?
  certbotbot_s3_publish "$workspace" "$CERTBOTBOT_CERT_NAME" \
    "$CERTBOTBOT_S3_BUCKET" "$CERTBOTBOT_S3_KEY" \
    "$changed" "$CERTBOTBOT_UPLOAD_NO_RENEWAL" || return $?

  printf 'certbotbot: %s %s; s3://%s/%s; published=%s\n' \
    "$outcome" "$CERTBOTBOT_CERT_NAME" "$CERTBOTBOT_S3_BUCKET" \
    "$CERTBOTBOT_S3_KEY" "$CERTBOTBOT_S3_PUBLISHED"
  return 0
}

## @fn certbotbot_main()
## @brief Validates the public invocation and dispatches the MVP lifecycle.
## @param ... Public command arguments.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Help, version or completed operation status.
## @par STDERR
## Non-sensitive diagnostics for invalid or unsuccessful operations.
## @returns Public command status for help, version or one selected certificate.
## @retval 0 Successful operation or explicitly requested help/version.
## @retval 64 Invalid invocation.
## @note Nonzero lifecycle stage statuses propagate unchanged.
certbotbot_main() {
  case "${1:-}" in
    --help|-h|help) certbotbot_usage; return 0 ;;
    --version|-V|version) certbotbot_version; return 0 ;;
  esac
  certbotbot_config_resolve "$@" || return $?
  certbotbot_identity_resolve || return $?
  certbotbot_lifecycle_execute
}

certbotbot_main "$@"
