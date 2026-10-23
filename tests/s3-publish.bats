#!/usr/bin/env bats

setup() {
  : "${BASH_STARTER_ARTIFACT:?Built artifact required}"
  ROOT="$(mktemp -d)"
  WORKSPACE="$ROOT/workspace"
  CONFIG="$WORKSPACE/config"
  SELECTED=example.com
  REMOTE="$ROOT/authoritative-object.tar.gz"
  mkdir -m 700 "$WORKSPACE" "$CONFIG"
  ACCOUNT="$CONFIG/accounts/acme-v02.api.letsencrypt.org/directory/account-id"
  mkdir -p "$ACCOUNT" "$CONFIG/archive/$SELECTED" \
    "$CONFIG/live/$SELECTED" "$CONFIG/renewal"
  printf '{"key":"existing"}\n' >"$ACCOUNT/private_key.json"
  printf '{"regr":"existing"}\n' >"$ACCOUNT/regr.json"
  printf '{"meta":"existing"}\n' >"$ACCOUNT/meta.json"
  chmod 600 "$ACCOUNT/"*.json
  local part
  for part in cert privkey chain fullchain; do
    printf 'existing-%s\n' "$part" >"$CONFIG/archive/$SELECTED/${part}1.pem"
    ln -s "../../archive/$SELECTED/${part}1.pem" \
      "$CONFIG/live/$SELECTED/$part.pem"
  done
  chmod 600 "$CONFIG/archive/$SELECTED/privkey1.pem"
  cat >"$CONFIG/renewal/$SELECTED.conf" <<'CONF'
version = 5.8.0
archive_dir = /etc/letsencrypt/archive/example.com
cert = /etc/letsencrypt/live/example.com/cert.pem
privkey = /etc/letsencrypt/live/example.com/privkey.pem
chain = /etc/letsencrypt/live/example.com/chain.pem
fullchain = /etc/letsencrypt/live/example.com/fullchain.pem
[renewalparams]
account = account-id
authenticator = dns-route53
server = https://acme-v02.api.letsencrypt.org/directory
CONF
  chmod 600 "$CONFIG/renewal/$SELECTED.conf"
  mkdir "$ROOT/bin"
  export S3_MOCK_LOG="$ROOT/s3-calls"
  export S3_MOCK_REMOTE="$REMOTE"
  export S3_MOCK_MODE=success
  printf 'old-authoritative-bytes\n' >"$REMOTE"
  cp "$REMOTE" "$ROOT/original-remote"
  cat >"$ROOT/bin/aws" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == --no-cli-pager ]] || exit 95
shift
[[ "$1" == s3api && "$2" == put-object ]] || exit 96
shift 2
{
  printf 'put-object'
  printf ' <%s>' "$@"
  printf '\n'
} >>"$S3_MOCK_LOG"
bucket='' key='' body='' checksum='' content_type=''
while (( $# > 0 )); do
  case "$1" in
    --bucket) bucket="$2"; shift 2 ;;
    --key) key="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --checksum-algorithm) checksum="$2"; shift 2 ;;
    --content-type) content_type="$2"; shift 2 ;;
    --output) [[ "$2" == json ]] || exit 97; shift 2 ;;
    *) exit 98 ;;
  esac
done
[[ "$bucket" == fixture-bucket && "$key" == latest.tar.gz ]] || exit 99
[[ "$checksum" == SHA256 && "$content_type" == application/gzip ]] || exit 99
[[ -f "$body" ]] || exit 99
case "$S3_MOCK_MODE" in
  success) cp -- "$body" "$S3_MOCK_REMOTE" ;;
  denied)
    printf 'ExpiredToken credential-redacted\n' >&2
    exit 254
    ;;
  uncertain)
    cp -- "$body" "$S3_MOCK_REMOTE"
    printf 'request timed out after remote write\n' >&2
    exit 254
    ;;
  *) exit 98 ;;
esac
printf '{"ETag":"not-a-checksum"}\n'
MOCK
  chmod 755 "$ROOT/bin/aws"
  PATH="$ROOT/bin:$PATH"
  export PATH
}

teardown() {
  rm -rf -- "$ROOT"
}

publish() {
  local changed="${1:-false}" override="${2:-false}"
  run bash -c '
    source "$1" --help >/dev/null
    certbotbot_s3_publish "$2" "$3" "$4" "$5" "$6" "$7"
    code=$?
    printf "published=%s\n" "$CERTBOTBOT_S3_PUBLISHED"
    exit "$code"
  ' _ "$BASH_STARTER_ARTIFACT" "$WORKSPACE" "$SELECTED" \
    fixture-bucket latest.tar.gz "$changed" "$override"
}

@test "unchanged successful no-op skips S3 and does not build candidate" {
  publish false false
  [ "$status" -eq 0 ]
  [ "$output" = published=false ]
  [ ! -e "$S3_MOCK_LOG" ]
  [ ! -e "$WORKSPACE/candidate.tar.gz" ]
  cmp "$REMOTE" "$ROOT/original-remote"
}

@test "actual durable change publishes the exact key without override" {
  publish true false
  [ "$status" -eq 0 ]
  [ "$output" = published=true ]
  [ "$(wc -l <"$S3_MOCK_LOG")" -eq 1 ]
  grep -Fq '<--bucket> <fixture-bucket> <--key> <latest.tar.gz>' \
    "$S3_MOCK_LOG"
  cmp "$WORKSPACE/candidate.tar.gz" "$REMOTE"
  [ "$(stat -c %a "$WORKSPACE/candidate.tar.gz")" = 600 ]
}

@test "forced unchanged no-op packages and uploads same object" {
  publish false true
  [ "$status" -eq 0 ]
  [ "$output" = published=true ]
  [ "$(wc -l <"$S3_MOCK_LOG")" -eq 1 ]
  grep -Fq '<--key> <latest.tar.gz>' "$S3_MOCK_LOG"
  cmp "$WORKSPACE/candidate.tar.gz" "$REMOTE"
}

@test "changed with override also performs exactly one PutObject" {
  publish true true
  [ "$status" -eq 0 ]
  [ "$output" = published=true ]
  [ "$(wc -l <"$S3_MOCK_LOG")" -eq 1 ]
  ! grep -Eq '(copy-object|create-bucket|delete-object)' "$S3_MOCK_LOG"
}

@test "candidate is a validated canonical account-and-lineage tar archive" {
  publish true false
  [ "$status" -eq 0 ]
  run bash -c '
    source "$1" --help >/dev/null
    certbotbot_archive_validate "$2"
  ' _ "$BASH_STARTER_ARTIFACT" "$REMOTE"
  [ "$status" -eq 0 ]
  local another="$ROOT/clean-runner"
  mkdir -m 700 "$another"
  run bash -c '
    source "$1" --help >/dev/null
    certbotbot_archive_restore "$2" "$3" &&
      certbotbot_state_preflight "$3/config" "$4"
  ' _ "$BASH_STARTER_ARTIFACT" "$REMOTE" "$another" "$SELECTED"
  [ "$status" -eq 0 ]
  cmp "$ACCOUNT/private_key.json" \
    "$another/config/accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json"
  [ "$(readlink "$another/config/live/example.com/cert.pem")" = \
    '../../archive/example.com/cert1.pem' ]
  cmp "$CONFIG/renewal/$SELECTED.conf" \
    "$another/config/renewal/$SELECTED.conf"
}

@test "invalid booleans never permit a remote write" {
  publish maybe false
  [ "$status" -eq 64 ]
  publish false yes
  [ "$status" -eq 64 ]
  [ ! -e "$S3_MOCK_LOG" ]
  cmp "$REMOTE" "$ROOT/original-remote"
}

@test "invalid bucket and key are rejected before any S3 call" {
  run bash -c '
    source "$1" --help >/dev/null
    certbotbot_s3_publish "$2" "$3" "$4" "$5" true false
  ' _ "$BASH_STARTER_ARTIFACT" "$WORKSPACE" "$SELECTED" \
    fixture-bucket '../another.tar.gz'
  [ "$status" -eq 64 ]
  run bash -c '
    source "$1" --help >/dev/null
    certbotbot_s3_publish "$2" "$3" "" latest.tar.gz true false
  ' _ "$BASH_STARTER_ARTIFACT" "$WORKSPACE" "$SELECTED"
  [ "$status" -eq 64 ]
  [ ! -e "$S3_MOCK_LOG" ]
}

@test "invalid source account forbids forced no-op upload" {
  rm "$ACCOUNT/private_key.json"
  publish false true
  [ "$status" -eq 65 ]
  [[ "$output" == *'published='* ]]
  [ ! -e "$S3_MOCK_LOG" ]
  cmp "$REMOTE" "$ROOT/original-remote"
}

@test "invalid source state cannot pass a skipped no-op" {
  rm "$ACCOUNT/regr.json"
  publish false false
  [ "$status" -eq 65 ]
  [ ! -e "$S3_MOCK_LOG" ]
}

@test "runner-local renewal paths prevent every upload" {
  sed -i "s|/etc/letsencrypt/|$CONFIG/|g" \
    "$CONFIG/renewal/$SELECTED.conf"
  publish true false
  [ "$status" -eq 65 ]
  [ ! -e "$S3_MOCK_LOG" ]
  [ ! -e "$WORKSPACE/candidate.tar.gz" ]
  cmp "$REMOTE" "$ROOT/original-remote"
}

@test "invalid packaging permissions never authorize PutObject" {
  chmod 644 "$CONFIG/archive/$SELECTED/privkey1.pem"
  publish false true
  [ "$status" -eq 65 ]
  [ ! -e "$S3_MOCK_LOG" ]
  cmp "$REMOTE" "$ROOT/original-remote"
}

@test "occupied candidate path blocks uploads instead of trusting it" {
  printf 'unverified-payload\n' >"$WORKSPACE/candidate.tar.gz"
  publish true false
  [ "$status" -eq 64 ]
  [ ! -e "$S3_MOCK_LOG" ]
  [ "$(cat "$WORKSPACE/candidate.tar.gz")" = unverified-payload ]
  cmp "$REMOTE" "$ROOT/original-remote"
}

@test "missing AWS client prevents mutation after local preflight" {
  mv "$ROOT/bin/aws" "$ROOT/bin/old-aws"
  local oldpath="$PATH"
  PATH="$ROOT/bin:/usr/bin:/bin"
  publish true false
  PATH="$oldpath"
  [ "$status" -eq 69 ]
  [ ! -e "$S3_MOCK_LOG" ]
  cmp "$REMOTE" "$ROOT/original-remote"
}

@test "denied PutObject never reports publication success" {
  export S3_MOCK_MODE=denied
  publish true false
  [ "$status" -eq 74 ]
  [[ "$output" == *'published='* ]]
  [[ "$output" != *'ExpiredToken'* ]]
  [[ "$output" != *'credential-redacted'* ]]
  [ "$(wc -l <"$S3_MOCK_LOG")" -eq 1 ]
  cmp "$REMOTE" "$ROOT/original-remote"
}

@test "uncertain PutObject failure never asserts remote bytes remain unchanged" {
  export S3_MOCK_MODE=uncertain
  publish true false
  [ "$status" -eq 74 ]
  [[ "$output" == *'published='* ]]
  [ "$(wc -l <"$S3_MOCK_LOG")" -eq 1 ]
  ! cmp -s "$REMOTE" "$ROOT/original-remote"
}

@test "private workspace must be canonical, owned and mode 0700" {
  chmod 755 "$WORKSPACE"
  publish true false
  [ "$status" -eq 64 ]
  chmod 700 "$WORKSPACE"
  ln -s "$WORKSPACE" "$ROOT/alias"
  WORKSPACE="$ROOT/alias"
  publish true false
  [ "$status" -eq 64 ]
  [ ! -e "$S3_MOCK_LOG" ]
}

@test "public lifecycle is still fail-closed until integration" {
  publish true false
  [ "$status" -eq 0 ]
  run "$BASH_STARTER_ARTIFACT" --s3-bucket fixture-bucket example.com
  [ "$status" -eq 69 ]
}
