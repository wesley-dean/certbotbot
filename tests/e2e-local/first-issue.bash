#!/usr/bin/env bash
# shellcheck shell=bash
## @file tests/e2e-local/first-issue.bash
## @brief Exercises real Pebble certificate lifecycles and local failures.
## @details
## Test-only, inside the ephemeral sealed runner. Each positive or negative
## mode executes in a distinct container with no shared Certbot workspace.
## Every provider response and certificate/key stays in disposable mode-0700
## tmpfs.  Only bounded status and nonsecret digests leave this process.
## Pebble explicitly skips validation of DNS-01: ADR-047.  The Route53 stub
## is not an AWS interoperability test.
## @par Usage
## @code{.sh}
## first-issue.bash bootstrap
## first-issue.bash verify ARCHIVE_SHA256
## first-issue.bash baseline
## first-issue.bash fault SCENARIO ARCHIVE_SHA256
## @endcode

set -euo pipefail
umask 077

readonly PROVIDER=/usr/local/libexec/certbotbot-e2e/provider-env.bash
readonly ARTIFACT=/usr/local/bin/certbotbot.bash
readonly ARTIFACT_DEV=/usr/local/bin/certbotbot.dev.bash
readonly ARTIFACT_MIN=/usr/local/bin/certbotbot.min.bash
readonly CONFIG=/usr/local/share/certbotbot-e2e/empty.env
readonly BUCKET=certbotbot-local-e2e
readonly KEY=latest.tar.gz
readonly NAME=test.e2e.test
readonly EMAIL=local-e2e@example.invalid
readonly FORCE_STATE=/tmp/.certbotbot-e2e-renewal

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
  local flavor="$1" executable=''
  shift
  case "$flavor" in
    development) executable="$ARTIFACT_DEV" ;;
    ordinary) executable="$ARTIFACT" ;;
    minified) executable="$ARTIFACT_MIN" ;;
    *) error 'unknown producer flavor'; return 64 ;;
  esac
  bash "$PROVIDER" -- "$executable" "$@"
}

## @fn issuer()
## @brief Calls ordinary issuance with the selected real Pebble account.
issuer() {
  local flavor="${1:-ordinary}"
  provider "$flavor" \
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
  # Independently prove that the matching archived private-key generation
  # corresponds to this leaf, without ever printing or exporting the key.
  local generation key
  generation="${leaf##*/cert}"
  generation="${generation%.pem}"
  [[ "$generation" =~ ^[0-9]+$ ]] ||
    { error 'noncanonical certificate generation'; return 65; }
  key="./archive/$NAME/privkey${generation}.pem"
  tar -xOzf "$archive" "$key" >"$workspace/leaf-key.pem" 2>/dev/null ||
    { error 'selected private-key generation absent'; return 65; }
  openssl x509 -in "$workspace/leaf.pem" -pubkey -noout >"$workspace/leaf.pub" 2>/dev/null ||
    { error 'leaf public-key extraction failed'; return 65; }
  openssl pkey -in "$workspace/leaf-key.pem" -pubout >"$workspace/key.pub" 2>/dev/null ||
    { error 'archive private key unusable'; return 65; }
  cmp -s "$workspace/leaf.pub" "$workspace/key.pub" ||
    { error 'private key and certificate mismatch'; return 65; }
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

  if ! provider ordinary register \
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

## @fn object_metadata()
## @brief Reads the selected SeaweedFS object identity with the real AWS CLI.
## @param output Private destination for parsed metadata.
## @retval 0 The object has valid quoted ETag and LastModified fields.
## @retval 69 Missing or malformed S3 metadata.
object_metadata() {
  local output="$1" raw=''
  raw="$(aws_local s3api head-object --bucket "$BUCKET" --key "$KEY" \
    --output json 2>/dev/null)" ||
    { error 'selected S3 object metadata unavailable'; return 69; }
  jq -ce '(.ETag | type == "string")
    and (.LastModified | type == "string")
    and (.ContentLength | type == "number")' <<<"$raw" >/dev/null ||
    { error 'selected S3 object metadata malformed'; return 69; }
  jq -c '[.ETag, .LastModified, .ContentLength]' <<<"$raw" >"$output" ||
    { error 'selected S3 identity parsing failed'; return 69; }
}

## @fn noop()
## @brief Restores one exact public producer flavor and checks a non-due no-op.
## @details
## Uses fresh runner state with no local account, keys or renewal files.
## Compares independently fetched bytes, ETag, modification metadata, and the
## existing leaf/key against pre- and post-execution S3 object observations.
## The host harness separately rejects any increment in Pebble's new-order
## counter. Provider output plus S3 metadata are not a raw S3 PUT packet trace.
## @param workspace Disposable local tmpfs directory.
## @param flavor development, ordinary, or minified.
## @param expected Bootstrap archive SHA-256.
noop() {
  local workspace="$1" flavor="$2" expected="$3" actual=''
  [[ "$expected" =~ ^[a-f0-9]{64}$ ]] ||
    { error 'invalid archive digest for no-op'; return 64; }
  fetch_archive "$workspace/before.tar.gz" || return $?
  actual="$(sha256sum "$workspace/before.tar.gz" | awk '{print $1}')" || return 74
  [[ "$actual" == "$expected" ]] ||
    { error 'fresh-runner input archive differs'; return 65; }
  verify_account "$workspace/before.tar.gz" || return $?
  verify_certificate "$workspace/before.tar.gz" "$workspace" || return $?
  object_metadata "$workspace/before.meta" || return $?

  # A real producer invocation (not a Certbot mock) fetches and restores
  # account, lineage, renewal paths and keys from SeaweedFS itself.
  if ! issuer "$flavor" >"$workspace/noop.log" 2>&1; then
    error 'fresh-runner selected renewal/no-op failed'
    return 74
  fi
  grep -Fq 'certbotbot: checked ' "$workspace/noop.log" &&
    grep -Fq '; published=false' "$workspace/noop.log" ||
    { error 'selected no-op unexpectedly changed or published state'; return 65; }

  object_metadata "$workspace/after.meta" || return $?
  cmp -s "$workspace/before.meta" "$workspace/after.meta" ||
    { error 'S3 object identity changed during no-op'; return 65; }
  fetch_archive "$workspace/after.tar.gz" || return $?
  actual="$(sha256sum "$workspace/after.tar.gz" | awk '{print $1}')" || return 74
  [[ "$actual" == "$expected" ]] ||
    { error 'S3 archive bytes changed during no-op'; return 65; }
  verify_account "$workspace/after.tar.gz" || return $?
  verify_certificate "$workspace/after.tar.gz" "$workspace" || return $?
  printf 'local-first-issue: fresh_runner_noop=%s; archive_sha256=%s\n' "$flavor" "$expected"
}

## @fn account_identity()
## @brief Hashes the unique canonical account key and identity from an archive.
## @details
## A private key is neither printed nor copied outside this runner. The
## caller compares this opaque hash across separately retrieved objects.
## @param archive Private downloaded account/certificate archive.
## @returns SHA-256 of unique account key path and its exact file bytes.
## @retval 65 Ambiguous, missing or unreadable native account identity.
account_identity() {
  local archive="$1" entries='' item='' digest=''
  entries="$(tar -tzf "$archive" 2>/dev/null)" ||
    { error 'account archive listing failed'; return 65; }
  item="$(grep -E '^\./accounts/acme-staging-v02\.api\.letsencrypt\.org/directory/[^/]+/private_key\.json$' <<<"$entries" || true)"
  [[ -n "$item" && "$item" != *$'\n'* ]] ||
    { error 'account identity missing or ambiguous'; return 65; }
  digest="$({ printf '%s\n' "$item"; tar -xOzf "$archive" "$item"; } |
    sha256sum | awk '{print $1}')" ||
    { error 'account identity bytes unavailable'; return 65; }
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 65
  printf '%s\n' "$digest"
}

## @fn verify_selected_only()
## @brief Refuses foreign lineages in this one-certificate synthetic scenario.
## @param archive Private archive to verify.
## @retval 65 Unexpected additional or missing lineage.
verify_selected_only() {
  local entries='' archive="$1" names=''
  entries="$(tar -tzf "$archive" 2>/dev/null)" ||
    { error 'lineage listing unavailable'; return 65; }
  names="$(grep -E '^\./renewal/[^/]+\.conf$' <<<"$entries" || true)"
  [[ "$names" == "./renewal/$NAME.conf" ]] ||
    { error 'unexpected selected renewal configuration'; return 65; }
  local item
  while IFS= read -r item; do
    case "$item" in
      "./archive/$NAME/"*|"./live/$NAME/"*) ;;
      ./archive/*/*|./live/*/*)
        error 'unexpected additional lineage'
        return 65
        ;;
    esac
  done <<<"$entries"
}

## @fn verify_no_force_persistence()
## @brief Refuses any test-only force-renewal setting in durable archive.
## @param archive Reissued certificate-bearing object.
## @param workspace Owned private scratch directory.
verify_no_force_persistence() {
  local archive="$1" workspace="$2"
  tar -xOzf "$archive" "./renewal/$NAME.conf" \
    >"$workspace/renewal.conf" 2>/dev/null ||
    { error 'renewal config extraction failed'; return 65; }
  if grep -Ei '^[[:space:]]*(force_renewal|renew_by_default)[[:space:]]*=[[:space:]]*(true|yes|1)([[:space:]]|$)|--force-renewal' \
    "$workspace/renewal.conf" >/dev/null; then
    error 'test-only force flag persisted in renewal state'
    return 65
  fi
}

## @fn renew()
## @brief Invokes one genuine real-Certbot renewal through one-shot test trigger.
## @details
## An unchanged public producer fetches its own S3 archive into fresh state.
## Only the private single-use marker authorizes the test-only Certbot argv
## adapter to add --force-renewal to one selected renewal. All renewed material,
## S3 metadata and account continuity are verified by independent readbacks.
## @param workspace Private ephemeral tmpfs scratch directory.
## @param expected Previously observed remote archive SHA-256.
## @returns Nonsecret renewed object and DER SHA-256 identities.
## @retval 0 New real selected certificate was published and independently read.
## @retval 65 Missing or inconsistent proof.
## @retval 74 Real provider or S3 operation failed.
renew() {
  local workspace="$1" expected="$2" original='' oldcert='' newcert=''
  local original_account='' new_account='' updated='' old_etag='' new_etag=''
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] ||
    { error 'invalid pre-renewal archive identity'; return 64; }
  [[ ! -e "$FORCE_STATE" && ! -L "$FORCE_STATE" ]] ||
    { error 'renewal activation state already occupied'; return 65; }

  fetch_archive "$workspace/before.tar.gz" || return $?
  original="$(sha256sum "$workspace/before.tar.gz" | awk '{print $1}')" || return 74
  [[ "$original" == "$expected" ]] ||
    { error 'pre-renewal remote archive identity changed'; return 65; }
  verify_account "$workspace/before.tar.gz" || return $?
  verify_selected_only "$workspace/before.tar.gz" || return $?
  verify_certificate "$workspace/before.tar.gz" "$workspace" || return $?
  oldcert="$(sha256sum "$workspace/leaf.der" | awk '{print $1}')" || return 74
  original_account="$(account_identity "$workspace/before.tar.gz")" || return $?
  object_metadata "$workspace/before.meta" || return $?
  old_etag="$(jq -r '.[0]' "$workspace/before.meta")" || return 65

  mkdir -m 700 -- "$FORCE_STATE" ||
    { error 'private renewal authorization state unavailable'; return 74; }
  printf '%s\n' 'certbotbot-e2e-task-248' >"$FORCE_STATE/intent" ||
    { error 'renewal authorization write failed'; return 74; }
  chmod 600 -- "$FORCE_STATE/intent" || return 74

  # Real Certbot's plugins and show_account probes are forwarded normally.
  # The shim permits the force flag only on the selected renewal, then
  # consumes the private marker before execing /usr/bin/certbot.
  if ! issuer ordinary >"$workspace/renew.log" 2>&1; then
    error 'selected real-Certbot renewal or publication failed'
    return 74
  fi
  [[ ! -e "$FORCE_STATE/intent" &&
    -f "$FORCE_STATE/receipt" && ! -L "$FORCE_STATE/receipt" &&
    "$(cat "$FORCE_STATE/receipt" 2>/dev/null)" == real-certbot-selected-renewal-forced ]] ||
    { error 'single-use real-Certbot adapter was not consumed'; return 65; }
  grep -Fq 'certbotbot: checked ' "$workspace/renew.log" &&
    grep -Fq '; published=true' "$workspace/renew.log" ||
    { error 'renewal was not durably published by producer'; return 65; }

  object_metadata "$workspace/after.meta" || return $?
  new_etag="$(jq -r '.[0]' "$workspace/after.meta")" || return 65
  [[ "$new_etag" != "$old_etag" ]] ||
    { error 'S3 object ETag unchanged after real renewal'; return 65; }
  fetch_archive "$workspace/after.tar.gz" || return $?
  updated="$(sha256sum "$workspace/after.tar.gz" | awk '{print $1}')" || return 74
  [[ "$updated" =~ ^[0-9a-f]{64}$ && "$updated" != "$original" ]] ||
    { error 'renewed object bytes are unchanged'; return 65; }
  verify_account "$workspace/after.tar.gz" || return $?
  verify_selected_only "$workspace/after.tar.gz" || return $?
  verify_certificate "$workspace/after.tar.gz" "$workspace" || return $?
  verify_no_force_persistence "$workspace/after.tar.gz" "$workspace" || return $?
  new_account="$(account_identity "$workspace/after.tar.gz")" || return $?
  [[ "$new_account" == "$original_account" ]] ||
    { error 'ACME account key or identity changed during renewal'; return 65; }
  newcert="$(sha256sum "$workspace/leaf.der" | awk '{print $1}')" || return 74
  [[ "$newcert" =~ ^[0-9a-f]{64}$ && "$newcert" != "$oldcert" ]] ||
    { error 'no new signed certificate bytes after real renewal'; return 65; }

  printf 'local-first-issue: renewed_archive_sha256=%s\n' "$updated"
  printf 'local-first-issue: renewed_cert_der_sha256=%s\n' "$newcert"
  printf '%s\n' 'local-first-issue: real_certbot_force_trigger_consumed=true'
}

## @fn main()
## @brief Runs one bounded phase and removes private state on every exit.
main() {
  local mode="${1-}" workspace=''
  case "$mode" in
    bootstrap) (( $# == 1 )) || { error 'unexpected bootstrap arguments'; return 64; } ;;
    verify) (( $# == 2 )) || { error 'expected one digest'; return 64; } ;;
    noop)
      (( $# == 3 )) || { error 'expected flavor and archive digest'; return 64; }
      case "$2" in development|ordinary|minified) ;; *)
        error 'invalid no-op producer flavor'; return 64 ;;
      esac
      [[ "$3" =~ ^[a-f0-9]{64}$ ]] || { error 'invalid no-op digest'; return 64; }
      ;;
    renew)
      (( $# == 2 )) || { error 'expected one renewal archive digest'; return 64; }
      [[ "$2" =~ ^[a-f0-9]{64}$ ]] ||
        { error 'invalid renewal archive digest'; return 64; }
      ;;
    baseline)
      (( $# == 1 )) || { error 'unexpected baseline arguments'; return 64; }
      ;;
    fault)
      (( $# == 3 )) || { error 'expected fault name and archive digest'; return 64; }
      case "$2" in
        ca-production|s3-unavailable|route53-unavailable|acme-unavailable|acme-order-rejected|s3-put-reject|corrupt-archive) ;;
        *) error 'unsupported fault scenario'; return 64 ;;
      esac
      [[ "$3" =~ ^[a-f0-9]{64}$ ]] ||
        { error 'invalid fault archive digest'; return 64; }
      ;;
    *) error 'usage: first-issue.bash bootstrap|verify|noop|renew|baseline|fault'; return 64 ;;
  esac
  workspace="$(mktemp -d)" ||
    { error 'private test workspace unavailable'; return 74; }
  if [[ "$mode" == renew ]]; then
    trap 'rm -rf -- "$workspace" "$FORCE_STATE"' EXIT
  else
    trap 'rm -rf -- "$workspace"' EXIT
  fi
  case "$mode" in
    bootstrap) bootstrap "$workspace" ;;
    verify) verify "$workspace" "$2" ;;
    noop) noop "$workspace" "$2" "$3" ;;
    renew) renew "$workspace" "$2" ;;
    baseline)
      # Test-only helpers are never sourced in release or positive runs.
      source /usr/local/libexec/certbotbot-e2e/negative-scenarios.bash
      negative_baseline "$workspace"
      ;;
    fault)
      source /usr/local/libexec/certbotbot-e2e/negative-scenarios.bash
      negative_scenario "$workspace" "$2" "$3"
      ;;
  esac
}

main "$@"
