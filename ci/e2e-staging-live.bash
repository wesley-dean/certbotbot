#!/usr/bin/env bash
# shellcheck shell=bash
## @file ci/e2e-staging-live.bash
## @brief Runs one authorized, real staging-only public producer lifecycle.
## @details
## Invoked only by the manual trusted-main E2E workflow after an exact
## same-run release-artifact handoff has been independently verified.
## Stage issue requires a preseeded staging account but no existing selected
## certificate and checks an authentic first issuance/publication. Stage
## restore runs on another GitHub job/runner, downloads the same S3 object
## afresh and requires the normal selected renewal/no-op path. Neither stage
## registers an account, forces renewal, decrypts archives, or calls production.
## All cloud/Certbot details remain in owned mode-0700 private temporary files;
## only fixed nonsecret status messages and an opaque object digest cross jobs.
##
## @param stage "issue" or "restore".
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Fixed redacted progress/evidence status only.
## @par STDERR
## Fixed failure category; raw AWS and Certbot diagnostics are suppressed.
## @retval 0 Authorized staging outcome and remote continuity verified.
## @retval 64 Invalid invocation or authorization.
## @retval 65 Unsafe or mismatched staging S3/account/domain state.
## @retval 69 Required provider tooling unavailable.
## @retval 74 Cloud, Certbot, or S3 publication failure.
set -euo pipefail
set +x
umask 077

fail() {
  printf 'staging E2E: %s\n' "$1" >&2
  exit "${2:-65}"
}

[[ $# -eq 1 ]] || fail 'expected one scenario' 64
case "$1" in issue|restore) stage="$1" ;; *) fail 'unsupported scenario' 64 ;; esac
bash ci/e2e-staging-guard.bash scope || fail 'staging admission rejected' 64
for executable in aws jq tar sha256sum certbot openssl; do
  command -v "$executable" >/dev/null 2>&1 ||
    fail 'required external tooling unavailable' 69
done
[[ -n "${RUNNER_TEMP-}" && -d "$RUNNER_TEMP" ]] ||
  fail 'private runner temp directory unavailable' 65
[[ -f dist/certbotbot.bash && ! -L dist/certbotbot.bash &&
  -x dist/certbotbot.bash &&
  -f dist/certbotbot.bash.sha256 &&
  ! -L dist/certbotbot.bash.sha256 ]] ||
  fail 'shipped public artifact is unavailable' 65
(cd dist && sha256sum -c certbotbot.bash.sha256 >/dev/null 2>&1) ||
  fail 'public artifact checksum is invalid' 65

# Ignore ambient AWS profile, override endpoint and region configuration.
# All AWS account authority comes solely from this stage's injected secrets.
unset AWS_PROFILE AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
unset AWS_ENDPOINT_URL AWS_ENDPOINT_URL_S3 AWS_ENDPOINT_URL_ROUTE53
export AWS_DEFAULT_REGION="$CERTBOTBOT_AWS_REGION"
export AWS_REGION="$CERTBOTBOT_AWS_REGION"
export AWS_EC2_METADATA_DISABLED=true
unset GPG_SYMMETRIC_KEY
unset ACME_ENVIRONMENT S3_KEY_TEMPLATE S3_KEY ADDITIONAL_SANS

# Decode at most 32 MiB of untrusted remote archive data before asking
# tar to list members. This is a nonextracting supplementary check; the
# public producer applies its stronger native archive validator.
list_bounded_archive() {
  local source_archive="$1" member_list="$2" bytes
  if ! (set -o pipefail
    gzip -cd -- "$source_archive" 2>/dev/null |
      head -c 33554433 >"$private/decoded.tar"
  ); then
    fail 'staging archive decompression failed or exceeded bounded limit'
  fi
  bytes="$(wc -c <"$private/decoded.tar")"
  if (( bytes < 1024 || bytes > 33554432 )); then
    fail 'staging archive exceeds safe decoded size'
  fi
  tar -tf "$private/decoded.tar" >"$member_list" 2>/dev/null ||
    fail 'staging archive has invalid tar boundaries'
  rm -f -- "$private/decoded.tar"
}

private="$(mktemp -d "$RUNNER_TEMP/staging-e2e.XXXXXXXX")" ||
  fail 'cannot allocate private runner workspace' 65
trap 'rm -rf -- "$private"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -m 700 "$private/runtime"
: >"$private/empty.env"
export TMPDIR="$private/runtime"
export HOME="$private/runtime"

# Preflight: no implicit registration, no blind object creation, and no
# classification of an ambiguous S3 error as a missing object.
aws sts get-caller-identity >/dev/null 2>&1 ||
  fail 'AWS execution identity preflight failed' 74
aws s3api head-bucket --bucket "$E2E_S3_BUCKET" >/dev/null 2>&1 ||
  fail 'staging bucket is unavailable' 74
region="$(aws s3api get-bucket-location --bucket "$E2E_S3_BUCKET" \
  --query LocationConstraint --output text 2>/dev/null)" ||
  fail 'staging bucket region is unavailable' 74
[[ "$region" == None ]] && region=us-east-1
[[ "$region" == "$CERTBOTBOT_AWS_REGION" ]] ||
  fail 'staging bucket region mismatch'
aws route53 get-hosted-zone --id "$E2E_ROUTE53_ZONE_ID" \
  --output json >"$private/zone.json" 2>/dev/null ||
  fail 'staging public DNS zone unavailable' 74
zone_name="$(jq -er \
  'select(.HostedZone.Config.PrivateZone == false) | .HostedZone.Name' \
  "$private/zone.json" 2>/dev/null)" ||
  fail 'DNS zone is not public'
zone_name="${zone_name%.}"
case "$E2E_DOMAIN" in
  "$zone_name"|*."$zone_name") ;;
  *) fail 'test domain does not belong to selected public zone' ;;
esac

aws s3api head-object --bucket "$E2E_S3_BUCKET" \
  --key "$E2E_S3_KEY" >/dev/null 2>&1 ||
  fail 'existing staging seed cannot be proven' 74
aws s3api get-object --bucket "$E2E_S3_BUCKET" \
  --key "$E2E_S3_KEY" "$private/before.tar.gz" >/dev/null 2>&1 ||
  fail 'staging archive cannot be read' 74
list_bounded_archive "$private/before.tar.gz" "$private/members"
# This checks the CA namespace without extracting untrusted tar members.
# The public producer supplies the authoritative bounded archive validator.
grep -Eq '^(\./)?accounts/acme-staging-v02\.api\.letsencrypt\.org/directory/[^/]+/regr\.json$' \
  "$private/members" ||
  fail 'native staging ACME registration was not found'
if grep -Eq '^(\./)?accounts/acme-v02\.api\.letsencrypt\.org/' \
    "$private/members"; then
  fail 'production account found in staging archive'
fi

if [[ "$stage" == restore ]]; then
  [[ "${EXPECTED_ARCHIVE_SHA256-}" =~ ^[a-f0-9]{64}$ ]] ||
    fail 'missing first-run archive identity'
  before_sha="$(sha256sum "$private/before.tar.gz" | awk '{print $1}')"
  [[ "$before_sha" == "$EXPECTED_ARCHIVE_SHA256" ]] ||
    fail 'staging archive changed between independent runners'
fi

# All direct arguments explicitly select the approved bounded CA and
# no-retention plaintext behavior; empty private --config blocks ./.env.
# No contact address is injected and this command never calls "register".
if dist/certbotbot.bash \
  --config "$private/empty.env" \
  --acme-environment staging \
  --domain "$E2E_DOMAIN" \
  --include-subdomains true \
  --s3-bucket "$E2E_S3_BUCKET" \
  --s3-key "$E2E_S3_KEY" \
  --archive-encryption none \
  --archive-migration none \
  --upload-no-renewal false \
  --dated-backup-enabled false \
  --backup-retention-count 0 >"$private/producer.log" 2>&1; then
  :
else
  fail 'public producer failed; remote write state may be uncertain' 74
fi
if [[ "$stage" == issue ]]; then
  grep -Eq '^certbotbot: issued .*; published=true$' \
    "$private/producer.log" ||
    fail 'first-issuance outcome was not verified; inspect privately'
else
  grep -Eq '^certbotbot: checked .*; published=false$' \
    "$private/producer.log" ||
    fail 'selected no-op outcome was not verified; inspect privately'
fi

# Independently GET and hash the S3 object rather than trusting a producer
# status line. A failed read is NOT proof that a PUT was rolled back.
aws s3api get-object --bucket "$E2E_S3_BUCKET" \
  --key "$E2E_S3_KEY" "$private/after.tar.gz" >/dev/null 2>&1 ||
  fail 'published/current staging object is not independently readable' 74
list_bounded_archive "$private/after.tar.gz" "$private/after-members"
after_sha="$(sha256sum "$private/after.tar.gz" | awk '{print $1}')"
if [[ "$stage" == restore ]]; then
  [[ "$after_sha" == "$before_sha" ]] ||
    fail 'no-op unexpectedly changed durable staging object'
else
  [[ "$after_sha" != "$(sha256sum "$private/before.tar.gz" | awk '{print $1}')" ]] ||
    fail 'first issuance did not change durable object'
  [[ -n "${GITHUB_OUTPUT-}" ]] ||
    fail 'workflow output channel unavailable' 65
  printf 'object_sha256=%s\n' "$after_sha" >> "$GITHUB_OUTPUT"
fi
printf 'staging E2E: %s completed; real staging ACME/Route53/S3 boundary exercised; private diagnostics withheld\n' "$stage"
