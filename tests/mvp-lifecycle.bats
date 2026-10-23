#!/usr/bin/env bats

setup() {
  : "${BASH_STARTER_ARTIFACT:?Select standalone public artifact}"
  ROOT="$(mktemp -d)"
  export TMPDIR="$ROOT/tmp"
  mkdir -m 700 "$TMPDIR" "$ROOT/seed"
  ROOT_ACCOUNT="$ROOT/seed/accounts/acme-v02.api.letsencrypt.org/directory/account-id"
  mkdir -p "$ROOT_ACCOUNT"
  printf '{"account":"existing-key"}\n' >"$ROOT_ACCOUNT/private_key.json"
  printf '{"account":"existing-registration"}\n' >"$ROOT_ACCOUNT/regr.json"
  printf '{"account":"existing-metadata"}\n' >"$ROOT_ACCOUNT/meta.json"
  chmod 600 "$ROOT_ACCOUNT/"*.json
  export S3_MOCK_REMOTE="$ROOT/remote.tar.gz"
  export S3_MOCK_CALLS="$ROOT/s3-calls"
  export S3_MOCK_MODE=ok
  export CERTBOT_MOCK_CALLS="$ROOT/certbot-calls"
  export CERTBOT_MOCK_MODE=ok
  export EXPECTED_S3_KEY=latest.tar.gz
  tar --format=ustar --sort=name --owner=0 --group=0 --numeric-owner \
    -czf "$S3_MOCK_REMOTE" -C "$ROOT/seed" .
  mkdir "$ROOT/bin"
  cat >"$ROOT/bin/aws" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == --no-cli-pager && "$2" == s3api ]] || exit 91
action="$3"
shift 3
bucket='' key='' dest='' body=''
while (( $# > 0 )); do
  case "$1" in
    --bucket) bucket="$2"; shift 2 ;;
    --key) key="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --output|--checksum-algorithm|--content-type)
      shift 2 ;;
    --*) exit 93 ;;
    *) dest="$1"; shift ;;
  esac
done
{
  printf '%s <%s> <%s>\n' "$action" "$bucket" "$key"
} >>"$S3_MOCK_CALLS"
[[ "$bucket" == seeded-bucket ]] || exit 94
if [[ "$action" != head-bucket && "$key" != "$EXPECTED_S3_KEY" ]]; then
  exit 95
fi
case "$action" in
  head-object)
    if [[ "$S3_MOCK_MODE" == missing || ! -f "$S3_MOCK_REMOTE" ]]; then
      printf 'An error occurred (404) when calling the HeadObject operation\n' >&2
      exit 255
    fi
    ;;
  head-bucket) ;;
  get-object)
    if [[ "$S3_MOCK_MODE" == failed_get ]]; then exit 255; fi
    cp -- "$S3_MOCK_REMOTE" "$dest"
    ;;
  put-object)
    [[ -f "$body" ]] || exit 96
    [[ "$S3_MOCK_MODE" == failed_put ]] && exit 254
    cp -- "$body" "$S3_MOCK_REMOTE"
    ;;
  *) exit 97 ;;
esac
MOCK
  cat >"$ROOT/bin/certbot" <<'MOCK'
#!/usr/bin/env bash
verb="$1"
shift
config='' selected='' account='' names=()
while (( $# > 0 )); do
  case "$1" in
    --config-dir) config="$2"; shift 2 ;;
    --cert-name) selected="$2"; shift 2 ;;
    --account) account="$2"; shift 2 ;;
    -d) names+=("$2"); shift 2 ;;
    --work-dir|--logs-dir|--server) shift 2 ;;
    --preferred-challenges) shift 2 ;;
    --dns-route53|--no-directory-hooks|--non-interactive|--authenticators|--renew-with-new-domains)
      shift ;;
    *) exit 97 ;;
  esac
done
printf '%s <%s> <%s>\n' "$verb" "$selected" "$account" \
  >>"$CERTBOT_MOCK_CALLS"
case "$verb" in
  plugins)
    if [[ "$CERTBOT_MOCK_MODE" == no_plugin ]]; then
      printf '* standalone\n'
    else
      printf '* dns-route53\n'
    fi
    exit 0
    ;;
  show_account)
    [[ "$CERTBOT_MOCK_MODE" == account_unreadable ]] && exit 2
    [[ "$account" == account-id ]] || exit 3
    [[ -f "$config/accounts/acme-v02.api.letsencrypt.org/directory/$account/regr.json" ]] || exit 3
    exit 0
    ;;
  renew)
    [[ "$selected" == example.com ]] || exit 4
    [[ "$CERTBOT_MOCK_MODE" == failed_renew ]] && exit 10
    [[ "$CERTBOT_MOCK_MODE" == renew_update ]] || exit 0
    names=(example.com '*.example.com')
    ;;
  certonly)
    [[ "$selected" == example.com ]] || exit 4
    [[ "$account" == account-id ]] || exit 5
    [[ "$CERTBOT_MOCK_MODE" == failed_issue ]] && exit 10
    ;;
  *) exit 98 ;;
esac
mkdir -p "$config/archive/$selected" "$config/live/$selected" "$config/renewal"
version=1
[[ -e "$config/archive/$selected/cert1.pem" ]] && version=2
archive="$config/archive/$selected"
live="$config/live/$selected"
extra=''
for domain in "${names[@]}"; do
  if [[ -n "$extra" ]]; then extra+=,; fi
  extra+="DNS:$domain"
done
if [[ "$CERTBOT_MOCK_MODE" == bad_sans ]]; then extra='DNS:unrelated.org'; fi
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -nodes -days 7 -subj /CN=example.com -addext "subjectAltName=$extra" \
  -keyout "$archive/privkey$version.pem" -out "$archive/cert$version.pem" \
  >/dev/null 2>&1 || exit 16
cp -- "$archive/cert$version.pem" "$archive/fullchain$version.pem"
cp -- "$archive/cert$version.pem" "$archive/chain$version.pem"
if [[ "$CERTBOT_MOCK_MODE" == wrong_key ]]; then
  openssl ecparam -name prime256v1 -genkey -noout \
    -out "$archive/privkey$version.pem" >/dev/null 2>&1
fi
if [[ "$CERTBOT_MOCK_MODE" == broken_fullchain ]]; then
  printf 'not a certificate\n' >"$archive/fullchain$version.pem"
fi
chmod 600 "$archive/privkey$version.pem"
for part in cert privkey chain fullchain; do
  rm -f -- "$live/$part.pem"
  ln -s "../../archive/$selected/${part}$version.pem" "$live/$part.pem"
done
if [[ "$version" == 1 ]]; then
  cat >"$config/renewal/$selected.conf" <<CONF
version = 5.8.0
archive_dir = $config/archive/$selected
cert = $config/live/$selected/cert.pem
privkey = $config/live/$selected/privkey.pem
chain = $config/live/$selected/chain.pem
fullchain = $config/live/$selected/fullchain.pem
[renewalparams]
account = account-id
authenticator = dns-route53
server = https://acme-v02.api.letsencrypt.org/directory
CONF
  chmod 600 "$config/renewal/$selected.conf"
fi
exit 0
MOCK
  chmod 755 "$ROOT/bin/aws" "$ROOT/bin/certbot"
  PATH="$ROOT/bin:$PATH"
  export PATH
}

teardown() {
  rm -rf -- "$ROOT"
}

public_run() {
  run "$BASH_STARTER_ARTIFACT" --s3-bucket seeded-bucket "$@"
  printf "# MVP DIAG status=%s output=%s\n" "$status" "$output" >&3
}

@test "first public invocation issues selected cert and publishes seeded key" {
  public_run example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'seeded-bucket/latest.tar.gz'* ]]
  [ "$(grep -c '^put-object ' "$S3_MOCK_CALLS")" -eq 1 ]
  grep -Fq 'certonly <example.com> <account-id>' "$CERTBOT_MOCK_CALLS"
  tar -tzf "$S3_MOCK_REMOTE" | grep -Fq './renewal/example.com.conf'
  mkdir "$ROOT/check"
  tar -xzf "$S3_MOCK_REMOTE" -C "$ROOT/check"
  grep -Fq 'archive_dir = /etc/letsencrypt/archive/example.com' \
    "$ROOT/check/renewal/example.com.conf"
  cmp "$ROOT_ACCOUNT/regr.json" \
    "$ROOT/check/accounts/acme-v02.api.letsencrypt.org/directory/account-id/regr.json"
  [ -z "$(find "$TMPDIR" -mindepth 1 -print)" ]
}

@test "second independent public invocation reuses account and skips unchanged upload" {
  public_run example.com
  [ "$status" -eq 0 ]
  cp "$S3_MOCK_REMOTE" "$ROOT/issued"
  : >"$S3_MOCK_CALLS"
  : >"$CERTBOT_MOCK_CALLS"
  public_run example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'unchanged'* ]]
  [ "$(grep -c '^get-object ' "$S3_MOCK_CALLS")" -eq 1 ]
  ! grep -q '^put-object ' "$S3_MOCK_CALLS"
  grep -Fq 'renew <example.com> <account-id>' "$CERTBOT_MOCK_CALLS"
  cmp "$ROOT/issued" "$S3_MOCK_REMOTE"
  [ -z "$(find "$TMPDIR" -mindepth 1 -print)" ]
}

@test "forced no-op publishes a validated unchanged archive at same key" {
  public_run example.com
  [ "$status" -eq 0 ]
  : >"$S3_MOCK_CALLS"
  public_run --upload-no-renewal true example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'uploaded'* ]]
  [ "$(grep -c '^put-object ' "$S3_MOCK_CALLS")" -eq 1 ]
  [ "$(grep -c '^get-object ' "$S3_MOCK_CALLS")" -eq 1 ]
}

@test "existing selected renewal updates same account and lineage" {
  public_run example.com
  [ "$status" -eq 0 ]
  export CERTBOT_MOCK_MODE=renew_update
  : >"$S3_MOCK_CALLS"
  public_run example.com
  [ "$status" -eq 0 ]
  [ "$(grep -c '^put-object ' "$S3_MOCK_CALLS")" -eq 1 ]
  mkdir "$ROOT/second"
  tar -xzf "$S3_MOCK_REMOTE" -C "$ROOT/second"
  [ -f "$ROOT/second/archive/example.com/cert2.pem" ]
  [ "$(readlink "$ROOT/second/live/example.com/cert.pem")" = '../../archive/example.com/cert2.pem' ]
  cmp "$ROOT_ACCOUNT/regr.json" \
    "$ROOT/second/accounts/acme-v02.api.letsencrypt.org/directory/account-id/regr.json"
}

@test "SAN policy transition preserves original selected lineage and account" {
  public_run --include-subdomains false example.com
  [ "$status" -eq 0 ]
  : >"$CERTBOT_MOCK_CALLS"
  public_run example.com
  [ "$status" -eq 0 ]
  grep -Fq 'certonly <example.com> <account-id>' "$CERTBOT_MOCK_CALLS"
  mkdir "$ROOT/change"
  tar -xzf "$S3_MOCK_REMOTE" -C "$ROOT/change"
  [ -f "$ROOT/change/archive/example.com/cert2.pem" ]
  [ ! -e "$ROOT/change/renewal/example.com-0001.conf" ]
}

@test "missing seeded object fails before Certbot or PutObject" {
  export S3_MOCK_MODE=missing
  public_run example.com
  [ "$status" -eq 66 ]
  [ ! -e "$CERTBOT_MOCK_CALLS" ]
  ! grep -q '^put-object ' "$S3_MOCK_CALLS"
}

@test "corrupt seeded archive never reaches Certbot or upload" {
  printf 'corrupt\n' >"$S3_MOCK_REMOTE"
  public_run example.com
  [ "$status" -ne 0 ]
  [ ! -e "$CERTBOT_MOCK_CALLS" ]
  ! grep -q '^put-object ' "$S3_MOCK_CALLS"
}

@test "missing seeded ACME account cannot initiate certificate issuance" {
  rm -rf "$ROOT/seed/accounts"
  tar -czf "$S3_MOCK_REMOTE" -C "$ROOT/seed" .
  public_run example.com
  [ "$status" -ne 0 ]
  [ ! -e "$CERTBOT_MOCK_CALLS" ]
  ! grep -q '^put-object ' "$S3_MOCK_CALLS"
}

@test "failed selected Certbot issuance never replaces seeded archive" {
  cp "$S3_MOCK_REMOTE" "$ROOT/original"
  export CERTBOT_MOCK_MODE=failed_issue
  public_run example.com
  [ "$status" -ne 0 ]
  cmp "$ROOT/original" "$S3_MOCK_REMOTE"
  ! grep -q '^put-object ' "$S3_MOCK_CALLS"
}

@test "missing Route53 plugin blocks account usage and publication" {
  export CERTBOT_MOCK_MODE=no_plugin
  public_run example.com
  [ "$status" -ne 0 ]
  ! grep -q '^put-object ' "$S3_MOCK_CALLS"
}

@test "wrong certificate SANs never publish newly issued state" {
  cp "$S3_MOCK_REMOTE" "$ROOT/original"
  export CERTBOT_MOCK_MODE=bad_sans
  public_run example.com
  [ "$status" -ne 0 ]
  cmp "$ROOT/original" "$S3_MOCK_REMOTE"
  ! grep -q '^put-object ' "$S3_MOCK_CALLS"
}

@test "private key mismatch never authorizes publication" {
  cp "$S3_MOCK_REMOTE" "$ROOT/original"
  export CERTBOT_MOCK_MODE=wrong_key
  public_run example.com
  [ "$status" -ne 0 ]
  cmp "$ROOT/original" "$S3_MOCK_REMOTE"
  ! grep -q '^put-object ' "$S3_MOCK_CALLS"
}

@test "invalid fullchain blocks publication" {
  cp "$S3_MOCK_REMOTE" "$ROOT/original"
  export CERTBOT_MOCK_MODE=broken_fullchain
  public_run example.com
  [ "$status" -ne 0 ]
  cmp "$ROOT/original" "$S3_MOCK_REMOTE"
  ! grep -q '^put-object ' "$S3_MOCK_CALLS"
}

@test "failed S3 publication returns nonzero without success claim" {
  cp "$S3_MOCK_REMOTE" "$ROOT/original"
  export S3_MOCK_MODE=failed_put
  public_run example.com
  [ "$status" -eq 74 ]
  [[ "$output" != *'uploaded'* ]]
  cmp "$ROOT/original" "$S3_MOCK_REMOTE"
}

@test "chosen alternative key is the same for retrieval and publication" {
  export EXPECTED_S3_KEY=chosen.tar.gz
  public_run --s3-key chosen.tar.gz example.com
  [ "$status" -eq 0 ]
  [ "$(grep -c '^put-object <seeded-bucket> <chosen.tar.gz>' "$S3_MOCK_CALLS")" -eq 1 ]
  ! grep -q 'latest.tar.gz' "$S3_MOCK_CALLS"
}

@test "a completed run leaves no retained private workspace" {
  public_run example.com
  [ "$status" -eq 0 ]
  [ -z "$(find "$TMPDIR" -mindepth 1 -print)" ]
}
