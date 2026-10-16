#!/usr/bin/env bats

## @file tests/import-assess-archives.bats
## @brief Verifies non-activating archive-to-assessment orchestration.
## @details
## Uses synthetic local account metadata and PEM placeholders. These tests
## establish archive staging, rejection, and cleanup contracts, not real ACME
## registration, certificate validity, or active Certbot import.

setup() {
  : "${CERTBOTBOT_ARTIFACT:?A standalone artifact is required}"
  export CERTBOTBOT_TMPDIR="$BATS_TEST_TMPDIR"
  export ASSESS_SOURCE="$BATS_TEST_TMPDIR/source"
  export ASSESS_COMMON="$BATS_TEST_TMPDIR/common.tar.gz"
  export ASSESS_DOMAIN="$BATS_TEST_TMPDIR/example.com.tar.gz"
  export ASSESS_ACCOUNT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  mkdir -p "$ASSESS_SOURCE/common" "$ASSESS_SOURCE/domain"
  umask 077
}

make_archives() {
  local host=acme-v02.api.letsencrypt.org
  local account="$ASSESS_SOURCE/common/accounts/$host/directory/$ASSESS_ACCOUNT"
  local root="$ASSESS_SOURCE/domain" kind
  mkdir -p "$account" "$root/archive/example.com" \
    "$root/live/example.com" "$root/renewal" "$root/combined"
  for kind in meta regr private_key; do
    printf '{"fixture":"%s"}\n' "$kind" >"$account/$kind.json"
    chmod 0600 "$account/$kind.json"
  done
  chmod 0700 "$ASSESS_SOURCE/common/accounts" \
    "$ASSESS_SOURCE/common/accounts/$host" \
    "$ASSESS_SOURCE/common/accounts/$host/directory" "$account"

  for kind in cert chain fullchain privkey; do
    printf '%s fixture\n' "$kind" >"$root/archive/example.com/${kind}1.pem"
    ln -s "../../archive/example.com/${kind}1.pem" \
      "$root/live/example.com/$kind.pem"
  done
  printf 'combined fixture\n' >"$root/combined/example.com.pem"
  cp "$root/combined/example.com.pem" "$root/live/example.com/combined.pem"
  chmod 0600 "$root/archive/example.com/privkey1.pem" \
    "$root/combined/example.com.pem" \
    "$root/live/example.com/combined.pem"

  cat >"$root/renewal/example.com.conf" <<'RENEWAL'
version = 5.8.0
archive_dir = /previous-runner/config/archive/example.com
cert = /previous-runner/config/live/example.com/cert.pem
privkey = /previous-runner/config/live/example.com/privkey.pem
chain = /previous-runner/config/live/example.com/chain.pem
fullchain = /previous-runner/config/live/example.com/fullchain.pem

[renewalparams]
account = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
server = https://acme-v02.api.letsencrypt.org/directory
authenticator = dns-route53
key_type = ecdsa
RENEWAL
  tar -czf "$ASSESS_COMMON" -C "$ASSESS_SOURCE/common" accounts
  tar -czf "$ASSESS_DOMAIN" -C "$root" archive live renewal combined
}

@test "archive assessment succeeds without installing or retaining staged data" {
  make_archives
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    certbotbot_import_assess_archives "$2" "$3" example.com production
    result=$?
    [[ "$result" -eq 0 ]] || exit 1
    [[ -z "$CERTBOTBOT_COMMON_STAGE" &&
      -z "$CERTBOTBOT_RESTORE_ROOT" &&
      -z "$CERTBOTBOT_RENEWAL_PREVIEW" ]] || exit 1
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_CONFIG" -mindepth 1 -print -quit)" ]] ||
      exit 1
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_ROOT" -mindepth 1 -maxdepth 1 \
      ! -name config ! -name work ! -name logs -print -quit)" ]] || exit 1
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ASSESS_COMMON" "$ASSESS_DOMAIN"
  [ "$status" -eq 0 ]
}

@test "bad domain archive discards previously restored common stage" {
  make_archives
  printf 'broken gzip\n' >"$ASSESS_DOMAIN"
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    certbotbot_import_assess_archives "$2" "$3" example.com production
    result=$?
    [[ "$result" -ne 0 ]] || exit 1
    [[ -z "$CERTBOTBOT_COMMON_STAGE" &&
      -z "$CERTBOTBOT_RESTORE_ROOT" ]] || exit 1
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_CONFIG" -mindepth 1 -print -quit)" ]] ||
      exit 1
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ASSESS_COMMON" "$ASSESS_DOMAIN"
  [ "$status" -eq 0 ]
}

@test "wrong ACME environment fails closed and discards both stages" {
  make_archives
  run env ACME_ENVIRONMENT=staging bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    certbotbot_import_assess_archives "$2" "$3" example.com staging
    result=$?
    [[ "$result" -eq 65 ]] || exit 1
    [[ -z "$CERTBOTBOT_COMMON_STAGE" &&
      -z "$CERTBOTBOT_RESTORE_ROOT" &&
      -z "$CERTBOTBOT_RENEWAL_PREVIEW" ]] || exit 1
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_CONFIG" -mindepth 1 -print -quit)" ]] ||
      exit 1
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ASSESS_COMMON" "$ASSESS_DOMAIN"
  [ "$status" -eq 0 ]
}

@test "wrong requested lineage cannot leave partial stage or active state" {
  make_archives
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    certbotbot_import_assess_archives "$2" "$3" example.net production
    result=$?
    [[ "$result" -eq 64 ]] || exit 1
    [[ -z "$CERTBOTBOT_COMMON_STAGE" &&
      -z "$CERTBOTBOT_RESTORE_ROOT" ]] || exit 1
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_CONFIG" -mindepth 1 -print -quit)" ]] ||
      exit 1
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ASSESS_COMMON" "$ASSESS_DOMAIN"
  [ "$status" -eq 0 ]
}

@test "an existing caller-owned stage is never destroyed by assessment" {
  make_archives
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    certbotbot_common_restore "$2" || exit
    owned="$CERTBOTBOT_COMMON_STAGE"
    certbotbot_import_assess_archives "$2" "$3" example.com production
    result=$?
    [[ "$result" -eq 64 && "$CERTBOTBOT_COMMON_STAGE" == "$owned" &&
      -d "$owned" ]] || exit 1
    certbotbot_common_discard || exit
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ASSESS_COMMON" "$ASSESS_DOMAIN"
  [ "$status" -eq 0 ]
}

@test "archive assessment does not expose public certificate issuance" {
  run "$CERTBOTBOT_ARTIFACT" example.com
  [ "$status" -eq 69 ]
}

@test "invalid common archive never attempts to install domain state" {
  make_archives
  printf 'invalid\n' >"$ASSESS_COMMON"
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    certbotbot_import_assess_archives "$2" "$3" example.com production
    result=$?
    [[ "$result" -ne 0 && -z "$CERTBOTBOT_COMMON_STAGE" &&
      -z "$CERTBOTBOT_RESTORE_ROOT" ]] || exit 1
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_CONFIG" -mindepth 1 -print -quit)" ]] ||
      exit 1
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ASSESS_COMMON" "$ASSESS_DOMAIN"
  [ "$status" -eq 0 ]
}

@test "a hidden active config marker is preserved on failed assessment" {
  make_archives
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    printf "original\n" >"$CERTBOTBOT_WORKSPACE_CONFIG/.marker"
    certbotbot_import_assess_archives "$2" "$3" example.com production
    result=$?
    [[ "$result" -eq 64 ]] || exit 1
    [[ "$(cat "$CERTBOTBOT_WORKSPACE_CONFIG/.marker")" == original ]] || exit 1
    [[ -z "$CERTBOTBOT_COMMON_STAGE" &&
      -z "$CERTBOTBOT_RESTORE_ROOT" &&
      -z "$CERTBOTBOT_RENEWAL_PREVIEW" ]] || exit 1
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ASSESS_COMMON" "$ASSESS_DOMAIN"
  [ "$status" -eq 0 ]
}
