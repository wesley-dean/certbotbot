#!/usr/bin/env bats

## @file tests/publication-candidate.bats
## @brief Verifies a frozen pre-publication collection without cloud writes.
## @details
## Fixtures contain real, locally CA-signed leaf certificates and matching
## private keys. The ACME account metadata is synthetic, and issuance remains
## completely disabled. The requested SAN set is explicit in every test.

setup() {
  : "${CERTBOTBOT_ARTIFACT:?Artifact required}"
  command -v openssl >/dev/null 2>&1 || skip 'OpenSSL required'
  export CERTBOTBOT_TMPDIR="$BATS_TEST_TMPDIR"
  export PUB_SOURCE="$BATS_TEST_TMPDIR/source"
  export PUB_COMMON="$BATS_TEST_TMPDIR/common.tar.gz"
  export PUB_CA="$BATS_TEST_TMPDIR/fixture-ca.crt"
  export PUB_AWS_LOG="$BATS_TEST_TMPDIR/aws-calls"
  export PUB_BIN="$BATS_TEST_TMPDIR/bin"
  unset GPG_PASSPHRASE || :
  umask 077
  mkdir -m 0700 "$PUB_SOURCE" "$PUB_BIN"
  cat >"$PUB_BIN/aws" <<'AWS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PUB_AWS_LOG"
exit 89
AWS
  chmod 0700 "$PUB_BIN/aws"

  openssl ecparam -name prime256v1 -genkey -noout \
    -out "$BATS_TEST_TMPDIR/ca.key" >/dev/null 2>&1
  openssl req -new -x509 -key "$BATS_TEST_TMPDIR/ca.key" -days 2 \
    -out "$PUB_CA" -subj '/CN=Publication fixture CA' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
  local account=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  local parent="$PUB_SOURCE/common"
  local path="$parent/accounts/acme-v02.api.letsencrypt.org/directory/$account"
  mkdir -p "$path"
  chmod 0700 "$parent/accounts" \
    "$parent/accounts/acme-v02.api.letsencrypt.org" \
    "$parent/accounts/acme-v02.api.letsencrypt.org/directory" "$path"
  local file
  for file in meta regr private_key; do
    printf '{"test_only":"%s"}\n' "$file" >"$path/$file.json"
    chmod 0600 "$path/$file.json"
  done
  tar -czf "$PUB_COMMON" -C "$parent" accounts
}

make_lineage() {
  local name=$1 root="$PUB_SOURCE/$1" kind='' csr=''
  local archive="$BATS_TEST_TMPDIR/$name.tar.gz"
  mkdir -p "$root/archive/$name" "$root/live/$name" "$root/renewal"
  chmod 0700 "$root" "$root/archive" "$root/archive/$name" \
    "$root/live" "$root/live/$name" "$root/renewal"
  openssl ecparam -name prime256v1 -genkey -noout \
    -out "$root/archive/$name/privkey1.pem" >/dev/null 2>&1
  csr="$BATS_TEST_TMPDIR/$name.csr"
  openssl req -new -key "$root/archive/$name/privkey1.pem" \
    -out "$csr" -subj "/CN=$name" >/dev/null 2>&1
  cat >"$BATS_TEST_TMPDIR/$name.ext" <<EXT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:$name,DNS:*.$name
EXT
  openssl x509 -req -in "$csr" -CA "$PUB_CA" \
    -CAkey "$BATS_TEST_TMPDIR/ca.key" -CAcreateserial -days 2 \
    -extfile "$BATS_TEST_TMPDIR/$name.ext" \
    -out "$root/archive/$name/cert1.pem" >/dev/null 2>&1
  cp "$PUB_CA" "$root/archive/$name/chain1.pem"
  cat "$root/archive/$name/cert1.pem" "$PUB_CA" \
    >"$root/archive/$name/fullchain1.pem"
  chmod 0600 "$root/archive/$name/"*1.pem
  for kind in cert chain fullchain privkey; do
    ln -s "../../archive/$name/${kind}1.pem" \
      "$root/live/$name/$kind.pem"
  done
  cat >"$root/renewal/$name.conf" <<RENEWAL
version = 5.8.0
archive_dir = /other-host/config/archive/$name
cert = /other-host/config/live/$name/cert.pem
privkey = /other-host/config/live/$name/privkey.pem
chain = /other-host/config/live/$name/chain.pem
fullchain = /other-host/config/live/$name/fullchain.pem

[renewalparams]
account = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
server = https://acme-v02.api.letsencrypt.org/directory
authenticator = dns-route53
key_type = ecdsa
RENEWAL
  bash -c '
    source "$1" --version >/dev/null
    certbotbot_pem_assemble "$2" "$3"
  ' _ "$CERTBOTBOT_ARTIFACT" "$root" "$name" || return 1
  tar -czf "$archive" -C "$root" archive live renewal combined
}

run_candidate() {
  run env PATH="$PUB_BIN:$PATH" bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit 96
    shift
    certbotbot_publication_prepare "$@"
    result=$?
    printf "result=%s\n" "$result"
    if (( result == 0 )); then
      printf "count=%s\n" "${#CERTBOTBOT_PUBLICATION_KEYS[@]}"
      printf "key0=%s\n" "${CERTBOTBOT_PUBLICATION_KEYS[0]}"
      for (( i=0; i<${#CERTBOTBOT_PUBLICATION_KEYS[@]}; i++ )); do
        [[ -s ${CERTBOTBOT_PUBLICATION_FILES[i]} &&
          "$(stat -c "%a" "${CERTBOTBOT_PUBLICATION_FILES[i]}")" == 600 ]] ||
          exit 97
      done
      certbotbot_publication_discard || exit 98
    else
      [[ -z "$CERTBOTBOT_PUBLICATION_ROOT" ]] || exit 91
    fi
    [[ -z "$CERTBOTBOT_RESTORE_ROOT" &&
      -z "$CERTBOTBOT_COMMON_STAGE" ]] || exit 90
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_CONFIG" \
      -mindepth 1 -print -quit)" ]] || exit 92
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_ROOT" -mindepth 1 \
      -maxdepth 1 ! -name config ! -name work ! -name logs \
      -print -quit)" ]] || exit 93
    certbotbot_workspace_destroy || exit 94
  ' _ "$CERTBOTBOT_ARTIFACT" "$@"
}

@test "valid signed certificate, exact SANs, and common state prepare no writes" {
  make_lineage example.com
  run_candidate valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=0'* &&
    "$output" == *'count=2'* &&
    "$output" == *'key0=common-latest.tar.gz'* ]]
  [ ! -e "$PUB_AWS_LOG" ]
}

@test "two complete lineages produce common-first private candidate order" {
  make_lineage example.com
  make_lineage example.net
  run_candidate valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com' \
    example.net "$BATS_TEST_TMPDIR/example.net.tar.gz" \
    'example.net,*.example.net'
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=0'* && "$output" == *'count=3'* ]]
  [ ! -e "$PUB_AWS_LOG" ]
}

@test "unexpected requested SAN blocks the entire publication candidate" {
  make_lineage example.com
  run_candidate valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com,www.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=65'* ]]
  [ ! -e "$PUB_AWS_LOG" ]
}

@test "unknown CA signer blocks a structurally valid lineage" {
  make_lineage example.com
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$BATS_TEST_TMPDIR/untrusted.key" -days 1 \
    -out "$BATS_TEST_TMPDIR/untrusted.crt" \
    -subj '/CN=Untrusted CA' >/dev/null 2>&1
  run_candidate valid-bucket "$PUB_COMMON" \
    "$BATS_TEST_TMPDIR/untrusted.crt" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=65'* ]]
  [ ! -e "$PUB_AWS_LOG" ]
}

@test "tampered leaf certificate blocks publication even with matching metadata" {
  make_lineage example.com
  local root="$PUB_SOURCE/example.com"
  printf 'not a certificate\n' >"$root/archive/example.com/cert1.pem"
  tar -czf "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    -C "$root" archive live renewal combined
  run_candidate valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=65'* ]]
  [ ! -e "$PUB_AWS_LOG" ]
}

@test "an unsupported renewal hook blocks publication before crypto checks" {
  make_lineage example.com
  local root="$PUB_SOURCE/example.com"
  printf 'pre_hook = /bin/sh\n' >>"$root/renewal/example.com.conf"
  tar -czf "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    -C "$root" archive live renewal combined
  run_candidate valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=64'* ]]
  [ ! -e "$PUB_AWS_LOG" ]
}

@test "duplicate lineage is rejected before private staging or network access" {
  make_lineage example.com
  run_candidate valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com' \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=64'* ]]
  [ ! -e "$PUB_AWS_LOG" ]
}

@test "empty or malformed SAN list is rejected before candidate preparation" {
  make_lineage example.com
  run_candidate valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=64'* ]]
  [ ! -e "$PUB_AWS_LOG" ]
}

@test "preexisting active Certbot configuration cannot be overwritten" {
  make_lineage example.com
  run env PATH="$PUB_BIN:$PATH" bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit 1
    printf "preserve\n" >"$CERTBOTBOT_WORKSPACE_CONFIG/.marker"
    certbotbot_publication_prepare \
      valid-bucket "$2" "$3" example.com "$4" \
      "example.com,*.example.com"
    result=$?
    [[ "$result" == 64 &&
      "$(cat "$CERTBOTBOT_WORKSPACE_CONFIG/.marker")" == preserve &&
      -z "$CERTBOTBOT_PUBLICATION_ROOT" ]] || exit 2
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$PUB_COMMON" "$PUB_CA" \
    "$BATS_TEST_TMPDIR/example.com.tar.gz"
  [ "$status" -eq 0 ]
  [ ! -e "$PUB_AWS_LOG" ]
}

@test "encryption prepares only private AES-256 candidate bytes" {
  command -v gpg >/dev/null 2>&1 || skip 'GPG required'
  make_lineage example.com
  run env GPG_PASSPHRASE='disposable publication test passphrase' \
    PATH="$PUB_BIN:$PATH" bash -c '
      source "$1" --version >/dev/null
      certbotbot_workspace_create || exit 1
      certbotbot_publication_prepare \
        valid-bucket "$2" "$3" example.com "$4" \
        "example.com,*.example.com" || exit 2
      [[ "${CERTBOTBOT_PUBLICATION_KEYS[0]}" == common-latest.tar.gz.enc &&
        "${CERTBOTBOT_PUBLICATION_KEYS[1]}" == example.com-latest.tar.gz.enc ]] ||
        exit 3
      plain="$(mktemp -- "$CERTBOTBOT_WORKSPACE_ROOT/decrypted.XXXXXXXX")" ||
        exit 4
      certbotbot_gpg_decrypt_archive \
        "${CERTBOTBOT_PUBLICATION_FILES[0]}" "$plain" || exit 5
      tar -tzf "$plain" | grep -Fq 'accounts/' || exit 6
      rm -f -- "$plain" || exit 7
      certbotbot_publication_discard || exit 8
      certbotbot_workspace_destroy
    ' _ "$CERTBOTBOT_ARTIFACT" "$PUB_COMMON" "$PUB_CA" \
    "$BATS_TEST_TMPDIR/example.com.tar.gz"
  [ "$status" -eq 0 ]
  [ ! -e "$PUB_AWS_LOG" ]
}

@test "public certificate issuance and upload are still unavailable" {
  run "$CERTBOTBOT_ARTIFACT" example.com
  [ "$status" -eq 69 ]
  [ ! -e "$PUB_AWS_LOG" ]
}
