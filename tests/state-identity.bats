#!/usr/bin/env bats

## Fixture-only identity checks.  Certbot, AWS, and Let's Encrypt are never
## called.  Account JSON is synthetically populated and not authenticated.

setup() {
  : "${CERTBOTBOT_ARTIFACT:?Missing standalone artifact}"
  export IDENTITY_COMMON="$BATS_TEST_TMPDIR/account.aaaaaaaa"
  export IDENTITY_LINEAGE="$BATS_TEST_TMPDIR/restore.bbbbbbbb"
  export IDENTITY_ACCOUNT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export IDENTITY_CONF="$IDENTITY_LINEAGE/renewal/example.com.conf"
  export IDENTITY_PROD='https://acme-v02.api.letsencrypt.org/directory'
  export IDENTITY_STAGE='https://acme-staging-v02.api.letsencrypt.org/directory'
  mkdir -m 0700 "$IDENTITY_COMMON" "$IDENTITY_LINEAGE"
  mkdir -m 0700 "$IDENTITY_LINEAGE/renewal"
  make_account production
  make_renewal "$IDENTITY_PROD" "$IDENTITY_ACCOUNT"
}

make_account() {
  local environment=${1:-production} host path file
  if [[ $environment == production ]]; then
    host=acme-v02.api.letsencrypt.org
  else
    host=acme-staging-v02.api.letsencrypt.org
  fi
  mkdir -p "$IDENTITY_COMMON/accounts/$host/directory/$IDENTITY_ACCOUNT"
  chmod 0700 "$IDENTITY_COMMON/accounts" "$IDENTITY_COMMON/accounts/$host" \
    "$IDENTITY_COMMON/accounts/$host/directory" \
    "$IDENTITY_COMMON/accounts/$host/directory/$IDENTITY_ACCOUNT"
  path="$IDENTITY_COMMON/accounts/$host/directory/$IDENTITY_ACCOUNT"
  for file in meta regr private_key; do
    printf '{"fixture":"%s"}\n' "$file" >"$path/$file.json"
    chmod 0600 "$path/$file.json"
  done
}

make_renewal() {
  local server="$1" account="$2"
  cat >"$IDENTITY_CONF" <<RENEWAL
version = 5.8.0
archive_dir = /old-producer/letsencrypt/archive/example.com
cert = /old-producer/letsencrypt/live/example.com/cert.pem
privkey = /old-producer/letsencrypt/live/example.com/privkey.pem
chain = /old-producer/letsencrypt/live/example.com/chain.pem
fullchain = /old-producer/letsencrypt/live/example.com/fullchain.pem

[renewalparams]
account = $account
server = $server
authenticator = dns-route53
key_type = ecdsa
[acme_renewal_info]
ari_retry_after = 2026-10-16T01:02:03
RENEWAL
}

verify_identity() {
  local environment=${1:-production}
  run env ACME_ENVIRONMENT="$environment" bash -c '
    source "$1" --version >/dev/null
    CERTBOTBOT_COMMON_STAGE=$2
    CERTBOTBOT_RESTORE_ROOT=$3
    certbotbot_state_verify_identity "$2" "$3" example.com "$4"
  ' _ "$CERTBOTBOT_ARTIFACT" "$IDENTITY_COMMON" "$IDENTITY_LINEAGE" "$environment"
}

@test "production renewal matches restored production account" {
  verify_identity
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "staging renewal matches independently staged staging account" {
  make_account staging
  make_renewal "$IDENTITY_STAGE" "$IDENTITY_ACCOUNT"
  verify_identity staging
  [ "$status" -eq 0 ]
}

@test "staging rejects production renewal metadata" {
  make_account staging
  verify_identity staging
  [ "$status" -eq 65 ]
}

@test "production rejects a staging renewal server" {
  make_renewal "$IDENTITY_STAGE" "$IDENTITY_ACCOUNT"
  verify_identity production
  [ "$status" -eq 65 ]
}

@test "staging renewal requires an account under the staging authority" {
  make_renewal "$IDENTITY_STAGE" "$IDENTITY_ACCOUNT"
  verify_identity staging
  [ "$status" -eq 65 ]
}

@test "renewal references must name a present account" {
  make_renewal "$IDENTITY_PROD" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  verify_identity
  [ "$status" -eq 65 ]
}

@test "a missing restored account key fails closed" {
  rm "$IDENTITY_COMMON/accounts/acme-v02.api.letsencrypt.org/directory/$IDENTITY_ACCOUNT/private_key.json"
  verify_identity
  [ "$status" -eq 65 ]
}

@test "symlinked account key fails closed" {
  local key="$IDENTITY_COMMON/accounts/acme-v02.api.letsencrypt.org/directory/$IDENTITY_ACCOUNT/private_key.json"
  mv "$key" "$key.saved"
  ln -s "$key.saved" "$key"
  verify_identity
  [ "$status" -eq 65 ]
}

@test "group-readable restored account key fails closed" {
  chmod 0644 "$IDENTITY_COMMON/accounts/acme-v02.api.letsencrypt.org/directory/$IDENTITY_ACCOUNT/private_key.json"
  verify_identity
  [ "$status" -eq 65 ]
}

@test "duplicate account identity fields fail closed" {
  printf 'account = %s\n' "$IDENTITY_ACCOUNT" >>"$IDENTITY_CONF"
  verify_identity
  [ "$status" -eq 65 ]
}

@test "a duplicate renewalparams section fails closed" {
  printf '[renewalparams]\n' >>"$IDENTITY_CONF"
  verify_identity
  [ "$status" -eq 65 ]
}

@test "missing renewal server is not inferred from defaults" {
  sed -i '/^server = /d' "$IDENTITY_CONF"
  verify_identity
  [ "$status" -eq 65 ]
}

@test "unknown authenticator cannot reuse selected Route53 account" {
  sed -i 's/^authenticator = .*/authenticator = standalone/' "$IDENTITY_CONF"
  verify_identity
  [ "$status" -eq 65 ]
}

@test "renewal hook directives are never accepted as harmless metadata" {
  printf 'post_hook = /usr/bin/curl https://example.test/\n' >>"$IDENTITY_CONF"
  verify_identity
  [ "$status" -eq 64 ]
}

@test "unknown renewal config section fails closed" {
  printf '[arbitrary_plugin]\nfoo = value\n' >>"$IDENTITY_CONF"
  verify_identity
  [ "$status" -eq 64 ]
}

@test "a NUL byte in the renewal configuration is rejected" {
  printf '\000' >>"$IDENTITY_CONF"
  verify_identity
  [ "$status" -eq 64 ]
}

@test "a symlink to an external renewal file is rejected" {
  mv "$IDENTITY_CONF" "$IDENTITY_CONF.real"
  ln -s "$IDENTITY_CONF.real" "$IDENTITY_CONF"
  verify_identity
  [ "$status" -eq 64 ]
}

@test "unrelated unregistered staging root is rejected" {
  run env ACME_ENVIRONMENT=production bash -c '
    source "$1" --version >/dev/null
    CERTBOTBOT_COMMON_STAGE=$2
    CERTBOTBOT_RESTORE_ROOT=$3
    certbotbot_state_verify_identity "$2" /tmp example.com production
  ' _ "$CERTBOTBOT_ARTIFACT" "$IDENTITY_COMMON" "$IDENTITY_LINEAGE"
  [ "$status" -eq 64 ]
}

@test "explicit mode mismatch with the current invocation fails closed" {
  run env ACME_ENVIRONMENT=staging bash -c '
    source "$1" --version >/dev/null
    CERTBOTBOT_COMMON_STAGE=$2
    CERTBOTBOT_RESTORE_ROOT=$3
    certbotbot_state_verify_identity "$2" "$3" example.com production
  ' _ "$CERTBOTBOT_ARTIFACT" "$IDENTITY_COMMON" "$IDENTITY_LINEAGE"
  [ "$status" -eq 64 ]
}

@test "identity verification does not enable issuance" {
  run "$CERTBOTBOT_ARTIFACT" --staging example.com
  [ "$status" -eq 69 ]
}
