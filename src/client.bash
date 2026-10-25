#!/usr/bin/env bash
# shellcheck shell=bash
## @file src/client.bash
## @brief Read-only standalone certificate consumer's public entrypoint.
## @details
## The consumer resolves and retrieves one current S3 object, verifies it
## with the shared bounded archive validator, and atomically activates only a
## complete privately restored tree. ADR-037 adds mode/key capture and a
## conditional crypto capability preflight and complete authenticated
## decryption in private staging before the existing archive validator. This module does not invoke the issuer.
## Modules are concatenated at assembly time, not sourced from disk at runtime.

## @fn certbotbot_client_usage()
## @brief Prints supported client CLI options.
## @par STDIN
## Nothing is read from STDIN.
## @returns Usage text is written to STDOUT.
## @retval 0 Help printed.
certbotbot_client_usage() {
  cat <<'EOF'
Usage: certbotbot-client.bash --destination DIRECTORY [options]
Options:
  --destination DIRECTORY       New, absent extraction-root directory (required)
  --s3-bucket BUCKET            Existing S3 bucket (S3_BUCKET)
  --s3-key KEY                  Current literal archive key (default latest.tar.gz)
  --s3-key-template TEMPLATE    Current key template ({YEAR}, {MONTH}, {DOM})
  --archive-encryption MODE     auto|none|gpg-ocb (default auto; key selects gpg-ocb)
  --config FILE                 Explicit literal .env-format config file
  --help                        Show this help
  --version                     Show client build provenance

Encrypted mode requires GnuPG 2.4.7+ with working AES-256/OCB support.
The only secret input is exported GPG_SYMMETRIC_KEY; never place it in CLI or .env.
auto uses authenticated OCB when the key is present; otherwise plain gzip/tar.
none plus key or gpg-ocb without key is an error. No format/key fallback.
The destination must be absent under an existing caller-owned private parent.
Only the selected S3 object is read; the client never issues or uploads certs.
See doc/client-settings.md in the project for the full configuration contract.
EOF
}

## @fn certbotbot_client_version()
## @brief Prints client version/build provenance injected during assembly.
## @par STDIN
## Nothing is read from STDIN.
## @returns Version and provenance to STDOUT.
## @retval 0 Version printed.
certbotbot_client_version() {
  printf 'version: %s\n' "${BASH_STARTER_VERSION:-0.0.0-dev}"
  printf 'build-date: %s\n' "${BASH_STARTER_BUILD_DATE:-unknown}"
  printf 'build-commit: %s\n' "${BASH_STARTER_BUILD_COMMIT:-unknown}"
}

## @fn certbotbot_client_destination_preflight()
## @brief Validates absent destination and caller-owned canonical parent.
## @param destination Caller-selected new local destination path.
## @par STDIN
## Nothing is read from STDIN.
## @returns CERTBOTBOT_CLIENT_PARENT and FINAL_PATH variables.
## @retval 0 Valid, absent target under controlled parent.
## @retval 73 Unsafe, occupied or untrusted destination.
certbotbot_client_destination_preflight() {
  local destination="$1" parent physical lexical basename owner mode
  [[ -n "$destination" && "$destination" != */ && "$destination" != *$'\n'* ]] ||
    { certbotbot_client_error 'unsafe destination' 73; return 73; }
  basename="${destination##*/}"
  [[ "$basename" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ &&
    "$basename" != .. && "$basename" != . ]] ||
    { certbotbot_client_error 'unsafe destination name' 73; return 73; }
  parent="${destination%/*}"
  if [[ "$parent" == "$destination" ]]; then parent=.; fi
  if [[ "$parent" == '' ]]; then parent=/; fi
  if [[ "$parent" != /* ]]; then parent="$PWD/$parent"; fi
  lexical="$(realpath -ms -- "$parent" 2>/dev/null)" ||
    { certbotbot_client_error 'invalid destination parent' 73; return 73; }
  physical="$(realpath -e -- "$parent" 2>/dev/null)" ||
    { certbotbot_client_error 'destination parent missing' 73; return 73; }
  [[ "$lexical" == "$physical" && -d "$physical" && ! -L "$physical" ]] ||
    { certbotbot_client_error 'untrusted destination parent' 73; return 73; }
  owner="$(stat -c %u -- "$physical" 2>/dev/null)" ||
    { certbotbot_client_error 'cannot inspect destination parent' 73; return 73; }
  mode="$(stat -c %a -- "$physical" 2>/dev/null)" ||
    { certbotbot_client_error 'cannot inspect destination parent' 73; return 73; }
  [[ "$owner" == "$EUID" && "$mode" =~ ^[0-7]{3,4}$ &&
    -w "$physical" && -x "$physical" ]] ||
    { certbotbot_client_error 'destination parent not writable by caller' 73; return 73; }
  if (( (8#$mode & 8#022) != 0 )); then
    certbotbot_client_error 'destination parent is group/other writable' 73
    return 73
  fi
  CERTBOTBOT_CLIENT_PARENT="$physical"
  CERTBOTBOT_CLIENT_FINAL_PATH="$physical/$basename"
  [[ ! -e "$CERTBOTBOT_CLIENT_FINAL_PATH" && ! -L "$CERTBOTBOT_CLIENT_FINAL_PATH" ]] ||
    { certbotbot_client_error 'destination already exists' 73; return 73; }
}

## @fn certbotbot_client_cleanup()
## @brief Deletes only the temporary private workspace created by this process.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @retval 0 Cleanup attempted.
certbotbot_client_cleanup() {
  if [[ -n "${CERTBOTBOT_CLIENT_WORKSPACE:-}" ]]; then
    rm -rf -- "$CERTBOTBOT_CLIENT_WORKSPACE"
    CERTBOTBOT_CLIENT_WORKSPACE=''
  fi
}

## @fn certbotbot_client_main()
## @brief Retrieves, validates and activates one complete current S3 object.
## @param ... Public CLI arguments.
## @par STDIN
## Nothing is read from STDIN.
## @returns On success, only the canonical absolute destination on STDOUT.
## @retval 0 Help/version printed or validated destination fully activated.
## @retval 64 Invalid configuration.
## @retval 65 Unsupported, malformed or unsafe downloaded archive.
## @retval 66 Confirmed missing S3 key.
## @retval 69 Unavailable GnuPG capability or uncertain AWS result.
## @retval 73 Unsafe or occupied destination.
## @retval 74 Local staging failure.
certbotbot_client_main() {
  # Disable inherited xtrace before touching the exported secret.
  set +x
  local CERTBOTBOT_CLIENT_GPG_SECRET="${GPG_SYMMETRIC_KEY-}"
  # Do not let a similarly named caller environment export the local secret.
  export -n CERTBOTBOT_CLIENT_GPG_SECRET ||
    { certbotbot_client_error 'cannot protect encryption key'; return 64; }
  unset GPG_SYMMETRIC_KEY ||
    { certbotbot_client_error 'cannot protect encryption key'; return 64; }

  if (( $# == 1 )); then
    case "$1" in
      --help) certbotbot_client_usage; return 0 ;;
      --version) certbotbot_client_version; return 0 ;;
    esac
  fi
  # Local help/version do not require a valid secret format, but any
  # invocation that retrieves content rejects unrepresentable FD input.
  if [[ "$CERTBOTBOT_CLIENT_GPG_SECRET" == *$'\n'* ||
    "$CERTBOTBOT_CLIENT_GPG_SECRET" == *$'\r'* ]]; then
    certbotbot_client_error 'invalid encryption key format'
    return 64
  fi
  certbotbot_client_config_resolve "$@" || return $?
  certbotbot_client_destination_preflight "$CERTBOTBOT_CLIENT_DESTINATION" || return $?
  CERTBOTBOT_CLIENT_WORKSPACE="$(umask 077; mktemp -d "$CERTBOTBOT_CLIENT_PARENT/.certbotbot-client.XXXXXXXX")" ||
    { certbotbot_client_error 'cannot create private staging directory' 74; return 74; }
  trap 'certbotbot_client_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # Plaintext mode does not inspect or require a GnuPG binary. Encrypted
  # mode must prove working authenticated AES-256/OCB before any S3 read.
  if [[ "$CERTBOTBOT_CLIENT_ARCHIVE_ENCRYPTION" == gpg-ocb ]]; then
    certbotbot_client_crypto_require "$CERTBOTBOT_CLIENT_WORKSPACE" || return $?
  fi
  certbotbot_client_s3_fetch "$CERTBOTBOT_CLIENT_WORKSPACE" \
    "$CERTBOTBOT_S3_BUCKET" "$CERTBOTBOT_S3_KEY" || return $?
  # The encrypted branch never reaches tar or destination activation until
  # exact packet framing and complete authenticated GnuPG decryption succeed.
  # Plaintext mode bypasses GnuPG and retains its original extraction path.
  if [[ "$CERTBOTBOT_CLIENT_ARCHIVE_ENCRYPTION" == gpg-ocb ]]; then
    certbotbot_client_crypto_unwrap "$CERTBOTBOT_CLIENT_WORKSPACE" || return $?
  fi
  certbotbot_client_extract_and_activate "$CERTBOTBOT_CLIENT_WORKSPACE" \
    "$CERTBOTBOT_CLIENT_FINAL_PATH" || return $?
  # The private downloaded bytes are removed by EXIT cleanup; only the
  # complete validated tree is activated in the caller's destination.
  printf '%s\n' "$CERTBOTBOT_CLIENT_FINAL_PATH"
  return 0
}

certbotbot_client_main "$@"
