#!/usr/bin/env bats

## Uses real OpenSSL-generated EC keys and CA-signed X.509 certificates.
## Nothing contacts Let's Encrypt, Route53, AWS, or other external services.

setup() {
  : "${CERTBOTBOT_ARTIFACT:?Missing certbotbot artifact}"
  command -v openssl >/dev/null 2>&1 || skip 'OpenSSL is required'
  export CRYPTO_ROOT="$BATS_TEST_TMPDIR/config"
  export CRYPTO_CA="$BATS_TEST_TMPDIR/ca.crt"
  local name=example.com kind
  mkdir -m 0700 "$CRYPTO_ROOT"
  mkdir -p "$CRYPTO_ROOT/archive/$name" "$CRYPTO_ROOT/live/$name"
  chmod 0700 "$CRYPTO_ROOT/archive" "$CRYPTO_ROOT/live" \
    "$CRYPTO_ROOT/archive/$name" "$CRYPTO_ROOT/live/$name"

  openssl ecparam -name prime256v1 -genkey -noout \
    -out "$BATS_TEST_TMPDIR/ca.key" >/dev/null 2>&1
  openssl req -new -x509 -key "$BATS_TEST_TMPDIR/ca.key" -days 2 \
    -out "$CRYPTO_CA" -subj '/CN=certbotbot fixture CA' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1

  openssl ecparam -name prime256v1 -genkey -noout \
    -out "$CRYPTO_ROOT/archive/$name/privkey1.pem" >/dev/null 2>&1
  openssl req -new \
    -key "$CRYPTO_ROOT/archive/$name/privkey1.pem" \
    -out "$BATS_TEST_TMPDIR/request.csr" -subj '/CN=example.com' \
    >/dev/null 2>&1

  cat >"$BATS_TEST_TMPDIR/cert.ext" <<'EXT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:example.com,DNS:*.example.com
EXT
  openssl x509 -req -in "$BATS_TEST_TMPDIR/request.csr" \
    -CA "$CRYPTO_CA" -CAkey "$BATS_TEST_TMPDIR/ca.key" \
    -CAcreateserial -days 2 -extfile "$BATS_TEST_TMPDIR/cert.ext" \
    -out "$CRYPTO_ROOT/archive/$name/cert1.pem" >/dev/null 2>&1

  cp "$CRYPTO_CA" "$CRYPTO_ROOT/archive/$name/chain1.pem"
  cat "$CRYPTO_ROOT/archive/$name/cert1.pem" "$CRYPTO_CA" \
    >"$CRYPTO_ROOT/archive/$name/fullchain1.pem"
  chmod 0600 "$CRYPTO_ROOT/archive/$name/privkey1.pem"
  for kind in cert chain fullchain privkey; do
    ln -s "../../archive/$name/${kind}1.pem" \
      "$CRYPTO_ROOT/live/$name/$kind.pem"
  done
  bash -c 'source "$1" --version >/dev/null; certbotbot_pem_assemble "$2" example.com' \
    _ "$CERTBOTBOT_ARTIFACT" "$CRYPTO_ROOT"
}

verify_crypto() {
  run bash -c 'source "$1" --version >/dev/null; certbotbot_crypto_verify_lineage "$2" example.com "$3"' \
    _ "$CERTBOTBOT_ARTIFACT" "$CRYPTO_ROOT" "${1:-$CRYPTO_CA}"
}

@test "trusted EC certificate and matching private key validate" {
  verify_crypto
  [ "$status" -eq 0 ]
  [ -z "$(find "$CRYPTO_ROOT" -maxdepth 1 -name '.crypto.*' -print)" ]
}

@test "certificate verification rejects a different valid private key" {
  openssl ecparam -name prime256v1 -genkey -noout \
    -out "$CRYPTO_ROOT/archive/example.com/privkey1.pem" >/dev/null 2>&1
  chmod 0600 "$CRYPTO_ROOT/archive/example.com/privkey1.pem"
  verify_crypto
  [ "$status" -eq 65 ]
}

@test "certificate verification rejects an untrusted signer" {
  openssl ecparam -name prime256v1 -genkey -noout \
    -out "$BATS_TEST_TMPDIR/other-ca.key" >/dev/null 2>&1
  openssl req -new -x509 -key "$BATS_TEST_TMPDIR/other-ca.key" \
    -days 2 -out "$BATS_TEST_TMPDIR/other-ca.crt" \
    -subj '/CN=Unrelated CA' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
  verify_crypto "$BATS_TEST_TMPDIR/other-ca.crt"
  [ "$status" -eq 65 ]
}

@test "explicit private CA bundle is necessary for the fixture trust chain" {
  verify_crypto ''
  [ "$status" -eq 65 ]
}

@test "certificate verification rejects malformed X.509 leaf data" {
  printf '%s\n' 'not a certificate' \
    >"$CRYPTO_ROOT/archive/example.com/cert1.pem"
  verify_crypto
  [ "$status" -eq 65 ]
}

@test "fullchain must begin with exactly the expected leaf certificate" {
  cp "$CRYPTO_CA" "$CRYPTO_ROOT/archive/example.com/fullchain1.pem"
  verify_crypto
  [ "$status" -eq 65 ]
}

@test "combined PEMs must match fullchain followed by the private key" {
  printf '%s\n' 'tampered output' \
    >"$CRYPTO_ROOT/combined/example.com.pem"
  verify_crypto
  [ "$status" -eq 65 ]
}

@test "insecure combined PEM permissions fail before cryptographic checks" {
  chmod 0644 "$CRYPTO_ROOT/live/example.com/combined.pem"
  verify_crypto
  [ "$status" -eq 64 ]
}

@test "missing combined PEM is rejected" {
  rm -f "$CRYPTO_ROOT/combined/example.com.pem"
  verify_crypto
  [ "$status" -eq 64 ]
}

@test "CA bundles must be readable regular files, not symlinks" {
  ln -s "$CRYPTO_CA" "$BATS_TEST_TMPDIR/ca-link.crt"
  verify_crypto "$BATS_TEST_TMPDIR/ca-link.crt"
  [ "$status" -eq 64 ]
}

@test "verification does not activate normal issuance" {
  run "$CERTBOTBOT_ARTIFACT" example.com
  [ "$status" -eq 69 ]
}
