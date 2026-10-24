#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/crypto.bash
## @brief Authenticates an optional encrypted envelope around the shared tar.
## @details
## ADR-031 requires AES-256/OCB, iterated SHA-512 S2K, an exact versioned
## envelope, and a private staging boundary before exposing plaintext.
## The operator's exported secret must already have been captured into the
## unexported CERTBOTBOT_GPG_SECRET variable and removed from the environment.
## The runtime treats GnuPG as a trusted external executable, not a sandbox.

## @fn certbotbot_crypto_packet_valid()
## @brief Rejects any GnuPG encrypted payload without the required AEAD mode.
## @param workspace Owned private runner root with isolated GPG home.
## @param packet Existing private OpenPGP ciphertext file.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @retval 0 Expected AES256/OCB and SHA512 iterated S2K packet layout.
## @retval 1 Unrecognized or downgraded OpenPGP packet layout.
certbotbot_crypto_packet_valid() {
  local workspace="$1" packet="$2" detail
  [[ -s "$packet" && ! -L "$packet" ]] || return 1
  # Packet inspection is not authentication; successful authenticated
  # decryption and archive validation are additional mandatory gates.
  detail="$(gpg --no-options --homedir "$workspace/.gnupg" --batch --no-tty \
    --no-symkey-cache --list-packets "$packet" \
    2>/dev/null || :)"
  [[ "$detail" == *':symkey enc packet: version 5, cipher 9, aead 2, s2k 3, hash 10,'* &&
    "$detail" == *':aead encrypted packet: cipher=9 aead=2'* &&
    "$detail" == *'count 16777216'* ]]
}

## @fn certbotbot_crypto_encrypt_packet()
## @brief Creates a verified authenticated OCB ciphertext packet.
## @param workspace Private existing runner root with an isolated GPG home.
## @param source Existing plaintext file, never a remote or logged argument.
## @param target Absent private output filename.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @retval 0 A supported authenticated encryption packet was produced.
## @retval 65 Unsupported mode or failed private encryption.
certbotbot_crypto_encrypt_packet() {
  local workspace="$1" source="$2" target="$3"
  [[ -f "$source" && ! -L "$source" &&
    ! -e "$target" && ! -L "$target" ]] || return 65
  if ! (umask 077; gpg --no-options --homedir "$workspace/.gnupg" \
    --batch --yes --no-tty --pinentry-mode loopback --no-symkey-cache \
    --passphrase-fd 3 --symmetric --force-ocb --cipher-algo AES256 \
    --s2k-mode 3 --s2k-digest-algo SHA512 --s2k-count 16777216 \
    --output "$target" "$source" 3<<<"$CERTBOTBOT_GPG_SECRET" \
    >/dev/null 2>&1) ||
    ! certbotbot_crypto_packet_valid "$workspace" "$target"; then
    rm -f -- "$target"
    return 65
  fi
  return 0
}

## @fn certbotbot_crypto_decrypt_packet()
## @brief Quarantines decrypted bytes until authenticated GnuPG exits zero.
## @param workspace Private runner root with an isolated GPG home.
## @param source Validated-mode packet staged under private root.
## @param target Absent private plaintext staging file.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @retval 0 Authentication succeeded and complete staged plaintext exists.
## @retval 65 Authentication or private decryption failed.
certbotbot_crypto_decrypt_packet() {
  local workspace="$1" source="$2" target="$3"
  [[ ! -e "$target" && ! -L "$target" ]] || return 65
  certbotbot_crypto_packet_valid "$workspace" "$source" || return 65
  if ! (umask 077; gpg --no-options --homedir "$workspace/.gnupg" \
    --batch --yes --no-tty --pinentry-mode loopback --no-symkey-cache \
    --passphrase-fd 3 --decrypt --output "$target" "$source" \
    3<<<"$CERTBOTBOT_GPG_SECRET" >/dev/null 2>&1) ||
    [[ ! -s "$target" || -L "$target" ]]; then
    rm -f -- "$target"
    return 65
  fi
  return 0
}

## @fn certbotbot_crypto_require()
## @brief Probes the minimum GnuPG version and actual AES-OCB roundtrip.
## @param workspace Newly allocated private mode-0700 runner workspace.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Static nonsecret diagnostic on failure.
## @retval 0 Runtime supports authenticated encryption and decryption.
## @retval 69 Missing or incompatible GnuPG runtime.
certbotbot_crypto_require() {
  local workspace="$1" version major minor patch result=0
  if ! command -v gpg >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: authenticated GnuPG runtime unavailable' >&2
    return 69
  fi
  version="$(gpg --version 2>/dev/null)" || version=''
  if [[ "$version" =~ gpg\ \(GnuPG\)\ ([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
  else
    major=0; minor=0; patch=0
  fi
  if (( major < 2 || (major == 2 &&
    (minor < 4 || (minor == 4 && patch < 7))) )); then
    printf '%s\n' 'certbotbot: authenticated GnuPG runtime unavailable' >&2
    return 69
  fi
  if ! mkdir -m 700 -- "$workspace/.gnupg" 2>/dev/null; then
    printf '%s\n' 'certbotbot: private crypto workspace unavailable' >&2
    return 69
  fi
  if ! (umask 077; printf '%s\n' 'certbotbot-ocb-capability-v1' \
    >"$workspace/.crypto-probe.in") ||
    ! certbotbot_crypto_encrypt_packet "$workspace" \
      "$workspace/.crypto-probe.in" "$workspace/.crypto-probe.gpg" ||
    ! certbotbot_crypto_decrypt_packet "$workspace" \
      "$workspace/.crypto-probe.gpg" "$workspace/.crypto-probe.out" ||
    ! cmp -s -- "$workspace/.crypto-probe.in" \
      "$workspace/.crypto-probe.out"; then
    result=69
  fi
  rm -f -- "$workspace/.crypto-probe.in" \
    "$workspace/.crypto-probe.gpg" "$workspace/.crypto-probe.out"
  if (( result != 0 )); then
    printf '%s\n' 'certbotbot: authenticated GnuPG runtime unavailable' >&2
  fi
  return "$result"
}

## @fn certbotbot_crypto_unwrap()
## @brief Authenticates the downloaded object before ordinary tar restore.
## @details
## With a known encrypted envelope, successful GnuPG authentication and
## full gzip/tar validation are required before renaming staged plaintext
## to downloaded.tar.gz. Plaintext-to-encrypted conversion requires the
## independently confirmed migration settings before any provider work.
## @param workspace Private workspace with downloaded.tar.gz from S3.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed nonsecret format/decryption diagnostic.
## @retval 0 Existing object matches the selected mode and migration intent.
## @retval 65 Wrong format, invalid key, archive or authentication.
certbotbot_crypto_unwrap() {
  local workspace="$1" raw="$1/downloaded.tar.gz"
  local body="$1/.download-packet" plain="$1/.download-plain.tar.gz"
  local marker=false
  # Read later by the publisher; ShellCheck scans modules independently.
  # shellcheck disable=SC2034
  CERTBOTBOT_MIGRATING=false
  [[ -s "$raw" && ! -L "$raw" ]] || return 65
  if head -c 22 -- "$raw" |
    cmp -s - <(printf 'CERTBOTBOT-GPG-OCB-V1\n'); then
    marker=true
  fi
  if [[ "$CERTBOTBOT_ARCHIVE_ENCRYPTION" == none ]]; then
    if [[ "$marker" == true ]]; then
      printf '%s\n' 'certbotbot: encrypted object requires encrypted mode' >&2
      return 65
    fi
    return 0
  fi
  if [[ "$marker" != true ]]; then
    if [[ "$CERTBOTBOT_ARCHIVE_MIGRATION" != plaintext-to-gpg-ocb ||
      "$CERTBOTBOT_ARCHIVE_MIGRATION_BACKUP_CONFIRMED" != true ]] ||
      ! certbotbot_archive_validate "$raw" >/dev/null 2>&1; then
      printf '%s\n' 'certbotbot: encrypted object or migration required' >&2
      return 65
    fi
    # shellcheck disable=SC2034
    CERTBOTBOT_MIGRATING=true
    return 0
  fi
  if [[ "$CERTBOTBOT_ARCHIVE_MIGRATION" != none ]]; then
    printf '%s\n' 'certbotbot: migration source is already encrypted' >&2
    return 65
  fi
  if ! (umask 077; tail -c +23 -- "$raw" >"$body") ||
    ! certbotbot_crypto_decrypt_packet "$workspace" "$body" "$plain" ||
    ! certbotbot_archive_validate "$plain" >/dev/null 2>&1; then
    rm -f -- "$body" "$plain"
    printf '%s\n' 'certbotbot: encrypted archive could not be authenticated' >&2
    return 65
  fi
  if ! mv -T -- "$raw" "$workspace/downloaded.tar.gz.enc" ||
    ! mv -T -- "$plain" "$raw"; then
    rm -f -- "$body" "$plain"
    printf '%s\n' 'certbotbot: encrypted archive staging failed' >&2
    return 65
  fi
  rm -f -- "$body"
  return 0
}

## @fn certbotbot_crypto_wrap()
## @brief Encrypts a validated full tar candidate and verifies a local roundtrip.
## @param workspace Private workspace with an assembled candidate.tar.gz.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Static nonsecret error diagnostic.
## @retval 0 Candidate.tar.gz.enc contains verified authenticated ciphertext.
## @retval 65 Encryption, format inspection or roundtrip verification failed.
certbotbot_crypto_wrap() {
  local workspace="$1" plain="$1/candidate.tar.gz"
  local body="$1/.publish-packet" check="$1/.publish-verified.tar.gz"
  local output="$1/candidate.tar.gz.enc"
  if [[ ! -s "$plain" || -L "$plain" ||
    -e "$output" || -L "$output" ]]; then
    return 65
  fi
  if ! certbotbot_archive_validate "$plain" >/dev/null 2>&1 ||
    ! certbotbot_crypto_encrypt_packet "$workspace" "$plain" "$body" ||
    ! (umask 077; printf 'CERTBOTBOT-GPG-OCB-V1\n' >"$output" &&
      cat -- "$body" >>"$output") ||
    ! certbotbot_crypto_decrypt_packet "$workspace" "$body" "$check" ||
    ! cmp -s -- "$plain" "$check" ||
    ! certbotbot_archive_validate "$check" >/dev/null 2>&1; then
    rm -f -- "$body" "$check" "$output"
    printf '%s\n' 'certbotbot: encrypted candidate validation failed' >&2
    return 65
  fi
  rm -f -- "$body" "$check"
  return 0
}
