#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/client-crypto.bash
## @brief Conditional authenticated-GnuPG capability preflight for the client.
## @details
## ADR-037 requires a real AES-256/OCB encrypt/decrypt roundtrip with the
## producer's exact S2K and packet parameters before encrypted retrieval.
## This module does NOT decrypt downloaded archives or authorize extraction.
## The entrypoint captures the exported secret into a non-exported Bash local
## and removes its environment name before any external program is invoked.

## @fn certbotbot_client_crypto_probe_packets()
## @brief Recognizes the expected issuer-compatible authenticated probe format.
## @param home Private GnuPG home owned by this invocation.
## @param packet Fresh probe ciphertext in the private workspace.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @retval 0 Probe packet reports the expected v1 OCB cipher and S2K.
## @retval 1 Missing, invalid, or unsupported probe packet.
## @note Packet inspection is not authentication; a complete verified
## decrypt-and-compare is a separate mandatory preflight gate.
certbotbot_client_crypto_probe_packets() {
  local home="$1" packet="$2" detail
  [[ -s "$packet" && -f "$packet" && ! -L "$packet" ]] || return 1
  detail="$(gpg --no-options --homedir "$home" --batch --no-tty \
    --no-symkey-cache --list-packets "$packet" 2>/dev/null || :)"
  [[ "$detail" == *':symkey enc packet: version 5, cipher 9, aead 2, s2k 3, hash 10,'* &&
    "$detail" == *':aead encrypted packet: cipher=9 aead=2'* &&
    "$detail" == *'count 16777216'* ]]
}

## @fn certbotbot_client_crypto_require()
## @brief Proves the local GnuPG implementation can produce and consume v1 OCB.
## @param workspace New private mode-0700 staging directory.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## A single fixed nonsecret diagnostic is written on failure.
## @retval 0 GnuPG >=2.4.7 and actual authenticated OCB roundtrip succeeded.
## @retval 69 Missing, incompatible, or malfunctioning GnuPG capability.
## @note CERTBOTBOT_CLIENT_GPG_SECRET is a non-exported Bash-local variable
## dynamically scoped from the entrypoint, never an OS process argument.
certbotbot_client_crypto_require() {
  local workspace="$1" version major minor patch
  local home="$workspace/.gnupg"
  local source="$workspace/.crypto-probe.in"
  local packet="$workspace/.crypto-probe.gpg"
  local restored="$workspace/.crypto-probe.out"
  local result=0

  if ! command -v gpg >/dev/null 2>&1; then
    certbotbot_client_error 'authenticated GnuPG runtime unavailable' 69
    return 69
  fi
  version="$(gpg --version 2>/dev/null)" || version=''
  if [[ "$version" =~ gpg\ \(GnuPG\)\ ([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
  else
    major=0
    minor=0
    patch=0
  fi
  if (( major < 2 || (major == 2 &&
    (minor < 4 || (minor == 4 && patch < 7))) )); then
    certbotbot_client_error 'authenticated GnuPG runtime unavailable' 69
    return 69
  fi
  if ! mkdir -m 700 -- "$home" 2>/dev/null; then
    certbotbot_client_error 'private GnuPG staging unavailable' 69
    return 69
  fi

  if ! (umask 077; printf '%s\n' 'certbotbot-client-ocb-capability-v1' >"$source") ||
    ! (umask 077; gpg --no-options --homedir "$home" --batch --yes \
      --no-tty --pinentry-mode loopback --no-symkey-cache \
      --passphrase-fd 3 --symmetric --force-ocb --cipher-algo AES256 \
      --s2k-mode 3 --s2k-digest-algo SHA512 --s2k-count 16777216 \
      --output "$packet" "$source" \
      3<<<"$CERTBOTBOT_CLIENT_GPG_SECRET" >/dev/null 2>&1) ||
    ! certbotbot_client_crypto_probe_packets "$home" "$packet" ||
    ! (umask 077; gpg --no-options --homedir "$home" --batch --yes \
      --no-tty --pinentry-mode loopback --no-symkey-cache \
      --passphrase-fd 3 --decrypt --output "$restored" "$packet" \
      3<<<"$CERTBOTBOT_CLIENT_GPG_SECRET" >/dev/null 2>&1) ||
    ! cmp -s -- "$source" "$restored"; then
    result=69
  fi
  rm -f -- "$source" "$packet" "$restored"
  if (( result != 0 )); then
    certbotbot_client_error 'authenticated GnuPG runtime unavailable' 69
  fi
  return "$result"
}
