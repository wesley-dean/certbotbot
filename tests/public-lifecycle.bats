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
  export LIFECYCLE_CONTEXTS="$ROOT/certbot-contexts"
  export LIFECYCLE_MODE=ok
  export LIFECYCLE_EXPECTED_KEY=latest.tar.gz
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
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
    case "$LIFECYCLE_MODE" in
      head-failure) exit 9 ;;
      head-denied)
        printf '%s\n' 'An error occurred (403), private-token-DO-NOT-LOG' >&2
        exit 9
        ;;
      head-service)
        printf '%s\n' 'An error occurred (500)' >&2
        exit 9
        ;;
      head-transport)
        printf '%s\n' 'Connect timeout on endpoint URL' >&2
        exit 9
        ;;
      head-ambiguous-missing)
        printf '%s\n' 'An error occurred (404)' >&2
        exit 9
        ;;
    esac
    [[ -f "$LIFECYCLE_REMOTE" ]] || { printf '(404)\n' >&2; exit 1; }
    ;;
  get-object)
    case "$LIFECYCLE_MODE" in
      get-failure) exit 9 ;;
      get-partial)
        printf '%s\n' 'incomplete local download' >"$target"
        exit 9
        ;;
      get-empty)
        : >"$target"
        exit 0
        ;;
      get-corrupt)
        printf '%s\n' 'corrupt gzip data, not an archive' >"$target"
        exit 0
        ;;
    esac
    cp "$LIFECYCLE_REMOTE" "$target" || exit 9
    ;;
  put-object)
    # Permit a successful local Certbot operation with an independent remote
    # failure, including acceptance followed by a lost response.
    put_mode="${LIFECYCLE_PUT_MODE:-$LIFECYCLE_MODE}"
    if [[ "$put_mode" == put-failure ]]; then
      printf '%s\n' 'AWS failure mock-private-PUT-TOKEN' >&2
      exit 9
    fi
    cp "$body" "$LIFECYCLE_REMOTE" || exit 9
    # A lost response cannot prove whether S3 accepted the put.
    if [[ "$put_mode" == put-after-write-failure ]]; then
      printf '%s\n' 'AWS lost-response mock-private-PUT-TOKEN' >&2
      exit 9
    fi
    exit 0
    ;;
  head-bucket)
    [[ "$LIFECYCLE_MODE" == head-ambiguous-missing ]] && exit 9
    exit 0
    ;;
  *) exit 99 ;;
esac
MOCK
  cat >"$ROOT/bin/certbot" <<'MOCK'
#!/usr/bin/env bash
verb="$1"
shift
printf 'certbot:%s\n' "$verb" >>"$LIFECYCLE_CALLS"
config='' work='' logs='' name='' account='' reconcile=false
sanext=''
while (( $# )); do
  case "$1" in
    --config-dir) config="$2"; shift 2 ;;
    --work-dir) work="$2"; shift 2 ;;
    --logs-dir) logs="$2"; shift 2 ;;
    --cert-name) name="$2"; shift 2 ;;
    --account) account="$2"; shift 2 ;;
    -d) sanext+="${sanext:+,}DNS:$2"; shift 2 ;;
    --renew-with-new-domains) reconcile=true; shift ;;
    *) shift ;;
  esac
done
printf 'certbot-context:%s:%s:%s:%s:%s:%s\n' \
  "$verb" "$config" "$work" "$logs" "$name" "$account" \
  >>"$LIFECYCLE_CONTEXTS"
printf 'certbot-sans:%s:%s\n' "$verb" "$sanext" \
  >>"$LIFECYCLE_CONTEXTS"
if [[ "$reconcile" == true ]]; then
  printf 'certbot-reconcile:%s\n' "$name" >>"$LIFECYCLE_CONTEXTS"
fi
case "$verb" in
  plugins) printf '* dns-route53\n' ;;
  show_account) [[ "$account" == account-id ]] || exit 91 ;;
  certonly)
    [[ "$LIFECYCLE_MODE" == certbot-failure ]] && exit 9
    [[ "$account" == account-id &&
      "$name" == "$LIFECYCLE_EXPECTED_CERT_NAME" ]] || exit 91
    mkdir -p "$config/archive/$name" "$config/live/$name" "$config/renewal"
    [[ -n "$sanext" ]] || exit 92
    if [[ "$reconcile" == true ]]; then
      # Reconciliation reuses the original lineage key and path links.
      [[ -f "$config/archive/$name/privkey1.pem" ]] || exit 92
      openssl req -x509 -new -days 4 -subj '/CN=example.com' \
        -key "$config/archive/$name/privkey1.pem" \
        -addext "subjectAltName=$sanext" \
        -out "$config/archive/$name/cert1.pem" >/dev/null 2>&1 || exit 92
    else
      openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
        -subj '/CN=example.com' -addext "subjectAltName=$sanext" \
        -keyout "$config/archive/$name/privkey1.pem" \
        -out "$config/archive/$name/cert1.pem" >/dev/null 2>&1 || exit 92
      chmod 600 "$config/archive/$name/privkey1.pem"
    fi
    cp "$config/archive/$name/cert1.pem" "$config/archive/$name/chain1.pem"
    cp "$config/archive/$name/cert1.pem" "$config/archive/$name/fullchain1.pem"
    if [[ "$LIFECYCLE_MODE" == bad-fullchain ]]; then
      printf '%s\n' 'not a certificate' >"$config/archive/$name/fullchain1.pem"
    fi
    if [[ "$reconcile" != true ]]; then
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
    fi
    ;;
  renew)
    [[ "$LIFECYCLE_MODE" == certbot-failure ]] && exit 9
    if [[ "$LIFECYCLE_MODE" == renew-partial-failure ]]; then
      printf '%s\n' '{"meta":"interrupted"}' \
        >"$config/accounts/acme-v02.api.letsencrypt.org/directory/account-id/meta.json"
      exit 9
    elif [[ "$LIFECYCLE_MODE" == renew-bad-leaf ]]; then
      openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
        -subj '/CN=example.com' \
        -addext 'subjectAltName=DNS:example.com,DNS:*.example.com' \
        -keyout "$work/unpublished-key.pem" \
        -out "$config/archive/$name/cert1.pem" >/dev/null 2>&1 || exit 93
      cp "$config/archive/$name/cert1.pem" \
        "$config/archive/$name/fullchain1.pem"
      cp "$config/archive/$name/cert1.pem" \
        "$config/archive/$name/chain1.pem"
    elif [[ "$LIFECYCLE_MODE" == renew-bad-chain ]]; then
      printf '%s\n' 'invalid PEM chain' \
        >"$config/archive/$name/chain1.pem"
    elif [[ "$LIFECYCLE_MODE" == renew-unsafe-metadata ]]; then
      printf '%s\n' 'renew_hook = /bin/true' \
        >>"$config/renewal/$name.conf"
    elif [[ "$LIFECYCLE_MODE" == metadata-changed ]]; then
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
  local runner="${LIFECYCLE_RUNNER_TMPDIR:-$ROOT/runner-temp}"
  run env TMPDIR="$runner" "$BASH_STARTER_ARTIFACT" \
    --s3-bucket fixture-bucket "$@" example.com
}

execute_domain() {
  local domain="$1" runner="${LIFECYCLE_RUNNER_TMPDIR:-$ROOT/runner-temp}"
  shift
  run env TMPDIR="$runner" "$BASH_STARTER_ARTIFACT" \
    --s3-bucket fixture-bucket "$@" "$domain"
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

@test "three separate runners preserve original account and selected lineage" {
  mkdir -m 700 "$ROOT/runner-a" "$ROOT/runner-b" "$ROOT/runner-c"

  # Runner A starts only from the seeded existing account-only S3 archive.
  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/runner-a"
  execute
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
  first="$(grep '^certbot-context:certonly:' "$LIFECYCLE_CONTEXTS")"
  IFS=: read -r marker verb first_config first_work first_logs \
    first_name first_account <<< "$first"
  [ "$marker" = certbot-context ]
  [ "$verb" = certonly ]
  [ "$first_name" = example.com ]
  [ "$first_account" = account-id ]
  [[ "$first_config" == "$ROOT/runner-a/"* ]]
  [[ "$first_work" == "$ROOT/runner-a/"* ]]
  [[ "$first_logs" == "$ROOT/runner-a/"* ]]
  [ -z "$(find "$ROOT/runner-a" -mindepth 1 -print -quit)" ]

  # Runner B has a distinct temporary root and no state from runner A.
  cp "$LIFECYCLE_REMOTE" "$ROOT/first-published.tar.gz"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/runner-b"
  execute
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=false"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$ROOT/first-published.tar.gz" "$LIFECYCLE_REMOTE"
  second="$(grep '^certbot-context:renew:' "$LIFECYCLE_CONTEXTS")"
  IFS=: read -r marker verb second_config second_work second_logs \
    second_name second_account <<< "$second"
  [ "$second_name" = "$first_name" ]
  [ "$second_account" = "$first_account" ]
  [[ "$second_config" == "$ROOT/runner-b/"* ]]
  [[ "$second_work" == "$ROOT/runner-b/"* ]]
  [[ "$second_logs" == "$ROOT/runner-b/"* ]]
  [ "$second_config" != "$first_config" ]
  [ "$second_work" != "$first_work" ]
  [ "$second_logs" != "$first_logs" ]
  [ -z "$(find "$ROOT/runner-b" -mindepth 1 -print -quit)" ]

  # Runner C renews only the restored selected lineage and persists it.
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/runner-c"
  export LIFECYCLE_MODE=renew-changed
  execute
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
  third="$(grep '^certbot-context:renew:' "$LIFECYCLE_CONTEXTS" | tail -n 1)"
  IFS=: read -r marker verb third_config third_work third_logs \
    third_name third_account <<< "$third"
  [ "$third_name" = "$first_name" ]
  [ "$third_account" = "$first_account" ]
  [[ "$third_config" == "$ROOT/runner-c/"* ]]
  [[ "$third_work" == "$ROOT/runner-c/"* ]]
  [[ "$third_logs" == "$ROOT/runner-c/"* ]]
  [ "$third_config" != "$second_config" ]
  [ "$third_work" != "$second_work" ]
  [ "$third_logs" != "$second_logs" ]
  [ -z "$(find "$ROOT/runner-c" -mindepth 1 -print -quit)" ]

  # Persisted state remains canonical and retains the original account.
  mkdir -m 700 "$ROOT/inspected"
  tar -xzf "$LIFECYCLE_REMOTE" -C "$ROOT/inspected"
  cmp -s "$ROOT/seed/accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json" \
    "$ROOT/inspected/accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json"
  [ "$(readlink "$ROOT/inspected/live/example.com/cert.pem")" = \
    "../../archive/example.com/cert1.pem" ]
  grep -Fq 'archive_dir = /etc/letsencrypt/archive/example.com' \
    "$ROOT/inspected/renewal/example.com.conf"
  grep -Fq 'account = account-id' \
    "$ROOT/inspected/renewal/example.com.conf"
  ! grep -Fq "$ROOT/runner-a" "$ROOT/inspected/renewal/example.com.conf"
  ! grep -Fq "$ROOT/runner-b" "$ROOT/inspected/renewal/example.com.conf"
  ! grep -Fq "$ROOT/runner-c" "$ROOT/inspected/renewal/example.com.conf"
  ! cmp -s "$ROOT/first-published.tar.gz" "$LIFECYCLE_REMOTE"
}

# Local checks intentionally inspect the mock's authoritative object and calls.
# They do not infer safety solely from a nonzero process exit.
assert_failed_fetch_is_nondestructive() {
  [ -f "$LIFECYCLE_CALLS" ]
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/remote-before.tar.gz"
  [ -z "$(find "$ROOT/runner-temp" -mindepth 1 -print -quit)" ]
  [[ "$output" != *"published=true"* ]]
}

@test "missing S3 key is fatal for both apex and wildcard selections" {
  rm -f "$LIFECYCLE_REMOTE"
  for domain in example.com '*.example.com'; do
    : >"$LIFECYCLE_CALLS"
    execute_domain "$domain"
    [ "$status" -eq 66 ]
    [[ "$output" == *"existing S3 archive was not found"* ]]
    [ "$(grep -c '^aws:head-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
    [ "$(grep -c '^aws:head-bucket:' "$LIFECYCLE_CALLS")" -eq 1 ]
    ! grep -q '^aws:get-object:' "$LIFECYCLE_CALLS"
    ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
    ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
    [ -z "$(find "$ROOT/runner-temp" -mindepth 1 -print -quit)" ]
  done
}

@test "ambiguous HeadObject 404 plus failing HeadBucket is never missing state" {
  cp "$LIFECYCLE_REMOTE" "$ROOT/remote-before.tar.gz"
  export LIFECYCLE_MODE=head-ambiguous-missing
  execute
  [ "$status" -eq 69 ]
  [[ "$output" == *"S3 object cannot be inspected safely"* ]]
  [ "$(grep -c '^aws:head-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:head-bucket:' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^aws:get-object:' "$LIFECYCLE_CALLS"
  assert_failed_fetch_is_nondestructive
}

@test "S3 permission denial, service error and transport failure do not bootstrap" {
  local scenario
  cp "$LIFECYCLE_REMOTE" "$ROOT/remote-before.tar.gz"
  for scenario in head-denied head-service head-transport; do
    : >"$LIFECYCLE_CALLS"
    export LIFECYCLE_MODE="$scenario"
    execute
    [ "$status" -eq 69 ]
    [[ "$output" == *"S3 object cannot be inspected safely"* ]]
    [[ "$output" != *"private-token-DO-NOT-LOG"* ]]
    [[ "$output" != *"Connect timeout on endpoint URL"* ]]
    [ "$(grep -c '^aws:head-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
    ! grep -q '^aws:head-bucket:' "$LIFECYCLE_CALLS"
    ! grep -q '^aws:get-object:' "$LIFECYCLE_CALLS"
    assert_failed_fetch_is_nondestructive
  done
}

@test "partial and zero-byte GetObject downloads never activate staged state" {
  local scenario
  cp "$LIFECYCLE_REMOTE" "$ROOT/remote-before.tar.gz"
  for scenario in get-partial get-empty; do
    : >"$LIFECYCLE_CALLS"
    export LIFECYCLE_MODE="$scenario"
    execute
    [ "$status" -eq 74 ]
    [[ "$output" == *"S3 archive"* ]]
    [ "$(grep -c '^aws:head-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
    [ "$(grep -c '^aws:get-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
    assert_failed_fetch_is_nondestructive
  done
}

@test "successful GetObject returning corrupted gzip is rejected before Certbot" {
  cp "$LIFECYCLE_REMOTE" "$ROOT/remote-before.tar.gz"
  export LIFECYCLE_MODE=get-corrupt
  execute
  [ "$status" -ne 0 ]
  [ "$(grep -c '^aws:get-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
  assert_failed_fetch_is_nondestructive
}

@test "missing seeded ACME account key cannot trigger new registration or issuance" {
  rm -f "$ROOT/seed/accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json"
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/seed" .
  cp "$LIFECYCLE_REMOTE" "$ROOT/remote-before.tar.gz"
  execute
  [ "$status" -ne 0 ]
  [ "$(grep -c '^aws:get-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
  assert_failed_fetch_is_nondestructive
}

@test "archive with incompatible staging account fails without selecting local identity" {
  mv "$ROOT/seed/accounts/acme-v02.api.letsencrypt.org" \
    "$ROOT/seed/accounts/acme-staging-v02.api.letsencrypt.org"
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/seed" .
  cp "$LIFECYCLE_REMOTE" "$ROOT/remote-before.tar.gz"
  execute
  [ "$status" -ne 0 ]
  [ "$(grep -c '^aws:get-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
  assert_failed_fetch_is_nondestructive
}

@test "foreign renewal lineage in existing archive fails before invoking Certbot" {
  execute
  [ "$status" -eq 0 ]
  : >"$LIFECYCLE_CALLS"
  mkdir -m 700 "$ROOT/altered-state"
  tar -xzf "$LIFECYCLE_REMOTE" -C "$ROOT/altered-state"
  mv "$ROOT/altered-state/renewal/example.com.conf" \
    "$ROOT/altered-state/renewal/foreign.example.com.conf"
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/altered-state" .
  cp "$LIFECYCLE_REMOTE" "$ROOT/remote-before.tar.gz"
  execute
  [ "$status" -ne 0 ]
  [ "$(grep -c '^aws:get-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
  assert_failed_fetch_is_nondestructive
}

@test "valid seeded archive allows wildcard input without creating another lineage" {
  execute_domain '*.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
  tar -tzf "$LIFECYCLE_REMOTE" | grep -Fq './renewal/example.com.conf'
  ! tar -tzf "$LIFECYCLE_REMOTE" |
    grep -Fq './renewal/*.example.com.conf'
}

@test "public success and failure diagnostics never echo ACME or AWS secret fixtures" {
  local marker='fixture-acme-private-CANNOT-LOG'
  printf '{"seed":"%s"}\n' "$marker" \
    >"$ROOT/seed/accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json"
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/seed" .

  execute
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  [[ "$output" != *"$marker"* ]]
  [[ "$output" != *'-----BEGIN PRIVATE KEY-----'* ]]

  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_MODE=head-denied
  execute
  [ "$status" -eq 69 ]
  [[ "$output" != *"$marker"* ]]
  [[ "$output" != *'private-token-DO-NOT-LOG'* ]]
  [[ "$output" != *'-----BEGIN PRIVATE KEY-----'* ]]
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"

  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_MODE=certbot-failure
  execute
  [ "$status" -ne 0 ]
  [[ "$output" != *"$marker"* ]]
  [[ "$output" != *'-----BEGIN PRIVATE KEY-----'* ]]
  [[ "$output" != *'published=true'* ]]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
}

# The mock remote SHA-256 proves local failure preservation, not AWS atomicity.
snapshot_remote_sha256() {
  REMOTE_BASELINE="$(sha256sum -- "$LIFECYCLE_REMOTE" | cut -d ' ' -f1)"
  [ -n "$REMOTE_BASELINE" ]
}
assert_remote_sha256_unchanged() {
  [ "$(sha256sum -- "$LIFECYCLE_REMOTE" | cut -d ' ' -f1)" = "$REMOTE_BASELINE" ]
}
assert_remote_sha256_changed() {
  [ "$(sha256sum -- "$LIFECYCLE_REMOTE" | cut -d ' ' -f1)" != "$REMOTE_BASELINE" ]
}
prepare_known_good_remote() {
  execute
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"published=true"* ]] || return 1
  tar -tzf "$LIFECYCLE_REMOTE" |
    grep -Fq './renewal/example.com.conf' || return 1
  snapshot_remote_sha256
  : >"$LIFECYCLE_CALLS"
}
assert_no_publication_after_failure() {
  [ "$status" -ne 0 ]
  [[ "$output" != *"published=true"* ]]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  assert_remote_sha256_unchanged
  [ -z "$(find "$ROOT/runner-temp" -mindepth 1 -print -quit)" ]
}

@test "partial failing renewal cannot replace the last known-good S3 archive" {
  prepare_known_good_remote
  export LIFECYCLE_MODE=renew-partial-failure
  execute
  [ "$status" -eq 74 ]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  assert_no_publication_after_failure
}

@test "successful Certbot with mismatched private key cannot publish" {
  prepare_known_good_remote
  export LIFECYCLE_MODE=renew-bad-leaf
  execute
  [ "$status" -ne 0 ]
  [[ "$output" == *"certificate and private key verification failed"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  assert_no_publication_after_failure
}

@test "successful Certbot with invalid fullchain cannot publish" {
  prepare_known_good_remote
  export LIFECYCLE_MODE=renew-bad-chain
  execute
  [ "$status" -ne 0 ]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  assert_no_publication_after_failure
}

@test "unsafe metadata written during renewal cannot be published" {
  prepare_known_good_remote
  export LIFECYCLE_MODE=renew-unsafe-metadata
  execute
  [ "$status" -ne 0 ]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  assert_no_publication_after_failure
}

@test "failed candidate compression after renewal preserves known-good S3" {
  prepare_known_good_remote
  export LIFECYCLE_MODE=metadata-changed
  cat >"$ROOT/bin/tar" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == --format=ustar ]]; then exit 27; fi
exec /usr/bin/tar "$@"
MOCK
  chmod 755 "$ROOT/bin/tar"
  execute
  [ "$status" -ne 0 ]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  assert_no_publication_after_failure
}

@test "invalid candidate from successful tar command is never published" {
  prepare_known_good_remote
  export LIFECYCLE_MODE=metadata-changed
  cat >"$ROOT/bin/tar" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == --format=ustar ]]; then
  printf 'not a tar archive'
  exit 0
fi
exec /usr/bin/tar "$@"
MOCK
  chmod 755 "$ROOT/bin/tar"
  execute
  [ "$status" -ne 0 ]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  assert_no_publication_after_failure
}

@test "verified no-op does not write or change the remote object digest" {
  prepare_known_good_remote
  execute
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=false"* ]]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  assert_remote_sha256_unchanged
}

@test "rejected forced PutObject preserves old digest but reports uncertainty" {
  prepare_known_good_remote
  export UPLOAD_NO_RENEWAL=true
  export LIFECYCLE_PUT_MODE=put-failure
  execute
  [ "$status" -eq 74 ]
  [[ "$output" == *"remote state is uncertain"* ]]
  [[ "$output" != *"published=true"* ]]
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
  assert_remote_sha256_unchanged
}

@test "lost successful PutObject reply cannot promise remote preservation" {
  prepare_known_good_remote
  export LIFECYCLE_MODE=metadata-changed
  export LIFECYCLE_PUT_MODE=put-after-write-failure
  execute
  [ "$status" -eq 74 ]
  [[ "$output" == *"remote state is uncertain"* ]]
  [[ "$output" != *"published=true"* ]]
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
  assert_remote_sha256_changed
}

@test "successful metadata publication changes the one selected S3 digest" {
  prepare_known_good_remote
  export LIFECYCLE_MODE=metadata-changed
  execute
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  assert_remote_sha256_changed
}

@test "explicit lineage name survives selected issuance and a restored renewal" {
  export LIFECYCLE_EXPECTED_CERT_NAME=issued.example.com
  execute --cert-name issued.example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"issued issued.example.com"* ]]
  [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
  tar -tzf "$LIFECYCLE_REMOTE" | grep -Fq \
    "./renewal/issued.example.com.conf"
  tar -xOf "$LIFECYCLE_REMOTE" ./renewal/issued.example.com.conf |
    grep -Fq "archive_dir = /etc/letsencrypt/archive/issued.example.com"
  ! tar -tzf "$LIFECYCLE_REMOTE" | grep -Fq "./renewal/example.com.conf"
  : >"$LIFECYCLE_CALLS"
  execute --cert-name issued.example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"checked issued.example.com"* ]]
  [[ "$output" == *"published=false"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
}

@test "conflicting stored explicit lineage refuses silent reissue or rename" {
  export LIFECYCLE_EXPECTED_CERT_NAME=issued.example.com
  execute --cert-name issued.example.com
  [ "$status" -eq 0 ]
  cp "$LIFECYCLE_REMOTE" "$ROOT/before-conflict.tar.gz"
  : >"$LIFECYCLE_CALLS"
  execute --cert-name different.example.com
  [ "$status" -eq 65 ]
  [[ "$output" != *"published=true"* ]]
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before-conflict.tar.gz"
  [ -z "$(find "$ROOT/runner-temp" -mindepth 1 -print -quit)" ]
}

# Reset to the same operator-seeded, existing account-only remote object.
# Each subsequent public call must choose a lineage without host state.
reset_seeded_remote() {
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/seed" .
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
}

@test "apex and wildcard public inputs choose the same shortest lineage" {
  local primary
  for primary in example.com '*.example.com'; do
    reset_seeded_remote
    execute_domain "$primary"
    [ "$status" -eq 0 ]
    [[ "$output" == *"issued example.com"* ]]
    [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
    [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
      "$LIFECYCLE_CALLS")" -eq 1 ]
    tar -tzf "$LIFECYCLE_REMOTE" |
      grep -Fxq './renewal/example.com.conf'
    ! tar -tzf "$LIFECYCLE_REMOTE" |
      grep -Fq './renewal/*.example.com.conf'
    [ "$(grep -c '^certbot-sans:certonly:' \
      "$LIFECYCLE_CONTEXTS")" -eq 1 ]
  done
}

@test "CLI overrides exported and literal env-file CERT_NAME on public issue" {
  printf '%s\n' 'CERT_NAME=file.example.com' >"$ROOT/names.env"
  export CERT_NAME=env.example.com
  export LIFECYCLE_EXPECTED_CERT_NAME=cli.example.com
  execute --config "$ROOT/names.env" --cert-name=cli.example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"issued cli.example.com"* ]]
  tar -tzf "$LIFECYCLE_REMOTE" |
    grep -Fxq './renewal/cli.example.com.conf'
  grep -Fq ':cli.example.com:account-id' "$LIFECYCLE_CONTEXTS"
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
}

@test "exported CERT_NAME overrides literal env-file name on public issue" {
  printf '%s\n' 'CERT_NAME=file.example.com' >"$ROOT/names.env"
  export CERT_NAME=env.example.com
  export LIFECYCLE_EXPECTED_CERT_NAME=env.example.com
  execute --config "$ROOT/names.env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"issued env.example.com"* ]]
  tar -tzf "$LIFECYCLE_REMOTE" |
    grep -Fxq './renewal/env.example.com.conf'
  grep -Fq ':env.example.com:account-id' "$LIFECYCLE_CONTEXTS"
}

@test "literal env-file name overrides shortest-SAN default on public issue" {
  printf '%s\n' 'CERT_NAME=file.example.com' >"$ROOT/names.env"
  export LIFECYCLE_EXPECTED_CERT_NAME=file.example.com
  execute --config "$ROOT/names.env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"issued file.example.com"* ]]
  tar -tzf "$LIFECYCLE_REMOTE" |
    grep -Fxq './renewal/file.example.com.conf'
  grep -Fq ':file.example.com:account-id' "$LIFECYCLE_CONTEXTS"
}

@test "invalid explicit and derived names fail before any cloud access" {
  local name
  for name in '*.example.com' 'UPPER.example.com' \
    '.example.com' 'example.com.' '../unsafe' 'x y.example.com'; do
    : >"$LIFECYCLE_CALLS"
    execute --cert-name "$name"
    [ "$status" -eq 64 ]
    [[ "$output" != *"published=true"* ]]
    ! grep -q '^aws:' "$LIFECYCLE_CALLS"
    ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
  done
  : >"$LIFECYCLE_CALLS"
  execute_domain '*.example.com' --include-subdomains=false
  [ "$status" -eq 64 ]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
}

@test "explicit safe name permits a wildcard-only SAN without renaming archive" {
  export LIFECYCLE_EXPECTED_CERT_NAME=issued.example.com
  execute_domain '*.example.com' --include-subdomains=false \
    --cert-name issued.example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"issued issued.example.com"* ]]
  grep -Fxq 'certbot-sans:certonly:DNS:*.example.com' \
    "$LIFECYCLE_CONTEXTS"
  tar -tzf "$LIFECYCLE_REMOTE" |
    grep -Fxq './renewal/issued.example.com.conf'
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
}

@test "same lineage survives both public SAN-policy transitions" {
  execute --include-subdomains=false --cert-name example.com
  [ "$status" -eq 0 ]
  grep -Fxq 'certbot-sans:certonly:DNS:example.com' \
    "$LIFECYCLE_CONTEXTS"
  tar -xOf "$LIFECYCLE_REMOTE" \
    ./accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json \
    >"$ROOT/first-account"
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"

  execute --include-subdomains=true --cert-name example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
  grep -Fxq 'certbot-reconcile:example.com' "$LIFECYCLE_CONTEXTS"
  grep -Fxq 'certbot-sans:certonly:DNS:example.com,DNS:*.example.com' \
    "$LIFECYCLE_CONTEXTS"
  tar -tzf "$LIFECYCLE_REMOTE" |
    grep -Fxq './renewal/example.com.conf'
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"

  execute --include-subdomains=false --cert-name example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  grep -Fxq 'certbot-reconcile:example.com' "$LIFECYCLE_CONTEXTS"
  grep -Fxq 'certbot-sans:certonly:DNS:example.com' \
    "$LIFECYCLE_CONTEXTS"
  : >"$LIFECYCLE_CALLS"
  execute --include-subdomains=false --cert-name example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=false"* ]]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  tar -xOf "$LIFECYCLE_REMOTE" \
    ./accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json \
    >"$ROOT/final-account"
  cmp -s "$ROOT/first-account" "$ROOT/final-account"
  [ "$(tar -tzf "$LIFECYCLE_REMOTE" |
    grep -c '^./renewal/[^/]*\.conf$')" -eq 1 ]
}

@test "independent runners keep selected explicit name and account with no writes" {
  mkdir -m 700 "$ROOT/name-runner-a" "$ROOT/name-runner-b"
  export LIFECYCLE_EXPECTED_CERT_NAME=stable.example.com
  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/name-runner-a"
  execute --cert-name stable.example.com
  [ "$status" -eq 0 ]
  cp "$LIFECYCLE_REMOTE" "$ROOT/first-archive"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/name-runner-b"
  execute --cert-name stable.example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"checked stable.example.com"* ]]
  [[ "$output" == *"published=false"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/first-archive"
  [ -z "$(find "$ROOT/name-runner-a" -mindepth 1 -print -quit)" ]
  [ -z "$(find "$ROOT/name-runner-b" -mindepth 1 -print -quit)" ]
}

@test "an extra archived lineage cannot cause numbering or another S3 object" {
  export LIFECYCLE_EXPECTED_CERT_NAME=issued.example.com
  execute --cert-name issued.example.com
  [ "$status" -eq 0 ]
  mkdir -m 700 "$ROOT/extra-lineage"
  tar -xzf "$LIFECYCLE_REMOTE" -C "$ROOT/extra-lineage"
  cp "$ROOT/extra-lineage/renewal/issued.example.com.conf" \
    "$ROOT/extra-lineage/renewal/issued.example.com-0001.conf"
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/extra-lineage" .
  cp "$LIFECYCLE_REMOTE" "$ROOT/before-extra"
  : >"$LIFECYCLE_CALLS"
  execute --cert-name issued.example.com
  [ "$status" -ne 0 ]
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before-extra"
}

@test "equal-length ASCII tie is invariant to candidate order in each artifact" {
  run bash -c '
    source "$1" --help >/dev/null || exit $?
    certbotbot_identity_shortest beta.example.com alfa.example.com || exit $?
    first="$REPLY"
    certbotbot_identity_shortest alfa.example.com beta.example.com || exit $?
    printf "%s|%s" "$first" "$REPLY"
  ' _ "$BASH_STARTER_ARTIFACT"
  [ "$status" -eq 0 ]
  [ "$output" = 'alfa.example.com|alfa.example.com' ]
}

@test "CLI forced unchanged republish uses the same custom key on a new runner" {
  mkdir -m 700 "$ROOT/force-runner-a" "$ROOT/force-runner-b"
  export LIFECYCLE_EXPECTED_KEY=custom-state.tar.gz
  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/force-runner-a"
  execute --s3-key custom-state.tar.gz
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  tar -xOf "$LIFECYCLE_REMOTE" \
    ./accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json \
    >"$ROOT/force-account-before.json"
  : >"$LIFECYCLE_CALLS"

  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/force-runner-b"
  execute --s3-key custom-state.tar.gz --upload-no-renewal=true
  [ "$status" -eq 0 ]
  [[ "$output" == *"checked example.com"* ]]
  [[ "$output" == *"s3://fixture-bucket/custom-state.tar.gz"* ]]
  [[ "$output" == *"published=true"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
  [ "$(grep -c '^aws:head-object:fixture-bucket:custom-state.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:get-object:fixture-bucket:custom-state.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:put-object:fixture-bucket:custom-state.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:' "$LIFECYCLE_CALLS")" -eq 3 ]
  tar -tzf "$LIFECYCLE_REMOTE" |
    grep -Fxq './renewal/example.com.conf'
  tar -xOf "$LIFECYCLE_REMOTE" ./renewal/example.com.conf |
    grep -Fq 'archive_dir = /etc/letsencrypt/archive/example.com'
  tar -xOf "$LIFECYCLE_REMOTE" \
    ./accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json \
    >"$ROOT/force-account-after.json"
  cmp -s "$ROOT/force-account-before.json" "$ROOT/force-account-after.json"
  [ -z "$(find "$ROOT/force-runner-a" -mindepth 1 -print -quit)" ]
  [ -z "$(find "$ROOT/force-runner-b" -mindepth 1 -print -quit)" ]
}

@test "metadata-only change uploads despite explicit no-renewal override false" {
  execute
  [ "$status" -eq 0 ]
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_MODE=metadata-changed
  execute --upload-no-renewal=false
  [ "$status" -eq 0 ]
  [[ "$output" == *"checked example.com"* ]]
  [[ "$output" == *"published=true"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(tar -xOf "$LIFECYCLE_REMOTE" \
    ./accounts/acme-v02.api.letsencrypt.org/directory/account-id/meta.json)" = \
    '{"meta":"renewed"}' ]
}

@test "forcing publication after failing renewal never overwrites S3 state" {
  execute
  [ "$status" -eq 0 ]
  cp "$LIFECYCLE_REMOTE" "$ROOT/force-before-failure.tar.gz"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_MODE=certbot-failure
  execute --upload-no-renewal=true
  [ "$status" -eq 74 ]
  [[ "$output" != *"published=true"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/force-before-failure.tar.gz"
  [ -z "$(find "$ROOT/runner-temp" -mindepth 1 -print -quit)" ]
}

@test "forcing publication cannot bypass invalid first-issue certificate" {
  cp "$LIFECYCLE_REMOTE" "$ROOT/force-before-invalid.tar.gz"
  export LIFECYCLE_MODE=bad-fullchain
  execute --upload-no-renewal=true
  [ "$status" -ne 0 ]
  [[ "$output" != *"published=true"* ]]
  [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/force-before-invalid.tar.gz"
  [ -z "$(find "$ROOT/runner-temp" -mindepth 1 -print -quit)" ]
}
