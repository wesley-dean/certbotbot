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

## Builds a second independent domain archive using the same common account.
## Versioned leaf files and relative symlinks remain scoped to example.net.
make_second_archive() {
  local root="$ASSESS_SOURCE/domain-second" kind
  export ASSESS_SECOND="$BATS_TEST_TMPDIR/example.net.tar.gz"
  mkdir -p "$root"
  cp -a "$ASSESS_SOURCE/domain/." "$root/"
  mv "$root/archive/example.com" "$root/archive/example.net"
  mv "$root/live/example.com" "$root/live/example.net"
  mv "$root/renewal/example.com.conf" "$root/renewal/example.net.conf"
  mv "$root/combined/example.com.pem" "$root/combined/example.net.pem"
  for kind in cert chain fullchain privkey; do
    rm "$root/live/example.net/$kind.pem"
    ln -s "../../archive/example.net/${kind}1.pem" \
      "$root/live/example.net/$kind.pem"
  done
  sed -i 's/example[.]com/example.net/g' \
    "$root/renewal/example.net.conf"
  tar -czf "$ASSESS_SECOND" -C "$root" archive live renewal combined
}

@test "batch accepts two lineages without altering active config" {
  make_archives
  make_second_archive
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit 1
    certbotbot_import_assess_batch "$2" production \
      example.com "$3" example.net "$4" || exit 1
    [[ -z "$CERTBOTBOT_COMMON_STAGE" &&
      -z "$CERTBOTBOT_RESTORE_ROOT" &&
      -z "$CERTBOTBOT_RENEWAL_PREVIEW" ]] || exit 1
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_CONFIG" \
      -mindepth 1 -print -quit)" ]] || exit 1
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_ROOT" \
      -mindepth 1 -maxdepth 1 ! -name config ! -name work \
      ! -name logs -print -quit)" ]] || exit 1
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ASSESS_COMMON" "$ASSESS_DOMAIN" "$ASSESS_SECOND"
  [ "$status" -eq 0 ]
}

@test "batch rejects a corrupt later domain and cleans previous stages" {
  make_archives
  make_second_archive
  printf 'bad gzip\n' >"$ASSESS_SECOND"
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit 1
    certbotbot_import_assess_batch "$2" production \
      example.com "$3" example.net "$4"
    result=$?
    [[ "$result" -ne 0 &&
      -z "$CERTBOTBOT_COMMON_STAGE" &&
      -z "$CERTBOTBOT_RESTORE_ROOT" &&
      -z "$CERTBOTBOT_RENEWAL_PREVIEW" ]] || exit 1
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_CONFIG" \
      -mindepth 1 -print -quit)" ]] || exit 1
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_ROOT" \
      -mindepth 1 -maxdepth 1 ! -name config ! -name work \
      ! -name logs -print -quit)" ]] || exit 1
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ASSESS_COMMON" "$ASSESS_DOMAIN" "$ASSESS_SECOND"
  [ "$status" -eq 0 ]
}

@test "batch rejects duplicate lineage identities before restore" {
  make_archives
  make_second_archive
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit 1
    certbotbot_import_assess_batch "$2" production \
      example.com "$3" example.com "$4"
    result=$?
    [[ "$result" -eq 64 ]] || exit 1
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_ROOT" \
      -mindepth 1 -maxdepth 1 ! -name config ! -name work \
      ! -name logs -print -quit)" ]] || exit 1
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ASSESS_COMMON" "$ASSESS_DOMAIN" "$ASSESS_SECOND"
  [ "$status" -eq 0 ]
}

@test "batch rejects a repeated domain archive before restore" {
  make_archives
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit 1
    certbotbot_import_assess_batch "$2" production \
      example.com "$3" example.net "$3"
    result=$?
    [[ "$result" -eq 64 ]] || exit 1
    [[ -z "$CERTBOTBOT_COMMON_STAGE" &&
      -z "$CERTBOTBOT_RESTORE_ROOT" ]] || exit 1
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ASSESS_COMMON" "$ASSESS_DOMAIN"
  [ "$status" -eq 0 ]
}

@test "batch rejects missing final archive before inspecting earlier domains" {
  make_archives
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit 1
    certbotbot_import_assess_batch "$2" production \
      example.com "$3" example.net "$4"
    result=$?
    [[ "$result" -eq 64 ]] || exit 1
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_ROOT" \
      -mindepth 1 -maxdepth 1 ! -name config ! -name work \
      ! -name logs -print -quit)" ]] || exit 1
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ASSESS_COMMON" "$ASSESS_DOMAIN" \
    "$BATS_TEST_TMPDIR/missing.tar.gz"
  [ "$status" -eq 0 ]
}

@test "batch rejects later wrong-authority lineage without residual stages" {
  make_archives
  make_second_archive
  local root="$ASSESS_SOURCE/domain-second"
  sed -i 's@https://acme-v02.api.letsencrypt.org/directory@https://acme-staging-v02.api.letsencrypt.org/directory@' \
    "$root/renewal/example.net.conf"
  tar -czf "$ASSESS_SECOND" -C "$root" archive live renewal combined
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit 1
    certbotbot_import_assess_batch "$2" production \
      example.com "$3" example.net "$4"
    result=$?
    [[ "$result" -eq 65 &&
      -z "$CERTBOTBOT_COMMON_STAGE" &&
      -z "$CERTBOTBOT_RESTORE_ROOT" &&
      -z "$CERTBOTBOT_RENEWAL_PREVIEW" ]] || exit 1
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_CONFIG" \
      -mindepth 1 -print -quit)" ]] || exit 1
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ASSESS_COMMON" "$ASSESS_DOMAIN" "$ASSESS_SECOND"
  [ "$status" -eq 0 ]
}

@test "batch preserves a hidden active file and refuses to assess" {
  make_archives
  make_second_archive
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit 1
    printf "untouched\n" >"$CERTBOTBOT_WORKSPACE_CONFIG/.marker"
    certbotbot_import_assess_batch "$2" production \
      example.com "$3" example.net "$4"
    result=$?
    [[ "$result" -eq 64 &&
      "$(cat "$CERTBOTBOT_WORKSPACE_CONFIG/.marker")" == untouched ]] ||
      exit 1
    [[ -z "$CERTBOTBOT_COMMON_STAGE" &&
      -z "$CERTBOTBOT_RESTORE_ROOT" ]] || exit 1
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ASSESS_COMMON" "$ASSESS_DOMAIN" "$ASSESS_SECOND"
  [ "$status" -eq 0 ]
}

@test "batch requires complete domain path pairs" {
  make_archives
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit 1
    certbotbot_import_assess_batch "$2" production example.com "$3" example.net
    result=$?
    [[ "$result" -eq 64 ]] || exit 1
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ASSESS_COMMON" "$ASSESS_DOMAIN"
  [ "$status" -eq 0 ]
}

## Exercising the policy through the public-artifact internal assessment
## confirms that restored archives cannot bypass it. Failures still clean
## private stage roots and leave the active configuration empty.
run_renewal_policy_archive() {
  tar -czf "$ASSESS_DOMAIN" -C "$ASSESS_SOURCE/domain" \
    archive live renewal combined
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit 1
    certbotbot_import_assess_archives "$2" "$3" example.com production
    result=$?
    [[ -z "$CERTBOTBOT_COMMON_STAGE" &&
      -z "$CERTBOTBOT_RESTORE_ROOT" &&
      -z "$CERTBOTBOT_RENEWAL_PREVIEW" ]] || exit 1
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_CONFIG" \
      -mindepth 1 -print -quit)" ]] || exit 1
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_ROOT" \
      -mindepth 1 -maxdepth 1 ! -name config ! -name work \
      ! -name logs -print -quit)" ]] || exit 1
    certbotbot_workspace_destroy || exit 1
    exit "$result"
  ' _ "$CERTBOTBOT_ARTIFACT" "$ASSESS_COMMON" "$ASSESS_DOMAIN"
}

@test "policy accepts the minimal supported Certbot 5.8.0 renewal profile" {
  make_archives
  run_renewal_policy_archive
  [ "$status" -eq 0 ]
}

@test "policy accepts bounded Route53 DNS-01 options and ARI retry state" {
  make_archives
  cat >>"$ASSESS_SOURCE/domain/renewal/example.com.conf" <<'RENEWAL'
pref_challs = dns-01
dns_route53_propagation_seconds = 120
[acme_renewal_info]
ari_retry_after = 2026-10-16T01:02:03
RENEWAL
  run_renewal_policy_archive
  [ "$status" -eq 0 ]
}

@test "policy supports the RSA key type used in supported Certbot profiles" {
  make_archives
  sed -i 's/^key_type = ecdsa$/key_type = rsa/' \
    "$ASSESS_SOURCE/domain/renewal/example.com.conf"
  run_renewal_policy_archive
  [ "$status" -eq 0 ]
}

@test "policy refuses unexpected renewal settings from an archive" {
  make_archives
  printf 'unreviewed_setting = true\n' \
    >>"$ASSESS_SOURCE/domain/renewal/example.com.conf"
  run_renewal_policy_archive
  [ "$status" -eq 64 ]
}

@test "policy refuses a foreign credential file configuration" {
  make_archives
  printf 'dns_route53_credentials = /tmp/foreign-creds\n' \
    >>"$ASSESS_SOURCE/domain/renewal/example.com.conf"
  run_renewal_policy_archive
  [ "$status" -eq 64 ]
}

@test "policy refuses a renewal hook that could execute archived commands" {
  make_archives
  printf 'pre_hook = /bin/sh -c true\n' \
    >>"$ASSESS_SOURCE/domain/renewal/example.com.conf"
  run_renewal_policy_archive
  [ "$status" -eq 64 ]
}

@test "policy refuses a non-Route53 authenticator" {
  make_archives
  sed -i 's/authenticator = dns-route53/authenticator = standalone/' \
    "$ASSESS_SOURCE/domain/renewal/example.com.conf"
  run_renewal_policy_archive
  [ "$status" -eq 65 ]
}

@test "policy refuses an installer option even if it is syntactically valid" {
  make_archives
  printf 'installer = apache\n' \
    >>"$ASSESS_SOURCE/domain/renewal/example.com.conf"
  run_renewal_policy_archive
  [ "$status" -eq 64 ]
}

@test "policy refuses a duplicate key in renewalparams" {
  make_archives
  printf 'key_type = rsa\n' \
    >>"$ASSESS_SOURCE/domain/renewal/example.com.conf"
  run_renewal_policy_archive
  [ "$status" -eq 64 ]
}

@test "policy refuses a second renewalparams section" {
  make_archives
  printf '[renewalparams]\nkey_type = ecdsa\n' \
    >>"$ASSESS_SOURCE/domain/renewal/example.com.conf"
  run_renewal_policy_archive
  [ "$status" -eq 65 ]
}

@test "policy refuses unknown renewal configuration sections" {
  make_archives
  printf '[plugin_options]\ncommand = /bin/sh\n' \
    >>"$ASSESS_SOURCE/domain/renewal/example.com.conf"
  run_renewal_policy_archive
  [ "$status" -eq 64 ]
}

@test "policy refuses persisted non-DNS preferred challenges" {
  make_archives
  printf 'pref_challs = http-01\n' \
    >>"$ASSESS_SOURCE/domain/renewal/example.com.conf"
  run_renewal_policy_archive
  [ "$status" -eq 64 ]
}

@test "policy refuses unsupported key types" {
  make_archives
  sed -i 's/key_type = ecdsa/key_type = invalid/' \
    "$ASSESS_SOURCE/domain/renewal/example.com.conf"
  run_renewal_policy_archive
  [ "$status" -eq 64 ]
}

@test "policy refuses unsupported Route53 propagation settings" {
  make_archives
  printf 'dns_route53_propagation_seconds = 9999\n' \
    >>"$ASSESS_SOURCE/domain/renewal/example.com.conf"
  run_renewal_policy_archive
  [ "$status" -eq 64 ]
}

@test "policy refuses a malformed ARI scheduling value" {
  make_archives
  printf '[acme_renewal_info]\nari_retry_after = soon\n' \
    >>"$ASSESS_SOURCE/domain/renewal/example.com.conf"
  run_renewal_policy_archive
  [ "$status" -eq 64 ]
}

@test "policy refuses an empty ARI section" {
  make_archives
  printf '[acme_renewal_info]\n' \
    >>"$ASSESS_SOURCE/domain/renewal/example.com.conf"
  run_renewal_policy_archive
  [ "$status" -eq 64 ]
}

@test "policy refuses duplicated ARI scheduling state" {
  make_archives
  cat >>"$ASSESS_SOURCE/domain/renewal/example.com.conf" <<'RENEWAL'
[acme_renewal_info]
ari_retry_after = 2026-10-16T01:02:03
ari_retry_after = 2026-10-17T01:02:03
RENEWAL
  run_renewal_policy_archive
  [ "$status" -eq 64 ]
}

@test "policy refuses a persisted override of automatic renewal timing" {
  make_archives
  sed -i '1i renew_before_expiry = 4 years' \
    "$ASSESS_SOURCE/domain/renewal/example.com.conf"
  run_renewal_policy_archive
  [ "$status" -eq 64 ]
}

@test "policy refuses missing key_type in a restored lineage" {
  make_archives
  sed -i '/^key_type = /d' \
    "$ASSESS_SOURCE/domain/renewal/example.com.conf"
  run_renewal_policy_archive
  [ "$status" -eq 64 ]
}
