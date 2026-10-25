#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/client-extract.bash
## @brief Activates a fully validated plaintext Certbot archive without clobber.
## @details
## This module owns the consumer-only transition from untrusted S3 bytes to a
## complete caller-visible certificate state directory. It reuses the producer's
## strict gzip/tar validator and inactive restore adapter at build time.
## Extraction and permission normalization occur only within a new invocation-
## owned mode-0700 staging directory. An absent destination is rechecked
## immediately before a same-filesystem no-clobber rename. Concurrent writes
## by a separate process with the same UID must be serialized by the operator,
## as explicitly limited in ADR-035. No archive contents are executed.

## @fn certbotbot_client_extract_and_activate()
## @brief Verifies, privately extracts and activates one complete S3 archive.
## @param workspace Canonical private mode-0700 invocation staging directory.
## @param destination Previously selected canonical, absent output directory.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT. The entrypoint reports the final path.
## @par STDERR
## Fixed, nonsecret diagnostics; external extractor output is suppressed.
## @returns A complete normalized Certbot tree at the selected destination.
## @retval 0 All archive and destination checks passed; output installed.
## @retval 65 Unsupported, encrypted, corrupt, oversized or unsafe archive.
## @retval 69 GNU tar/gzip or required archive inspection tool unavailable.
## @retval 73 The chosen destination is no longer absent or trustworthy.
## @retval 74 Local staging, permission hardening, or rename failed.
certbotbot_client_extract_and_activate() {
  local workspace="${1:-}" destination="${2:-}" root status
  [[ "$workspace" == /* && -d "$workspace" && -n "$destination" ]] ||
    { certbotbot_client_error 'invalid extraction arguments' 73; return 73; }

  # Missing tools are prerequisites, not evidence of a malformed archive.
  local tool
  for tool in tar gzip od head find chmod mv stat; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      certbotbot_client_error 'required archive tool unavailable' 69
      return 69
    fi
  done
  if ! tar --version 2>/dev/null | grep -q '^tar (GNU tar)'; then
    certbotbot_client_error 'GNU tar required' 69
    return 69
  fi

  # The existing restoration adapter validates the *copied* exact bytes
  # before tar is called and refuses untrusted member types and links.
  if certbotbot_archive_restore "$workspace/downloaded.tar.gz" "$workspace"; then
    :
  else
    status=$?
    case "$status" in
      64|65) return 65 ;;
      74) return 74 ;;
      *) return 65 ;;
    esac
  fi

  root="$workspace/config"
  [[ -d "$root" && ! -L "$root" ]] ||
    { certbotbot_client_error 'restored tree missing' 65; return 65; }

  # Tar restores safe logical contents and relative PEM symlinks. Tighten
  # every ordinary file to 0600 and every directory to 0700 so private keys,
  # account registration and archived renewal metadata are inaccessible
  # to other users. Removing executable bits also avoids a stored hook
  # becoming executable through this extraction boundary.
  if ! find "$root" -type f -exec chmod 0600 -- {} + >/dev/null 2>&1 ||
    ! find "$root" -type d -exec chmod 0700 -- {} + >/dev/null 2>&1; then
    certbotbot_client_error 'cannot protect extracted certificate state' 74
    return 74
  fi

  # Preserve the exact caller-selected path and reject late parent changes.
  # GNU mv -n -T is intentionally used rather than a replacing rename.
  if ! certbotbot_client_destination_preflight "$destination"; then
    return 73
  fi
  if ! mv -n -T -- "$root" "$destination" >/dev/null 2>&1; then
    certbotbot_client_error 'cannot activate extracted certificate state' 74
    return 74
  fi
  # -n can return success after declining a newly occupied target; reject
  # that case instead of ever presenting the pre-existing object as ours.
  if [[ -e "$root" || -L "$root" || ! -d "$destination" ||
    -L "$destination" || ! -O "$destination" ]]; then
    certbotbot_client_error 'destination occupied during activation' 73
    return 73
  fi
  return 0
}
