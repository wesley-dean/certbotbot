#!/usr/bin/env bats

## A renewal-path preview must be private, derived from consistent original
## paths, and have no effect on the restored source or active Certbot config.
## These are synthetic Certbot-format fixtures, not a real renewal execution.

setup() {
  : "${CERTBOTBOT_ARTIFACT:?The built standalone artifact is required}"
  export PORTABLE_OLD=/old-jenkins-runner/letsencrypt
  export PORTABLE_ACCOUNT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export PORTABLE_ACCOUNT_STAGE="$BATS_TEST_TMPDIR/account.aaaaaaaa"
  export PORTABLE_DOMAIN_STAGE="$BATS_TEST_TMPDIR/restore.bbbbbbbb"
  export PORTABLE_CONF="$PORTABLE_DOMAIN_STAGE/renewal/example.com.conf"
  export PORTABLE_TEMP="$BATS_TEST_TMPDIR/producer"
  mkdir -m 0700 "$PORTABLE_ACCOUNT_STAGE" "$PORTABLE_DOMAIN_STAGE" "$PORTABLE_TEMP"
  mkdir -m 0700 "$PORTABLE_DOMAIN_STAGE/renewal"
  local base="$PORTABLE_ACCOUNT_STAGE/accounts/acme-v02.api.letsencrypt.org/directory/$PORTABLE_ACCOUNT" kind
  mkdir -p "$base"
  chmod 0700 "$PORTABLE_ACCOUNT_STAGE/accounts" \
    "$PORTABLE_ACCOUNT_STAGE/accounts/acme-v02.api.letsencrypt.org" \
    "$PORTABLE_ACCOUNT_STAGE/accounts/acme-v02.api.letsencrypt.org/directory" "$base"
  for kind in meta regr private_key; do
    printf '{"fixture":"%s"}\n' "$kind" >"$base/$kind.json"
    chmod 0600 "$base/$kind.json"
  done
  make_conf production
}

make_conf() {
  local environment=${1:-production} server
  if [[ $environment == production ]]; then
    server=https://acme-v02.api.letsencrypt.org/directory
  else
    server=https://acme-staging-v02.api.letsencrypt.org/directory
  fi
  cat >"$PORTABLE_CONF" <<RENEWAL
version = 5.8.0
archive_dir = $PORTABLE_OLD/archive/example.com
cert = $PORTABLE_OLD/live/example.com/cert.pem
privkey = $PORTABLE_OLD/live/example.com/privkey.pem
chain = $PORTABLE_OLD/live/example.com/chain.pem
fullchain = $PORTABLE_OLD/live/example.com/fullchain.pem

[renewalparams]
account = $PORTABLE_ACCOUNT
server = $server
authenticator = dns-route53
key_type = ecdsa
[acme_renewal_info]
ari_retry_after = 2026-10-16T01:02:03
RENEWAL
}

run_preview() {
  local environment=${1:-production}
  run env ACME_ENVIRONMENT="$environment" CERTBOTBOT_TMPDIR="$PORTABLE_TEMP" bash -c '
    source "$1" --version >/dev/null
    CERTBOTBOT_COMMON_STAGE=$2
    CERTBOTBOT_RESTORE_ROOT=$3
    certbotbot_workspace_create || exit
    certbotbot_renewal_path_preview example.com "$4"
    rc=$?
    if [[ "$rc" -eq 0 ]]; then
      [[ -f "$CERTBOTBOT_RENEWAL_PREVIEW" ]] || exit
      [[ "$(stat -c "%a" "$CERTBOTBOT_RENEWAL_PREVIEW")" == 600 ]] || exit
      printf "preview=%s\n" "$(cat "$CERTBOTBOT_RENEWAL_PREVIEW")"
      certbotbot_renewal_preview_discard || exit
    fi
    certbotbot_workspace_destroy || exit
    exit "$rc"
  ' _ "$CERTBOTBOT_ARTIFACT" "$PORTABLE_ACCOUNT_STAGE" \
    "$PORTABLE_DOMAIN_STAGE" "$environment"
}

@test "valid production paths preview under a different private workspace" {
  local original
  original="$(sha256sum "$PORTABLE_CONF")"
  run_preview
  [ "$status" -eq 0 ]
  [[ "$output" == *"/config/archive/example.com"* ]]
  [[ "$output" == *"/config/live/example.com/privkey.pem"* ]]
  [[ "$output" != *"$PORTABLE_OLD"* ]]
  [ "$(sha256sum "$PORTABLE_CONF")" = "$original" ]
  [ -z "$(find "$PORTABLE_TEMP" -mindepth 1 -print)" ]
}

@test "staging paths preview against an independently restored staging account" {
  local prod="$PORTABLE_ACCOUNT_STAGE/accounts/acme-v02.api.letsencrypt.org"
  mkdir -p "$PORTABLE_ACCOUNT_STAGE/accounts/acme-staging-v02.api.letsencrypt.org/directory"
  chmod 0700 "$PORTABLE_ACCOUNT_STAGE/accounts/acme-staging-v02.api.letsencrypt.org" \
    "$PORTABLE_ACCOUNT_STAGE/accounts/acme-staging-v02.api.letsencrypt.org/directory"
  mv "$prod/directory/$PORTABLE_ACCOUNT" \
    "$PORTABLE_ACCOUNT_STAGE/accounts/acme-staging-v02.api.letsencrypt.org/directory/"
  make_conf staging
  run_preview staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"/config/live/example.com/fullchain.pem"* ]]
}

@test "mismatched original cert path is rejected before any preview" {
  sed -i 's@cert = /old-jenkins-runner/letsencrypt/@cert = /another-runner/letsencrypt/@' "$PORTABLE_CONF"
  run_preview
  [ "$status" -eq 64 ]
  [ -z "$(find "$PORTABLE_TEMP" -mindepth 1 -print)" ]
}

@test "cross-lineage archive_dir is rejected" {
  sed -i 's@archive/example.com@archive/example.net@' "$PORTABLE_CONF"
  run_preview
  [ "$status" -eq 64 ]
}

@test "parent path traversal in original root is rejected" {
  sed -i 's@/old-jenkins-runner/letsencrypt/archive/@/old-jenkins-runner/../letsencrypt/archive/@' "$PORTABLE_CONF"
  run_preview
  [ "$status" -eq 64 ]
}

@test "duplicate path keys are rejected" {
  printf 'cert = /old-jenkins-runner/letsencrypt/live/example.com/cert.pem\n' \
    >>"$PORTABLE_CONF"
  run_preview
  [ "$status" -eq 64 ]
}

@test "missing original path is rejected" {
  sed -i '/^fullchain = /d' "$PORTABLE_CONF"
  run_preview
  [ "$status" -eq 64 ]
}

@test "saved work_dir override is rejected rather than copied to the next host" {
  printf 'work_dir = /another-runner/work\n' >>"$PORTABLE_CONF"
  run_preview
  [ "$status" -eq 64 ]
}

@test "unsupported top-level path directives are rejected" {
  sed -i '1i custom_path = /tmp/from-old-runner' "$PORTABLE_CONF"
  run_preview
  [ "$status" -eq 64 ]
}

@test "wrong ACME environment blocks path relocation" {
  run_preview staging
  [ "$status" -eq 65 ]
}

@test "a renewal post_hook is rejected before preview" {
  printf 'post_hook = /bin/true\n' >>"$PORTABLE_CONF"
  run_preview
  [ "$status" -eq 64 ]
}

@test "a preview cannot run without the private producer workspace" {
  run bash -c '
    source "$1" --version >/dev/null
    CERTBOTBOT_COMMON_STAGE=$2
    CERTBOTBOT_RESTORE_ROOT=$3
    certbotbot_renewal_path_preview example.com production
  ' _ "$CERTBOTBOT_ARTIFACT" "$PORTABLE_ACCOUNT_STAGE" "$PORTABLE_DOMAIN_STAGE"
  [ "$status" -eq 64 ]
}

@test "normal certificate issuance remains explicitly unavailable" {
  run "$CERTBOTBOT_ARTIFACT" example.com
  [ "$status" -eq 69 ]
}
