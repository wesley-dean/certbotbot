#!/usr/bin/env bash
# shellcheck shell=bash
## @file tests/oci-lifecycle-case.bash
## @brief Exercise a producer scenario using local synthetic S3 and Certbot.
## @details
## The caller supplies one read-only fixture directory and a private,
## disposable writable workspace. All mock cloud interactions are local.
## This driver invokes the ordinary producer and verifies publication and
## failure invariants, identically on the host and inside the same OCI image.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## A deterministic case summary without sensitive certificate material.
## @par STDERR
## Nonsecret scenario diagnostics when a case violates its contract.
## @retval 0 The selected lifecycle contract was demonstrated.
## @retval 1 The producer or mocked environment broke the contract.
## @retval 64 The caller supplied an invalid scenario.

set -euo pipefail
if (( $# != 2 )); then
  printf 'usage: %s PRODUCER SCENARIO\n' "$0" >&2
  exit 64
fi
producer=$1
scenario=$2
fixture=${OCI_FIXTURE_ROOT:-/fixture}
work=${OCI_RUN_ROOT:-/run/certbotbot}
[[ -d "$fixture/bin" && -f "$fixture/seeded-remote.tar.gz" &&
  -d "$work" && -w "$work" && -f "$producer" ]] || {
  printf 'oci lifecycle: missing producer, fixture, or private workspace\n' >&2
  exit 1
}

export HOME="$work" TMPDIR="$work"
export PATH="$fixture/bin:$PATH"
export LIFECYCLE_REMOTE="$work/remote.tar.gz"
export LIFECYCLE_CALLS="$work/calls"
export LIFECYCLE_CONTEXTS="$work/certbot-contexts"
export LIFECYCLE_EXPECTED_KEY=latest.tar.gz
export LIFECYCLE_EXPECTED_CERT_NAME=example.com
export LIFECYCLE_BACKUP_ENABLED_MOCK=false
export LIFECYCLE_BACKUP_KEY=archive-20261020.tar.gz
export LIFECYCLE_BACKUP_REMOTE="$work/dated-backup.tar.gz"
export LIFECYCLE_BACKUP_META="$work/dated-backup.meta"
export LIFECYCLE_MODE=ok
export INCLUDE_SUBDOMAINS=true UPLOAD_NO_RENEWAL=false
unset GPG_SYMMETRIC_KEY CERTBOTBOT_GPG_SECRET AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
unset CERT_NAME ADDITIONAL_SANS S3_KEY S3_BUCKET S3_KEY_TEMPLATE
unset ARCHIVE_ENCRYPTION ARCHIVE_MIGRATION

cp -- "$fixture/seeded-remote.tar.gz" "$LIFECYCLE_REMOTE"
chmod 0600 "$LIFECYCLE_REMOTE"
baseline="$(sha256sum "$LIFECYCLE_REMOTE" | awk '{print $1}')"
: > "$LIFECYCLE_CALLS"
: > "$LIFECYCLE_CONTEXTS"
printf '%s\n' 'UPLOAD_NO_RENEWAL=false' > "$work/config.env"

domain=example.com
extra=()
expected_uploads=0
expected_renewals=1
expected_published=false
case "$scenario" in
  no-op) ;;
  wildcard) domain='*.example.com' ;;
  forced)
    extra=(--config "$work/config.env" --upload-no-renewal=true)
    expected_uploads=1
    expected_published=true
    ;;
  cli-false)
    printf '%s\n' 'UPLOAD_NO_RENEWAL=true' > "$work/config.env"
    export UPLOAD_NO_RENEWAL=true
    extra=(--config "$work/config.env" --upload-no-renewal=false)
    ;;
  env-true)
    export UPLOAD_NO_RENEWAL=true
    extra=(--config "$work/config.env")
    expected_uploads=1
    expected_published=true
    ;;
  missing)
    rm -f -- "$LIFECYCLE_REMOTE"
    expected_renewals=0
    ;;
  denied)
    export LIFECYCLE_MODE=head-denied
    expected_renewals=0
    ;;
  corrupt)
    export LIFECYCLE_MODE=get-corrupt
    expected_renewals=0
    ;;
  partial)
    export LIFECYCLE_MODE=get-partial
    expected_renewals=0
    ;;
  bad-option)
    extra=(--oci-unknown-option)
    expected_renewals=0
    ;;
  *)
    printf 'oci lifecycle: unknown scenario\n' >&2
    exit 64
    ;;
esac

status=0
"$producer" --s3-bucket fixture-bucket "${extra[@]}" "$domain" \
  > "$work/producer.out" 2> "$work/producer.err" || status=$?
uploads="$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS" || :)"
renewals="$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS" || :)"
issues="$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS" || :)"
[[ "$uploads" =~ ^[0-9]+$ && "$renewals" =~ ^[0-9]+$ &&
  "$issues" =~ ^[0-9]+$ ]] || exit 1

case "$scenario" in
  missing) [[ "$status" -eq 66 ]] || exit 1 ;;
  denied|corrupt|partial|bad-option) [[ "$status" -ne 0 ]] || exit 1 ;;
  *)
    [[ "$status" -eq 0 ]] || {
      printf 'oci lifecycle: %s returned %d\n' "$scenario" "$status" >&2
      exit 1
    }
    ;;
esac
[[ "$uploads" -eq "$expected_uploads" &&
  "$renewals" -eq "$expected_renewals" && "$issues" -eq 0 ]] || {
  printf 'oci lifecycle: %s unexpected S3/Certbot calls\n' "$scenario" >&2
  exit 1
}

if ((status == 0)); then
  grep -Fq "published=$expected_published" "$work/producer.out" || {
    printf 'oci lifecycle: %s wrong published status\n' "$scenario" >&2
    exit 1
  }
  grep -Fq 'checked example.com' "$work/producer.out" || {
    printf 'oci lifecycle: %s did not retain selected lineage\n' "$scenario" >&2
    exit 1
  }
fi
if ((uploads == 0)) && [[ -f "$LIFECYCLE_REMOTE" ]]; then
  [[ "$(sha256sum "$LIFECYCLE_REMOTE" | awk '{print $1}')" == "$baseline" ]] || {
    printf 'oci lifecycle: %s changed authoritative bytes without put\n' "$scenario" >&2
    exit 1
  }
fi
[[ ! -s "$work/producer.err" || $status -ne 0 ]] || {
  printf 'oci lifecycle: %s unexpected successful stderr\n' "$scenario" >&2
  exit 1
}
! grep -Eq 'private-token-DO-NOT-LOG|mock-private-PUT-TOKEN' \
  "$work/producer.out" "$work/producer.err" || {
  printf 'oci lifecycle: %s leaked mocked cloud diagnostic\n' "$scenario" >&2
  exit 1
}
printf 'case=%s result=%s uploads=%s renewals=%s issues=%s\n' \
  "$scenario" "$(if ((status == 0)); then printf success; else printf failure; fi)" \
  "$uploads" "$renewals" "$issues"
