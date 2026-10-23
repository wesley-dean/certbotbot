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
  printf '{"key":"original"}\n' >"$ACCOUNT/private_key.json"
  printf '{"registration":"original"}\n' >"$ACCOUNT/regr.json"
  printf '{"metadata":"original"}\n' >"$ACCOUNT/meta.json"
  chmod 600 "$ACCOUNT/"*.json
  local part
  for part in cert chain fullchain privkey; do
    printf 'original-%s\n' "$part" >"$CONFIG/archive/$NAME/${part}1.pem"
    ln -s "../../archive/$NAME/${part}1.pem" "$CONFIG/live/$NAME/$part.pem"
  done
  printf 'old-apex\n' >"$CONFIG/archive/$NAME/cert1.pem"
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
  mkdir "$ROOT/bin"
  export SAN_MOCK_LOG="$ROOT/provider-log"
  export SAN_MOCK_CONFIG="$CONFIG"
  export SAN_MOCK_SCENARIO=changed
  cat >"$ROOT/bin/certbot" <<'MOCK'
#!/usr/bin/env bash
verb="$1"; shift
{
  printf '[%s]' "$verb"
  printf ' <%s>' "$@"
  printf '\n'
} >>"$SAN_MOCK_LOG"
case "$verb" in
  plugins)
    [[ "$SAN_MOCK_SCENARIO" == plugin_failed ]] && exit 3
    if [[ "$SAN_MOCK_SCENARIO" == plugin_missing ]]; then
      printf '* standalone\n'
    else
      printf '* dns-route53\n'
    fi
    ;;
  show_account)
    [[ "$SAN_MOCK_SCENARIO" == account_failed ]] && exit 3
    ;;
  certonly)
    grep -Fxq "archive_dir = $SAN_MOCK_CONFIG/archive/example.com" \
      "$SAN_MOCK_CONFIG/renewal/example.com.conf" || exit 4
    [[ "$SAN_MOCK_SCENARIO" == certonly_failed ]] && exit 5
    [[ "$SAN_MOCK_SCENARIO" == unchanged ]] && exit 0
    value='new-dual'
    case "$SAN_MOCK_SCENARIO" in
      wrong_sans) value='new-unexpected' ;;
      changed_to_apex) value='new-apex' ;;
      changed_to_wildcard) value='new-wildcard' ;;
    esac
    printf '%s\n' "$value" >"$SAN_MOCK_CONFIG/archive/example.com/cert2.pem"
    rm "$SAN_MOCK_CONFIG/live/example.com/cert.pem"
    ln -s ../../archive/example.com/cert2.pem \
      "$SAN_MOCK_CONFIG/live/example.com/cert.pem"
    if [[ "$SAN_MOCK_SCENARIO" == account_replaced ]]; then
      mv "$SAN_MOCK_CONFIG/accounts/acme-v02.api.letsencrypt.org/directory/account-id" \
        "$SAN_MOCK_CONFIG/accounts/acme-v02.api.letsencrypt.org/directory/other-id"
    fi
    if [[ "$SAN_MOCK_SCENARIO" == missing_lineage ]]; then
      rm "$SAN_MOCK_CONFIG/live/example.com/fullchain.pem"
    fi
    ;;
  renew) ;;
  *) exit 99 ;;
esac
MOCK
  cat >"$ROOT/bin/openssl" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == x509 ]] || exit 98
case "$(cat "$3")" in
  old-apex|new-apex) names='DNS:example.com' ;;
  old-dual|new-dual) names='DNS:example.com, DNS:*.example.com' ;;
  old-wildcard|new-wildcard) names='DNS:*.example.com' ;;
  new-unexpected) names='DNS:example.com, DNS:bad.example.net' ;;
  *) exit 99 ;;
esac
printf 'X509v3 Subject Alternative Name:\n    %s\n' "$names"
MOCK
  chmod 755 "$ROOT/bin/certbot" "$ROOT/bin/openssl"
  PATH="$ROOT/bin:$PATH"
  export PATH
}

teardown() {
  rm -rf -- "$ROOT"
}

reconcile() {
  run bash -c '
    source "$1" --help >/dev/null
    shift
    certbotbot_provider_existing "$@"
    status=$?
    printf "renewed=%s durable=%s\n" \
      "$CERTBOTBOT_RENEWAL_OCCURRED" "$CERTBOTBOT_DURABLE_CHANGED"
    exit "$status"
  ' _ "$BASH_STARTER_ARTIFACT" "$WORKSPACE" "$NAME" "$@"
}

@test "apex-only to dual SAN replaces exactly the existing named lineage" {
  reconcile example.com '*.example.com'
  [ "$status" -eq 0 ]
  [ "$output" = 'renewed=true durable=true' ]
  [ "$(wc -l <"$SAN_MOCK_LOG")" -eq 3 ]
  grep -Fq '[certonly]' "$SAN_MOCK_LOG"
  grep -Fq '<--renew-with-new-domains>' "$SAN_MOCK_LOG"
  grep -Fq '<--cert-name> <example.com>' "$SAN_MOCK_LOG"
  grep -Fq '<--account> <account-id>' "$SAN_MOCK_LOG"
  grep -Fq '<-d> <example.com> <-d> <*.example.com>' "$SAN_MOCK_LOG"
  grep -Fxq 'archive_dir = /etc/letsencrypt/archive/example.com' \
    "$CONFIG/renewal/example.com.conf"
  [ -f "$CONFIG/archive/example.com/cert1.pem" ]
  [ -f "$CONFIG/archive/example.com/cert2.pem" ]
  [ "$(readlink "$CONFIG/live/example.com/cert.pem")" = '../../archive/example.com/cert2.pem' ]
}

@test "dual SAN to apex-only drops wildcard on same selected lineage" {
  printf 'old-dual\n' >"$CONFIG/archive/example.com/cert1.pem"
  export SAN_MOCK_SCENARIO=changed_to_apex
  reconcile example.com
  [ "$status" -eq 0 ]
  [ "$output" = 'renewed=true durable=true' ]
  grep -Fq '[certonly]' "$SAN_MOCK_LOG"
  grep -Fq '<-d> <example.com>' "$SAN_MOCK_LOG"
  ! grep -Fq '<-d> <*.example.com>' "$SAN_MOCK_LOG"
}

@test "existing exact SAN match uses ordinary selected renew without certonly" {
  reconcile example.com
  [ "$status" -eq 0 ]
  [ "$output" = 'renewed=false durable=false' ]
  grep -Fq '[renew] <--cert-name> <example.com>' "$SAN_MOCK_LOG"
  ! grep -q '^\[certonly\]' "$SAN_MOCK_LOG"
}

@test "requested SAN order does not trigger replacement" {
  printf 'old-dual\n' >"$CONFIG/archive/example.com/cert1.pem"
  reconcile '*.example.com' example.com
  [ "$status" -eq 0 ]
  [ "$output" = 'renewed=false durable=false' ]
  ! grep -q '^\[certonly\]' "$SAN_MOCK_LOG"
}

@test "wildcard-only to apex-and-wildcard stays in same lineage" {
  printf 'old-wildcard\n' >"$CONFIG/archive/example.com/cert1.pem"
  reconcile '*.example.com' example.com
  [ "$status" -eq 0 ]
  [ "$output" = 'renewed=true durable=true' ]
  grep -Fq '<--cert-name> <example.com>' "$SAN_MOCK_LOG"
}

@test "a simulated success without changed cert material fails closed" {
  export SAN_MOCK_SCENARIO=unchanged
  reconcile example.com '*.example.com'
  [ "$status" -eq 65 ]
  [[ "$output" == *'renewed= durable='* ]]
  grep -Fq '[certonly]' "$SAN_MOCK_LOG"
}

@test "failed Certbot change never returns publishable status" {
  export SAN_MOCK_SCENARIO=certonly_failed
  reconcile example.com '*.example.com'
  [ "$status" -eq 74 ]
  [[ "$output" == *'renewed= durable='* ]]
  grep -Fxq "archive_dir = $CONFIG/archive/example.com" \
    "$CONFIG/renewal/example.com.conf"
}

@test "unexpected post-issuance SAN is refused despite successful Certbot" {
  export SAN_MOCK_SCENARIO=wrong_sans
  reconcile example.com '*.example.com'
  [ "$status" -eq 65 ]
  [[ "$output" == *'renewed= durable='* ]]
}

@test "replacement of the restored ACME account identity is refused" {
  export SAN_MOCK_SCENARIO=account_replaced
  reconcile example.com '*.example.com'
  [ "$status" -eq 65 ]
  [[ "$output" == *'renewed= durable='* ]]
}

@test "a broken post-change lineage cannot be accepted" {
  export SAN_MOCK_SCENARIO=missing_lineage
  reconcile example.com '*.example.com'
  [ "$status" -eq 65 ]
}

@test "unrelated SAN and malformed SAN input do not invoke Certbot" {
  reconcile example.com unrelated.org
  [ "$status" -eq 64 ]
  reconcile 'example.com; touch /tmp/bad'
  [ "$status" -eq 64 ]
  reconcile example.com example.com
  [ "$status" -eq 64 ]
  [ ! -e "$SAN_MOCK_LOG" ]
}

@test "missing or incomplete restored account stops before provider calls" {
  rm "$ACCOUNT/private_key.json"
  reconcile example.com '*.example.com'
  [ "$status" -eq 65 ]
  [ ! -e "$SAN_MOCK_LOG" ]
}

@test "bad renewal path and hook directive prevent provider invocation" {
  printf 'post_hook = /bin/sh -c anything\n' >>"$CONFIG/renewal/example.com.conf"
  reconcile example.com '*.example.com'
  [ "$status" -eq 65 ]
  [ ! -e "$SAN_MOCK_LOG" ]
}

@test "missing Route53 plugin prevents account probe and certonly" {
  export SAN_MOCK_SCENARIO=plugin_missing
  reconcile example.com '*.example.com'
  [ "$status" -eq 69 ]
  [ "$(wc -l <"$SAN_MOCK_LOG")" -eq 1 ]
}

@test "unrecognized account prevents certonly" {
  export SAN_MOCK_SCENARIO=account_failed
  reconcile example.com '*.example.com'
  [ "$status" -eq 69 ]
  [ "$(wc -l <"$SAN_MOCK_LOG")" -eq 2 ]
}

@test "invalid workspace permissions forbid provider calls" {
  chmod 755 "$WORKSPACE"
  reconcile example.com '*.example.com'
  [ "$status" -eq 64 ]
  [ ! -e "$SAN_MOCK_LOG" ]
}

@test "provider never chooses duplicate, expand, force-renewal or register" {
  reconcile example.com '*.example.com'
  [ "$status" -eq 0 ]
  ! grep -Eq '^\[(register|run)\]' "$SAN_MOCK_LOG"
  ! grep -Eq '<--(duplicate|expand|force-renewal)>' "$SAN_MOCK_LOG"
}

@test "public lifecycle and S3 publication remain unavailable" {
  reconcile example.com '*.example.com'
  [ "$status" -eq 0 ]
  run "$BASH_STARTER_ARTIFACT" --s3-bucket fixture-bucket example.com
  [ "$status" -eq 69 ]
}
