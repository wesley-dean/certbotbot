#!/usr/bin/env bats

## @file tests/staging-second-lineage-sans.bats
## @brief Verify staging's second issuance identity matches ADR-018/036.
## @details
## Locally signed fixture certificates are checked against the unchanged
## production SAN and cryptographic verification boundaries. No real Certbot,
## AWS, DNS, ACME, or production state is used. Every artifact runs this suite.
## @see doc/adr/ADR-055-real-staging-second-lineage-sans.md

setup() {
  : "${CERTBOTBOT_ARTIFACT:?Standalone release artifact required}"
  export STAGING_SECOND_SCRIPT="$BATS_TEST_DIRNAME/integration/live-staging-multilineage.bash"
  export STAGING_SECOND_NAME=second.example.com
  export CERTBOTBOT_STAGING_SECOND_NAME="$STAGING_SECOND_NAME"
  export CERTBOTBOT_STAGING_CA_BUNDLE="$BATS_TEST_TMPDIR/ca.pem"
  command -v openssl >/dev/null 2>&1 || skip 'OpenSSL required'
  umask 077
}

verify_signed_second() {
  local san_text=$1
  run env STAGING_SAN_TEXT="$san_text" bash -c '
    set -euo pipefail
    umask 077
    source "$1" --version >/dev/null
    source "$2"
    config="$3/config"
    name="$CERTBOTBOT_STAGING_SECOND_NAME"
    mkdir -m 0700 -p -- "$config/archive/$name" \
      "$config/live/$name" "$config/combined"
    find "$config" -type d -exec chmod 0700 -- {} +
    openssl ecparam -name prime256v1 -genkey -noout \
      -out "$3/ca.key" >/dev/null 2>&1
    openssl req -new -x509 -key "$3/ca.key" \
      -out "$CERTBOTBOT_STAGING_CA_BUNDLE" -days 2 \
      -subj "/CN=second-lineage-test-CA" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
    openssl ecparam -name prime256v1 -genkey -noout \
      -out "$config/archive/$name/privkey1.pem" >/dev/null 2>&1
    openssl req -new -key "$config/archive/$name/privkey1.pem" \
      -out "$3/lineage.csr" -subj "/CN=$name" >/dev/null 2>&1
    cat >"$3/lineage.ext" <<EXT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=$STAGING_SAN_TEXT
EXT
    openssl x509 -req -in "$3/lineage.csr" \
      -CA "$CERTBOTBOT_STAGING_CA_BUNDLE" -CAkey "$3/ca.key" \
      -CAcreateserial -days 2 -extfile "$3/lineage.ext" \
      -out "$config/archive/$name/cert1.pem" >/dev/null 2>&1
    cp -- "$CERTBOTBOT_STAGING_CA_BUNDLE" \
      "$config/archive/$name/chain1.pem"
    cat -- "$config/archive/$name/cert1.pem" \
      "$CERTBOTBOT_STAGING_CA_BUNDLE" \
      >"$config/archive/$name/fullchain1.pem"
    chmod 0600 -- "$config/archive/$name/privkey1.pem"
    for part in cert chain fullchain privkey; do
      ln -s "../../archive/$name/${part}1.pem" \
        "$config/live/$name/$part.pem"
    done
    staging_multi_check "$config"
  ' _ "$CERTBOTBOT_ARTIFACT" "$STAGING_SECOND_SCRIPT" "$BATS_TEST_TMPDIR"
}

@test "locally trusted second certificate with base and wildcard passes" {
  verify_signed_second 'DNS:second.example.com,DNS:*.second.example.com'
  [ "$status" -eq 0 ]
}

@test "single-SAN second certificate is rejected despite valid chain and key" {
  verify_signed_second 'DNS:second.example.com'
  [ "$status" -eq 65 ]
}

@test "real staging example requests both identities and remains uninstalled" {
  grep -Fq -- '-d "$name" -d "*.$name"' "$STAGING_SECOND_SCRIPT"
  grep -Fq 'certbotbot_crypto_verify_sans "$config" "$name" "$name" "*.$name"' \
    "$STAGING_SECOND_SCRIPT"
  [ -f "$BATS_TEST_DIRNAME/../examples/github-actions/real-staging-evidence.yml" ]
  [ ! -e "$BATS_TEST_DIRNAME/../.github/workflows/real-staging-evidence.yml" ]
}
