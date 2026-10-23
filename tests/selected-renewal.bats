#!/usr/bin/env bats

setup() {
  : "${BASH_STARTER_ARTIFACT:?Select built artifact}"
  ROOT="$(mktemp -d)"
  WORKSPACE="$ROOT/workspace"
  CONFIG="$WORKSPACE/config"
  NAME=example.com
  mkdir -m 700 "$WORKSPACE" "$CONFIG"
  ACCOUNT="$CONFIG/accounts/acme-v02.api.letsencrypt.org/directory/account-id"
  mkdir -p "$ACCOUNT" "$CONFIG/live/$NAME" "$CONFIG/archive/$NAME" "$CONFIG/renewal"
  printf '{"key":"existing"}\n' >"$ACCOUNT/private_key.json"
  printf '{"registration":"existing"}\n' >"$ACCOUNT/regr.json"
  printf '{"meta":"existing"}\n' >"$ACCOUNT/meta.json"
  chmod 600 "$ACCOUNT/"*.json
  local part
  for part in cert chain fullchain privkey; do
    printf 'initial-%s\n' "$part" >"$CONFIG/archive/$NAME/${part}1.pem"
    ln -s "../../archive/$NAME/${part}1.pem" "$CONFIG/live/$NAME/$part.pem"
  done
  cat >"$CONFIG/renewal/$NAME.conf" <<'CONF'
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
  chmod 600 "$CONFIG/renewal/$NAME.conf"
  mkdir -m 700 "$ROOT/bin"
  export RENEW_MOCK_LOG="$ROOT/certbot-commands"
  export RENEW_MOCK_CONFIG="$CONFIG"
  export RENEW_MOCK_ACCOUNT="$ACCOUNT"
  export RENEW_MOCK_SCENARIO=noop
  export RENEW_MOCK_SANS='DNS:example.com, DNS:*.example.com'
  cat >"$ROOT/bin/certbot" <<'MOCK'
#!/usr/bin/env bash
verb="$1"; shift
{
  printf '[%s]' "$verb"
  printf ' <%s>' "$@"
  printf '\n'
} >>"$RENEW_MOCK_LOG"
case "$verb" in
  plugins)
    if [[ "$RENEW_MOCK_SCENARIO" == plugin_failed ]]; then exit 10; fi
    if [[ "$RENEW_MOCK_SCENARIO" == plugin_missing ]]; then
      printf '* standalone\n'
    else
      printf '* dns-route53\n'
    fi
    ;;
  show_account)
    [[ "$RENEW_MOCK_SCENARIO" == account_failed ]] && exit 11
    printf 'known account\n'
    ;;
  renew)
    grep -Fq "archive_dir = $RENEW_MOCK_CONFIG/archive/example.com" \
      "$RENEW_MOCK_CONFIG/renewal/example.com.conf" || exit 12
    case "$RENEW_MOCK_SCENARIO" in
      failed) exit 13 ;;
      changed|bad_after)
        printf 'renewed-cert\n' \
          >"$RENEW_MOCK_CONFIG/archive/example.com/cert1.pem"
        if [[ "$RENEW_MOCK_SCENARIO" == bad_after ]]; then
          rm "$RENEW_MOCK_CONFIG/live/example.com/cert.pem"
        fi
        ;;
      account_changed)
        printf '{"meta":"updated"}\n' \
          >"$RENEW_MOCK_ACCOUNT/meta.json"
        ;;
    esac
    ;;
  *) exit 99 ;;
esac
MOCK
  cat >"$ROOT/bin/openssl" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == x509 ]] || exit 98
[[ "$RENEW_MOCK_SCENARIO" == bad_cert ]] && exit 15
printf 'X509v3 Subject Alternative Name:\n    %s\n' "$RENEW_MOCK_SANS"
MOCK
  chmod 755 "$ROOT/bin/certbot" "$ROOT/bin/openssl"
  PATH="$ROOT/bin:$PATH"
  export PATH
}

teardown() {
  rm -rf -- "$ROOT"
}

renew() {
  run bash -c '
    source "$1" --help >/dev/null
    shift
    certbotbot_provider_renew "$@"
    code=$?
    printf "renewed=%s durable=%s\n" \
      "$CERTBOTBOT_RENEWAL_OCCURRED" "$CERTBOTBOT_DURABLE_CHANGED"
    exit "$code"
  ' _ "$BASH_STARTER_ARTIFACT" "$WORKSPACE" "$NAME" "$@"
}

@test "matching SAN selected renew returns unchanged for a no-op" {
  renew example.com '*.example.com'
  [ "$status" -eq 0 ]
  [ "$output" = 'renewed=false durable=false' ]
  [ "$(wc -l <"$RENEW_MOCK_LOG")" -eq 3 ]
  grep -Fq '[renew]' "$RENEW_MOCK_LOG"
  grep -Fq '<--cert-name> <example.com>' "$RENEW_MOCK_LOG"
  grep -Fq '<--no-directory-hooks>' "$RENEW_MOCK_LOG"
  grep -Fq "<--config-dir> <$CONFIG>" "$RENEW_MOCK_LOG"
  grep -Fxq 'archive_dir = /etc/letsencrypt/archive/example.com' \
    "$CONFIG/renewal/example.com.conf"
}

@test "due renewal changes certificate bytes and durable state" {
  export RENEW_MOCK_SCENARIO=changed
  renew example.com '*.example.com'
  [ "$status" -eq 0 ]
  [ "$output" = 'renewed=true durable=true' ]
  [ "$(cat "$CONFIG/live/example.com/cert.pem")" = renewed-cert ]
  grep -Fxq 'cert = /etc/letsencrypt/live/example.com/cert.pem' \
    "$CONFIG/renewal/example.com.conf"
}

@test "metadata-only updates require publication even without replacement" {
  export RENEW_MOCK_SCENARIO=account_changed
  renew example.com '*.example.com'
  [ "$status" -eq 0 ]
  [ "$output" = 'renewed=false durable=true' ]
  grep -Fq '"updated"' "$ACCOUNT/meta.json"
}

@test "SAN order does not affect equality" {
  renew '*.example.com' example.com
  [ "$status" -eq 0 ]
  [ "$output" = 'renewed=false durable=false' ]
}

@test "wildcard enabled after a single-SAN certificate is blocked" {
  export RENEW_MOCK_SANS='DNS:example.com'
  renew example.com '*.example.com'
  [ "$status" -eq 65 ]
  [ ! -e "$RENEW_MOCK_LOG" ]
  [[ "$output" == *'renewed= durable='* ]]
}

@test "wildcard disabled on existing two-name certificate is blocked" {
  renew example.com
  [ "$status" -eq 65 ]
  [ ! -e "$RENEW_MOCK_LOG" ]
}

@test "ordinary renewal refuses valid unrelated SAN drift and duplicate inputs" {
  renew example.com unrelated.org
  [ "$status" -eq 65 ]
  renew example.com example.com
  [ "$status" -eq 64 ]
  [ ! -e "$RENEW_MOCK_LOG" ]
}

@test "certificate with unsupported SAN type is refused" {
  export RENEW_MOCK_SANS='DNS:example.com, IP Address:127.0.0.1'
  renew example.com '*.example.com'
  [ "$status" -eq 65 ]
  [ ! -e "$RENEW_MOCK_LOG" ]
}

@test "unparseable certificate fails before any Certbot call" {
  export RENEW_MOCK_SCENARIO=bad_cert
  renew example.com '*.example.com'
  [ "$status" -eq 65 ]
  [ ! -e "$RENEW_MOCK_LOG" ]
}

@test "Certbot renewal failure never supplies success results" {
  export RENEW_MOCK_SCENARIO=failed
  renew example.com '*.example.com'
  [ "$status" -eq 74 ]
  [[ "$output" == *'renewed= durable='* ]]
  grep -Fq '[renew]' "$RENEW_MOCK_LOG"
}

@test "post-renewal broken lineage fails without claiming success" {
  export RENEW_MOCK_SCENARIO=bad_after
  renew example.com '*.example.com'
  [ "$status" -eq 65 ]
  [[ "$output" == *'renewed= durable='* ]]
}

@test "missing plugin blocks account probe and renewal" {
  export RENEW_MOCK_SCENARIO=plugin_missing
  renew example.com '*.example.com'
  [ "$status" -eq 69 ]
  [ "$(wc -l <"$RENEW_MOCK_LOG")" -eq 1 ]
}

@test "unrecognized account blocks renewal" {
  export RENEW_MOCK_SCENARIO=account_failed
  renew example.com '*.example.com'
  [ "$status" -eq 69 ]
  [ "$(wc -l <"$RENEW_MOCK_LOG")" -eq 2 ]
}

@test "missing account blocks any Certbot process" {
  rm -rf "$CONFIG/accounts"
  renew example.com '*.example.com'
  [ "$status" -eq 65 ]
  [ ! -e "$RENEW_MOCK_LOG" ]
}

@test "unsupported renewal hooks fail before any Certbot process" {
  printf 'pre_hook = /bin/true\n' >>"$CONFIG/renewal/example.com.conf"
  renew example.com '*.example.com'
  [ "$status" -eq 65 ]
  [ ! -e "$RENEW_MOCK_LOG" ]
}

@test "failed canonical path mapping blocks Certbot renewal" {
  sed -i 's|/etc/letsencrypt/archive/example.com|/tmp/untrusted|' \
    "$CONFIG/renewal/example.com.conf"
  renew example.com '*.example.com'
  [ "$status" -eq 65 ]
  ! grep -q '^\[renew\]' "$RENEW_MOCK_LOG" 2>/dev/null
}

@test "the provider never launches a global renew or account registration" {
  renew example.com '*.example.com'
  [ "$status" -eq 0 ]
  grep -Fq '[renew] <--cert-name> <example.com>' "$RENEW_MOCK_LOG"
  ! grep -Eq '^\[(register|certonly|run)\]' "$RENEW_MOCK_LOG"
  ! grep -Fq '<--force-renewal>' "$RENEW_MOCK_LOG"
}

