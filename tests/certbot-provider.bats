#!/usr/bin/env bats

setup() {
  : "${BASH_STARTER_ARTIFACT:?Artifact path is required}"
  ROOT="$(mktemp -d)"
  WORKSPACE="$ROOT/worker"
  mkdir -m 700 "$WORKSPACE" "$WORKSPACE/config"
  ACCOUNT="$WORKSPACE/config/accounts/acme-v02.api.letsencrypt.org/directory/account-abc"
  mkdir -p "$ACCOUNT"
  printf '%s\n' '{"fixture":"key"}' >"$ACCOUNT/private_key.json"
  printf '%s\n' '{"fixture":"reg"}' >"$ACCOUNT/regr.json"
  printf '%s\n' '{"fixture":"meta"}' >"$ACCOUNT/meta.json"
  chmod 600 "$ACCOUNT/"*.json
  mkdir "$ROOT/bin"
  export CERTBOT_PROVIDER_MOCK_LOG="$ROOT/requests"
  export CERTBOT_PROVIDER_MOCK_SCENARIO=ok
  cat >"$ROOT/bin/certbot" <<'MOCK'
#!/usr/bin/env bash
verb="$1"
shift
{
  printf '[%s]' "$verb"
  printf ' <%s>' "$@"
  printf '\n'
} >>"$CERTBOT_PROVIDER_MOCK_LOG"
case "$verb" in
  plugins)
    [[ "$CERTBOT_PROVIDER_MOCK_SCENARIO" == plugin_error ]] && exit 2
    if [[ "$CERTBOT_PROVIDER_MOCK_SCENARIO" == no_plugin ]]; then
      printf '%s\n' '* standalone'
    else
      printf '%s\n' '* dns-route53'
    fi
    ;;
  show_account)
    [[ "$CERTBOT_PROVIDER_MOCK_SCENARIO" == bad_account ]] && exit 2
    printf '%s\n' 'mock account status'
    ;;
  certonly)
    [[ "$CERTBOT_PROVIDER_MOCK_SCENARIO" == issue_error ]] && exit 2
    printf '%s\n' 'mock issue success'
    ;;
  *) exit 99 ;;
esac
MOCK
  chmod 755 "$ROOT/bin/certbot"
  PATH="$ROOT/bin:$PATH"
  export PATH
}

teardown() {
  rm -rf -- "$ROOT"
}

issue() {
  run bash -c '
    source "$1" --help >/dev/null
    shift
    certbotbot_provider_issue "$@"
  ' _ "$BASH_STARTER_ARTIFACT" "$WORKSPACE" "$@"
}

@test "issue uses selected lineage and exact SANs in a private runtime" {
  issue example.com example.com '*.example.com'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(wc -l <"$CERTBOT_PROVIDER_MOCK_LOG")" -eq 3 ]
  sed -n '1p' "$CERTBOT_PROVIDER_MOCK_LOG" | grep -Fq '[plugins]'
  sed -n '2p' "$CERTBOT_PROVIDER_MOCK_LOG" | grep -Fq '[show_account]'
  sed -n '3p' "$CERTBOT_PROVIDER_MOCK_LOG" | grep -Fq '[certonly]'
  grep -Fq '<--cert-name> <example.com>' "$CERTBOT_PROVIDER_MOCK_LOG"
  grep -Fq '<-d> <example.com> <-d> <*.example.com>' "$CERTBOT_PROVIDER_MOCK_LOG"
  grep -Fq '<--account> <account-abc>' "$CERTBOT_PROVIDER_MOCK_LOG"
  grep -Fq '<--dns-route53>' "$CERTBOT_PROVIDER_MOCK_LOG"
  grep -Fq '<--no-directory-hooks>' "$CERTBOT_PROVIDER_MOCK_LOG"
  grep -Fq '<--non-interactive>' "$CERTBOT_PROVIDER_MOCK_LOG"
  grep -Fq '<--preferred-challenges> <dns-01>' "$CERTBOT_PROVIDER_MOCK_LOG"
  grep -Fq "<--config-dir> <$WORKSPACE/config>" "$CERTBOT_PROVIDER_MOCK_LOG"
  grep -Fq "<--work-dir> <$WORKSPACE/work>" "$CERTBOT_PROVIDER_MOCK_LOG"
  grep -Fq "<--logs-dir> <$WORKSPACE/logs>" "$CERTBOT_PROVIDER_MOCK_LOG"
  [ "$(stat -c %a "$WORKSPACE/work")" = 700 ]
  [ "$(stat -c %a "$WORKSPACE/logs")" = 700 ]
}

@test "one literal wildcard SAN stays one literal wildcard" {
  issue example.com '*.example.com'
  [ "$status" -eq 0 ]
  grep -Fq '<-d> <*.example.com>' "$CERTBOT_PROVIDER_MOCK_LOG"
  ! grep -Fq '<-d> <example.com>' "$CERTBOT_PROVIDER_MOCK_LOG"
}

@test "wildcard apex pair permits either input ordering" {
  issue example.com '*.example.com' example.com
  [ "$status" -eq 0 ]
  grep -Fq '<-d> <*.example.com> <-d> <example.com>' "$CERTBOT_PROVIDER_MOCK_LOG"
}

@test "unrelated and duplicate SAN pairs fail without provider calls" {
  issue example.com example.com unrelated.org
  [ "$status" -eq 64 ]
  [ ! -e "$CERTBOT_PROVIDER_MOCK_LOG" ]
  issue example.com example.com example.com
  [ "$status" -eq 64 ]
  [ ! -e "$CERTBOT_PROVIDER_MOCK_LOG" ]
}

@test "unsafe SAN and invalid cert name fail before provider calls" {
  issue example.com 'example.com;touch /tmp/unwanted'
  [ "$status" -eq 64 ]
  issue '*.example.com' example.com
  [ "$status" -eq 64 ]
  [ ! -e "$CERTBOT_PROVIDER_MOCK_LOG" ]
}

@test "no SAN or too many SANs are rejected" {
  issue example.com
  [ "$status" -eq 64 ]
  issue example.com example.com '*.example.com' third.example.com
  [ "$status" -eq 64 ]
  [ ! -e "$CERTBOT_PROVIDER_MOCK_LOG" ]
}

@test "missing account stops before any Certbot call" {
  rm -rf -- "$WORKSPACE/config/accounts"
  issue example.com example.com
  [ "$status" -eq 65 ]
  [ ! -e "$CERTBOT_PROVIDER_MOCK_LOG" ]
}

@test "an incomplete lineage cannot be overwritten or numbered" {
  mkdir -p "$WORKSPACE/config/renewal"
  printf 'incomplete\n' >"$WORKSPACE/config/renewal/example.com.conf"
  issue example.com example.com
  [ "$status" -eq 65 ]
  [ ! -e "$CERTBOT_PROVIDER_MOCK_LOG" ]
}

@test "missing Route53 plugin aborts before checking account" {
  export CERTBOT_PROVIDER_MOCK_SCENARIO=no_plugin
  issue example.com example.com
  [ "$status" -eq 69 ]
  [ "$(wc -l <"$CERTBOT_PROVIDER_MOCK_LOG")" -eq 1 ]
}

@test "failed plugin discovery aborts before account probe" {
  export CERTBOT_PROVIDER_MOCK_SCENARIO=plugin_error
  issue example.com example.com
  [ "$status" -eq 69 ]
  [ "$(wc -l <"$CERTBOT_PROVIDER_MOCK_LOG")" -eq 1 ]
}

@test "Certbot account recognition failure aborts before issuance" {
  export CERTBOT_PROVIDER_MOCK_SCENARIO=bad_account
  issue example.com example.com
  [ "$status" -eq 69 ]
  [ "$(wc -l <"$CERTBOT_PROVIDER_MOCK_LOG")" -eq 2 ]
  ! grep -q '^\[certonly\]' "$CERTBOT_PROVIDER_MOCK_LOG"
}

@test "Certbot certificate failure returns nonzero with fixed diagnostic" {
  export CERTBOT_PROVIDER_MOCK_SCENARIO=issue_error
  issue example.com example.com
  [ "$status" -eq 74 ]
  [ "$(wc -l <"$CERTBOT_PROVIDER_MOCK_LOG")" -eq 3 ]
  [[ "$output" != *'account-abc'* ]]
  [[ "$output" != *'mock issue success'* ]]
}

@test "no registration, renew-all, installer or implicit TOS operation" {
  issue example.com example.com
  [ "$status" -eq 0 ]
  ! grep -Eq '^\[(register|renew|run)\]' "$CERTBOT_PROVIDER_MOCK_LOG"
  ! grep -Fq '<--force-renewal>' "$CERTBOT_PROVIDER_MOCK_LOG"
  ! grep -Fq '<--agree-tos>' "$CERTBOT_PROVIDER_MOCK_LOG"
}

@test "unsafe workspace and aliased runtime directories stop locally" {
  chmod 755 "$WORKSPACE"
  issue example.com example.com
  [ "$status" -eq 64 ]
  chmod 700 "$WORKSPACE"
  mkdir "$ROOT/redirect"
  ln -s "$ROOT/redirect" "$WORKSPACE/logs"
  issue example.com example.com
  [ "$status" -eq 64 ]
  [ ! -e "$CERTBOT_PROVIDER_MOCK_LOG" ]
}

@test "archived global Certbot configuration is never trusted" {
  printf 'pre-hook = unwanted\n' >"$WORKSPACE/config/cli.ini"
  issue example.com example.com
  [ "$status" -eq 65 ]
  [ ! -e "$CERTBOT_PROVIDER_MOCK_LOG" ]
}

@test "provider component success does not bypass public seeded storage requirement" {
  issue example.com example.com
  [ "$status" -eq 0 ]
  [ ! -e "$WORKSPACE/config/live" ]
  run "$BASH_STARTER_ARTIFACT" --s3-bucket seeded-bucket example.com
  [ "$status" -eq 69 ]
}


@test "explicit stable cert name is independent of the requested DNS SAN" {
  issue custom.example.com example.com
  [ "$status" -eq 0 ]
  grep -Fq '<--cert-name> <custom.example.com>' "$CERTBOT_PROVIDER_MOCK_LOG"
  grep -Fq '<-d> <example.com>' "$CERTBOT_PROVIDER_MOCK_LOG"
  ! grep -Fq '<-d> <custom.example.com>' "$CERTBOT_PROVIDER_MOCK_LOG"
}

@test "existing complete selected lineage is refused before provider execution" {
  local part
  mkdir -p "$WORKSPACE/config/live/example.com"
  mkdir -p "$WORKSPACE/config/archive/example.com"
  mkdir -p "$WORKSPACE/config/renewal"
  for part in cert chain fullchain privkey; do
    printf 'fixture-%s\n' "$part" >"$WORKSPACE/config/archive/example.com/${part}1.pem"
    ln -s "../../archive/example.com/${part}1.pem" \
      "$WORKSPACE/config/live/example.com/$part.pem"
  done
  printf 'archive_dir = /etc/letsencrypt/archive/example.com\n' \
    >"$WORKSPACE/config/renewal/example.com.conf"
  chmod 600 "$WORKSPACE/config/renewal/example.com.conf"
  issue example.com example.com
  [ "$status" -eq 65 ]
  [ ! -e "$CERTBOT_PROVIDER_MOCK_LOG" ]
}
