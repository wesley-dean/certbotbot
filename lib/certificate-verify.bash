# shellcheck shell=bash
## @file lib/certificate-verify.bash
## @brief Verifies the cryptographic usability of a prepared Certbot lineage.
## @details
## This is a pre-publication validation boundary (issue #12).  It uses the
## installed OpenSSL executable to verify the private key parses and is
## internally consistent, that it matches the leaf X.509 certificate's
## public key (without assuming RSA), that the certificate is in its
## validity period, and that its signature chain reaches a trusted root.
##
## The trusted CA bundle is optional: omitted means OpenSSL's default
## system trust; an explicit bundle supports controlled staging CA tests.
## The first certificate in fullchain.pem must equal cert.pem, and both
## deployable combined PEM files must contain exactly fullchain followed
## by a newline and the private key, matching ADR-019.  A passing result
## is not a service configuration or hostname authorization check.
##
## This module makes no S3, Route53, ACME, or Certbot calls.  It is included
## in the standalone artifact but is not yet connected to public issuance.
## @see doc/adr/ADR-029-pre-publication-cryptographic-verification.md

## @fn certbotbot_crypto_verify_lineage()
## @brief Verifies an existing, fully assembled lineage before publication.
## @param config_dir Private Certbot configuration root.
## @param name Validated canonical lineage identity.
## @param ca_bundle Optional readable trusted root bundle, or empty for
## OpenSSL's host trust configuration.
## @retval 0 The key, certificate, trust chain, and combined outputs validate.
## @retval 64 Input paths, ownership, permissions, or artifact layout are unsafe.
## @retval 65 Cryptographic checks or exact combined PEM comparisons failed.
## @retval 69 OpenSSL is not installed.
## @retval 73 Private temporary verification state could not be created.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @note Certificate SAN scope and service-specific TLS settings are outside
## this helper's contract and must be checked separately by the producer.
certbotbot_crypto_verify_lineage() {
  local root=${1:-} name=${2:-} ca_bundle=${3:-}
  local tmp='' kind path mode result=0
  local cert chain fullchain key combined live_combined
  local -a verify_args=()

  if (( $# < 2 || $# > 3 )) ||
    ! certbotbot_validate_hostname "$name" ||
    [[ $name == \*.* || $name != "${name,,}" ||
      $root != /* || -L $root ]]; then
    return 64
  fi
  certbotbot_pem_check_directory "$root" || return 64
  mode="$(stat -c '%a' -- "$root")" || return 64
  if [[ ! $mode =~ ^[0-7]{3,4}$ ]] ||
    (( (8#$mode & 8#77) != 0 )); then
    return 64
  fi
  for path in archive "archive/$name" live "live/$name" combined; do
    certbotbot_pem_check_directory "$root/$path" || return 64
  done
  for kind in cert chain fullchain privkey; do
    certbotbot_pem_check_link "$root" "$name" "$kind" || return 64
  done

  cert="$root/live/$name/cert.pem"
  chain="$root/live/$name/chain.pem"
  fullchain="$root/live/$name/fullchain.pem"
  key="$root/live/$name/privkey.pem"
  combined="$root/combined/$name.pem"
  live_combined="$root/live/$name/combined.pem"

  for path in "$combined" "$live_combined"; do
    if [[ ! -f $path || -L $path || ! -O $path || ! -r $path ||
      ! -s $path ]]; then
      return 64
    fi
    mode="$(stat -c '%a' -- "$path")" || return 64
    if [[ ! $mode =~ ^[0-7]{3,4}$ ]] ||
      (( (8#$mode & 8#77) != 0 )); then
      return 64
    fi
  done

  if [[ -n $ca_bundle ]] &&
    [[ $ca_bundle != /* || ! -f $ca_bundle ||
      -L $ca_bundle || ! -r $ca_bundle ]]; then
    return 64
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    return 69
  fi
  if [[ -n $ca_bundle ]]; then
    verify_args=(-CAfile "$ca_bundle")
  fi

  tmp="$(mktemp -d -- "$root/.crypto.XXXXXXXX")" || return 73
  chmod 0700 -- "$tmp" || {
    rm -rf -- "$tmp"
    return 73
  }

  # Never print full private key or OpenSSL command arguments into logs.
  if ! openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 ||
    ! openssl pkey -in "$key" -check -noout >/dev/null 2>&1 ||
    ! openssl verify -purpose sslserver "${verify_args[@]}" \
      -untrusted "$chain" "$cert" >/dev/null 2>&1; then
    result=65
  fi

  if (( result == 0 )); then
    if ! openssl x509 -in "$cert" -outform DER \
      -out "$tmp/cert.der" >/dev/null 2>&1 ||
      ! openssl x509 -in "$fullchain" -outform DER \
      -out "$tmp/fullchain-first.der" >/dev/null 2>&1 ||
      ! cmp -s -- "$tmp/cert.der" "$tmp/fullchain-first.der"; then
      result=65
    fi
  fi

  if (( result == 0 )); then
    if ! openssl x509 -in "$cert" -pubkey -noout \
      >"$tmp/cert-public.pem" 2>/dev/null ||
      ! openssl pkey -pubin -in "$tmp/cert-public.pem" \
      -outform DER -out "$tmp/cert-public.der" >/dev/null 2>&1 ||
      ! openssl pkey -in "$key" -pubout -outform DER \
      -out "$tmp/key-public.der" >/dev/null 2>&1 ||
      ! cmp -s -- "$tmp/cert-public.der" "$tmp/key-public.der"; then
      result=65
    fi
  fi

  if (( result == 0 )); then
    if ! { cat -- "$fullchain"; printf '\n'; cat -- "$key"; } \
      >"$tmp/expected-combined.pem"; then
      result=73
    elif ! cmp -s -- "$tmp/expected-combined.pem" "$combined" ||
      ! cmp -s -- "$tmp/expected-combined.pem" "$live_combined"; then
      result=65
    fi
  fi

  if ! rm -rf -- "$tmp"; then
    return 73
  fi
  return "$result"
}
