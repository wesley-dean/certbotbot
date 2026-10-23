#!/usr/bin/env bats

setup() {
  : "${BASH_STARTER_ARTIFACT:?Built artifact required}"
  ROOT="$(mktemp -d)"
  mkdir -m 700 "$ROOT/bin" "$ROOT/seed"
  mkdir -p "$ROOT/seed/accounts/acme-v02.api.letsencrypt.org/directory/account-id"
  printf '{"seed":"private"}\n' > "$ROOT/seed/accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json"
  printf '{"seed":"reg"}\n' > "$ROOT/seed/accounts/acme-v02.api.letsencrypt.org/directory/account-id/regr.json"
  printf '{"seed":"meta"}\n' > "$ROOT/seed/accounts/acme-v02.api.letsencrypt.org/directory/account-id/meta.json"
  chmod 600 "$ROOT/seed/accounts/acme-v02.api.letsencrypt.org/directory/account-id/"*.json
  tar -czf "$ROOT/remote.tar.gz" -C "$ROOT/seed" .
  export LIFECYCLE_REMOTE="$ROOT/remote.tar.gz"
  export LIFECYCLE_CALLS="$ROOT/calls"
  export LIFECYCLE_MODE=ok
  export LIFECYCLE_EXPECTED_KEY=latest.tar.gz
  mkdir -m 700 "$ROOT/runner-temp"
  cat >"$ROOT/bin/aws" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == --no-cli-pager && "$2" == s3api ]] || exit 99
action="$3"
shift 3
bucket='' key='' body='' target=''
while (( $# )); do
  case "$1" in
    --bucket) bucket="$2"; shift 2 ;;
    --key) key="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --checksum-algorithm|--content-type|--output) shift 2 ;;
    *) target="$1"; shift ;;
  esac
done
printf 'aws:%s:%s:%s\n' "$action" "$bucket" "$key" >>"$LIFECYCLE_CALLS"
[[ "$bucket" == fixture-bucket ]] || exit 99
# HeadBucket is bucket-scoped and must not carry an object key.
[[ "$action" == head-bucket || "$key" == "$LIFECYCLE_EXPECTED_KEY" ]] || exit 99
case "$action" in
  head-object)
    [[ "$LIFECYCLE_MODE" == head-failure ]] && exit 9
    [[ -f "$LIFECYCLE_REMOTE" ]] || { printf '(404)\n' >&2; exit 1; }
    ;;
  get-object)
    [[ "$LIFECYCLE_MODE" == get-failure ]] && exit 9
    cp "$LIFECYCLE_REMOTE" "$target" || exit 9
    ;;
  put-object)
    [[ "$LIFECYCLE_MODE" == put-failure ]] && exit 9
    cp "$body" "$LIFECYCLE_REMOTE" || exit 9
    # A lost response cannot prove whether S3 accepted the put.
    [[ "$LIFECYCLE_MODE" == put-after-write-failure ]] && exit 9
    exit 0
    ;;
  head-bucket) : ;;
  *) exit 99 ;;
esac
MOCK
  cat >"$ROOT/bin/certbot" <<'MOCK'
#!/usr/bin/env bash
verb="$1"
shift
printf 'certbot:%s\n' "$verb" >>"$LIFECYCLE_CALLS"
config='' name='' account='' 
while (( $# )); do
  case "$1" in
    --config-dir) config="$2"; shift 2 ;;
    --cert-name) name="$2"; shift 2 ;;
    --account) account="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$verb" in
  plugins) printf '* dns-route53\n' ;;
  show_account) [[ "$account" == account-id ]] || exit 91 ;;
  certonly)
    [[ "$LIFECYCLE_MODE" == certbot-failure ]] && exit 9
    [[ "$account" == account-id && "$name" == example.com ]] || exit 91
    mkdir -p "$config/archive/$name" "$config/live/$name" "$config/renewal"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj '/CN=example.com' \
      -addext 'subjectAltName=DNS:example.com,DNS:*.example.com' \
      -keyout "$config/archive/$name/privkey1.pem" \
      -out "$config/archive/$name/cert1.pem" >/dev/null 2>&1 || exit 92
    chmod 600 "$config/archive/$name/privkey1.pem"
    cp "$config/archive/$name/cert1.pem" "$config/archive/$name/chain1.pem"
    cp "$config/archive/$name/cert1.pem" "$config/archive/$name/fullchain1.pem"
    if [[ "$LIFECYCLE_MODE" == bad-fullchain ]]; then
      printf '%s\n' 'not a certificate' >"$config/archive/$name/fullchain1.pem"
    fi
    for part in cert chain fullchain privkey; do
      ln -s "../../archive/$name/${part}1.pem" "$config/live/$name/$part.pem"
    done
    cat >"$config/renewal/$name.conf" <<EOF
version = 5.8.0
archive_dir = $config/archive/$name
cert = $config/live/$name/cert.pem
privkey = $config/live/$name/privkey.pem
chain = $config/live/$name/chain.pem
fullchain = $config/live/$name/fullchain.pem
[renewalparams]
account = account-id
authenticator = dns-route53
server = https://acme-v02.api.letsencrypt.org/directory
EOF
    chmod 600 "$config/renewal/$name.conf"
    ;;
  renew)
    [[ "$LIFECYCLE_MODE" == certbot-failure ]] && exit 9
    if [[ "$LIFECYCLE_MODE" == metadata-changed ]]; then
      printf '%s\n' '{"meta":"renewed"}' \
        >"$config/accounts/acme-v02.api.letsencrypt.org/directory/account-id/meta.json"
    elif [[ "$LIFECYCLE_MODE" == renew-changed ]]; then
      openssl req -x509 -new \
        -key "$config/archive/$name/privkey1.pem" \
        -days 4 -subj '/CN=example.com' \
        -addext 'subjectAltName=DNS:example.com,DNS:*.example.com' \
        -out "$config/archive/$name/cert1.pem" >/dev/null 2>&1 || exit 93
      cp "$config/archive/$name/cert1.pem" \
        "$config/archive/$name/chain1.pem"
      cp "$config/archive/$name/cert1.pem" \
        "$config/archive/$name/fullchain1.pem"
    fi
    exit 0
    ;;
  *) exit 98 ;;
esac
MOCK
  chmod 755 "$ROOT/bin/"*
  export PATH="$ROOT/bin:$PATH"
  unset DOMAIN S3_BUCKET S3_KEY CERT_NAME
  export UPLOAD_NO_RENEWAL=false INCLUDE_SUBDOMAINS=true
}

teardown() {
  rm -rf -- "$ROOT"
}

execute() {
  run env TMPDIR="$ROOT/runner-temp" "$BASH_STARTER_ARTIFACT" \
    --s3-bucket fixture-bucket "$@" example.com
}

@test "seeded first issuance publishes one same-key archive" {
  execute
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
  tar -tzf "$LIFECYCLE_REMOTE" | grep -Fq './renewal/example.com.conf'
  tar -xOf "$LIFECYCLE_REMOTE" ./renewal/example.com.conf |
    grep -Fq 'archive_dir = /etc/letsencrypt/archive/example.com'
}

@test "new independent run restores and checks existing lineage without upload" {
  execute
  [ "$status" -eq 0 ]
  cp "$LIFECYCLE_REMOTE" "$ROOT/snapshot.tar.gz"
  : >"$LIFECYCLE_CALLS"
  execute
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=false"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/snapshot.tar.gz"
}

@test "forced no-renewal republish is a single same-key put" {
  execute
  [ "$status" -eq 0 ]
  : >"$LIFECYCLE_CALLS"
  export UPLOAD_NO_RENEWAL=true
  execute
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
}

@test "missing seeded remote object never calls Certbot or PutObject" {
  rm -f "$LIFECYCLE_REMOTE"
  execute
  [ "$status" -eq 66 ]
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
}

@test "failed issuer cannot publish or claim success" {
  export LIFECYCLE_MODE=certbot-failure
  cp "$LIFECYCLE_REMOTE" "$ROOT/snapshot.tar.gz"
  execute
  [ "$status" -ne 0 ]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/snapshot.tar.gz"
}

@test "failed upload reports failure and never claims publication" {
  export LIFECYCLE_MODE=put-failure
  execute
  [ "$status" -ne 0 ]
  [[ "$output" != *"published=true"* ]]
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
}

@test "unreadable or missing archive never invokes the provider" {
  export LIFECYCLE_MODE=get-failure
  execute
  [ "$status" -ne 0 ]
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
}

@test "changed renewal republishes the same lineage and original account" {
  execute
  [ "$status" -eq 0 ]
  tar -xOf "$LIFECYCLE_REMOTE" ./archive/example.com/cert1.pem \
    >"$ROOT/old-leaf.pem"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_MODE=renew-changed
  execute
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
  tar -xOf "$LIFECYCLE_REMOTE" ./archive/example.com/cert1.pem \
    >"$ROOT/new-leaf.pem"
  ! cmp -s "$ROOT/old-leaf.pem" "$ROOT/new-leaf.pem"
  tar -xOf "$LIFECYCLE_REMOTE" \
    ./accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json \
    >"$ROOT/restored-account.json"
  cmp -s "$ROOT/restored-account.json" \
    "$ROOT/seed/accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_MODE=ok
  execute
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=false"* ]]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
}

@test "account-only durable metadata change publishes without reissuing leaf" {
  execute
  [ "$status" -eq 0 ]
  tar -xOf "$LIFECYCLE_REMOTE" ./archive/example.com/cert1.pem \
    >"$ROOT/old-leaf.pem"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_MODE=metadata-changed
  execute
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
  tar -xOf "$LIFECYCLE_REMOTE" ./archive/example.com/cert1.pem \
    >"$ROOT/new-leaf.pem"
  cmp -s "$ROOT/old-leaf.pem" "$ROOT/new-leaf.pem"
  [ "$(tar -xOf "$LIFECYCLE_REMOTE" \
    ./accounts/acme-v02.api.letsencrypt.org/directory/account-id/meta.json)" = \
    '{"meta":"renewed"}' ]
}

@test "explicit archive key is used unchanged for head get and put" {
  export LIFECYCLE_EXPECTED_KEY=custom-state.tar.gz
  execute --s3-key custom-state.tar.gz
  [ "$status" -eq 0 ]
  [[ "$output" == *"s3://fixture-bucket/custom-state.tar.gz"* ]]
  [ "$(grep -c '^aws:head-object:fixture-bucket:custom-state.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:get-object:fixture-bucket:custom-state.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:put-object:fixture-bucket:custom-state.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:' "$LIFECYCLE_CALLS")" -eq 3 ]
}

@test "corrupt downloaded archive is never passed to Certbot or publisher" {
  printf '%s\n' 'corrupted remote bytes' >"$LIFECYCLE_REMOTE"
  cp "$LIFECYCLE_REMOTE" "$ROOT/before"
  execute
  [ "$status" -ne 0 ]
  [[ "$output" != *"published=true"* ]]
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before"
}

@test "bad issued fullchain never replaces the seeded S3 object" {
  cp "$LIFECYCLE_REMOTE" "$ROOT/before"
  export LIFECYCLE_MODE=bad-fullchain
  execute
  [ "$status" -ne 0 ]
  [[ "$output" != *"published=true"* ]]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before"
}

@test "local tar serialization failure prevents any S3 put" {
  cp "$LIFECYCLE_REMOTE" "$ROOT/before"
  cat >"$ROOT/bin/tar" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == --format=ustar ]]; then exit 27; fi
exec /usr/bin/tar "$@"
MOCK
  chmod 755 "$ROOT/bin/tar"
  execute
  [ "$status" -ne 0 ]
  [[ "$output" != *"published=true"* ]]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before"
}

@test "pre-acceptance PutObject failure preserves old bytes in mock" {
  cp "$LIFECYCLE_REMOTE" "$ROOT/before"
  export LIFECYCLE_MODE=put-failure
  execute
  [ "$status" -eq 74 ]
  [[ "$output" != *"published=true"* ]]
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before"
}

@test "a failed PutObject after remote acceptance has uncertain remote status" {
  cp "$LIFECYCLE_REMOTE" "$ROOT/before"
  export LIFECYCLE_MODE=put-after-write-failure
  execute
  [ "$status" -eq 74 ]
  [[ "$output" == *"remote state is uncertain"* ]]
  [[ "$output" != *"published=true"* ]]
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before"
}

@test "invocation workspaces are destroyed after success and local failure" {
  execute
  [ "$status" -eq 0 ]
  [ -z "$(find "$ROOT/runner-temp" -mindepth 1 -print -quit)" ]
  export LIFECYCLE_MODE=certbot-failure
  : >"$LIFECYCLE_CALLS"
  execute
  [ "$status" -ne 0 ]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  [ -z "$(find "$ROOT/runner-temp" -mindepth 1 -print -quit)" ]
}
