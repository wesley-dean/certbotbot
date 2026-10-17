#!/usr/bin/env bats

## @file tests/remote-state-preflight.bats
## @brief Exercises S3-to-archive assessment and fail-closed cleanup.
## @details
## Uses local synthetic tar archives and a PATH-injected AWS GetObject fake.
## Nothing here establishes a registered ACME account or certificate trust.

setup() {
  : "${CERTBOTBOT_ARTIFACT:?A standalone artifact is required}"
  export CERTBOTBOT_TMPDIR="$BATS_TEST_TMPDIR/producer"
  export PREFLIGHT_STORE="$BATS_TEST_TMPDIR/store"
  export PREFLIGHT_BIN="$BATS_TEST_TMPDIR/bin"
  export PREFLIGHT_CALLS="$BATS_TEST_TMPDIR/calls"
  export PREFLIGHT_MODE=normal
  umask 077
  mkdir -m 0700 "$CERTBOTBOT_TMPDIR" "$PREFLIGHT_STORE" "$PREFLIGHT_BIN"
  cat >"$PREFLIGHT_BIN/aws" <<'AWS'
#!/usr/bin/env bash
set -eu
if [[ ${1:-} == --endpoint-url ]]; then
  shift 2
fi
[[ ${1:-} == s3api && ${2:-} == get-object ]] || exit 97
shift 2
bucket='' key='' dest=''
while (( $# > 0 )); do
  case "$1" in
    --bucket) bucket=$2; shift 2 ;;
    --key) key=$2; shift 2 ;;
    *) dest=$1; shift ;;
  esac
done
[[ "$bucket" == valid-bucket && -n "$key" && "$dest" == /* ]] || exit 98
printf '%s\n' "$key" >>"$PREFLIGHT_CALLS"
case "${PREFLIGHT_MODE:-normal}" in
  denied)
    printf 'An error occurred (AccessDenied) when calling the GetObject operation: Denied\n' >&2
    exit 254
    ;;
  timeout)
    printf 'Connection failed\n' >&2
    exit 255
    ;;
esac
if [[ ! -f "$PREFLIGHT_STORE/$key" ]]; then
  printf 'An error occurred (NoSuchKey) when calling the GetObject operation: Missing\n' >&2
  exit 254
fi
cp -- "$PREFLIGHT_STORE/$key" "$dest"
AWS
  chmod 0700 "$PREFLIGHT_BIN/aws"
}

make_common() {
  local base="$BATS_TEST_TMPDIR/source/common"
  local account=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  local path="$base/accounts/acme-v02.api.letsencrypt.org/directory/$account"
  mkdir -p "$path"
  chmod 0700 "$base/accounts" \
    "$base/accounts/acme-v02.api.letsencrypt.org" \
    "$base/accounts/acme-v02.api.letsencrypt.org/directory" "$path"
  local file
  for file in meta regr private_key; do
    printf '{"fixture":"%s"}\n' "$file" >"$path/$file.json"
    chmod 0600 "$path/$file.json"
  done
  tar -czf "$PREFLIGHT_STORE/common-latest.tar.gz" -C "$base" accounts
}

make_domain() {
  local name=$1 root="$BATS_TEST_TMPDIR/source/$1" kind
  mkdir -p "$root/archive/$name" "$root/live/$name" \
    "$root/renewal" "$root/combined"
  for kind in cert chain fullchain privkey; do
    printf '%s fixture\n' "$kind" >"$root/archive/$name/${kind}1.pem"
    ln -s "../../archive/$name/${kind}1.pem" \
      "$root/live/$name/$kind.pem"
  done
  printf 'combined fixture\n' >"$root/combined/$name.pem"
  cp "$root/combined/$name.pem" "$root/live/$name/combined.pem"
  chmod 0600 "$root/archive/$name/privkey1.pem" \
    "$root/combined/$name.pem" "$root/live/$name/combined.pem"
  cat >"$root/renewal/$name.conf" <<RENEWAL
version = 5.8.0
archive_dir = /other-producer/config/archive/$name
cert = /other-producer/config/live/$name/cert.pem
privkey = /other-producer/config/live/$name/privkey.pem
chain = /other-producer/config/live/$name/chain.pem
fullchain = /other-producer/config/live/$name/fullchain.pem

[renewalparams]
account = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
server = https://acme-v02.api.letsencrypt.org/directory
authenticator = dns-route53
key_type = ecdsa
RENEWAL
  pack_domain "$name"
}

pack_domain() {
  local name=$1 root="$BATS_TEST_TMPDIR/source/$1"
  tar -czf "$PREFLIGHT_STORE/$name-latest.tar.gz" \
    -C "$root" archive live renewal combined
}

run_remote() {
  local environment=$1
  shift
  run env PATH="$PREFLIGHT_BIN:$PATH" \
    PREFLIGHT_MODE="$PREFLIGHT_MODE" \
    ACME_ENVIRONMENT="$environment" bash -c '
      source "$1" --version >/dev/null
      certbotbot_workspace_create || exit 98
      certbotbot_state_assess_remote valid-bucket "${@:2}"
      result=$?
      printf "result=%s\n" "$result"
      for name in "${CERTBOTBOT_STATE_MISSING_NAMES[@]}"; do
        printf "missing=%s\n" "$name"
      done
      [[ -z "$CERTBOTBOT_S3_STAGE_ROOT" &&
        -z "$CERTBOTBOT_COMMON_STAGE" &&
        -z "$CERTBOTBOT_RESTORE_ROOT" &&
        -z "$CERTBOTBOT_RENEWAL_PREVIEW" ]] || exit 97
      [[ -z "$(find "$CERTBOTBOT_WORKSPACE_CONFIG" \
        -mindepth 1 -print -quit)" ]] || exit 96
      [[ -z "$(find "$CERTBOTBOT_WORKSPACE_ROOT" -mindepth 1 \
        -maxdepth 1 ! -name config ! -name work ! -name logs \
        -print -quit)" ]] || exit 95
      certbotbot_workspace_destroy || exit 94
    ' _ "$CERTBOTBOT_ARTIFACT" "$@"
}

@test "two S3 lineages are completely assessed and discarded" {
  make_common
  make_domain example.com
  make_domain example.net
  run_remote production example.com example.net
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=0'* && "$output" != *'missing='* ]]
  [ "$(wc -l <"$PREFLIGHT_CALLS")" -eq 3 ]
}

@test "valid common archive with only new domains is still verified" {
  make_common
  run_remote production example.com example.net
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=0'* &&
    "$output" == *'missing=example.com'* &&
    "$output" == *'missing=example.net'* ]]
}

@test "valid common and mixed domain presence reports missing names in order" {
  make_common
  make_domain example.net
  run_remote production example.com example.net
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=0'* && "$output" == *'missing=example.com'* ]]
  [[ "$output" != *'missing=example.net'* ]]
}

@test "fully empty storage returns typed missing but never registers" {
  run_remote production example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=10'* && "$output" != *'missing='* ]]
}

@test "a malformed common archive rejects even new lineages" {
  printf 'untrusted bytes\n' >"$PREFLIGHT_STORE/common-latest.tar.gz"
  run_remote production example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=64'* && "$output" != *'missing='* ]]
}

@test "a malformed later domain fails the whole batch" {
  make_common
  make_domain example.com
  printf 'malformed tar\n' >"$PREFLIGHT_STORE/example.net-latest.tar.gz"
  run_remote production example.com example.net
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=64'* && "$output" != *'missing='* ]]
}

@test "unsupported persisted hook is rejected before any active import" {
  make_common
  make_domain example.com
  printf 'deploy_hook = /bin/sh\n' \
    >>"$BATS_TEST_TMPDIR/source/example.com/renewal/example.com.conf"
  pack_domain example.com
  run_remote production example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=64'* ]]
}

@test "account authority mismatch is rejected and download discarded" {
  make_common
  make_domain example.com
  sed -i \
    's@https://acme-v02.api.letsencrypt.org/directory@https://acme-staging-v02.api.letsencrypt.org/directory@' \
    "$BATS_TEST_TMPDIR/source/example.com/renewal/example.com.conf"
  pack_domain example.com
  run_remote production example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=65'* ]]
}

@test "missing common with present domain is never first registration" {
  make_domain example.com
  run_remote production example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=65'* ]]
}

@test "remote authorization failure cannot become a missing archive" {
  PREFLIGHT_MODE=denied
  run_remote production example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=69'* ]]
}

@test "staging cannot accidentally accept production-only objects" {
  make_common
  make_domain example.com
  run_remote staging example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=10'* ]]
  grep -Fxq staging/common-latest.tar.gz "$PREFLIGHT_CALLS"
  ! grep -Fxq common-latest.tar.gz "$PREFLIGHT_CALLS"
}

@test "bad request and duplicate lineages make no S3 calls" {
  make_common
  run_remote production example.com example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=64'* ]]
  [ ! -e "$PREFLIGHT_CALLS" ]
}

@test "active configuration marker survives a refused retrieval" {
  make_common
  make_domain example.com
  run env PATH="$PREFLIGHT_BIN:$PATH" bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    printf "original\n" >"$CERTBOTBOT_WORKSPACE_CONFIG/.marker"
    certbotbot_state_assess_remote valid-bucket example.com
    result=$?
    [[ $result -eq 64 &&
      "$(cat "$CERTBOTBOT_WORKSPACE_CONFIG/.marker")" == original ]] ||
      exit 1
    [[ -z "$CERTBOTBOT_S3_STAGE_ROOT" ]] || exit 1
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT"
  [ "$status" -eq 0 ]
  [ ! -e "$PREFLIGHT_CALLS" ]
}

@test "issuer still fails explicitly rather than using downloaded state" {
  run "$CERTBOTBOT_ARTIFACT" example.com
  [ "$status" -eq 69 ]
}
