#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/client-crypto.bash
## @brief Conditional authenticated-GnuPG capability preflight for the client.
## @details
## ADR-037 requires a real AES-256/OCB encrypt/decrypt roundtrip with the
## producer's exact S2K and packet parameters before encrypted retrieval.
## Only authenticated, checked ciphertext is handed to the existing validator.
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

  # Encrypted-only packet framing needs a small trusted local tool set.
  # Treat a missing executable as a runtime prerequisite, not corrupt S3.
  local tool
  for tool in od awk tail; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      certbotbot_client_error 'authenticated archive tooling unavailable' 69
      return 69
    fi
  done
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


## @fn certbotbot_client_crypto_framing_valid()
## @brief Requires exactly one complete SKESK packet then one AEAD packet.
## @details
## OpenPGP packet framing is length-delimited; GnuPG diagnostic text alone
## does not prove that a complete ciphertext was consumed. This bounded,
## streaming byte walk accepts old/new definite-length headers and RFC-4880
## new-format partial-body chunks, but no extra packet or trailing bytes.
## Format details still require the separate GnuPG packet inspection and
## authenticated decrypt. This parser does not interpret crypto payloads.
## @param packet Privately staged binary GnuPG ciphertext.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @retval 0 Exactly two complete supported packet frames and no trailing data.
## @retval 1 Invalid, overlong, truncated or unsupported framing.
certbotbot_client_crypto_framing_valid() {
  local packet="$1" size
  [[ -s "$packet" && -f "$packet" && ! -L "$packet" ]] || return 1
  size="$(stat -c %s -- "$packet" 2>/dev/null)" || return 1
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  # The bounded decoded archive is 32 MiB. Permit compression/packet
  # overhead, but do not consume unbounded memory or disk while inspecting.
  (( size > 32 && size <= 50331648 )) || return 1
  # The awk program deliberately uses its own $i fields in a literal,
  # not shell expansions.
  # shellcheck disable=SC2016
  (set -o pipefail
    LC_ALL=C od -An -tu1 -v -- "$packet" 2>/dev/null |
      LC_ALL=C awk '
        BEGIN { state = "header"; packet = 0; maxlen = 50331648; bad = 0 }
        function invalid() { bad = 1; exit 1 }
        function finish_packet() {
          if (packet_bytes == 0) invalid()
          state = "header"
        }
        function start_body(n, is_partial) {
          if (n < 0 || n > maxlen) invalid()
          partial = is_partial
          if (n == 0) {
            if (partial) invalid()
            finish_packet()
          } else {
            remaining = n
            state = "body"
          }
        }
        function accept(b) {
          if (b < 0 || b > 255) invalid()
          if (state == "header") {
            if (++packet > 2 || b < 128) invalid()
            packet_bytes = 0
            newfmt = (b >= 192)
            tag = newfmt ? b % 64 : int(b / 4) % 16
            if ((packet == 1 && tag != 3) ||
                (packet == 2 && tag != 20)) invalid()
            if (newfmt) {
              state = "newlen"
            } else {
              form = b % 4
              if (form == 3) invalid()
              want = 2 ^ form
              bodylen = 0
              state = "length"
            }
          } else if (state == "newlen") {
            if (b < 192) start_body(b, 0)
            else if (b <= 223) { first = b; state = "newlen2" }
            else if (b <= 254) start_body(2 ^ (b - 224), 1)
            else { bodylen = 0; want = 4; state = "length" }
          } else if (state == "newlen2") {
            start_body((first - 192) * 256 + b + 192, 0)
          } else if (state == "length") {
            bodylen = bodylen * 256 + b
            if (--want == 0) start_body(bodylen, 0)
          } else if (state == "body") {
            packet_bytes++
            if (--remaining == 0) {
              if (partial) state = "newlen"
              else finish_packet()
            }
          } else invalid()
        }
        { for (i = 1; i <= NF; i++) accept($i + 0) }
        END { if (bad || state != "header" || packet != 2) exit 1 }
      ' >/dev/null 2>&1)
}

## @fn certbotbot_client_crypto_unwrap()
## @brief Authenticates the selected exact-v1 S3 ciphertext before any tar work.
## @details
## Only the existing client workspace is touched. GnuPG may write plaintext
## before its final AEAD check; therefore the private candidate is NEVER
## handed to tar or presented as downloaded.tar.gz until GnuPG has exited
## successfully, its complete framed packet has been inspected, and the
## existing bounded archive validator has accepted the decrypted file.
## The entrypoint's EXIT cleanup owns all temporary paths on every failure.
## @param workspace Existing private client workspace after one S3 GetObject.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed nonsecret diagnostics on failure; raw tool output suppressed.
## @retval 0 Full authenticated gzip/tar now staged as downloaded.tar.gz.
## @retval 65 Missing/wrong envelope, unsupported packet, bad key or archive.
## @retval 74 Local private staging failure.
certbotbot_client_crypto_unwrap() {
  local workspace="$1" raw="$1/downloaded.tar.gz"
  local packet="$1/.client-v1-packet" plain="$1/.client-v1-plaintext"
  local preserved="$1/.client-v1-object"
  [[ -s "$raw" && -f "$raw" && ! -L "$raw" &&
    ! -e "$packet" && ! -L "$packet" &&
    ! -e "$plain" && ! -L "$plain" &&
    ! -e "$preserved" && ! -L "$preserved" ]] ||
    { certbotbot_client_error 'invalid encrypted archive staging' 65; return 65; }

  # A recognized, exact v1 header is required. No auto-detection, plaintext
  # migration, raw OpenPGP, other envelope version or alternate object read.
  if ! head -c 22 -- "$raw" 2>/dev/null |
    cmp -s - <(printf 'CERTBOTBOT-GPG-OCB-V1\n'); then
    certbotbot_client_error 'unsupported authenticated archive envelope' 65
    return 65
  fi
  if ! (umask 077; tail -c +23 -- "$raw" >"$packet" 2>/dev/null); then
    certbotbot_client_error 'cannot stage encrypted packet' 74
    return 74
  fi
  if ! certbotbot_client_crypto_framing_valid "$packet" ||
    ! certbotbot_client_crypto_probe_packets "$workspace/.gnupg" "$packet"; then
    certbotbot_client_error 'unsupported authenticated archive packet' 65
    return 65
  fi
  if ! (umask 077; gpg --no-options --homedir "$workspace/.gnupg" \
    --batch --yes --no-tty --pinentry-mode loopback --no-symkey-cache \
    --passphrase-fd 3 --decrypt --output "$plain" "$packet" \
    3<<<"$CERTBOTBOT_CLIENT_GPG_SECRET" >/dev/null 2>&1) ||
    [[ ! -s "$plain" || ! -f "$plain" || -L "$plain" ]]; then
    certbotbot_client_error 'encrypted archive authentication failed' 65
    return 65
  fi
  # Successful GnuPG authentication is necessary, never sufficient:
  # post-authentication tar validation is the original ADR-022 gate.
  if ! certbotbot_archive_validate "$plain" >/dev/null 2>&1; then
    certbotbot_client_error 'decrypted archive failed validation' 65
    return 65
  fi
  if ! mv -T -- "$raw" "$preserved" 2>/dev/null ||
    ! mv -T -- "$plain" "$raw" 2>/dev/null; then
    certbotbot_client_error 'cannot activate authenticated staging' 74
    return 74
  fi
  # Preserve ciphertext only privately until EXIT cleanup; erase the
  # extracted packet immediately after successful authenticated staging.
  rm -f -- "$packet"
  return 0
}
