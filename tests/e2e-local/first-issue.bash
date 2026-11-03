#!/usr/bin/env bash
# shellcheck shell=bash
## @file tests/e2e-local/first-issue.bash
## @brief Exercises first local Pebble issuance and independently reads SeaweedFS.
## @details
## Test-only, inside the ephemeral sealed runner.  The bootstrap and verify
## modes execute in distinct containers with no shared Certbot workspace.
## Every provider response and certificate/key stays in disposable mode-0700
## tmpfs.  Only bounded status and nonsecret digests leave this process.
## Pebble explicitly skips validation of DNS-01: ADR-047.  The Route53 stub
## is not an AWS interoperability test.
## @par Usage
## @code{.sh}
## first-issue.bash bootstrap
## first-issue.bash verify ARCHIVE_SHA256
## @endcode

set -euo pipefail
umask 077

readonly PROVIDER=/usr/local/libexec/certbotbot-e2e/provider-env.bash
readonly ARTIFACT=/usr/local/bin/certbotbot.bash
readonly CONFIG=/usr/local/share/certbotbot-e2e/empty.env
readonly BUCKET=certbotbot-local-e2e
readonly KEY=latest.tar.gz
readonly NAME=test.e2e.test
readonly EMAIL=local-e2e@example.invalid

## @fn error()
## @brief Emits a static, nonsecret diagnostic.
## @param message Literal fixed diagnostic without raw provider output.
error() {
  printf 'local-first-issue: %s\n' "$1" >&2
}

## @fn aws_local()
## @brief Calls real AWS CLI with only synthetic local endpoint credentials.
## @param ... AWS CLI service command and parameters.
## @retval 0 Command succeeded against the private SeaweedFS endpoint.
## @retval 1 Nonzero AWS CLI status (never treat as remote rollback).
aws_local() {
  env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/tmp TMPDIR=/tmp \
    AWS_ACCESS_KEY_ID=CBOTBOT_LOCAL_TEST_ACCESS_ONLY \
    AWS_SECRET_ACCESS_KEY=CBOTBOT_LOCAL_TEST_SECRET_NOT_A_CLOUD_KEY \
    AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1 \
    AWS_EC2_METADATA_DISABLED=true AWS_CONFIG_FILE=/dev/null \
    AWS_SHARED_CREDENTIALS_FILE=/dev/null \
    AWS_ENDPOINT_URL_S3=http://172.31.248.4:8333 \
    AWS_ENDPOINT_URL_ROUTE53=http://172.31.248.6:8056 \
    aws --no-cli-pager "$@"
}

## @fn provider()
## @brief Runs exactly the genuine checked public producer through the guard.
## @param ... Real public producer options including explicit staging.
provider() {
  bash "$PROVIDER" -- "$ARTIFACT" "$@"
}

## @fn issuer()
## @brief Calls ordinary issuance with the selected real Pebble account.
issuer() {
  provider \
    --config "$CONFIG" \
    --acme-environment staging \
    --domain "$NAME" \
    --include-subdomains false \
    --cert-name "$NAME" \
    --s3-bucket "$BUCKET" \
    --s3-key "$KEY" \
    --archive-encryption none \
    --upload-no-renewal false
}

## @fn fetch_archive()
## @brief Independently downloads a real SeaweedFS object into private tmpfs.
## @param target Private destination path.
fetch_archive() {
  aws_local s3api get-object --bucket "$BUCKET" --key "$KEY" \
    --output json "$1" >/dev/null 2>&1 ||
    { error 'independent S3 object download failed'; return 74; }
  [[ -s "$1" ]] ||
    { error 'downloaded S3 object is empty'; return 65; }
}

## @fn verify_account()
## @brief Checks native account files under canonical staging CA identity.
## @param archive Downloaded compressed state archive.
verify_account() {
  local entries
  entries="$(tar -tzf "$1" 2>/dev/null)" ||
    { error 'account archive is unreadable'; return 65; }
  local prefix='^\./accounts/acme-staging-v02\.api\.letsencrypt\.org/directory/[^/]+/'
  for part in private_key.json regr.json meta.json; do
    grep -Eq "${prefix}${part}\$" <<<"$entries" ||
      { error 'native staging account data missing'; return 65; }
  done
}

## @fn verify_certificate()
## @brief Verifies an actual PEM leaf in the independently retrieved archive.
## @param archive Certificate-bearing compressed state archive.
## @param workspace Owned temporary private workspace.
verify_certificate() {
  local archive="$1" workspace="$2" leaf
  local entries
  entries="$(tar -tzf "$archive" 2>/dev/null)" ||
    { error 'certificate archive unreadable'; return 65; }
  grep -Eq '^\./renewal/test\.e2e\.test\.conf$' <<<"$entries" ||
    { error 'selected renewal lineage missing'; return 65; }
  leaf="$(grep -E '^\./archive/test\.e2e\.test/cert[0-9]+\.pem$' <<<"$entries" |
    LC_ALL=C sort -V | tail -n 1)" || return 65
  [[ -n "$leaf" ]] ||
    { error 'selected certificate bytes absent'; return 65; }
  tar -xOzf "$archive" "$leaf" >"$workspace/leaf.pem" 2>/dev/null ||
    { error 'certificate extraction failed'; return 65; }
  openssl x509 -in "$workspace/leaf.pem" -noout -ext subjectAltName 2>/dev/null |
    grep -Fq "DNS:$NAME" ||
    { error 'leaf SAN does not match requested identity'; return 65; }
  openssl x509 -in "$workspace/leaf.pem" -outform DER >"$workspace/leaf.der" 2>/dev/null ||
    { error 'invalid issued PEM certificate'; return 65; }
  [[ -s "$workspace/leaf.der" ]] ||
    { error 'issued certificate DER missing'; return 65; }
}

## @fn bootstrap()
## @brief Proves missing-object refusal before genuine registration and issuance.
## @param workspace Owned private scratch space.
bootstrap() {
  local workspace="$1" entries digest
  # Creating a synthetic local bucket never contacts AWS: sealed bridge,
  # literal endpoint, and nonfunctional credentials are mandatory.
  aws_local s3api create-bucket --bucket "$BUCKET" --output json >/dev/null 2>&1 ||
    { error 'local SeaweedFS bucket creation failed'; return 74; }
  aws_local s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 ||
    { error 'new synthetic bucket unavailable'; return 74; }
  if aws_local s3api head-object --bucket "$BUCKET" --key "$KEY" \
    >"$workspace/head.out" 2>"$workspace/head.err"; then
    error 'existing current archive forbids a first-issuance test'
    return 65
  fi
  # Do not turn S3 permissions, timeouts or service failures into missing-key.
  if ! grep -Eq '[(]404[)]|[(]NoSuchKey[)]|Not Found' "$workspace/head.err"; then
    error 'current S3 object state is ambiguous'
    return 69
  fi
  # Ordinary issuance may not register an account or create an object.
  if issuer >"$workspace/absent.log" 2>&1; then
    error 'ordinary issuance accepted missing account archive'
    return 65
  fi
  if aws_local s3api head-object --bucket "$BUCKET" --key "$KEY" \
    >"$workspace/head.out" 2>"$workspace/head.err"; then
    error 'failed ordinary issuance unexpectedly published an object'
    return 65
  fi
  if ! grep -Eq '[(]404[)]|[(]NoSuchKey[)]|Not Found' "$workspace/head.err"; then
    error 'current S3 object state became ambiguous after failed issuance'
    return 69
  fi

  if ! provider register \
    --config "$CONFIG" --acme-environment staging \
    --email "$EMAIL" --agree-tos true --eff-email-signup false \
    --s3-bucket "$BUCKET" --s3-key "$KEY" \
    --archive-encryption none >"$workspace/register.log" 2>&1; then
    error 'real Pebble account registration or conditional S3 publish failed'
    return 74
  fi
  grep -Fq 'published=true' "$workspace/register.log" ||
    { error 'registration did not confirm publication'; return 65; }

  fetch_archive "$workspace/account.tar.gz" || return $?
  verify_account "$workspace/account.tar.gz" || return $?
  entries="$(tar -tzf "$workspace/account.tar.gz" 2>/dev/null)" || return 65
  if grep -Eq '^\./(archive|live|renewal)/' <<<"$entries"; then
    error 'registration unexpectedly created a certificate lineage'
    return 65
  fi

  if ! issuer >"$workspace/issue.log" 2>&1; then
    error 'real Pebble certificate issuance or S3 publication failed'
    return 74
  fi
  grep -Fq 'published=true' "$workspace/issue.log" &&
    grep -Fq 'certbotbot: issued ' "$workspace/issue.log" ||
    { error 'first issuance did not report issuance and publication'; return 65; }

  fetch_archive "$workspace/issued.tar.gz" || return $?
  verify_account "$workspace/issued.tar.gz" || return $?
  verify_certificate "$workspace/issued.tar.gz" "$workspace" || return $?
  digest="$(sha256sum "$workspace/issued.tar.gz" | awk '{print $1}')" || return 74
  [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || return 65
  printf 'local-first-issue: issued_archive_sha256=%s\n' "$digest"
}

## @fn verify()
## @brief Reads the same S3 object in a new container with no issuer state.
## @param workspace Owned private scratch space.
## @param expected Digest emitted by successful bootstrap runner.
verify() {
  local workspace="$1" expected="$2" actual leaf_sha
  [[ "$expected" =~ ^[a-f0-9]{64}$ ]] ||
    { error 'invalid expected archive identity'; return 64; }
  fetch_archive "$workspace/verified.tar.gz" || return $?
  actual="$(sha256sum "$workspace/verified.tar.gz" | awk '{print $1}')" || return 74
  [[ "$actual" == "$expected" ]] ||
    { error 'independent object bytes changed'; return 65; }
  verify_account "$workspace/verified.tar.gz" || return $?
  verify_certificate "$workspace/verified.tar.gz" "$workspace" || return $?
  leaf_sha="$(sha256sum "$workspace/leaf.der" | awk '{print $1}')" || return 74
  [[ "$leaf_sha" =~ ^[a-f0-9]{64}$ ]] || return 65
  printf 'local-first-issue: independently_verified_cert_der_sha256=%s\n' "$leaf_sha"
}

## @fn main()
## @brief Runs one bounded phase and removes private state on every exit.
main() {
  local mode="${1-}" workspace=''
  case "$mode" in
    bootstrap) (( $# == 1 )) || { error 'unexpected bootstrap arguments'; return 64; } ;;
    verify) (( $# == 2 )) || { error 'expected one digest'; return 64; } ;;
    *) error 'usage: first-issue.bash bootstrap | verify ARCHIVE_SHA256'; return 64 ;;
  esac
  workspace="$(mktemp -d)" ||
    { error 'private test workspace unavailable'; return 74; }
  trap 'rm -rf -- "$workspace"' EXIT
  case "$mode" in
    bootstrap) bootstrap "$workspace" ;;
    verify) verify "$workspace" "$2" ;;
  esac
}

main "$@"
