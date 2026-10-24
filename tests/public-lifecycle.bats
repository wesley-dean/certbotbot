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
if [[ -n "${GPG_SYMMETRIC_KEY+x}" ||
  -n "${CERTBOTBOT_GPG_SECRET+x}" ]]; then
  printf '%s\n' 'aws:secret-inherited' >>"$LIFECYCLE_CALLS"
  exit 97
fi
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
if [[ -n "${GPG_SYMMETRIC_KEY+x}" ||
  -n "${CERTBOTBOT_GPG_SECRET+x}" ]]; then
  printf '%s\n' 'certbot:secret-inherited' >>"$LIFECYCLE_CALLS"
  exit 97
fi
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
    # Simulate a provider that succeeds but issues a different SAN set.
    if [[ "$LIFECYCLE_MODE" == reconcile-wrong-sans &&
      "$reconcile" == true ]]; then
      sanext='DNS:example.com,DNS:unrequested.other.net'
    fi
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
      # Preserve previously issued unrelated SANs on simulated due renewal.
      prior_sans="$(openssl x509 -in "$config/archive/$name/cert1.pem" \
        -noout -ext subjectAltName 2>/dev/null)" || exit 93
      prior_sans="${prior_sans#*$'\n'}"
      [[ -n "$prior_sans" && "$prior_sans" != *$'\n'* ]] || exit 93
      openssl req -x509 -new \
        -key "$config/archive/$name/privkey1.pem" \
        -days 4 -subj '/CN=example.com' \
        -addext "subjectAltName=$prior_sans" \
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
  unset DOMAIN S3_BUCKET S3_KEY S3_KEY_TEMPLATE BACKUP_KEY_TEMPLATE
  unset CERT_NAME ADDITIONAL_SANS
  unset GPG_SYMMETRIC_KEY CERTBOTBOT_GPG_SECRET ARCHIVE_ENCRYPTION
  unset ARCHIVE_MIGRATION ARCHIVE_MIGRATION_BACKUP_CONFIRMED
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

# Inspect issued leaf bytes from the same mock S3 object with the shipped,
# strict SAN comparator in each artifact flavor; no account key is disclosed.
assert_remote_sans() {
  tar -xOf "$LIFECYCLE_REMOTE" ./archive/example.com/cert1.pem \
    >"$ROOT/selected-leaf.pem" || return 1
  bash -c '
    source "$1" --help >/dev/null || exit $?
    shift
    certbotbot_renew_sans_match "$@"
  ' _ "$BASH_STARTER_ARTIFACT" "$ROOT/selected-leaf.pem" "$@"
}

assert_no_certbot_or_put() {
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS" 2>/dev/null &&
    ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS" 2>/dev/null
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

@test "distinct explicit names issue independent lineages and retain the original" {
  export LIFECYCLE_EXPECTED_CERT_NAME=issued.example.com
  execute --cert-name issued.example.com
  [ "$status" -eq 0 ]
  tar -xOf "$LIFECYCLE_REMOTE" ./archive/issued.example.com/cert1.pem \
    >"$ROOT/first-explicit-cert.pem"
  tar -xOf "$LIFECYCLE_REMOTE" ./renewal/issued.example.com.conf \
    >"$ROOT/first-explicit-renewal.conf"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_EXPECTED_CERT_NAME=different.example.com
  execute --cert-name different.example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"issued different.example.com"* &&
    "$output" == *"published=true"* ]]
  [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
  tar -tzf "$LIFECYCLE_REMOTE" | grep -Fxq './renewal/issued.example.com.conf'
  tar -tzf "$LIFECYCLE_REMOTE" | grep -Fxq './renewal/different.example.com.conf'
  ! tar -tzf "$LIFECYCLE_REMOTE" | grep -Fq './renewal/different.example.com-0001.conf'
  tar -xOf "$LIFECYCLE_REMOTE" ./archive/issued.example.com/cert1.pem |
    cmp -s - "$ROOT/first-explicit-cert.pem"
  tar -xOf "$LIFECYCLE_REMOTE" ./renewal/issued.example.com.conf |
    cmp -s - "$ROOT/first-explicit-renewal.conf"
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

# Each matrix test starts with one valid account-only archive, issues once,
# and checks the next invocation against the single known-good remote object.
prepare_override_existing() {
  execute
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"published=true"* ]] || return 1
  cp "$LIFECYCLE_REMOTE" "$ROOT/override-baseline.tar.gz"
  : >"$LIFECYCLE_CALLS"
}

reset_override_existing() {
  cp "$ROOT/override-baseline.tar.gz" "$LIFECYCLE_REMOTE"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_MODE=ok
  unset LIFECYCLE_PUT_MODE
}

assert_override_one_key() {
  local expected="$1" put_count="$2"
  [ "$(grep -Fxc "aws:head-object:fixture-bucket:$expected" \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -Fxc "aws:get-object:fixture-bucket:$expected" \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -Fxc "aws:put-object:fixture-bucket:$expected" \
    "$LIFECYCLE_CALLS" || true)" -eq "$put_count" ]
  [ "$(grep -c '^aws:' "$LIFECYCLE_CALLS")" -eq "$((2 + put_count))" ]
}

@test "each release artifact has a current valid SHA-256 companion" {
  local parent name
  parent="$(dirname "$BASH_STARTER_ARTIFACT")"
  name="$(basename "$BASH_STARTER_ARTIFACT")"
  [ -s "$BASH_STARTER_ARTIFACT.sha256" ]
  [ ! -e "$BASH_STARTER_ARTIFACT.256" ]
  run bash -c 'cd "$1" && sha256sum -c -- "$2.sha256"' \
    _ "$parent" "$name"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$name: OK"* ]]
}

@test "first issuance publishes for either override Boolean" {
  local flag
  for flag in false true; do
    tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/seed" .
    : >"$LIFECYCLE_CALLS"
    execute --upload-no-renewal="$flag"
    [ "$status" -eq 0 ]
    [[ "$output" == *"issued example.com"* ]]
    [[ "$output" == *"published=true"* ]]
    [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
    ! grep -q '^certbot:renew$' "$LIFECYCLE_CALLS"
    assert_override_one_key latest.tar.gz 1
    tar -tzf "$LIFECYCLE_REMOTE" |
      grep -Fxq './renewal/example.com.conf'
  done
}

@test "default unchanged selected renewal skips upload and preserves bytes" {
  prepare_override_existing
  execute
  [ "$status" -eq 0 ]
  [[ "$output" == *"checked example.com"* ]]
  [[ "$output" == *"published=false"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
  assert_override_one_key latest.tar.gz 0
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/override-baseline.tar.gz"
}

@test "CLI true overrides exported and literal false to republish once" {
  prepare_override_existing
  printf '%s\n' 'UPLOAD_NO_RENEWAL=false' >"$ROOT/override.env"
  export UPLOAD_NO_RENEWAL=false
  execute --config "$ROOT/override.env" --upload-no-renewal=true
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
  assert_override_one_key latest.tar.gz 1
  tar -tzf "$LIFECYCLE_REMOTE" |
    grep -Fxq './renewal/example.com.conf'
}

@test "CLI false overrides exported and literal true without writing" {
  prepare_override_existing
  printf '%s\n' 'UPLOAD_NO_RENEWAL=true' >"$ROOT/override.env"
  export UPLOAD_NO_RENEWAL=true
  execute --config "$ROOT/override.env" --upload-no-renewal false
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=false"* ]]
  assert_override_one_key latest.tar.gz 0
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/override-baseline.tar.gz"
}

@test "environment true overrides literal false with one valid put" {
  prepare_override_existing
  printf '%s\n' 'UPLOAD_NO_RENEWAL=false' >"$ROOT/override.env"
  export UPLOAD_NO_RENEWAL=true
  execute --config "$ROOT/override.env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  assert_override_one_key latest.tar.gz 1
}

@test "environment false overrides literal true to skip unchanged upload" {
  prepare_override_existing
  printf '%s\n' 'UPLOAD_NO_RENEWAL=true' >"$ROOT/override.env"
  export UPLOAD_NO_RENEWAL=false
  execute --config "$ROOT/override.env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=false"* ]]
  assert_override_one_key latest.tar.gz 0
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/override-baseline.tar.gz"
}

@test "literal file true and false override the default when env absent" {
  local flag expected_put
  prepare_override_existing
  unset UPLOAD_NO_RENEWAL
  for flag in true false; do
    reset_override_existing
    printf 'UPLOAD_NO_RENEWAL=%s\n' "$flag" >"$ROOT/override.env"
    execute --config "$ROOT/override.env"
    [ "$status" -eq 0 ]
    if [[ "$flag" == true ]]; then
      expected_put=1
      [[ "$output" == *"published=true"* ]]
    else
      expected_put=0
      [[ "$output" == *"published=false"* ]]
      cmp -s "$LIFECYCLE_REMOTE" "$ROOT/override-baseline.tar.gz"
    fi
    assert_override_one_key latest.tar.gz "$expected_put"
  done
}

@test "invalid or duplicate override settings fail before AWS and Certbot" {
  local candidate
  for candidate in TRUE False yes 1 ''; do
    : >"$LIFECYCLE_CALLS"
    execute --upload-no-renewal="$candidate"
    [ "$status" -eq 64 ]
    ! grep -q '^aws:' "$LIFECYCLE_CALLS"
    ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
  done
  : >"$LIFECYCLE_CALLS"
  execute --upload-no-renewal=true --upload-no-renewal=false
  [ "$status" -eq 64 ]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
  export UPLOAD_NO_RENEWAL=TRUE
  : >"$LIFECYCLE_CALLS"
  execute
  [ "$status" -eq 64 ]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
  unset UPLOAD_NO_RENEWAL
  printf '%s\n' 'UPLOAD_NO_RENEWAL=yes' >"$ROOT/override.env"
  : >"$LIFECYCLE_CALLS"
  execute --config "$ROOT/override.env"
  [ "$status" -eq 64 ]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
}

@test "due renewal publishes changed selected state for either override value" {
  local flag
  prepare_override_existing
  for flag in false true; do
    reset_override_existing
    export LIFECYCLE_MODE=renew-changed
    execute --upload-no-renewal="$flag"
    [ "$status" -eq 0 ]
    [[ "$output" == *"published=true"* ]]
    [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
    ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
    assert_override_one_key latest.tar.gz 1
    ! cmp -s "$LIFECYCLE_REMOTE" "$ROOT/override-baseline.tar.gz"
    tar -tzf "$LIFECYCLE_REMOTE" |
      grep -Fxq './renewal/example.com.conf'
  done
}

@test "metadata-only durable update publishes under either override value" {
  local flag
  prepare_override_existing
  tar -xOf "$LIFECYCLE_REMOTE" ./archive/example.com/cert1.pem \
    >"$ROOT/unchanged-leaf.pem"
  for flag in false true; do
    reset_override_existing
    export LIFECYCLE_MODE=metadata-changed
    execute --upload-no-renewal="$flag"
    [ "$status" -eq 0 ]
    [[ "$output" == *"published=true"* ]]
    [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
    assert_override_one_key latest.tar.gz 1
    tar -xOf "$LIFECYCLE_REMOTE" ./archive/example.com/cert1.pem \
      >"$ROOT/leaf-after.pem"
    cmp -s "$ROOT/unchanged-leaf.pem" "$ROOT/leaf-after.pem"
    [ "$(tar -xOf "$LIFECYCLE_REMOTE" \
      ./accounts/acme-v02.api.letsencrypt.org/directory/account-id/meta.json)" = \
      '{"meta":"renewed"}' ]
  done
}

@test "invalid downloaded archive blocks both override states before provider" {
  local flag
  printf '%s\n' 'invalid S3 tarball private payload' >"$LIFECYCLE_REMOTE"
  cp "$LIFECYCLE_REMOTE" "$ROOT/invalid-object"
  for flag in false true; do
    : >"$LIFECYCLE_CALLS"
    execute --upload-no-renewal="$flag"
    [ "$status" -ne 0 ]
    [[ "$output" != *"published=true"* ]]
    ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
    assert_override_one_key latest.tar.gz 0
    cmp -s "$LIFECYCLE_REMOTE" "$ROOT/invalid-object"
  done
}

@test "failed selected renewal forbids publication with either override" {
  local flag
  prepare_override_existing
  for flag in false true; do
    reset_override_existing
    export LIFECYCLE_MODE=certbot-failure
    execute --upload-no-renewal="$flag"
    [ "$status" -eq 74 ]
    [[ "$output" != *"published=true"* ]]
    [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
    assert_override_one_key latest.tar.gz 0
    cmp -s "$LIFECYCLE_REMOTE" "$ROOT/override-baseline.tar.gz"
  done
}

@test "invalid issued leaf blocks PutObject under either override" {
  local flag
  for flag in false true; do
    tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/seed" .
    cp "$LIFECYCLE_REMOTE" "$ROOT/bad-cert-object"
    : >"$LIFECYCLE_CALLS"
    export LIFECYCLE_MODE=bad-fullchain
    execute --upload-no-renewal="$flag"
    [ "$status" -ne 0 ]
    [[ "$output" != *"published=true"* ]]
    [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
    assert_override_one_key latest.tar.gz 0
    cmp -s "$LIFECYCLE_REMOTE" "$ROOT/bad-cert-object"
  done
}

@test "denied PutObject returns uncertainty with redacted stderr under both values" {
  local flag
  prepare_override_existing
  for flag in false true; do
    reset_override_existing
    export LIFECYCLE_MODE=metadata-changed
    export LIFECYCLE_PUT_MODE=put-failure
    execute --upload-no-renewal="$flag"
    [ "$status" -eq 74 ]
    [[ "$output" == *"remote state is uncertain"* ]]
    [[ "$output" != *"published=true"* ]]
    [[ "$output" != *"mock-private-PUT-TOKEN"* ]]
    assert_override_one_key latest.tar.gz 1
    cmp -s "$LIFECYCLE_REMOTE" "$ROOT/override-baseline.tar.gz"
  done
}

@test "accepted PutObject with lost response remains uncertain for both values" {
  local flag
  prepare_override_existing
  for flag in false true; do
    reset_override_existing
    export LIFECYCLE_MODE=metadata-changed
    export LIFECYCLE_PUT_MODE=put-after-write-failure
    execute --upload-no-renewal="$flag"
    [ "$status" -eq 74 ]
    [[ "$output" == *"remote state is uncertain"* ]]
    [[ "$output" != *"published=true"* ]]
    [[ "$output" != *"mock-private-PUT-TOKEN"* ]]
    assert_override_one_key latest.tar.gz 1
    ! cmp -s "$LIFECYCLE_REMOTE" "$ROOT/override-baseline.tar.gz"
  done
}
# Story #15 / task #46: public-command, cross-artifact multi-SAN acceptance.
# make test runs this same suite against .dev.bash, .bash and .min.bash.
# Real local OpenSSL/tar operate on mock-issued certificates; AWS/Certbot are
# executable local doubles, not live ACME, DNS or S3 interoperability tests.

@test "public issue requests and stores six exact SANs across unrelated zones" {
  execute --san api.example.net --san service.other.org
  [ "$status" -eq 0 ]
  [[ "$output" == *"issued example.com"* && "$output" == *"published=true"* ]]
  grep -Fxq 'certbot-sans:certonly:DNS:example.com,DNS:*.example.com,DNS:api.example.net,DNS:*.api.example.net,DNS:service.other.org,DNS:*.service.other.org' \
    "$LIFECYCLE_CONTEXTS"
  assert_remote_sans example.com '*.example.com' api.example.net \
    '*.api.example.net' service.other.org '*.service.other.org'
  [ "$(tar -tzf "$LIFECYCLE_REMOTE" |
    grep -c '^./renewal/[^/]*\.conf$')" -eq 1 ]
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot:renew$' "$LIFECYCLE_CALLS"
}

@test "explicit wildcard, duplicate and uppercase SANs expand once per input" {
  execute --san '*.api.other.org' --san api.other.org \
    --san EXAMPLE.COM --san '*.example.com'
  [ "$status" -eq 0 ]
  grep -Fxq 'certbot-sans:certonly:DNS:example.com,DNS:*.example.com,DNS:*.api.other.org,DNS:api.other.org' \
    "$LIFECYCLE_CONTEXTS"
  assert_remote_sans example.com '*.example.com' '*.api.other.org' api.other.org
  ! grep -q 'DNS:\*\.\*\.' "$LIFECYCLE_CONTEXTS"
}

@test "literal false suppresses complements on primary and unrelated additional inputs" {
  # These two SANs tie in length; select the established non-wildcard lineage
  # explicitly rather than allowing the ASCII tie-break to choose a wildcard.
  execute --include-subdomains=false --cert-name example.com \
    --san '*.other.org' --san EXAMPLE.COM
  [ "$status" -eq 0 ]
  grep -Fxq 'certbot-sans:certonly:DNS:example.com,DNS:*.other.org' \
    "$LIFECYCLE_CONTEXTS"
  assert_remote_sans example.com '*.other.org'
}

@test "implicit wildcard lineage from equal-length SAN tie fails before cloud access" {
  # Without an explicit lineage name, ASCII ordering picks '*.other.org'
  # before 'example.com'. A wildcard cannot be a Certbot lineage identifier.
  execute --include-subdomains=false --san '*.other.org' --san EXAMPLE.COM
  [ "$status" -eq 64 ]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
  assert_no_certbot_or_put
}

@test "public CLI replaces exported and literal additional SAN collections" {
  printf '%s\n' 'ADDITIONAL_SANS=file.example.net' >"$ROOT/extras.env"
  export ADDITIONAL_SANS=env.example.net
  execute --config "$ROOT/extras.env" --san=cli.other.org
  [ "$status" -eq 0 ]
  grep -Fxq 'certbot-sans:certonly:DNS:example.com,DNS:*.example.com,DNS:cli.other.org,DNS:*.cli.other.org' \
    "$LIFECYCLE_CONTEXTS"
  assert_remote_sans example.com '*.example.com' cli.other.org '*.cli.other.org'
}

@test "public exported additional SAN list replaces file, including empty override" {
  printf '%s\n' 'ADDITIONAL_SANS=file.example.net' >"$ROOT/extras.env"
  export ADDITIONAL_SANS=env.other.org
  execute --config "$ROOT/extras.env"
  [ "$status" -eq 0 ]
  assert_remote_sans example.com '*.example.com' env.other.org '*.env.other.org'

  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/seed" .
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
  export ADDITIONAL_SANS=''
  execute --config "$ROOT/extras.env"
  [ "$status" -eq 0 ]
  assert_remote_sans example.com '*.example.com'
  grep -Fxq 'certbot-sans:certonly:DNS:example.com,DNS:*.example.com' \
    "$LIFECYCLE_CONTEXTS"
}

@test "literal comma list selects exact unrelated SANs on the public command" {
  printf '%s\n' 'ADDITIONAL_SANS=foo.other.org,*.bar.example.net' \
    >"$ROOT/extras.env"
  execute --config "$ROOT/extras.env"
  [ "$status" -eq 0 ]
  assert_remote_sans example.com '*.example.com' foo.other.org \
    '*.foo.other.org' '*.bar.example.net' bar.example.net
  grep -Fxq 'certbot-sans:certonly:DNS:example.com,DNS:*.example.com,DNS:foo.other.org,DNS:*.foo.other.org,DNS:*.bar.example.net,DNS:bar.example.net' \
    "$LIFECYCLE_CONTEXTS"
}

@test "five independent runners issue reconcile add and remove then no-op one lineage" {
  local runner
  for runner in a b c d e; do
    mkdir -m 700 "$ROOT/multi-runner-$runner"
  done
  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/multi-runner-a"
  execute --san api.example.net
  [ "$status" -eq 0 ]
  [[ "$output" == *"issued example.com"* && "$output" == *"published=true"* ]]
  assert_remote_sans example.com '*.example.com' api.example.net '*.api.example.net'
  tar -xOf "$LIFECYCLE_REMOTE" \
    ./accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json \
    >"$ROOT/account-first"
  cp "$LIFECYCLE_REMOTE" "$ROOT/multi-first.tar.gz"

  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/multi-runner-b"
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
  execute --san api.example.net
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=false"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/multi-first.tar.gz"

  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/multi-runner-c"
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
  execute --san api.example.net --san service.other.org
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  grep -Fxq 'certbot-reconcile:example.com' "$LIFECYCLE_CONTEXTS"
  [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  assert_remote_sans example.com '*.example.com' api.example.net \
    '*.api.example.net' service.other.org '*.service.other.org'

  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/multi-runner-d"
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
  execute --san service.other.org
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  grep -Fxq 'certbot-reconcile:example.com' "$LIFECYCLE_CONTEXTS"
  assert_remote_sans example.com '*.example.com' service.other.org \
    '*.service.other.org'
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]

  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/multi-runner-e"
  : >"$LIFECYCLE_CALLS"
  execute --san service.other.org
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=false"* ]]
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  tar -xOf "$LIFECYCLE_REMOTE" \
    ./accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json \
    >"$ROOT/account-last"
  cmp -s "$ROOT/account-first" "$ROOT/account-last"
  [ "$(tar -tzf "$LIFECYCLE_REMOTE" |
    grep -c '^./renewal/[^/]*\.conf$')" -eq 1 ]
  for runner in a b c d e; do
    [ -z "$(find "$ROOT/multi-runner-$runner" -mindepth 1 -print -quit)" ]
  done
}

@test "due multi-SAN renewal retains unrelated names and publishes changed leaf" {
  execute --san api.example.net --san service.other.org
  [ "$status" -eq 0 ]
  cp "$LIFECYCLE_REMOTE" "$ROOT/before-renew.tar.gz"
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
  export LIFECYCLE_MODE=renew-changed
  execute --san api.example.net --san service.other.org
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
  assert_remote_sans example.com '*.example.com' api.example.net \
    '*.api.example.net' service.other.org '*.service.other.org'
  ! cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before-renew.tar.gz"
}

@test "shorter SAN chooses new lineage unless existing lineage is explicitly selected" {
  execute
  [ "$status" -eq 0 ]
  tar -xOf "$LIFECYCLE_REMOTE" ./archive/example.com/cert1.pem \
    >"$ROOT/before-shorter-cert.pem"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_EXPECTED_CERT_NAME=io.uk
  execute --san io.uk
  [ "$status" -eq 0 ]
  [[ "$output" == *"issued io.uk"* && "$output" == *"published=true"* ]]
  [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
  tar -tzf "$LIFECYCLE_REMOTE" | grep -Fxq './renewal/io.uk.conf'
  tar -xOf "$LIFECYCLE_REMOTE" ./archive/example.com/cert1.pem |
    cmp -s - "$ROOT/before-shorter-cert.pem"

  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
  execute --cert-name example.com --san io.uk
  [ "$status" -eq 0 ]
  [[ "$output" == *"checked example.com"* && "$output" == *"published=true"* ]]
  grep -Fxq 'certbot-reconcile:example.com' "$LIFECYCLE_CONTEXTS"
  assert_remote_sans example.com '*.example.com' io.uk '*.io.uk'
  tar -tzf "$LIFECYCLE_REMOTE" | grep -Fxq './renewal/io.uk.conf'
}

@test "multi-SAN successful unchanged forced republish uses one original key" {
  execute --san api.example.net
  [ "$status" -eq 0 ]
  : >"$LIFECYCLE_CALLS"
  execute --san api.example.net --upload-no-renewal=true
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=true"* ]]
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
  assert_remote_sans example.com '*.example.com' api.example.net '*.api.example.net'
}

@test "invalid additional SANs and malformed literal lists never contact AWS or Certbot" {
  local candidate
  for candidate in 'bad.example.net.' 'other.net,second.org' '*.bad.*.net' \
    'invalid$name.net' 'x y.other.org'; do
    : >"$LIFECYCLE_CALLS"
    execute --san "$candidate"
    [ "$status" -eq 64 ]
    ! grep -q '^aws:' "$LIFECYCLE_CALLS"
    assert_no_certbot_or_put
  done
  printf '%s\n' 'ADDITIONAL_SANS=other.net,,second.org' >"$ROOT/extras.env"
  : >"$LIFECYCLE_CALLS"
  execute --config "$ROOT/extras.env"
  [ "$status" -eq 64 ]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
  assert_no_certbot_or_put
}

@test "failed SAN reconciliation never publishes partial state" {
  execute --san api.example.net
  [ "$status" -eq 0 ]
  cp "$LIFECYCLE_REMOTE" "$ROOT/pre-failure.tar.gz"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_MODE=certbot-failure
  execute --san api.example.net --san service.other.org
  [ "$status" -eq 74 ]
  [[ "$output" != *"published=true"* ]]
  [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/pre-failure.tar.gz"
}

@test "provider success with unexpected unrelated SAN cannot publish" {
  execute --san api.example.net
  [ "$status" -eq 0 ]
  cp "$LIFECYCLE_REMOTE" "$ROOT/pre-wrong-san.tar.gz"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_MODE=reconcile-wrong-sans
  execute --san api.example.net --san service.other.org
  [ "$status" -eq 65 ]
  [[ "$output" != *"published=true"* ]]
  [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/pre-wrong-san.tar.gz"
}

@test "invalid restored non-DNS leaf SAN cannot be treated as legitimate drift" {
  execute --san api.example.net
  [ "$status" -eq 0 ]
  mkdir -m 700 "$ROOT/bad-leaf"
  tar -xzf "$LIFECYCLE_REMOTE" -C "$ROOT/bad-leaf"
  openssl req -x509 -new -days 2 -subj '/CN=example.com' \
    -key "$ROOT/bad-leaf/archive/example.com/privkey1.pem" \
    -addext 'subjectAltName=DNS:example.com,IP:127.0.0.1' \
    -out "$ROOT/bad-leaf/archive/example.com/cert1.pem" \
    >/dev/null 2>&1
  cp "$ROOT/bad-leaf/archive/example.com/cert1.pem" \
    "$ROOT/bad-leaf/archive/example.com/fullchain1.pem"
  cp "$ROOT/bad-leaf/archive/example.com/cert1.pem" \
    "$ROOT/bad-leaf/archive/example.com/chain1.pem"
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/bad-leaf" .
  cp "$LIFECYCLE_REMOTE" "$ROOT/invalid-leaf-baseline.tar.gz"
  : >"$LIFECYCLE_CALLS"
  execute --san service.other.org
  [ "$status" -eq 65 ]
  [[ "$output" != *"published=true"* ]]
  assert_no_certbot_or_put
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/invalid-leaf-baseline.tar.gz"
}

# Story #56 / task #61: selected-only actions on a shared archive.
# The larger cross-runner and negative matrix is reserved for task #62.

@test "second independent selected lineage retains first key and renewal state" {
  execute
  [ "$status" -eq 0 ]
  tar -xOf "$LIFECYCLE_REMOTE" ./archive/example.com/privkey1.pem \
    >"$ROOT/first-key.pem"
  tar -xOf "$LIFECYCLE_REMOTE" ./archive/example.com/cert1.pem \
    >"$ROOT/first-cert.pem"
  tar -xOf "$LIFECYCLE_REMOTE" ./renewal/example.com.conf \
    >"$ROOT/first-renewal.conf"
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
  export LIFECYCLE_EXPECTED_CERT_NAME=other.org
  execute_domain other.org --cert-name other.org
  [ "$status" -eq 0 ]
  [[ "$output" == *"issued other.org"* && "$output" == *"published=true"* ]]
  [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot:renew$' "$LIFECYCLE_CALLS"
  tar -tzf "$LIFECYCLE_REMOTE" | grep -Fxq './renewal/other.org.conf'
  tar -tzf "$LIFECYCLE_REMOTE" | grep -Fxq './renewal/example.com.conf'
  tar -xOf "$LIFECYCLE_REMOTE" ./archive/example.com/privkey1.pem \
    | cmp -s - "$ROOT/first-key.pem"
  tar -xOf "$LIFECYCLE_REMOTE" ./archive/example.com/cert1.pem \
    | cmp -s - "$ROOT/first-cert.pem"
  tar -xOf "$LIFECYCLE_REMOTE" ./renewal/example.com.conf \
    | cmp -s - "$ROOT/first-renewal.conf"
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]

  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
  execute --cert-name example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=false"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
}

@test "unsafe nonselected canonical metadata blocks issuance and publication" {
  execute
  [ "$status" -eq 0 ]
  mkdir -m 700 "$ROOT/multi-bad"
  tar -xzf "$LIFECYCLE_REMOTE" -C "$ROOT/multi-bad"
  sed -i 's|/etc/letsencrypt/live/example.com|/tmp/foreign/example.com|g' \
    "$ROOT/multi-bad/renewal/example.com.conf"
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/multi-bad" .
  cp "$LIFECYCLE_REMOTE" "$ROOT/multi-bad-baseline.tar.gz"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_EXPECTED_CERT_NAME=other.org
  execute_domain other.org --cert-name other.org
  [ "$status" -ne 0 ]
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/multi-bad-baseline.tar.gz"
}

# Story #56 / task #62: artifact-level multi-lineage, independent-runner
# acceptance. AWS and Certbot are process-local doubles; OpenSSL, GNU tar,
# gzip, actual built artifacts, and new runner directories remain real.

# Preserve all unselected files, private-key modes, relative symlink targets,
# and renewal configuration bytes. Do not compare the compressed tar stream:
# its metadata may change without a managed certificate changing.
snapshot_shared_lineage() {
  local label="$1"
  mkdir -m 700 "$ROOT/snapshot-$label"
  tar -xzf "$LIFECYCLE_REMOTE" -C "$ROOT/snapshot-$label"
}

assert_shared_lineage_unchanged() {
  local name="$1" label="$2" current part
  current="$(mktemp -d "$ROOT/inspect.XXXXXXXX")" || return 1
  tar -xzf "$LIFECYCLE_REMOTE" -C "$current" || return 1
  cmp -s "$ROOT/snapshot-$label/renewal/$name.conf" \
    "$current/renewal/$name.conf" || return 1
  diff -qr "$ROOT/snapshot-$label/archive/$name" \
    "$current/archive/$name" >/dev/null || return 1
  for part in cert chain fullchain privkey; do
    [[ "$(readlink -- "$ROOT/snapshot-$label/live/$name/$part.pem")" == \
      "$(readlink -- "$current/live/$name/$part.pem")" ]] || return 1
  done
  # GNU find's relative name, type, mode, and symlink target report catches
  # changes to sensitive file permissions and any versioned history.
  local before after
  before="$(cd "$ROOT/snapshot-$label" &&
    find "archive/$name" "live/$name" "renewal/$name.conf" \
      -printf '%p|%y|%m|%l\n' | LC_ALL=C sort)" || return 1
  after="$(cd "$current" &&
    find "archive/$name" "live/$name" "renewal/$name.conf" \
      -printf '%p|%y|%m|%l\n' | LC_ALL=C sort)" || return 1
  [[ "$before" == "$after" ]] || return 1
  rm -rf -- "$current"
}

assert_one_shared_s3_key() {
  ! grep -q '^aws:.*:fixture-bucket:' "$LIFECYCLE_CALLS" ||
    ! grep '^aws:.*:fixture-bucket:' "$LIFECYCLE_CALLS" |
      grep -v ':fixture-bucket:latest.tar.gz$' >/dev/null
}

# The extra selected name changes the provider's identity, not its account,
# key, underlying persisted S3 location, or implicit target selection.
seed_two_unrelated_lineages() {
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
  execute
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"published=true"* ]] || return 1
  export LIFECYCLE_EXPECTED_CERT_NAME=other.org
  execute_domain other.org --cert-name other.org
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"published=true"* ]] || return 1
  tar -tzf "$LIFECYCLE_REMOTE" | grep -Fxq './renewal/example.com.conf' ||
    return 1
  tar -tzf "$LIFECYCLE_REMOTE" | grep -Fxq './renewal/other.org.conf' ||
    return 1
}

@test "five clean runners preserve two unrelated lineages, account and same archive" {
  local runner
  for runner in a b c d e; do
    mkdir -m 700 "$ROOT/shared-runner-$runner"
  done
  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/shared-runner-a"
  execute
  [ "$status" -eq 0 ]
  [[ "$output" == *"issued example.com"* && "$output" == *"published=true"* ]]
  snapshot_shared_lineage original
  tar -xOf "$LIFECYCLE_REMOTE" \
    ./accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json \
    >"$ROOT/shared-account-original.json"

  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/shared-runner-b"
  export LIFECYCLE_EXPECTED_CERT_NAME=other.org
  : >"$LIFECYCLE_CALLS"
  execute_domain other.org --cert-name other.org
  [ "$status" -eq 0 ]
  [[ "$output" == *"issued other.org"* && "$output" == *"published=true"* ]]
  assert_shared_lineage_unchanged example.com original
  [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  assert_one_shared_s3_key
  snapshot_shared_lineage second

  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/shared-runner-c"
  : >"$LIFECYCLE_CALLS"
  execute_domain other.org --cert-name other.org
  [ "$status" -eq 0 ]
  [[ "$output" == *"checked other.org"* && "$output" == *"published=false"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  assert_shared_lineage_unchanged example.com original

  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/shared-runner-d"
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
  export LIFECYCLE_MODE=renew-changed
  : >"$LIFECYCLE_CALLS"
  execute --cert-name example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"checked example.com"* && "$output" == *"published=true"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  assert_shared_lineage_unchanged other.org second
  ! tar -xOf "$LIFECYCLE_REMOTE" ./archive/example.com/cert1.pem |
    cmp -s - "$ROOT/snapshot-original/archive/example.com/cert1.pem"
  assert_one_shared_s3_key

  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/shared-runner-e"
  export LIFECYCLE_EXPECTED_CERT_NAME=other.org
  export LIFECYCLE_MODE=ok
  : >"$LIFECYCLE_CALLS"
  execute_domain other.org --cert-name other.org
  [ "$status" -eq 0 ]
  [[ "$output" == *"checked other.org"* && "$output" == *"published=false"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  assert_shared_lineage_unchanged other.org second
  tar -xOf "$LIFECYCLE_REMOTE" \
    ./accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json \
    | cmp -s - "$ROOT/shared-account-original.json"
  [ "$(tar -tzf "$LIFECYCLE_REMOTE" | grep -c '^./renewal/[^/]*\.conf$')" -eq 2 ]
  for runner in a b c d e; do
    [ -z "$(find "$ROOT/shared-runner-$runner" -mindepth 1 -print -quit)" ]
  done
}

@test "two explicitly distinct lineages may share exact DNS SANs" {
  execute
  [ "$status" -eq 0 ]
  snapshot_shared_lineage overlapping
  export LIFECYCLE_EXPECTED_CERT_NAME=second.example.net
  : >"$LIFECYCLE_CALLS"
  execute --cert-name second.example.net
  [ "$status" -eq 0 ]
  [[ "$output" == *"issued second.example.net"* &&
    "$output" == *"published=true"* ]]
  [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
  assert_shared_lineage_unchanged example.com overlapping
  tar -tzf "$LIFECYCLE_REMOTE" |
    grep -Fxq './renewal/second.example.net.conf'
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
  execute --cert-name example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"published=false"* ]]
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
}

@test "invalid selected identity cannot mutate two archived lineages" {
  seed_two_unrelated_lineages
  cp "$LIFECYCLE_REMOTE" "$ROOT/two-before-invalid-name.tar.gz"
  : >"$LIFECYCLE_CALLS"
  execute --cert-name '*.other.org'
  [ "$status" -eq 64 ]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
  assert_no_certbot_or_put
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/two-before-invalid-name.tar.gz"
}

@test "corrupt unselected lineage blocks selected operation before Certbot and PutObject" {
  seed_two_unrelated_lineages
  mkdir -m 700 "$ROOT/incomplete-shared"
  tar -xzf "$LIFECYCLE_REMOTE" -C "$ROOT/incomplete-shared"
  rm "$ROOT/incomplete-shared/live/other.org/privkey.pem"
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/incomplete-shared" .
  cp "$LIFECYCLE_REMOTE" "$ROOT/two-incomplete-baseline.tar.gz"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
  execute --cert-name example.com
  [ "$status" -eq 65 ]
  assert_no_certbot_or_put
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/two-incomplete-baseline.tar.gz"
}

@test "missing existing account in a two-lineage archive never registers or publishes" {
  seed_two_unrelated_lineages
  mkdir -m 700 "$ROOT/missing-shared-account"
  tar -xzf "$LIFECYCLE_REMOTE" -C "$ROOT/missing-shared-account"
  rm "$ROOT/missing-shared-account/accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json"
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/missing-shared-account" .
  cp "$LIFECYCLE_REMOTE" "$ROOT/two-no-account-baseline.tar.gz"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
  execute --cert-name example.com
  [ "$status" -ne 0 ]
  assert_no_certbot_or_put
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/two-no-account-baseline.tar.gz"
}

@test "failed selected renewal preserves both lineages and last S3 bytes" {
  seed_two_unrelated_lineages
  snapshot_shared_lineage failedrenew
  cp "$LIFECYCLE_REMOTE" "$ROOT/two-before-renew-error.tar.gz"
  export LIFECYCLE_MODE=certbot-failure
  export LIFECYCLE_EXPECTED_CERT_NAME=other.org
  : >"$LIFECYCLE_CALLS"
  execute_domain other.org --cert-name other.org
  [ "$status" -eq 74 ]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/two-before-renew-error.tar.gz"
  assert_shared_lineage_unchanged example.com failedrenew
  assert_shared_lineage_unchanged other.org failedrenew
}

@test "two-lineage PutObject refusal preserves mocked remote but reports uncertainty" {
  seed_two_unrelated_lineages
  cp "$LIFECYCLE_REMOTE" "$ROOT/two-before-put-error.tar.gz"
  export LIFECYCLE_EXPECTED_CERT_NAME=other.org
  export LIFECYCLE_MODE=renew-changed
  export LIFECYCLE_PUT_MODE=put-failure
  : >"$LIFECYCLE_CALLS"
  execute_domain other.org --cert-name other.org
  [ "$status" -eq 74 ]
  [[ "$output" != *"published=true"* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/two-before-put-error.tar.gz"
}

@test "bad GetObject on two-lineage archive does not invoke provider or PutObject" {
  seed_two_unrelated_lineages
  cp "$LIFECYCLE_REMOTE" "$ROOT/two-before-corrupt-fetch.tar.gz"
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
  export LIFECYCLE_MODE=get-corrupt
  : >"$LIFECYCLE_CALLS"
  execute --cert-name example.com
  [ "$status" -ne 0 ]
  assert_no_certbot_or_put
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/two-before-corrupt-fetch.tar.gz"
}

# Task #42 focuses on the transport security boundary. Task #43 owns the
# expanded cross-runner encrypted interoperability and negative matrix.
require_gpg_ocb() {
  local version major minor patch
  command -v gpg >/dev/null 2>&1 || skip 'GnuPG not installed'
  version="$(gpg --version 2>/dev/null)"
  if [[ ! "$version" =~ gpg\ \(GnuPG\)\ ([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    skip 'GnuPG version unavailable'
  fi
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"
  if (( major < 2 || (major == 2 &&
    (minor < 4 || (minor == 4 && patch < 7))) )); then
    skip 'GnuPG 2.4.7+ required by ADR-031'
  fi
}

@test "plaintext mode remains unchanged when no key is configured" {
  execute --archive-encryption auto
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=true'* ]]
  gzip -t "$LIFECYCLE_REMOTE"
  tar -tzf "$LIFECYCLE_REMOTE" | grep -Fxq './renewal/example.com.conf'
}

@test "enabled archive encryption requires a key and never sends plaintext" {
  execute --archive-encryption gpg-ocb
  [ "$status" -eq 64 ]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
  export GPG_SYMMETRIC_KEY=fixture-strong-password-not-a-real-credential
  execute --archive-encryption none
  [ "$status" -eq 64 ]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
}

@test "migrating the same S3 key requires explicit operator backup acknowledgement" {
  require_gpg_ocb
  export GPG_SYMMETRIC_KEY=fixture-strong-password-not-a-real-credential
  execute --archive-encryption gpg-ocb
  [ "$status" -eq 65 ]
  assert_no_certbot_or_put
  execute --archive-migration plaintext-to-gpg-ocb
  [ "$status" -eq 64 ]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
}

@test "authenticated migration publishes ciphertext then cleanly decrypts on rerun" {
  require_gpg_ocb
  export GPG_SYMMETRIC_KEY=fixture-strong-password-not-a-real-credential
  execute --archive-migration plaintext-to-gpg-ocb \
    --archive-migration-backup-confirmed true
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=true'* ]]
  head -c 22 "$LIFECYCLE_REMOTE" |
    cmp -s - <(printf 'CERTBOTBOT-GPG-OCB-V1\n')
  ! gzip -t "$LIFECYCLE_REMOTE" 2>/dev/null
  ! grep -q '^aws:secret-inherited' "$LIFECYCLE_CALLS"
  ! grep -q '^certbot:secret-inherited' "$LIFECYCLE_CALLS"
  cp "$LIFECYCLE_REMOTE" "$ROOT/ciphertext-original"
  : >"$LIFECYCLE_CALLS"
  execute
  [ "$status" -eq 0 ]
  [[ "$output" == *'checked example.com'* &&
    "$output" == *'published=false'* ]]
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/ciphertext-original"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  ! grep -q 'secret-inherited' "$LIFECYCLE_CALLS"
}

@test "wrong decryption key fails before Certbot or remote state replacement" {
  require_gpg_ocb
  export GPG_SYMMETRIC_KEY=fixture-strong-password-not-a-real-credential
  execute --archive-migration plaintext-to-gpg-ocb \
    --archive-migration-backup-confirmed true
  [ "$status" -eq 0 ]
  cp "$LIFECYCLE_REMOTE" "$ROOT/ciphertext-safe"
  export GPG_SYMMETRIC_KEY=not-the-original-credential
  : >"$LIFECYCLE_CALLS"
  execute
  [ "$status" -eq 65 ]
  assert_no_certbot_or_put
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/ciphertext-safe"
  [[ "$output" != *fixture-strong-password-not-a-real-credential* ]]
  [[ "$output" != *not-the-original-credential* ]]
}

# ADR-031 / task #43: full public-command encrypted and plaintext compatibility.
# All real-GnuPG tests are mandatory under the dedicated Ubuntu 26.04 job.
# These fixtures intentionally retain one seeded S3 key and never call AWS.

encryption_assert_remote_ciphertext() {
  head -c 22 "$LIFECYCLE_REMOTE" |
    cmp -s - <(printf 'CERTBOTBOT-GPG-OCB-V1\n') || return 1
  ! gzip -t "$LIFECYCLE_REMOTE" 2>/dev/null || return 1
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -le 1 ] || return 1
}

encryption_decode_remote() {
  local target="$1" home="$ROOT/encryption-inspect-home"
  [[ -d "$home" ]] || mkdir -m 700 -- "$home" || return 1
  tail -c +23 -- "$LIFECYCLE_REMOTE" >"$ROOT/encryption-inspect-packet" ||
    return 1
  (umask 077; env -u GPG_SYMMETRIC_KEY -u CERTBOTBOT_GPG_SECRET \
    gpg --no-options --homedir "$home" --batch --yes --no-tty \
    --pinentry-mode loopback --no-symkey-cache --passphrase-fd 3 \
    --decrypt --output "$target" "$ROOT/encryption-inspect-packet" \
    3<<<"$GPG_SYMMETRIC_KEY" >/dev/null 2>&1) || return 1
  gzip -t "$target" && tar -tzf "$target" >/dev/null
}

encryption_seed_object() {
  require_gpg_ocb
  export GPG_SYMMETRIC_KEY=encryption-interoperability-test-only-7fb81647
  execute --archive-migration plaintext-to-gpg-ocb \
    --archive-migration-backup-confirmed true
  [ "$status" -eq 0 ] || return 1
  encryption_assert_remote_ciphertext || return 1
}

encryption_no_secret_exposure() {
  [[ "$output" != *"$GPG_SYMMETRIC_KEY"* ]] || return 1
  ! grep -q 'secret-inherited' "$LIFECYCLE_CALLS" || return 1
  ! grep -Fq -- "$GPG_SYMMETRIC_KEY" "$LIFECYCLE_CALLS" || return 1
  ! grep -Fq -- "$GPG_SYMMETRIC_KEY" "$LIFECYCLE_CONTEXTS" || return 1
}

@test "encryption setting honors literal file, environment, and CLI precedence" {
  printf '%s\n' 'ARCHIVE_ENCRYPTION=gpg-ocb' \
    'S3_BUCKET=fixture-bucket' >"$ROOT/encryption.env"
  execute --config "$ROOT/encryption.env"
  [ "$status" -eq 64 ]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
  ARCHIVE_ENCRYPTION=none
  export ARCHIVE_ENCRYPTION
  execute --config "$ROOT/encryption.env"
  [ "$status" -eq 0 ]
  gzip -t "$LIFECYCLE_REMOTE"
  unset ARCHIVE_ENCRYPTION
  : >"$LIFECYCLE_CALLS"
  execute --config "$ROOT/encryption.env" --archive-encryption none
  [ "$status" -eq 0 ]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
}

@test "encryption secret is forbidden in CLI and literal config file" {
  printf '%s\n' 'GPG_SYMMETRIC_KEY=not-a-real-secret' \
    'S3_BUCKET=fixture-bucket' >"$ROOT/bad-encryption.env"
  execute --config "$ROOT/bad-encryption.env"
  [ "$status" -eq 64 ]
  [[ "$output" != *not-a-real-secret* ]]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
  execute --gpg-symmetric-key not-a-real-secret
  [ "$status" -eq 64 ]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
}

@test "encryption rejects unknown mode, migration direction, and invalid backup flag" {
  execute --archive-encryption future-v2
  [ "$status" -eq 64 ]
  execute --archive-migration gpg-ocb-to-plaintext
  [ "$status" -eq 64 ]
  execute --archive-migration-backup-confirmed maybe
  [ "$status" -eq 64 ]
  execute --archive-migration-backup-confirmed true
  [ "$status" -eq 64 ]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
}

@test "encryption secret with newline or carriage return is rejected before AWS" {
  export GPG_SYMMETRIC_KEY=$'fake-line-one\nfake-line-two'
  execute
  [ "$status" -eq 64 ]
  [[ "$output" != *fake-line-one* ]]
  export GPG_SYMMETRIC_KEY=$'fake-line-one\rfake-line-two'
  execute
  [ "$status" -eq 64 ]
  [[ "$output" != *fake-line-two* ]]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
}

@test "encryption unsupported GnuPG version fails before S3 and Certbot" {
  cat >"$ROOT/bin/gpg" <<'MOCK_GPG'
#!/usr/bin/env bash
if [[ "$1" == --version ]]; then
  printf 'gpg (GnuPG) 2.2.27\n'
  exit 0
fi
exit 91
MOCK_GPG
  chmod 755 "$ROOT/bin/gpg"
  export GPG_SYMMETRIC_KEY=pretend-secret-for-old-runtime-only
  execute
  [ "$status" -eq 69 ]
  assert_no_certbot_or_put
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
  [[ "$output" != *pretend-secret-for-old-runtime-only* ]]
}

@test "encryption clean runners preserve complete tar account and two lineages" {
  require_gpg_ocb
  for runner in a b c d; do
    mkdir -m 700 "$ROOT/crypto-runner-$runner"
  done
  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/crypto-runner-a"
  execute
  [ "$status" -eq 0 ]
  export LIFECYCLE_EXPECTED_CERT_NAME=other.org
  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/crypto-runner-b"
  execute_domain other.org --cert-name other.org
  [ "$status" -eq 0 ]
  tar -xOf "$LIFECYCLE_REMOTE" ./archive/example.com/privkey1.pem \
    >"$ROOT/encryption-original-key.pem"
  tar -xOf "$LIFECYCLE_REMOTE" ./renewal/other.org.conf \
    >"$ROOT/encryption-original-renewal.conf"
  export GPG_SYMMETRIC_KEY=encryption-interoperability-test-only-7fb81647
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/crypto-runner-c"
  : >"$LIFECYCLE_CALLS"
  execute --archive-migration plaintext-to-gpg-ocb \
    --archive-migration-backup-confirmed true
  [ "$status" -eq 0 ]
  [[ "$output" == *'checked example.com'* && "$output" == *'published=true'* ]]
  encryption_assert_remote_ciphertext
  encryption_decode_remote "$ROOT/encryption-two-lineages.tar.gz"
  [ "$(tar -tzf "$ROOT/encryption-two-lineages.tar.gz" |
    grep -c '^./renewal/[^/]*\.conf$')" -eq 2 ]
  tar -xOf "$ROOT/encryption-two-lineages.tar.gz" \
    ./archive/example.com/privkey1.pem |
    cmp -s - "$ROOT/encryption-original-key.pem"
  tar -xOf "$ROOT/encryption-two-lineages.tar.gz" \
    ./renewal/other.org.conf |
    cmp -s - "$ROOT/encryption-original-renewal.conf"
  tar -xOf "$ROOT/encryption-two-lineages.tar.gz" \
    ./accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json |
    grep -Fxq '{"seed":"private"}'

  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/crypto-runner-d"
  export LIFECYCLE_EXPECTED_CERT_NAME=other.org
  export LIFECYCLE_MODE=renew-changed
  : >"$LIFECYCLE_CALLS"
  execute_domain other.org --cert-name other.org
  [ "$status" -eq 0 ]
  [[ "$output" == *'checked other.org'* && "$output" == *'published=true'* ]]
  encryption_assert_remote_ciphertext
  encryption_decode_remote "$ROOT/encryption-renewed-two-lineages.tar.gz"
  tar -xOf "$ROOT/encryption-renewed-two-lineages.tar.gz" \
    ./archive/example.com/privkey1.pem |
    cmp -s - "$ROOT/encryption-original-key.pem"
  tar -xOf "$ROOT/encryption-renewed-two-lineages.tar.gz" \
    ./renewal/other.org.conf |
    cmp -s - "$ROOT/encryption-original-renewal.conf"
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  encryption_no_secret_exposure
  for runner in a b c d; do
    [ -z "$(find "$ROOT/crypto-runner-$runner" -mindepth 1 -print -quit)" ]
  done
}

@test "encryption migration of unchanged plaintext requires and makes one write" {
  require_gpg_ocb
  execute
  [ "$status" -eq 0 ]
  export GPG_SYMMETRIC_KEY=encryption-interoperability-test-only-7fb81647
  : >"$LIFECYCLE_CALLS"
  execute --archive-migration plaintext-to-gpg-ocb \
    --archive-migration-backup-confirmed true
  [ "$status" -eq 0 ]
  [[ "$output" == *'checked example.com'* && "$output" == *'published=true'* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  encryption_assert_remote_ciphertext
  encryption_no_secret_exposure
}

@test "encryption missing key refuses encrypted object without cloud overwrite" {
  encryption_seed_object
  cp "$LIFECYCLE_REMOTE" "$ROOT/encryption-last-good"
  unset GPG_SYMMETRIC_KEY
  : >"$LIFECYCLE_CALLS"
  execute
  [ "$status" -eq 65 ]
  assert_no_certbot_or_put
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/encryption-last-good"
}

@test "encryption mode downgrade rejects ciphertext before cloud or provider" {
  encryption_seed_object
  cp "$LIFECYCLE_REMOTE" "$ROOT/encryption-last-good"
  : >"$LIFECYCLE_CALLS"
  execute --archive-encryption none
  [ "$status" -eq 64 ]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/encryption-last-good"
}

@test "encryption migration cannot run twice or reinterpret encrypted input" {
  encryption_seed_object
  cp "$LIFECYCLE_REMOTE" "$ROOT/encryption-last-good"
  : >"$LIFECYCLE_CALLS"
  execute --archive-migration plaintext-to-gpg-ocb \
    --archive-migration-backup-confirmed true
  [ "$status" -eq 65 ]
  assert_no_certbot_or_put
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/encryption-last-good"
}

@test "encryption wrong key fails closed without logging secret or publishing" {
  encryption_seed_object
  cp "$LIFECYCLE_REMOTE" "$ROOT/encryption-last-good"
  export GPG_SYMMETRIC_KEY=distinct-wrong-key-not-a-credential
  : >"$LIFECYCLE_CALLS"
  execute
  [ "$status" -eq 65 ]
  assert_no_certbot_or_put
  encryption_no_secret_exposure
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/encryption-last-good"
}

@test "encryption tampered authentication tag blocks provider and PutObject" {
  encryption_seed_object
  local length byte other escaped
  length="$(stat -c %s "$LIFECYCLE_REMOTE")"
  byte="$(od -An -tu1 -j "$((length - 1))" -N 1 \
    "$LIFECYCLE_REMOTE" | tr -d '[:space:]')"
  other="$((byte ^ 1))"
  printf -v escaped '\\%03o' "$other"
  printf '%b' "$escaped" | dd of="$LIFECYCLE_REMOTE" bs=1 \
    seek="$((length - 1))" conv=notrunc status=none
  cp "$LIFECYCLE_REMOTE" "$ROOT/encryption-corrupted-baseline"
  : >"$LIFECYCLE_CALLS"
  execute
  [ "$status" -eq 65 ]
  assert_no_certbot_or_put
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/encryption-corrupted-baseline"
  encryption_no_secret_exposure
}

@test "encryption unknown version never triggers plaintext migration fallback" {
  require_gpg_ocb
  export GPG_SYMMETRIC_KEY=encryption-interoperability-test-only-7fb81647
  printf 'CERTBOTBOT-GPG-OCB-V2\nmalformed-version\n' >"$LIFECYCLE_REMOTE"
  cp "$LIFECYCLE_REMOTE" "$ROOT/encryption-unknown-baseline"
  execute --archive-migration plaintext-to-gpg-ocb \
    --archive-migration-backup-confirmed true
  [ "$status" -eq 65 ]
  assert_no_certbot_or_put
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/encryption-unknown-baseline"
}

@test "encryption legacy non-AEAD GnuPG packet cannot impersonate OCB envelope" {
  require_gpg_ocb
  export GPG_SYMMETRIC_KEY=encryption-interoperability-test-only-7fb81647
  mkdir -m 700 "$ROOT/legacy-gpg-home"
  printf 'this payload is not an authorized certbotbot archive\n' \
    >"$ROOT/legacy-cleartext"
  (umask 077; env -u GPG_SYMMETRIC_KEY \
    gpg --no-options --homedir "$ROOT/legacy-gpg-home" --batch --yes \
      --no-tty --pinentry-mode loopback --no-symkey-cache \
      --passphrase-fd 3 --symmetric --cipher-algo AES256 \
      --output "$ROOT/legacy-ciphertext" "$ROOT/legacy-cleartext" \
      3<<<"$GPG_SYMMETRIC_KEY" >/dev/null 2>&1)
  printf 'CERTBOTBOT-GPG-OCB-V1\n' >"$LIFECYCLE_REMOTE"
  cat "$ROOT/legacy-ciphertext" >>"$LIFECYCLE_REMOTE"
  cp "$LIFECYCLE_REMOTE" "$ROOT/legacy-baseline"
  : >"$LIFECYCLE_CALLS"
  execute
  [ "$status" -eq 65 ]
  assert_no_certbot_or_put
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/legacy-baseline"
}

@test "encryption forced unchanged republish remains ciphertext on exact S3 key" {
  encryption_seed_object
  cp "$LIFECYCLE_REMOTE" "$ROOT/encryption-last-good"
  : >"$LIFECYCLE_CALLS"
  execute --upload-no-renewal true
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=true'* ]]
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  encryption_assert_remote_ciphertext
  ! cmp -s "$LIFECYCLE_REMOTE" "$ROOT/encryption-last-good"
  encryption_decode_remote "$ROOT/encryption-republish.tar.gz"
  encryption_no_secret_exposure
}

@test "encryption failed PutObject retains previous ciphertext without rollback claim" {
  encryption_seed_object
  cp "$LIFECYCLE_REMOTE" "$ROOT/encryption-last-good"
  export LIFECYCLE_PUT_MODE=put-failure
  : >"$LIFECYCLE_CALLS"
  execute --upload-no-renewal true
  [ "$status" -eq 74 ]
  [[ "$output" == *'remote state is uncertain'* ]]
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/encryption-last-good"
  encryption_no_secret_exposure
}

@test "encryption lost PutObject acknowledgement reports uncertain remote result" {
  encryption_seed_object
  cp "$LIFECYCLE_REMOTE" "$ROOT/encryption-last-good"
  export LIFECYCLE_PUT_MODE=put-after-write-failure
  : >"$LIFECYCLE_CALLS"
  execute --upload-no-renewal true
  [ "$status" -eq 74 ]
  [[ "$output" == *'remote state is uncertain'* ]]
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  ! cmp -s "$LIFECYCLE_REMOTE" "$ROOT/encryption-last-good"
  encryption_assert_remote_ciphertext
  encryption_decode_remote "$ROOT/encryption-lost-response.tar.gz"
  encryption_no_secret_exposure
}

# Filename tests reuse the full live-command AWS/Certbot fixture above. These
# deliberately exercise the same configured key at HeadObject, GetObject and
# PutObject, beyond argument-only rejection tests in filename-verification.bats.

@test "templated filename stays frozen across mocked midnight and all three S3 calls" {
  export LIFECYCLE_EXPECTED_KEY=state-20261020.tar.gz
  export FILENAME_DATE_CALLS="$ROOT/clock-calls"
  cat >"$ROOT/bin/date" <<'MOCK'
#!/usr/bin/env bash
[[ "$#" == 2 && "$1" == -u && "$2" == +%Y%m%d ]] || exit 90
if [[ -s "$FILENAME_DATE_CALLS" ]]; then
  printf '20261021\n'
else
  printf '20261020\n'
fi
printf 'called\n' >>"$FILENAME_DATE_CALLS"
MOCK
  chmod 755 "$ROOT/bin/date"
  execute --s3-key-template 'state-{YEAR}{MONTH}{DOM}.tar.gz'
  [ "$status" -eq 0 ]
  [[ "$output" == *"s3://fixture-bucket/state-20261020.tar.gz"* ]]
  [[ "$output" == *"published=true"* ]]
  [ "$(wc -l <"$FILENAME_DATE_CALLS")" -eq 1 ]
  [ "$(grep -Fc 'aws:head-object:fixture-bucket:state-20261020.tar.gz' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -Fc 'aws:get-object:fixture-bucket:state-20261020.tar.gz' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -Fc 'aws:put-object:fixture-bucket:state-20261020.tar.gz' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:' "$LIFECYCLE_CALLS")" -eq 3 ]
  tar -tzf "$LIFECYCLE_REMOTE" | grep -Fxq './renewal/example.com.conf'
}

@test "fresh runner restores no-op then forced publishes to the same templated key" {
  export LIFECYCLE_EXPECTED_KEY=cert-20261020.tar.gz
  cat >"$ROOT/bin/date" <<'MOCK'
#!/usr/bin/env bash
[[ "$#" == 2 && "$1" == -u && "$2" == +%Y%m%d ]] || exit 90
printf '20261020\n'
MOCK
  chmod 755 "$ROOT/bin/date"
  mkdir -m 700 "$ROOT/filename-runner-a" "$ROOT/filename-runner-b"
  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/filename-runner-a"
  execute --s3-key-template 'cert-{YEAR}{MONTH}{DOM}.tar.gz'
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=true'* ]]
  cp "$LIFECYCLE_REMOTE" "$ROOT/filename-baseline.tar.gz"
  : >"$LIFECYCLE_CALLS"

  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/filename-runner-b"
  execute --s3-key-template 'cert-{YEAR}{MONTH}{DOM}.tar.gz'
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=false'* ]]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/filename-baseline.tar.gz"
  : >"$LIFECYCLE_CALLS"

  execute --s3-key-template 'cert-{YEAR}{MONTH}{DOM}.tar.gz' \
    --upload-no-renewal true
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=true'* ]]
  [ "$(grep -Fc 'aws:head-object:fixture-bucket:cert-20261020.tar.gz' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -Fc 'aws:get-object:fixture-bucket:cert-20261020.tar.gz' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -Fc 'aws:put-object:fixture-bucket:cert-20261020.tar.gz' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ -z "$(find "$ROOT/filename-runner-a" -mindepth 1 -print -quit)" ]
  [ -z "$(find "$ROOT/filename-runner-b" -mindepth 1 -print -quit)" ]
}

@test "explicit backup template does not create a second object on successful issue" {
  export LIFECYCLE_EXPECTED_KEY=latest.tar.gz
  cat >"$ROOT/bin/date" <<'MOCK'
#!/usr/bin/env bash
[[ "$#" == 2 && "$1" == -u && "$2" == +%Y%m%d ]] || exit 90
printf '20261020\n'
MOCK
  chmod 755 "$ROOT/bin/date"
  execute --backup-key-template 'archive-{YEAR}{MONTH}{DOM}.tar.gz'
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=true'* ]]
  [ "$(grep -Fc 'aws:put-object:fixture-bucket:latest.tar.gz' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:' "$LIFECYCLE_CALLS")" -eq 3 ]
  ! grep -q 'archive-20261020.tar.gz' "$LIFECYCLE_CALLS"
}

@test "encryption migration under a templated key preserves ciphertext and key identity" {
  require_gpg_ocb
  export LIFECYCLE_EXPECTED_KEY=secure-20261020.tar.gz
  export GPG_SYMMETRIC_KEY=filename-encryption-interoperability-fixture
  cat >"$ROOT/bin/date" <<'MOCK'
#!/usr/bin/env bash
[[ "$#" == 2 && "$1" == -u && "$2" == +%Y%m%d ]] || exit 90
printf '20261020\n'
MOCK
  chmod 755 "$ROOT/bin/date"
  execute --s3-key-template 'secure-{YEAR}{MONTH}{DOM}.tar.gz' \
    --archive-migration plaintext-to-gpg-ocb \
    --archive-migration-backup-confirmed true
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=true'* ]]
  head -c 22 "$LIFECYCLE_REMOTE" |
    cmp -s - <(printf 'CERTBOTBOT-GPG-OCB-V1\n')
  [ "$(grep -Fc 'aws:put-object:fixture-bucket:secure-20261020.tar.gz' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q 'secure-20261020.tar.gz.enc' "$LIFECYCLE_CALLS"
  cp "$LIFECYCLE_REMOTE" "$ROOT/secure-filename-baseline"
  : >"$LIFECYCLE_CALLS"
  execute --s3-key-template 'secure-{YEAR}{MONTH}{DOM}.tar.gz'
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=false'* ]]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/secure-filename-baseline"
  ! grep -q 'secret-inherited' "$LIFECYCLE_CALLS"
}
