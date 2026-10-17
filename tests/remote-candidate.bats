#!/usr/bin/env bats

## @file tests/remote-candidate.bats
## @brief Verify complete S3-to-inactive-candidate integration and cleanup.
## @details
## Uses a bounded GetObject fake and locally generated certificate fixtures.
## No Certbot, Route53, public issuance, or remote mutation is authorized.
## Every standalone release artifact executes this suite.
## @see doc/adr/ADR-054-remote-verified-inactive-candidate.md

setup() {
  : "${CERTBOTBOT_ARTIFACT:?A standalone release artifact is required}"
  export CERTBOTBOT_TMPDIR="$BATS_TEST_TMPDIR/producer"
  export ASSEMBLY_SOURCE="$BATS_TEST_TMPDIR/source"
  export ASSEMBLY_COMMON="$BATS_TEST_TMPDIR/common.tar.gz"
  export ASSEMBLY_ACCOUNT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export REMOTE_STORE="$BATS_TEST_TMPDIR/store"
  export ASSEMBLY_BIN="$BATS_TEST_TMPDIR/bin"
  export REMOTE_CALLS="$BATS_TEST_TMPDIR/remote-calls"
  export REMOTE_FORBIDDEN="$BATS_TEST_TMPDIR/forbidden"
  export REMOTE_MODE=normal
  export REMOTE_VERIFY_MODE=none
  export REMOTE_TEST_CA="$BATS_TEST_TMPDIR/test-ca.crt"
  export AWS_EC2_METADATA_DISABLED=true
  unset GPG_PASSPHRASE || :
  umask 077
  mkdir -m 0700 "$CERTBOTBOT_TMPDIR" "$ASSEMBLY_SOURCE" \
    "$REMOTE_STORE" "$ASSEMBLY_BIN"
  cat >"$ASSEMBLY_BIN/aws" <<'AWS'
#!/usr/bin/env bash
set -eu
if [[ ${1:-} == --endpoint-url ]]; then shift 2; fi
[[ ${1:-} == s3api && ${2:-} == get-object ]] || {
  printf 'forbidden S3 mutation\n' >>"$REMOTE_FORBIDDEN"
  exit 97
}
shift 2
bucket='' key='' dest=''
while (( $# )); do
  case $1 in
    --bucket) bucket=$2; shift 2 ;;
    --key) key=$2; shift 2 ;;
    *) dest=$1; shift ;;
  esac
done
[[ $bucket == valid-bucket && $dest == /* && -z ${GPG_PASSPHRASE:-} ]] ||
  exit 98
printf '%s\n' "$key" >>"$REMOTE_CALLS"
if [[ ${REMOTE_MODE:-normal} == denied ]]; then
  printf 'An error occurred (AccessDenied) when calling the GetObject operation: Denied\n' >&2
  exit 254
fi
if [[ ! -f $REMOTE_STORE/$key ]]; then
  printf 'An error occurred (NoSuchKey) when calling the GetObject operation: Missing\n' >&2
  exit 254
fi
cp -- "$REMOTE_STORE/$key" "$dest"
AWS
  cat >"$ASSEMBLY_BIN/certbot" <<'CERTBOT'
#!/usr/bin/env bash
printf 'forbidden Certbot invocation\n' >>"$REMOTE_FORBIDDEN"
exit 99
CERTBOT
  chmod 0700 "$ASSEMBLY_BIN/aws" "$ASSEMBLY_BIN/certbot"
}

common_archive() {
  local host=acme-v02.api.letsencrypt.org
  local account="$ASSEMBLY_SOURCE/accounts/$host/directory/$ASSEMBLY_ACCOUNT"
  local kind=''
  mkdir -p "$account"
  chmod 0700 "$ASSEMBLY_SOURCE/accounts" \
    "$ASSEMBLY_SOURCE/accounts/$host" \
    "$ASSEMBLY_SOURCE/accounts/$host/directory" "$account"
  for kind in meta regr private_key; do
    printf '{"fixture":"%s"}\n' "$kind" >"$account/$kind.json"
    chmod 0600 "$account/$kind.json"
  done
  tar -czf "$ASSEMBLY_COMMON" -C "$ASSEMBLY_SOURCE" accounts
}

lineage_archive() {
  local name=$1 root="$ASSEMBLY_SOURCE/$1" kind=''
  mkdir -p "$root/archive/$name" "$root/live/$name" \
    "$root/combined" "$root/renewal"
  chmod 0700 "$root" "$root/archive" "$root/archive/$name" \
    "$root/live" "$root/live/$name" "$root/renewal" "$root/combined"
  for kind in cert chain fullchain privkey; do
    printf '%s synthetic fixture\n' "$kind" \
      >"$root/archive/$name/${kind}1.pem"
    ln -s "../../archive/$name/${kind}1.pem" \
      "$root/live/$name/$kind.pem"
  done
  printf 'combined synthetic fixture\n' >"$root/combined/$name.pem"
  cp -- "$root/combined/$name.pem" "$root/live/$name/combined.pem"
  chmod 0600 "$root/archive/$name/privkey1.pem" \
    "$root/combined/$name.pem" "$root/live/$name/combined.pem"
  cat >"$root/renewal/$name.conf" <<RENEWAL
version = 5.8.0
archive_dir = /previous-runner/config/archive/$name
cert = /previous-runner/config/live/$name/cert.pem
privkey = /previous-runner/config/live/$name/privkey.pem
chain = /previous-runner/config/live/$name/chain.pem
fullchain = /previous-runner/config/live/$name/fullchain.pem

[renewalparams]
account = $ASSEMBLY_ACCOUNT
server = https://acme-v02.api.letsencrypt.org/directory
authenticator = dns-route53
key_type = ecdsa
RENEWAL
  pack_lineage "$name"
}

pack_lineage() {
  local name=$1
  tar -czf "$BATS_TEST_TMPDIR/$name.tar.gz" \
    -C "$ASSEMBLY_SOURCE/$name" archive live renewal combined
}



put_fixture() {
  cp -- "$ASSEMBLY_COMMON" "$REMOTE_STORE/common-latest.tar.gz"
  local name
  for name in "$@"; do
    cp -- "$BATS_TEST_TMPDIR/$name.tar.gz" \
      "$REMOTE_STORE/$name-latest.tar.gz"
  done
}

make_test_ca() {
  openssl ecparam -name prime256v1 -genkey -noout \
    -out "$BATS_TEST_TMPDIR/ca.key" >/dev/null 2>&1
  openssl req -new -x509 -key "$BATS_TEST_TMPDIR/ca.key" \
    -days 30 -subj '/CN=certbotbot isolated test CA' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -out "$REMOTE_TEST_CA" >/dev/null 2>&1
}

sign_test_lineage() {
  local name=$1 root="$ASSEMBLY_SOURCE/$1" serial=''
  local leaf="$root/archive/$name"
  openssl ecparam -name prime256v1 -genkey -noout \
    -out "$leaf/privkey1.pem" >/dev/null 2>&1
  openssl req -new -key "$leaf/privkey1.pem" \
    -out "$BATS_TEST_TMPDIR/$name.csr" -subj "/CN=$name" \
    >/dev/null 2>&1
  cat >"$BATS_TEST_TMPDIR/$name.ext" <<EXT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:$name,DNS:*.$name
EXT
  openssl x509 -req -in "$BATS_TEST_TMPDIR/$name.csr" \
    -CA "$REMOTE_TEST_CA" -CAkey "$BATS_TEST_TMPDIR/ca.key" \
    -CAcreateserial -days 30 -extfile "$BATS_TEST_TMPDIR/$name.ext" \
    -out "$leaf/cert1.pem" >/dev/null 2>&1
  cp -- "$REMOTE_TEST_CA" "$leaf/chain1.pem"
  cat -- "$leaf/cert1.pem" "$REMOTE_TEST_CA" \
    >"$leaf/fullchain1.pem"
  { cat -- "$leaf/fullchain1.pem"; printf '\n'; \
    cat -- "$leaf/privkey1.pem"; } >"$root/combined/$name.pem"
  cp -- "$root/combined/$name.pem" "$root/live/$name/combined.pem"
  chmod 0600 -- "$leaf/privkey1.pem" "$root/combined/$name.pem" \
    "$root/live/$name/combined.pem"
  pack_lineage "$name"
}

run_remote() {
  run env PATH="$ASSEMBLY_BIN:$PATH" \
    REMOTE_MODE="$REMOTE_MODE" REMOTE_VERIFY_MODE="$REMOTE_VERIFY_MODE" \
    bash -c '
    source "$1" --version >/dev/null || exit 90
    certbotbot_workspace_create || exit 91
    shift
    certbotbot_remote_candidate_prepare valid-bucket "$@"
    code=$?
    printf "prepare=%s\n" "$code"
    if (( code == 0 )); then
      config=$CERTBOTBOT_IMPORT_CANDIDATE_CONFIG
      [[ -d $config/accounts && ! -e $CERTBOTBOT_S3_STAGE_ROOT &&
        -z $CERTBOTBOT_S3_STAGE_ROOT &&
        "$config" != "$CERTBOTBOT_WORKSPACE_CONFIG" ]] || exit 92
      for name in "$@"; do
        [[ -f $config/renewal/$name.conf &&
          -L $config/live/$name/cert.pem &&
          -f $config/combined/$name.pem ]] || exit 93
        grep -Fq "archive_dir = $config/archive/$name" \
          "$config/renewal/$name.conf" || exit 94
      done
      if [[ $REMOTE_VERIFY_MODE != none ]]; then
        case $REMOTE_VERIFY_MODE in
          wrong-san)
            certbotbot_remote_candidate_verify "$REMOTE_TEST_CA" \
              example.com "example.com *.example.com extra.example.com" \
              example.net "example.net *.example.net"
            ;;
          wrong-count)
            certbotbot_remote_candidate_verify "$REMOTE_TEST_CA" \
              example.com "example.com *.example.com"
            ;;
          *)
            certbotbot_remote_candidate_verify "$REMOTE_TEST_CA" \
              example.com "example.com *.example.com" \
              example.net "example.net *.example.net"
            ;;
        esac
        code=$?
        printf "verify=%s\n" "$code"
        if (( code == 0 )); then
          [[ $CERTBOTBOT_REMOTE_CANDIDATE_VERIFIED == true ]] || exit 95
        else
          [[ -z $CERTBOTBOT_REMOTE_CANDIDATE_VERIFIED &&
            -z $CERTBOTBOT_IMPORT_CANDIDATE_ROOT &&
            -z $CERTBOTBOT_IMPORT_CANDIDATE_CONFIG ]] || exit 96
        fi
      fi
      certbotbot_remote_candidate_discard || exit 97
    else
      [[ -z $CERTBOTBOT_IMPORT_CANDIDATE_ROOT &&
        -z $CERTBOTBOT_IMPORT_CANDIDATE_CONFIG &&
        -z $CERTBOTBOT_REMOTE_CANDIDATE_VERIFIED ]] || exit 98
    fi
    [[ -z $CERTBOTBOT_S3_STAGE_ROOT &&
      -z $CERTBOTBOT_COMMON_STAGE &&
      -z $CERTBOTBOT_RESTORE_ROOT &&
      -z $CERTBOTBOT_RENEWAL_PREVIEW ]] || exit 99
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_CONFIG" \
      -mindepth 1 -print -quit)" ]] || exit 100
    certbotbot_workspace_destroy || exit 101
  ' _ "$CERTBOTBOT_ARTIFACT" "$@"
}

@test "one existing lineage is downloaded, prepared, and fully discarded" {
  common_archive
  lineage_archive example.com
  put_fixture example.com
  run_remote example.com
  [ "$status" -eq 0 ]
  [[ $output == *'prepare=0'* ]]
  [ "$(wc -l <"$REMOTE_CALLS")" -eq 2 ]
  [ ! -e "$REMOTE_FORBIDDEN" ]
}

@test "two existing lineages coexist under the same remotely retrieved account" {
  common_archive
  lineage_archive example.com
  lineage_archive example.net
  put_fixture example.com example.net
  run_remote example.com example.net
  [ "$status" -eq 0 ]
  [[ $output == *'prepare=0'* ]]
  [ "$(wc -l <"$REMOTE_CALLS")" -eq 3 ]
  [ ! -e "$REMOTE_FORBIDDEN" ]
}

@test "fully absent S3 state stays typed status 10 without a candidate" {
  run_remote example.com
  [ "$status" -eq 0 ]
  [[ $output == *'prepare=10'* ]]
  [ ! -e "$REMOTE_FORBIDDEN" ]
}

@test "missing selected lineage cannot become an incomplete candidate" {
  common_archive
  lineage_archive example.com
  put_fixture example.com
  run_remote example.com example.net
  [ "$status" -eq 0 ]
  [[ $output == *'prepare=65'* ]]
  [ ! -e "$REMOTE_FORBIDDEN" ]
}

@test "denied S3 GetObject fails closed without a candidate" {
  export REMOTE_MODE=denied
  run_remote example.com
  [ "$status" -eq 0 ]
  [[ $output == *'prepare=69'* ]]
  [ ! -e "$REMOTE_FORBIDDEN" ]
}

@test "corrupt second archive leaves no partial first-lineage candidate" {
  common_archive
  lineage_archive example.com
  lineage_archive example.net
  put_fixture example.com example.net
  printf 'not a tar archive\n' >"$REMOTE_STORE/example.net-latest.tar.gz"
  run_remote example.com example.net
  [ "$status" -eq 0 ]
  [[ $output == *'prepare='* && $output != *'prepare=0'* ]]
  [ ! -e "$REMOTE_FORBIDDEN" ]
}

@test "crypto verification rejects synthetic PEMs and discards candidate" {
  command -v openssl >/dev/null 2>&1 || skip 'OpenSSL required'
  make_test_ca
  common_archive
  lineage_archive example.com
  lineage_archive example.net
  put_fixture example.com example.net
  export REMOTE_VERIFY_MODE=check
  run_remote example.com example.net
  [ "$status" -eq 0 ]
  [[ $output == *'prepare=0'* && $output == *'verify=65'* ]]
  [ ! -e "$REMOTE_FORBIDDEN" ]
}

@test "two locally signed lineages pass exact CA, key and SAN verification" {
  command -v openssl >/dev/null 2>&1 || skip 'OpenSSL required'
  make_test_ca
  common_archive
  lineage_archive example.com
  lineage_archive example.net
  sign_test_lineage example.com
  sign_test_lineage example.net
  put_fixture example.com example.net
  export REMOTE_VERIFY_MODE=check
  run_remote example.com example.net
  [ "$status" -eq 0 ]
  [[ $output == *'prepare=0'* && $output == *'verify=0'* ]]
  [ ! -e "$REMOTE_FORBIDDEN" ]
}

@test "valid certificates with a requested extra SAN fail the entire batch" {
  command -v openssl >/dev/null 2>&1 || skip 'OpenSSL required'
  make_test_ca
  common_archive
  lineage_archive example.com
  lineage_archive example.net
  sign_test_lineage example.com
  sign_test_lineage example.net
  put_fixture example.com example.net
  export REMOTE_VERIFY_MODE=wrong-san
  run_remote example.com example.net
  [ "$status" -eq 0 ]
  [[ $output == *'prepare=0'* && $output == *'verify=65'* ]]
  [ ! -e "$REMOTE_FORBIDDEN" ]
}

@test "incomplete requested verification set destroys the whole candidate" {
  common_archive
  lineage_archive example.com
  lineage_archive example.net
  put_fixture example.com example.net
  export REMOTE_VERIFY_MODE=wrong-count
  run_remote example.com example.net
  [ "$status" -eq 0 ]
  [[ $output == *'prepare=0'* && $output == *'verify=64'* ]]
  [ ! -e "$REMOTE_FORBIDDEN" ]
}

@test "ordinary product invocation remains blocked without network or Certbot" {
  run env PATH="$ASSEMBLY_BIN:$PATH" "$CERTBOTBOT_ARTIFACT" example.com
  [ "$status" -eq 69 ]
  [ ! -e "$REMOTE_FORBIDDEN" ]
  [ ! -e "$REMOTE_CALLS" ]
}
