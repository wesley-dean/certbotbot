#!/usr/bin/env bash
# shellcheck shell=bash
## @file src/main.bash
## @brief Public MVP selected-certificate command entrypoint.
## @details
## Configuration and identity preflight precede the selected S3, Certbot,
## certificate-verification and publication lifecycle. One invocation
## owns a disposable private workspace; failures remain nonzero without
## publishing incomplete local state.

## @fn certbotbot_usage()
## @brief Prints the current selected-certificate command syntax.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Supported options and usage.
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
## @retval 0 Version was printed.
certbotbot_version() {
  printf 'version: %s\n' "$BASH_STARTER_VERSION"
  printf 'build-date: %s\n' "$BASH_STARTER_BUILD_DATE"
  printf 'build-commit: %s\n' "$BASH_STARTER_BUILD_COMMIT"
}

## @fn certbotbot_main()
## @brief Validates invocation and runs the bounded selected MVP lifecycle.
## @param ... Public command arguments.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Help or build metadata when explicitly requested.
## @par STDERR
## Non-sensitive diagnostics for unsupported/incomplete operations.
## @retval 0 Help or version was requested.
## @retval 64 Invalid invocation.
## @retval 65 Unsafe restored certificate/account, cryptography or candidate.
## @retval 66 Seeded S3 archive positively missing.
## @retval 69 Required external tool or account unavailable.
## @retval 74 Certbot, packaging or S3 transfer failed.
certbotbot_main() {
  case "${1:-}" in
    --help|-h|help) certbotbot_usage; return 0 ;;
    --version|-V|version) certbotbot_version; return 0 ;;
  esac
  certbotbot_config_resolve "$@" || return 64
  certbotbot_identity_resolve || return 64
  certbotbot_lifecycle_execute "$CERTBOTBOT_CERT_NAME" \
    "$CERTBOTBOT_S3_BUCKET" "$CERTBOTBOT_S3_KEY" \
    "$CERTBOTBOT_UPLOAD_NO_RENEWAL" "${CERTBOTBOT_SANS[@]}"
}

certbotbot_main "$@"
