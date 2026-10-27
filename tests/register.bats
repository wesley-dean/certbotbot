#!/usr/bin/env bats

## @file tests/register.bats
## @brief Mock-only acceptance of explicit registration boundaries in task #58.
## @details
## These tests use real tar/gzip and the selected standalone producer artifact.
## They never contact S3, Route53 or Let's Encrypt; task #59 adds the broader
## clean-runner black-box and failure-isolation matrix.

setup() {
  : "${BASH_STARTER_ARTIFACT:?built producer artifact required}"
  ROOT="$(mktemp -d)"
  mkdir -m 700 "$ROOT/bin" "$ROOT/temp"
  export MOCK_REMOTE="$ROOT/remote.tar.gz"
  export MOCK_CALLS="$ROOT/calls"
  export MOCK_MODE=normal
  export PATH="$ROOT/bin:$PATH"
  cat >"$ROOT/bin/aws" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == --no-cli-pager ]] && shift
[[ "$1" == s3api ]] || exit 91
shift
action="$1"
shift
printf 'aws:%s %s\n' "$action" "$*" >>"$MOCK_CALLS"
case "$action" in
  head-object)
    if [[ "$MOCK_MODE" == denied ]]; then
      printf '%s\n' 'An error occurred (403)' >&2
      exit 255
    fi
    if [[ ! -f "$MOCK_REMOTE" ]]; then
      printf '%s\n' 'An error occurred (404)' >&2
      exit 255
    fi
    printf '%s\n' '"0123456789abcdef0123456789abcdef"'
    ;;
  head-bucket) exit 0 ;;
  get-object)
    [[ "$*" == *'--if-match'* ]] || exit 90
    cp -- "$MOCK_REMOTE" "${@: -1}"
    ;;
  put-object)
    case "$MOCK_MODE" in
      put-failure) exit 255 ;;
    esac
    if [[ -f "$MOCK_REMOTE" ]]; then
      [[ "$*" == *'--if-match'* ]] || exit 90
    else
      [[ "$*" == *'--if-none-match'* ]] || exit 90
    fi
    body=''
    while (( $# > 0 )); do
      case "$1" in
        --body) body="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [[ -n "$body" ]] || exit 91
    cp -- "$body" "$MOCK_REMOTE"
    ;;
  *) exit 91 ;;
esac
MOCK
  cat >"$ROOT/bin/certbot" <<'MOCK'
#!/usr/bin/env bash
printf 'certbot:%s\n' "$*" >>"$MOCK_CALLS"
action=''
config=''
email=''
server=''
args=("$@")
for ((i=0;i<${#args[@]};i++)); do
  case "${args[i]}" in
    register|show_account) action="${args[i]}" ;;
    --config-dir) config="${args[i+1]}" ;;
    --email) email="${args[i+1]}" ;;
    --server) server="${args[i+1]}" ;;
  esac
done
case "$server" in
  https://acme-v02.api.letsencrypt.org/directory)
    host=acme-v02.api.letsencrypt.org ;;
  https://acme-staging-v02.api.letsencrypt.org/directory)
    host=acme-staging-v02.api.letsencrypt.org ;;
  *) exit 93 ;;
esac
case "$action" in
  register)
    [[ "$*" == *--non-interactive* && "$*" == *--agree-tos* ]] || exit 90
    [[ "$MOCK_MODE" != certbot-failure ]] || exit 3
    account="$config/accounts/$host/directory/account-id"
    mkdir -p -- "$account"
    chmod 700 "$config/accounts" "$config/accounts/$host" \
      "$config/accounts/$host/directory" "$account"
    printf '%s\n' '{"kty":"RSA","private":"mock-only"}' \
      >"$account/private_key.json"
    printf '{"body":{"contact":["mailto:%s"],"status":"valid"}}\n' "$email" \
      >"$account/regr.json"
    printf '%s\n' '{"creation_dt":"mock-only"}' >"$account/meta.json"
    chmod 600 "$account/"*.json
    ;;
  show_account)
    [[ -d "$config/accounts/$host/directory/account-id" ]] && exit 0
    exit 1
    ;;
  *) exit 99 ;;
esac
MOCK
  chmod 755 "$ROOT/bin/aws" "$ROOT/bin/certbot"
}

teardown() {
  rm -rf -- "$ROOT"
}

register() {
  run env TMPDIR="$ROOT/temp" "$BASH_STARTER_ARTIFACT" register \
    --s3-bucket example-bucket --email person@example.org "$@"
}

@test "register help has no network or certificate operation" {
  run "$BASH_STARTER_ARTIFACT" register --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--agree-tos"* ]]
  [ ! -e "$MOCK_CALLS" ]
}

@test "TOS false by default blocks registration before S3" {
  register
  [ "$status" -eq 64 ]
  [[ "$output" == *"explicit terms agreement"* ]]
  [ ! -e "$MOCK_CALLS" ]
}

@test "explicit registration creates a validated account-only archive" {
  register --agree-tos true
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  [ -s "$MOCK_REMOTE" ]
  tar -tzf "$MOCK_REMOTE" | grep -Fq 'accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json'
  grep -Fq -- '--eff-email' "$MOCK_CALLS"
  ! grep -Fq -- '--no-eff-email' "$MOCK_CALLS"
  grep -Fq -- '--if-none-match' "$MOCK_CALLS"
  ! grep -Eq 'certbot:.*(certonly|renew)' "$MOCK_CALLS"
}

@test "operator may opt out of EFF signup" {
  register --agree-tos true --eff-email-signup false
  [ "$status" -eq 0 ]
  grep -Fq -- '--no-eff-email' "$MOCK_CALLS"
}

@test "staging account remains in staging-specific archive path" {
  register --agree-tos true --acme-environment staging
  [ "$status" -eq 0 ]
  tar -tzf "$MOCK_REMOTE" | grep -Fq \
    'accounts/acme-staging-v02.api.letsencrypt.org/directory/account-id/'
  ! tar -tzf "$MOCK_REMOTE" | grep -Fq \
    'accounts/acme-v02.api.letsencrypt.org/directory/account-id/'
}

@test "existing matching account is reused without Certbot register or S3 PUT" {
  register --agree-tos true
  [ "$status" -eq 0 ]
  cp "$MOCK_REMOTE" "$ROOT/before"
  : >"$MOCK_CALLS"
  register --agree-tos true
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=false"* ]]
  cmp -s "$ROOT/before" "$MOCK_REMOTE"
  ! grep -Fq 'certbot:register' "$MOCK_CALLS"
  ! grep -Fq 'aws:put-object' "$MOCK_CALLS"
  grep -Fq 'certbot:--config-dir' "$MOCK_CALLS"
}

@test "foreign CA account is rejected without replacing existing archive" {
  register --agree-tos true
  [ "$status" -eq 0 ]
  cp "$MOCK_REMOTE" "$ROOT/before"
  : >"$MOCK_CALLS"
  register --agree-tos true --acme-environment staging
  [ "$status" -eq 65 ]
  cmp -s "$MOCK_REMOTE" "$ROOT/before"
  ! grep -Fq 'aws:put-object' "$MOCK_CALLS"
  ! grep -Fq 'certbot:register' "$MOCK_CALLS"
}

@test "failed registration never attempts publication" {
  export MOCK_MODE=certbot-failure
  register --agree-tos true
  [ "$status" -eq 74 ]
  [ ! -e "$MOCK_REMOTE" ]
  ! grep -Fq 'aws:put-object' "$MOCK_CALLS"
}

@test "failed S3 publication is not reported as success" {
  export MOCK_MODE=put-failure
  register --agree-tos true
  [ "$status" -eq 74 ]
  [[ "$output" == *"remote state uncertain"* ]]
  [ ! -e "$MOCK_REMOTE" ]
}

@test "inaccessible S3 object is not mistaken for missing state" {
  export MOCK_MODE=denied
  register --agree-tos true
  [ "$status" -eq 69 ]
  ! grep -Fq 'certbot:register' "$MOCK_CALLS"
  ! grep -Fq 'aws:put-object' "$MOCK_CALLS"
}

@test "ordinary issuer cannot register when the archive is absent" {
  run env TMPDIR="$ROOT/temp" "$BASH_STARTER_ARTIFACT" \
    --s3-bucket example-bucket example.com
  [ "$status" -eq 66 ]
  ! grep -Fq 'certbot:register' "$MOCK_CALLS"
  ! grep -Fq 'aws:put-object' "$MOCK_CALLS"
}

@test "malformed contact and unsupported CA fail before cloud operations" {
  register --agree-tos true --email invalid
  [ "$status" -eq 64 ]
  register --agree-tos true --acme-environment another-ca
  [ "$status" -eq 64 ]
  [ ! -e "$MOCK_CALLS" ]
}
