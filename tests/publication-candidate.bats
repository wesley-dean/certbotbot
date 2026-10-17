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

## Configure the existing fake AWS executable for read-only recovery checks.
## Any PUT is an unconditional failure. Tests inspect exact frozen bytes.
enable_get_mock() {
  export PUB_S3_STORE="$BATS_TEST_TMPDIR/remote"
  export PUB_S3_MODE=normal
  mkdir -m 0700 "$PUB_S3_STORE"
  cat >"$PUB_BIN/aws" <<'AWS'
#!/usr/bin/env bash
set -u
if [[ ${1:-} == --endpoint-url ]]; then
  shift 2
fi
[[ ${1:-} == s3api && ${2:-} == get-object ]] || {
  printf 'PROHIBITED_WRITE\n' >>"$PUB_AWS_LOG"
  exit 88
}
shift 2
bucket='' key='' destination=''
while (( $# > 0 )); do
  case "$1" in
    --bucket) bucket=$2; shift 2 ;;
    --key) key=$2; shift 2 ;;
    *) destination=$1; shift ;;
  esac
done
printf 'GET:%s:%s\n' "$bucket" "$key" >>"$PUB_AWS_LOG"
[[ $bucket == valid-bucket && $destination == /* ]] || exit 87
case ${PUB_S3_MODE:-normal} in
  denied)
    printf 'An error occurred (AccessDenied) when calling the GetObject operation: Denied\n' >&2
    exit 254
    ;;
  timeout)
    printf 'Endpoint unreachable\n' >&2
    exit 255
    ;;
esac
if [[ ! -f "$PUB_S3_STORE/$key" ]]; then
  printf 'An error occurred (NoSuchKey) when calling the GetObject operation: Missing\n' >&2
  exit 254
fi
cp -- "$PUB_S3_STORE/$key" "$destination" || exit 73
AWS
  chmod 0700 "$PUB_BIN/aws"
}

stage_previous() {
  cp -- "$PUB_COMMON" "$PUB_S3_STORE/common-latest.tar.gz"
  local name
  for name in "$@"; do
    cp -- "$BATS_TEST_TMPDIR/$name.tar.gz" \
      "$PUB_S3_STORE/$name-latest.tar.gz"
  done
}

run_checkpoint() {
  run env PATH="$PUB_BIN:$PATH" bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit 89
    shift
    certbotbot_publication_prepare "$@" || exit 88
    certbotbot_publication_checkpoint valid-bucket
    result=$?
    printf "result=%s\n" "$result"
    if (( result == 0 )); then
      printf "empty=%s\n" "$CERTBOTBOT_CHECKPOINT_EMPTY"
      for (( i=0; i<${#CERTBOTBOT_CHECKPOINT_KEYS[@]}; i++ )); do
        printf "present-%s=%s\n" "$i" \
          "${CERTBOTBOT_CHECKPOINT_PRESENT[i]}"
        if [[ ${CERTBOTBOT_CHECKPOINT_PRESENT[i]} == 1 ]]; then
          [[ -s ${CERTBOTBOT_CHECKPOINT_FILES[i]} &&
            "$(stat -c "%a" "${CERTBOTBOT_CHECKPOINT_FILES[i]}")" == 600 ]] ||
            exit 85
          cmp -s -- "$PUB_S3_STORE/${CERTBOTBOT_CHECKPOINT_KEYS[i]}" \
            "${CERTBOTBOT_CHECKPOINT_FILES[i]}" || exit 84
        fi
      done
      certbotbot_checkpoint_verify || exit 83
      certbotbot_checkpoint_discard || exit 82
    else
      [[ -z $CERTBOTBOT_CHECKPOINT_ROOT ]] || exit 81
    fi
    [[ -z "$CERTBOTBOT_S3_STAGE_ROOT" &&
      -z "$CERTBOTBOT_RESTORE_ROOT" &&
      -z "$CERTBOTBOT_COMMON_STAGE" ]] || exit 80
    certbotbot_publication_discard || exit 79
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_ROOT" \
      -mindepth 1 -maxdepth 1 ! -name config ! -name work \
      ! -name logs -print -quit)" ]] || exit 78
    certbotbot_workspace_destroy || exit 77
  ' _ "$CERTBOTBOT_ARTIFACT" "$@"
}

@test "previous common and domain are frozen with exact remote bytes" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  run_checkpoint valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=0'* && "$output" == *'empty=false'* &&
    "$output" == *'present-0=1'* && "$output" == *'present-1=1'* ]]
  ! grep -Fq PROHIBITED_WRITE "$PUB_AWS_LOG"
}

@test "entirely new collection remains explicitly absent in checkpoint" {
  make_lineage example.com
  enable_get_mock
  run_checkpoint valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=0'* && "$output" == *'empty=true'* &&
    "$output" == *'present-0=0'* && "$output" == *'present-1=0'* ]]
  ! grep -Fq PROHIBITED_WRITE "$PUB_AWS_LOG"
}

@test "existing common with new domain records only the missing lineage" {
  make_lineage example.com
  enable_get_mock
  stage_previous
  run_checkpoint valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=0'* &&
    "$output" == *'present-0=1'* && "$output" == *'present-1=0'* ]]
}

@test "orphaned old domain cannot be accepted without a common account" {
  make_lineage example.com
  enable_get_mock
  cp "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    "$PUB_S3_STORE/example.com-latest.tar.gz"
  run_checkpoint valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=65'* ]]
}

@test "corrupt prior common archive cannot become a recovery checkpoint" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  printf 'invalid archive\n' >"$PUB_S3_STORE/common-latest.tar.gz"
  run_checkpoint valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=64'* ]]
}

@test "untrusted prior renewal hook invalidates the whole checkpoint" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  local root="$PUB_SOURCE/example.com"
  printf 'deploy_hook = /bin/sh\n' >>"$root/renewal/example.com.conf"
  tar -czf "$PUB_S3_STORE/example.com-latest.tar.gz" \
    -C "$root" archive live renewal combined
  run_checkpoint valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=64'* ]]
}

@test "ambiguous or denied S3 reads cannot become an empty checkpoint" {
  make_lineage example.com
  enable_get_mock
  export PUB_S3_MODE=denied
  run_checkpoint valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=69'* && "$output" != *'empty=true'* ]]
}

@test "checkpoint refuses a different bucket before any remote request" {
  make_lineage example.com
  enable_get_mock
  run env PATH="$PUB_BIN:$PATH" bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    certbotbot_publication_prepare valid-bucket "$2" "$3" \
      example.com "$4" "example.com,*.example.com" || exit
    certbotbot_publication_checkpoint another-bucket
    code=$?
    [[ $code == 64 && -z $CERTBOTBOT_CHECKPOINT_ROOT ]] || exit 2
    certbotbot_publication_discard || exit 3
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$PUB_COMMON" "$PUB_CA" \
    "$BATS_TEST_TMPDIR/example.com.tar.gz"
  [ "$status" -eq 0 ]
  [ ! -e "$PUB_AWS_LOG" ]
}

@test "encrypted recovery preserves exact previous ciphertext bytes" {
  command -v gpg >/dev/null 2>&1 || skip 'GPG required'
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  export GPG_PASSPHRASE='recovery-only fixture passphrase'
  env GPG_PASSPHRASE="$GPG_PASSPHRASE" bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit 1
    for remote in "$PUB_S3_STORE"/*.tar.gz; do
      plain="$(mktemp -- "$CERTBOTBOT_WORKSPACE_ROOT/plain.XXXXXXXX")" ||
        exit 2
      cipher="$(mktemp -- "$CERTBOTBOT_WORKSPACE_ROOT/cipher.XXXXXXXX")" ||
        exit 3
      cp -- "$remote" "$plain" || exit 4
      certbotbot_gpg_encrypt_archive "$plain" "$cipher" || exit 5
      cp -- "$cipher" "$remote.enc" || exit 6
      rm -f -- "$remote" "$plain" "$cipher" || exit 7
    done
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT"
  run_checkpoint valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=0'* && "$output" == *'present-0=1'* &&
    "$output" == *'present-1=1'* && "$output" == *'empty=false'* ]]
  grep -Fq ':common-latest.tar.gz.enc' "$PUB_AWS_LOG"
  ! grep -Fq PROHIBITED_WRITE "$PUB_AWS_LOG"
}

@test "changing frozen rollback bytes invalidates its recorded digest" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  run env PATH="$PUB_BIN:$PATH" bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit 1
    certbotbot_publication_prepare valid-bucket "$2" "$3" \
      example.com "$4" "example.com,*.example.com" || exit 2
    certbotbot_publication_checkpoint valid-bucket || exit 3
    path="${CERTBOTBOT_CHECKPOINT_FILES[1]}"
    printf "tampered\n" >"$path"
    certbotbot_checkpoint_verify
    result=$?
    [[ $result -eq 65 ]] || exit 4
    certbotbot_checkpoint_discard || exit 5
    certbotbot_publication_discard || exit 6
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$PUB_COMMON" "$PUB_CA" \
    "$BATS_TEST_TMPDIR/example.com.tar.gz"
  [ "$status" -eq 0 ]
  ! grep -Fq PROHIBITED_WRITE "$PUB_AWS_LOG"
}

## All plan tests use the strict fake AWS GetObject, and forbid PutObject.
run_local_plan() {
  local test_mode=$1
  shift
  run env PATH="$PUB_BIN:$PATH" bash -c '
    source "$1" --version >/dev/null
    mode=$2
    shift 2
    certbotbot_workspace_create || exit 80
    certbotbot_publication_prepare "$@" || exit 81
    certbotbot_publication_checkpoint valid-bucket || exit 82
    certbotbot_publication_plan_prepare
    code=$?
    printf "plan=%s\n" "$code"
    if (( code == 0 )); then
      [[ -f $CERTBOTBOT_PLAN_MANIFEST &&
        "$(stat -c "%a" "$CERTBOTBOT_PLAN_MANIFEST")" == 600 ]] || exit 83
      printf "records=%s\n" "$(grep -c "^object[[:space:]]" \
        "$CERTBOTBOT_PLAN_MANIFEST")"
      printf "first=%s\n" "$(sed -n "5p" \
        "$CERTBOTBOT_PLAN_MANIFEST" | cut -f3)"
      grep -q "^certbotbot-prepublication-plan" \
        "$CERTBOTBOT_PLAN_MANIFEST" || exit 84
      case "$mode" in
        valid)
          certbotbot_publication_plan_verify || exit 85
          ;;
        tamper-proposed)
          printf "tamper\n" >"${CERTBOTBOT_PUBLICATION_FILES[1]}"
          certbotbot_publication_plan_verify
          [[ $? == 65 ]] || exit 86
          ;;
        tamper-prior)
          printf "tamper\n" >"${CERTBOTBOT_CHECKPOINT_FILES[1]}"
          certbotbot_publication_plan_verify
          [[ $? == 65 ]] || exit 87
          ;;
        tamper-manifest)
          printf "tamper\n" >>"$CERTBOTBOT_PLAN_MANIFEST"
          certbotbot_publication_plan_verify
          [[ $? == 65 ]] || exit 88
          ;;
        *) exit 89 ;;
      esac
      certbotbot_publication_plan_discard || exit 90
    else
      [[ -z $CERTBOTBOT_PLAN_ROOT ]] || exit 91
    fi
    certbotbot_checkpoint_discard || exit 92
    certbotbot_publication_discard || exit 93
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_CONFIG" \
      -mindepth 1 -print -quit)" ]] || exit 94
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_ROOT" \
      -mindepth 1 -maxdepth 1 ! -name config ! -name work \
      ! -name logs -print -quit)" ]] || exit 95
    certbotbot_workspace_destroy || exit 96
  ' _ "$CERTBOTBOT_ARTIFACT" "$test_mode" "$@"
}

@test "existing S3 objects yield local checksummed common-first plan" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  run_local_plan valid valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'plan=0'* && "$output" == *'records=2'* &&
    "$output" == *'first=common-latest.tar.gz'* ]]
  ! grep -Fq PROHIBITED_WRITE "$PUB_AWS_LOG"
}

@test "first-run absence is explicit without treating it as an upload grant" {
  make_lineage example.com
  enable_get_mock
  run_local_plan valid valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'plan=0'* && "$output" == *'records=2'* ]]
  ! grep -Fq PROHIBITED_WRITE "$PUB_AWS_LOG"
}

@test "plan detects modification of proposed certificate bytes" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  run_local_plan tamper-proposed valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [ ! -e "$PUB_AWS_LOG" ] || ! grep -Fq PROHIBITED_WRITE "$PUB_AWS_LOG"
}

@test "plan detects mutation of prior recoverable ciphertext or plaintext" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  run_local_plan tamper-prior valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  ! grep -Fq PROHIBITED_WRITE "$PUB_AWS_LOG"
}

@test "plan detects changes to its local manifest bytes" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  run_local_plan tamper-manifest valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  ! grep -Fq PROHIBITED_WRITE "$PUB_AWS_LOG"
}

## Mock S3 PUT supports only write-once recovery keys. It never mutates latest.
enable_recovery_mock() {
  export RECOVERY_FAIL_AT=''
  export RECOVERY_CORRUPT_READ=false
  export RECOVERY_LOG="$BATS_TEST_TMPDIR/recovery-calls"
  cat >"$PUB_BIN/aws" <<'AWS'
#!/usr/bin/env bash
set -u
[[ ${1:-} == --endpoint-url ]] && shift 2
[[ ${1:-} == s3api ]] || exit 88
op=${2:-}
shift 2
bucket='' key='' source='' destination='' guard=''
while (( $# > 0 )); do
  case "$1" in
    --bucket) bucket=$2; shift 2 ;;
    --key) key=$2; shift 2 ;;
    --body) source=$2; shift 2 ;;
    --if-none-match) guard=$2; shift 2 ;;
    *) destination=$1; shift ;;
  esac
done
[[ $bucket == valid-bucket ]] || exit 89
printf '%s:%s:%s\n' "$op" "$key" "$guard" >>"$RECOVERY_LOG"
target="$PUB_S3_STORE/$key"
case "$op" in
  get-object)
    if [[ ! -f $target ]]; then
      printf 'An error occurred (NoSuchKey) when calling the GetObject operation: Missing\n' >&2
      exit 254
    fi
    cp -- "$target" "$destination" || exit 73
    if [[ ${RECOVERY_CORRUPT_READ:-false} == true &&
      $key == */*.prior ]]; then
      printf 'tampered readback\n' >>"$destination"
    fi
    ;;
  put-object)
    [[ $key == recovery/v1/* || $key == staging/recovery/v1/* ]] ||
      exit 86
    [[ $guard == '*' ]] || exit 85
    [[ -z ${RECOVERY_FAIL_AT:-} ||
      $key != *"$RECOVERY_FAIL_AT" ]] || exit 82
    [[ ! -e $target ]] || exit 84
    mkdir -p -- "${target%/*}" || exit 83
    cp -- "$source" "$target" || exit 73
    ;;
  *) exit 87 ;;
esac
AWS
  chmod 0700 "$PUB_BIN/aws"
}

run_recovery_generation() {
  local mode=$1
  shift
  run env PATH="$PUB_BIN:$PATH" \
    CERTBOTBOT_RECOVERY_WRITE_CONFIRM=yes bash -c '
    source "$1" --version >/dev/null
    mode=$2
    shift 2
    certbotbot_workspace_create || exit 70
    certbotbot_publication_prepare "$@" || exit 71
    certbotbot_publication_checkpoint valid-bucket || exit 72
    certbotbot_publication_plan_prepare || exit 73
    certbotbot_recovery_persist
    outcome=$?
    printf "persist=%s\n" "$outcome"
    if (( outcome == 0 )); then
      [[ $CERTBOTBOT_RECOVERY_GENERATION =~ ^[a-f0-9]{32}$ &&
        $CERTBOTBOT_RECOVERY_MANIFEST_SHA256 =~ ^[a-f0-9]{64}$ &&
        -z $CERTBOTBOT_RECOVERY_PENDING_GENERATION ]] || exit 74
      printf "generation=%s\n" "$CERTBOTBOT_RECOVERY_GENERATION"
      certbotbot_recovery_verify valid-bucket production \
        "$CERTBOTBOT_RECOVERY_GENERATION" \
        "$CERTBOTBOT_RECOVERY_MANIFEST_SHA256" || exit 75
      if [[ $mode == invalid-digest ]]; then
        bad=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        [[ $bad != "$CERTBOTBOT_RECOVERY_MANIFEST_SHA256" ]] ||
          bad=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        certbotbot_recovery_verify valid-bucket production \
          "$CERTBOTBOT_RECOVERY_GENERATION" "$bad"
        [[ $? == 65 ]] || exit 76
      fi
      # A newly created workspace has no previous source candidate,
      # checkpoint, or local manifest. Recovery is completely S3-backed.
      gen=$CERTBOTBOT_RECOVERY_GENERATION
      hash=$CERTBOTBOT_RECOVERY_MANIFEST_SHA256
    else
      [[ -z $CERTBOTBOT_RECOVERY_GENERATION &&
        -z $CERTBOTBOT_RECOVERY_MANIFEST_SHA256 &&
        $CERTBOTBOT_RECOVERY_PENDING_GENERATION =~ ^[a-f0-9]{32}$ ]] ||
        exit 77
    fi
    certbotbot_publication_plan_discard || exit 78
    certbotbot_checkpoint_discard || exit 79
    certbotbot_publication_discard || exit 80
    certbotbot_workspace_destroy || exit 81
    if (( outcome == 0 )); then
      certbotbot_workspace_create || exit 82
      certbotbot_recovery_verify valid-bucket production "$gen" "$hash" ||
        exit 83
      printf "independent=ok\n"
      certbotbot_workspace_destroy || exit 84
    fi
  ' _ "$CERTBOTBOT_ARTIFACT" "$mode" "$@"
}

@test "durable recovery saves exact previous bytes and verifies on new runner" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  enable_recovery_mock
  run_recovery_generation valid valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'persist=0'* && "$output" == *'independent=ok'* ]]
  [ -f "$PUB_S3_STORE/common-latest.tar.gz" ]
  [ -f "$PUB_S3_STORE/example.com-latest.tar.gz" ]
  grep -Eq '^put-object:recovery/v1/[a-f0-9]{32}/manifest.tsv:\*$' \
    "$RECOVERY_LOG"
  ! grep -E '^put-object:(common|example.com)-latest' "$RECOVERY_LOG"
}

@test "first-run absence commits manifest without inventing prior objects" {
  make_lineage example.com
  enable_get_mock
  enable_recovery_mock
  run_recovery_generation valid valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'persist=0'* && "$output" == *'independent=ok'* ]]
  ! grep -Eq '^put-object:recovery/v1/.*/[0-9]+.prior' "$RECOVERY_LOG"
  grep -Fq '/manifest.tsv:*' "$RECOVERY_LOG"
}

@test "backup upload denial refuses a committed generation" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  enable_recovery_mock
  export RECOVERY_FAIL_AT=1.prior
  run_recovery_generation failed valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'persist=69'* ]]
  ! grep -Fq 'put-object:recovery/v1/'"$CERTBOTBOT_RECOVERY_GENERATION"'/manifest.tsv' "$RECOVERY_LOG"
  [ -z "$(find "$PUB_S3_STORE/recovery" -name manifest.tsv -print -quit)" ]
}

@test "tampered S3 readback cannot be accepted as durable recovery" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  enable_recovery_mock
  export RECOVERY_CORRUPT_READ=true
  run_recovery_generation failed valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'persist=65'* ]]
  [ -z "$(find "$PUB_S3_STORE/recovery" -name manifest.tsv -print -quit)" ]
}

@test "manifest write denial cannot produce a completed remote checkpoint" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  enable_recovery_mock
  export RECOVERY_FAIL_AT=manifest.tsv
  run_recovery_generation failed valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'persist=69'* ]]
  [ -z "$(find "$PUB_S3_STORE/recovery" -name manifest.tsv -print -quit)" ]
}

@test "fresh runner rejects wrong trusted manifest digest" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  enable_recovery_mock
  run_recovery_generation invalid-digest valid-bucket \
    "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'persist=0'* && "$output" == *'independent=ok'* ]]
}

@test "recovery writes are impossible without explicit affirmative consent" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  enable_recovery_mock
  run env PATH="$PUB_BIN:$PATH" bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit 1
    certbotbot_recovery_persist
    [[ $? == 64 ]] || exit 2
    certbotbot_workspace_destroy || exit 3
  ' _ "$CERTBOTBOT_ARTIFACT"
  [ "$status" -eq 0 ]
  [ ! -e "$RECOVERY_LOG" ]
}

## Recheck the latest S3 objects after ADR-042/043/046 have frozen state.
## Mutations in this test simulate an independent external writer.
run_latest_drift() {
  local mode=$1
  shift
  run env PATH="$PUB_BIN:$PATH" bash -c '
    source "$1" --version >/dev/null
    mode=$2
    shift 2
    certbotbot_workspace_create || exit 80
    certbotbot_publication_prepare "$@" || exit 81
    certbotbot_publication_checkpoint valid-bucket || exit 82
    certbotbot_publication_plan_prepare || exit 83
    case "$mode" in
      unchanged) ;;
      change-common)
        printf "new writer\n" >>"$PUB_S3_STORE/common-latest.tar.gz"
        ;;
      change-domain)
        printf "new writer\n" >>"$PUB_S3_STORE/example.com-latest.tar.gz"
        ;;
      remove-domain)
        rm -f -- "$PUB_S3_STORE/example.com-latest.tar.gz"
        ;;
      remove-common)
        rm -f -- "$PUB_S3_STORE/common-latest.tar.gz"
        ;;
      remove-all)
        rm -f -- "$PUB_S3_STORE/common-latest.tar.gz" \
          "$PUB_S3_STORE/example.com-latest.tar.gz"
        ;;
      add-common-and-domain)
        cp -- "$PUB_COMMON" "$PUB_S3_STORE/common-latest.tar.gz"
        cp -- "$BATS_TEST_TMPDIR/example.com.tar.gz" \
          "$PUB_S3_STORE/example.com-latest.tar.gz"
        ;;
      add-domain)
        cp -- "$BATS_TEST_TMPDIR/example.com.tar.gz" \
          "$PUB_S3_STORE/example.com-latest.tar.gz"
        ;;
      opposite-mode)
        mv -- "$PUB_S3_STORE/example.com-latest.tar.gz" \
          "$PUB_S3_STORE/example.com-latest.tar.gz.enc"
        ;;
      denied)
        export PUB_S3_MODE=denied
        ;;
      wrong-environment)
        ACME_ENVIRONMENT=staging
        ;;
      tamper-local)
        printf "tampered proposed bytes\n" \
          >>"${CERTBOTBOT_PUBLICATION_FILES[1]}"
        ;;
      *) exit 84 ;;
    esac
    certbotbot_publication_precondition_check
    result=$?
    printf "precondition=%s\n" "$result"
    [[ -z "${CERTBOTBOT_S3_STAGE_ROOT:-}" &&
      -z "${CERTBOTBOT_RESTORE_ROOT:-}" &&
      -z "${CERTBOTBOT_COMMON_STAGE:-}" ]] || exit 85
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_CONFIG" \
      -mindepth 1 -print -quit)" ]] || exit 86
    certbotbot_publication_plan_discard || exit 87
    certbotbot_checkpoint_discard || exit 88
    certbotbot_publication_discard || exit 89
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_ROOT" \
      -mindepth 1 -maxdepth 1 ! -name config ! -name work \
      ! -name logs -print -quit)" ]] || exit 90
    certbotbot_workspace_destroy || exit 91
  ' _ "$CERTBOTBOT_ARTIFACT" "$mode" "$@"
}

@test "read-only latest precondition accepts byte-identical previous collection" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  run_latest_drift unchanged valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'precondition=0'* ]]
  [ ! -e "$PUB_AWS_LOG" ] || ! grep -Fq PROHIBITED_WRITE "$PUB_AWS_LOG"
}

@test "unchanged confirmed first-run absence remains a valid observation" {
  make_lineage example.com
  enable_get_mock
  run_latest_drift unchanged valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'precondition=0'* ]]
}

@test "new remote common and domain after absent checkpoint aborts" {
  make_lineage example.com
  enable_get_mock
  run_latest_drift add-common-and-domain valid-bucket \
    "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'precondition=65'* ]]
}

@test "new remote domain after existing common aborts" {
  make_lineage example.com
  enable_get_mock
  stage_previous
  run_latest_drift add-domain valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'precondition=65'* ]]
}

@test "changed remote common archive aborts before publication" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  run_latest_drift change-common valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'precondition=65'* ]]
}

@test "changed remote lineage archive aborts before publication" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  run_latest_drift change-domain valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'precondition=65'* ]]
}

@test "removed remote domain is different from a confirmed prior presence" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  run_latest_drift remove-domain valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'precondition=65'* ]]
}

@test "removed common while lineage remains is an inconsistent collection" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  run_latest_drift remove-common valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'precondition=65'* ]]
}

@test "removing all prior objects cannot appear as an unchanged first run" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  run_latest_drift remove-all valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'precondition=65'* ]]
}

@test "wrong-mode encrypted object cannot silently replace plaintext latest" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  run_latest_drift opposite-mode valid-bucket \
    "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'precondition=65'* ]]
}

@test "denied S3 read cannot be mistaken for missing or unchanged state" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  run_latest_drift denied valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'precondition=69'* ]]
}

@test "precondition requires matching ACME environment" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  run_latest_drift wrong-environment valid-bucket \
    "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'precondition=64'* ]]
}

@test "tampered local candidate fails before S3 reread" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  run_latest_drift tamper-local valid-bucket \
    "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'precondition=65'* ]]
}

## HEAD and conditional GET mock with opaque ETags, no writes permitted.
enable_etag_mock() {
  export ETAG_MOCK_MODE=normal
  cat >"$PUB_BIN/aws" <<'AWS'
#!/usr/bin/env bash
set -u
[[ ${1:-} == --endpoint-url ]] && shift 2
[[ ${1:-} == s3api ]] || exit 88
op=${2:-}
shift 2
bucket='' key='' destination='' predicate=''
while (( $# > 0 )); do
  case "$1" in
    --bucket) bucket=$2; shift 2 ;;
    --key) key=$2; shift 2 ;;
    --if-match) predicate=$2; shift 2 ;;
    --query|--output) shift 2 ;;
    *) destination=$1; shift ;;
  esac
done
printf '%s:%s:%s\n' "$op" "$key" "$predicate" >>"$PUB_AWS_LOG"
[[ $bucket == valid-bucket ]] || exit 87
[[ $op == get-object || $op == head-object ]] || {
  printf 'PROHIBITED_WRITE\n' >>"$PUB_AWS_LOG"
  exit 88
}
if [[ ${PUB_S3_MODE:-normal} == denied ||
  ( ${ETAG_MOCK_MODE:-normal} == denied-head && $op == head-object ) ]]; then
  printf 'An error occurred (AccessDenied) when calling the %s operation\n' "$op" >&2
  exit 254
fi
source="$PUB_S3_STORE/$key"
if [[ ! -f $source ]]; then
  printf 'An error occurred (NoSuchKey) when calling the GetObject operation: Missing\n' >&2
  exit 254
fi
if [[ $op == head-object && ${ETAG_MOCK_MODE:-normal} == change-on-head &&
  $key == *example.com-latest.tar.gz ]]; then
  printf 'concurrent writer\n' >>"$source"
fi
etag="\"$(sha256sum -- "$source" | cut -c1-32)\""
if [[ $op == head-object ]]; then
  if [[ ${ETAG_MOCK_MODE:-normal} == malformed-head ]]; then
    printf 'malformed-token\n'
  else
    printf '%s\n' "$etag"
  fi
  exit 0
fi
if [[ -n $predicate ]]; then
  if [[ ${ETAG_MOCK_MODE:-normal} == refuse-conditional ||
    $predicate != "$etag" ]]; then
    printf 'An error occurred (PreconditionFailed) when calling the GetObject operation\n' >&2
    exit 254
  fi
fi
cp -- "$source" "$destination" || exit 73
if [[ -n $predicate && ${ETAG_MOCK_MODE:-normal} == corrupt-conditional &&
  $key == *example.com-latest.tar.gz ]]; then
  printf 'bad returned data\n' >>"$destination"
fi
AWS
  chmod 0700 "$PUB_BIN/aws"
}

run_etag_conditions() {
  run env PATH="$PUB_BIN:$PATH" bash -c '
    source "$1" --version >/dev/null
    shift
    certbotbot_workspace_create || exit 90
    certbotbot_publication_prepare "$@" || exit 91
    certbotbot_publication_checkpoint valid-bucket || exit 92
    certbotbot_publication_plan_prepare || exit 93
    certbotbot_latest_conditions_capture
    code=$?
    printf "capture=%s\n" "$code"
    if (( code == 0 )); then
      count=${#CERTBOTBOT_PUBLICATION_KEYS[@]}
      [[ ${#CERTBOTBOT_LATEST_CONDITION_KEYS[@]} -eq "$count" &&
        ${#CERTBOTBOT_LATEST_CONDITION_KINDS[@]} -eq "$count" &&
        ${#CERTBOTBOT_LATEST_CONDITION_VALUES[@]} -eq "$count" &&
        $CERTBOTBOT_LATEST_CONDITION_PLAN_SHA256 == \
          "$CERTBOTBOT_PLAN_DIGEST" ]] || exit 94
      for (( i=0; i<count; i++ )); do
        printf "kind-%s=%s\n" "$i" \
          "${CERTBOTBOT_LATEST_CONDITION_KINDS[i]}"
        if [[ ${CERTBOTBOT_LATEST_CONDITION_KINDS[i]} == etag ]]; then
          [[ ${CERTBOTBOT_LATEST_CONDITION_VALUES[i]} =~ ^\"[A-Za-z0-9_.-]+\"$ ]] ||
            exit 95
        else
          [[ ${CERTBOTBOT_LATEST_CONDITION_KINDS[i]} == absent &&
            -z ${CERTBOTBOT_LATEST_CONDITION_VALUES[i]} ]] || exit 96
        fi
      done
      certbotbot_latest_conditions_capture
      [[ $? == 64 ]] || exit 97
    else
      [[ ${#CERTBOTBOT_LATEST_CONDITION_KEYS[@]} == 0 &&
        ${#CERTBOTBOT_LATEST_CONDITION_VALUES[@]} == 0 &&
        -z $CERTBOTBOT_LATEST_CONDITION_PLAN_SHA256 ]] || exit 98
    fi
    certbotbot_latest_conditions_discard || exit 99
    certbotbot_publication_plan_discard || exit 100
    certbotbot_checkpoint_discard || exit 101
    certbotbot_publication_discard || exit 102
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_ROOT" \
      -mindepth 1 -maxdepth 1 ! -name config ! -name work \
      ! -name logs -print -quit)" ]] || exit 103
    certbotbot_workspace_destroy || exit 104
  ' _ "$CERTBOTBOT_ARTIFACT" "$@"
}

@test "existing old bytes produce ETags only after matching conditional GETs" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  enable_etag_mock
  run_etag_conditions valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'capture=0'* && "$output" == *'kind-0=etag'* &&
    "$output" == *'kind-1=etag'* ]]
  grep -Fq 'head-object:common-latest.tar.gz:' "$PUB_AWS_LOG"
  grep -Eq '^get-object:example.com-latest.tar.gz:"[a-f0-9]{32}"$' "$PUB_AWS_LOG"
  ! grep -Fq PROHIBITED_WRITE "$PUB_AWS_LOG"
}

@test "confirmed absent keys produce explicit no-existing-object predicate" {
  make_lineage example.com
  enable_get_mock
  enable_etag_mock
  run_etag_conditions valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'capture=0'* && "$output" == *'kind-0=absent'* &&
    "$output" == *'kind-1=absent'* ]]
  ! grep -Fq 'head-object:' "$PUB_AWS_LOG"
}

@test "old common but new requested domain yields mixed etag/absent predicates" {
  make_lineage example.com
  enable_get_mock
  stage_previous
  enable_etag_mock
  run_etag_conditions valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'capture=0'* && "$output" == *'kind-0=etag'* &&
    "$output" == *'kind-1=absent'* ]]
}

@test "denied HEAD leaves no accepted conditional tokens" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  enable_etag_mock
  export ETAG_MOCK_MODE=denied-head
  run_etag_conditions valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'capture=69'* ]]
  ! grep -Fq PROHIBITED_WRITE "$PUB_AWS_LOG"
}

@test "malformed service ETag is rejected instead of shell-interpreted" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  enable_etag_mock
  export ETAG_MOCK_MODE=malformed-head
  run_etag_conditions valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'capture=69'* ]]
}

@test "conditional read failure is fatal even after successful HEAD" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  enable_etag_mock
  export ETAG_MOCK_MODE=refuse-conditional
  run_etag_conditions valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'capture=69'* ]]
}

@test "changed remote bytes after HEAD cannot inherit a stale checkpoint" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  enable_etag_mock
  export ETAG_MOCK_MODE=change-on-head
  run_etag_conditions valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'capture=65'* ]]
}

@test "corrupt conditional download bytes are rejected despite matching token" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  enable_etag_mock
  export ETAG_MOCK_MODE=corrupt-conditional
  run_etag_conditions valid-bucket "$PUB_COMMON" "$PUB_CA" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'capture=65'* ]]
}

## S3 facade for conditional latest writes and independently verified rollback.
## It uses the production CLI shape but keeps all effects under BATS_TEST_TMPDIR.
enable_latest_write_mock() {
  export LATEST_WRITE_LOG="$BATS_TEST_TMPDIR/latest-write.log"
  export LATEST_FAILURE=''
  export LATEST_MUTATE_AFTER_FAILURE=false
  cat >"$PUB_BIN/aws" <<'AWS'
#!/usr/bin/env bash
set -u
[[ ${1:-} == --endpoint-url ]] && shift 2
[[ ${1:-} == s3api ]] || exit 88
operation=${2:-}
shift 2
bucket='' key='' body='' destination='' ifmatch='' ifnone=''
while (( $# > 0 )); do
  case "$1" in
    --bucket) bucket=$2; shift 2 ;;
    --key) key=$2; shift 2 ;;
    --body) body=$2; shift 2 ;;
    --if-match) ifmatch=$2; shift 2 ;;
    --if-none-match) ifnone=$2; shift 2 ;;
    --query|--output) shift 2 ;;
    *) destination=$1; shift ;;
  esac
done
[[ $bucket == valid-bucket ]] || exit 87
target="$PUB_S3_STORE/$key"
printf '%s:%s:%s:%s\n' "$operation" "$key" "$ifmatch" "$ifnone" \
  >>"$LATEST_WRITE_LOG"
etag=''
if [[ -f $target ]]; then
  etag="\"$(sha256sum -- "$target" | cut -c1-32)\""
fi
case "$operation" in
  head-object)
    [[ -n $etag ]] || exit 254
    printf '%s\n' "$etag"
    ;;
  get-object)
    if [[ ! -f $target ]]; then
      printf 'An error occurred (NoSuchKey) when calling the GetObject operation: Missing\n' >&2
      exit 254
    fi
    [[ -z $ifmatch || $ifmatch == "$etag" ]] || exit 254
    cp -- "$target" "$destination" || exit 73
    ;;
  put-object)
    [[ $ifnone == '*' || -n $ifmatch ]] || exit 86
    [[ -z $ifnone || ! -e $target ]] || exit 254
    [[ -z $ifmatch || ( -n $etag && $ifmatch == "$etag" ) ]] ||
      exit 254
    if [[ ${LATEST_FAILURE:-} == fail-domain-before &&
      $key == example.com-latest.tar.gz ]]; then
      exit 255
    fi
    mkdir -p -- "${target%/*}" || exit 73
    cp -- "$body" "$target" || exit 73
    if [[ ${LATEST_FAILURE:-} == fail-domain-after &&
      $key == example.com-latest.tar.gz &&
      ! -e "$PUB_S3_STORE/.lost-domain-response-once" ]]; then
      : >"$PUB_S3_STORE/.lost-domain-response-once"
      exit 255
    fi
    ;;
  delete-object)
    [[ -n $ifmatch && -n $etag && $ifmatch == "$etag" ]] ||
      exit 254
    rm -f -- "$target" || exit 73
    ;;
  *) exit 85 ;;
esac
AWS
  chmod 0700 "$PUB_BIN/aws"
}

## Renew the proposal after saving a different, valid previous state remotely.
regenerate_latest_proposal() {
  printf '\n' >>"$PUB_SOURCE/common/accounts/acme-v02.api.letsencrypt.org/directory/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/meta.json"
  tar -czf "$PUB_COMMON" -C "$PUB_SOURCE/common" accounts
  rm -rf -- "$PUB_SOURCE/example.com"
  make_lineage example.com
}

## Run the entire guarded write protocol and optionally recover on fresh host.
run_conditional_publication() {
  local scenario=$1
  shift
  run env PATH="$PUB_BIN:$PATH" \
    CERTBOTBOT_RECOVERY_WRITE_CONFIRM=yes \
    CERTBOTBOT_LATEST_WRITE_CONFIRM=yes \
    CERTBOTBOT_LATEST_ROLLBACK_CONFIRM=yes bash -c '
    source "$1" --version >/dev/null
    mode=$2
    shift 2
    certbotbot_workspace_create || exit 70
    certbotbot_publication_prepare "$@" || exit 71
    certbotbot_publication_checkpoint valid-bucket || exit 72
    certbotbot_publication_plan_prepare || exit 73
    certbotbot_recovery_persist || exit 74
    generation=$CERTBOTBOT_RECOVERY_GENERATION
    hash=$CERTBOTBOT_RECOVERY_MANIFEST_SHA256
    certbotbot_latest_conditions_capture || exit 75
    CERTBOTBOT_LATEST_RECOVERY_ACK="$generation:$hash"
    certbotbot_latest_publish
    result=$?
    printf "publication=%s\n" "$result"
    printf "outcome=%s\n" "$CERTBOTBOT_LATEST_PUBLISH_OUTCOME"
    case "$mode" in
      complete)
        [[ $result == 0 &&
          $CERTBOTBOT_LATEST_PUBLISH_OUTCOME == complete ]] || exit 76
        ;;
      partial|lost-response|conflict)
        [[ $result == 69 &&
          $CERTBOTBOT_LATEST_PUBLISH_OUTCOME == partial ]] || exit 77
        ;;
      *) exit 78 ;;
    esac
    certbotbot_latest_conditions_discard || exit 79
    certbotbot_publication_plan_discard || exit 80
    certbotbot_checkpoint_discard || exit 81
    certbotbot_publication_discard || exit 82
    certbotbot_workspace_destroy || exit 83
    # A second runner has no access to predecessor candidate/checkpoint state.
    certbotbot_workspace_create || exit 84
    if [[ $mode == conflict ]]; then
      printf "third-party-state\n" >"$PUB_S3_STORE/example.com-latest.tar.gz"
    fi
    certbotbot_latest_recover valid-bucket production \
      "$generation" "$hash"
    rollback=$?
    printf "rollback=%s\n" "$rollback"
    if [[ $mode == conflict ]]; then
      [[ $rollback == 65 ]] || exit 85
    else
      [[ $rollback == 0 ]] || exit 86
    fi
    certbotbot_workspace_destroy || exit 87
  ' _ "$CERTBOTBOT_ARTIFACT" "$scenario" "$@"
}

@test "complete conditional publish and fresh-runner recovery return exact old bytes" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  regenerate_latest_proposal
  cp -- "$PUB_S3_STORE/common-latest.tar.gz" "$BATS_TEST_TMPDIR/original-common"
  cp -- "$PUB_S3_STORE/example.com-latest.tar.gz" \
    "$BATS_TEST_TMPDIR/original-domain"
  enable_latest_write_mock
  run_conditional_publication complete valid-bucket \
    "$PUB_COMMON" "$PUB_CA" example.com \
    "$BATS_TEST_TMPDIR/example.com.tar.gz" 'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'publication=0'* && "$output" == *'rollback=0'* ]]
  cmp -s "$PUB_S3_STORE/common-latest.tar.gz" \
    "$BATS_TEST_TMPDIR/original-common"
  cmp -s "$PUB_S3_STORE/example.com-latest.tar.gz" \
    "$BATS_TEST_TMPDIR/original-domain"
  grep -q '^put-object:common-latest.tar.gz:"' "$LATEST_WRITE_LOG"
  grep -q '^put-object:example.com-latest.tar.gz:"' "$LATEST_WRITE_LOG"
}

@test "partial domain PUT failure is recoverable on another empty worker" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  regenerate_latest_proposal
  cp -- "$PUB_S3_STORE/common-latest.tar.gz" "$BATS_TEST_TMPDIR/original-common"
  cp -- "$PUB_S3_STORE/example.com-latest.tar.gz" \
    "$BATS_TEST_TMPDIR/original-domain"
  enable_latest_write_mock
  export LATEST_FAILURE=fail-domain-before
  run_conditional_publication partial valid-bucket \
    "$PUB_COMMON" "$PUB_CA" example.com \
    "$BATS_TEST_TMPDIR/example.com.tar.gz" 'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'publication=69'* && "$output" == *'rollback=0'* ]]
  cmp -s "$PUB_S3_STORE/common-latest.tar.gz" \
    "$BATS_TEST_TMPDIR/original-common"
  cmp -s "$PUB_S3_STORE/example.com-latest.tar.gz" \
    "$BATS_TEST_TMPDIR/original-domain"
}

@test "lost S3 domain response is reconciled against actual remote bytes" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  regenerate_latest_proposal
  cp -- "$PUB_S3_STORE/common-latest.tar.gz" "$BATS_TEST_TMPDIR/original-common"
  cp -- "$PUB_S3_STORE/example.com-latest.tar.gz" \
    "$BATS_TEST_TMPDIR/original-domain"
  enable_latest_write_mock
  export LATEST_FAILURE=fail-domain-after
  run_conditional_publication lost-response valid-bucket \
    "$PUB_COMMON" "$PUB_CA" example.com \
    "$BATS_TEST_TMPDIR/example.com.tar.gz" 'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'publication=69'* && "$output" == *'rollback=0'* ]]
  cmp -s "$PUB_S3_STORE/common-latest.tar.gz" \
    "$BATS_TEST_TMPDIR/original-common"
  cmp -s "$PUB_S3_STORE/example.com-latest.tar.gz" \
    "$BATS_TEST_TMPDIR/original-domain"
}

@test "fresh rollback refuses unrelated modified key before changing any other key" {
  make_lineage example.com
  enable_get_mock
  stage_previous example.com
  regenerate_latest_proposal
  cp -- "$PUB_S3_STORE/common-latest.tar.gz" "$BATS_TEST_TMPDIR/original-common"
  enable_latest_write_mock
  export LATEST_FAILURE=fail-domain-before
  run_conditional_publication conflict valid-bucket \
    "$PUB_COMMON" "$PUB_CA" example.com \
    "$BATS_TEST_TMPDIR/example.com.tar.gz" 'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'publication=69'* && "$output" == *'rollback=65'* ]]
  ! cmp -s "$PUB_S3_STORE/common-latest.tar.gz" \
    "$BATS_TEST_TMPDIR/original-common"
  grep -Fq 'third-party-state' "$PUB_S3_STORE/example.com-latest.tar.gz"
}

@test "first-run recovery conditionally deletes only our newly created latest keys" {
  make_lineage example.com
  enable_get_mock
  enable_latest_write_mock
  run_conditional_publication complete valid-bucket \
    "$PUB_COMMON" "$PUB_CA" example.com \
    "$BATS_TEST_TMPDIR/example.com.tar.gz" 'example.com,*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *'publication=0'* && "$output" == *'rollback=0'* ]]
  [ ! -e "$PUB_S3_STORE/common-latest.tar.gz" ]
  [ ! -e "$PUB_S3_STORE/example.com-latest.tar.gz" ]
  grep -q '^delete-object:common-latest.tar.gz:"' "$LATEST_WRITE_LOG"
  grep -q '^delete-object:example.com-latest.tar.gz:"' "$LATEST_WRITE_LOG"
}
