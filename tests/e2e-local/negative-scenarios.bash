#!/usr/bin/env bash
# shellcheck shell=bash
## @file tests/e2e-local/negative-scenarios.bash
## @brief Runs explicitly bounded negative scenarios against the public producer.
## @details
## Sourced only by tests/e2e-local/first-issue.bash after its real S3, public
## producer, and independent archive helpers are defined. This is not a
## standalone release artifact. Every fixture and fault endpoint is synthetic
## and disposable. No success is inferred from failed provider replies, and no
## rollback is claimed after an uncertain remote write. ADR-047, task #246.

## @fn negative_issue_foreign_name()
## @brief Requests a new selected certificate so no-op cannot bypass faults.
## @param mode One literal approved negative provider fault.
## @param domain Exact selected synthetic name; blocked domain is test-only.
negative_issue_foreign_name() {
  local mode="$1" domain="${2:-fault.e2e.test}"
  case "$domain" in fault.e2e.test|blocked.e2e.test) ;;
    *) error 'unapproved fault-domain selection'; return 64 ;;
  esac
  LOCAL_E2E_FAULT_MODE="$mode" provider ordinary \
    --config "$CONFIG" \
    --acme-environment staging \
    --domain "$domain" \
    --include-subdomains false \
    --cert-name "$domain" \
    --s3-bucket "$BUCKET" \
    --s3-key "$KEY" \
    --archive-encryption none \
    --upload-no-renewal false
}

## @fn negative_issue_selected()
## @brief Invokes the existing ordinary producer against current remote state.
## @param mode One literal approved negative provider fault.
negative_issue_selected() {
  local mode="$1"
  LOCAL_E2E_FAULT_MODE="$mode" issuer ordinary
}

## @fn negative_corrupt_archive()
## @brief Seeds a distinct corrupt object and demands producer rejection.
## @param workspace Disposable scratch path.
## @retval 0 Both producer and independent S3 readback rejected mutation.
negative_corrupt_archive() {
  local workspace="$1" corrupt_key='latest-corrupt.tar.gz' observed=''
  printf '%s\n' 'invalid-gzip-local-only-archive' >"$workspace/corrupt-input"
  aws_local s3api put-object --bucket "$BUCKET" --key "$corrupt_key" \
    --body "$workspace/corrupt-input" --if-none-match '*' \
    --checksum-algorithm SHA256 --content-type application/gzip \
    >/dev/null 2>&1 ||
    { error 'cannot seed separate malformed S3 object'; return 74; }
  if LOCAL_E2E_FAULT_MODE=corrupt-archive provider ordinary \
    --config "$CONFIG" --acme-environment staging \
    --domain fault.e2e.test --include-subdomains false \
    --cert-name fault.e2e.test --s3-bucket "$BUCKET" \
    --s3-key "$corrupt_key" --archive-encryption none \
    --upload-no-renewal false >"$workspace/provider.log" 2>&1; then
    error 'public producer accepted corrupted remote archive'
    return 65
  fi
  if grep -Fq 'published=true' "$workspace/provider.log"; then
    error 'corrupt archive produced a misleading publication report'
    return 65
  fi
  aws_local s3api get-object --bucket "$BUCKET" --key "$corrupt_key" \
    "$workspace/corrupt-observed" > /dev/null 2>&1 ||
    { error 'corrupted S3 fixture could not be independently read'; return 74; }
  cmp -s "$workspace/corrupt-input" "$workspace/corrupt-observed" ||
    { error 'corrupted fixture was unexpectedly modified'; return 65; }
}

## @fn negative_baseline()
## @brief Independently reads the current unmodified certificate archive.
## @param workspace Disposable test scratch directory.
## @returns Nonsecret current remote archive SHA-256.
negative_baseline() {
  local workspace="$1" digest=''
  fetch_archive "$workspace/baseline.tar.gz" || return $?
  verify_account "$workspace/baseline.tar.gz" || return $?
  verify_certificate "$workspace/baseline.tar.gz" "$workspace" || return $?
  digest="$(sha256sum "$workspace/baseline.tar.gz" | awk '{print $1}')" ||
    return 74
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 65
  printf 'local-first-issue: baseline_archive_sha256=%s\n' "$digest"
}

## @fn negative_scenario()
## @brief Requires expected failure and independently unchanged SeaweedFS state.
## @param workspace Private disposable scratch directory.
## @param scenario One of six reviewed test failure injections.
## @param expected Previously checked SHA-256 of the current S3 object.
## @retval 0 Negative result and remote invariants established.
## @retval 65 Unexpected success, mutation, or missing evidence.
negative_scenario() {
  local workspace="$1" scenario="$2" expected="$3" actual=''
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] ||
    { error 'invalid expected negative baseline'; return 64; }
  fetch_archive "$workspace/before.tar.gz" || return $?
  actual="$(sha256sum "$workspace/before.tar.gz" | awk '{print $1}')" ||
    return 74
  [[ "$actual" == "$expected" ]] ||
    { error 'negative test started from a changed remote object'; return 65; }
  verify_account "$workspace/before.tar.gz" || return $?
  verify_certificate "$workspace/before.tar.gz" "$workspace" || return $?
  object_metadata "$workspace/before.meta" || return $?

  case "$scenario" in
    corrupt-archive)
      negative_corrupt_archive "$workspace" || return $?
      ;;
    ca-production)
      if LOCAL_E2E_FAULT_MODE=ca-production provider ordinary \
        --config "$CONFIG" --acme-environment production \
        --domain fault.e2e.test --include-subdomains false \
        --cert-name fault.e2e.test --s3-bucket "$BUCKET" \
        --s3-key "$KEY" --archive-encryption none \
        >"$workspace/provider.log" 2>&1; then
        error 'production CA was accepted in the private test profile'
        return 65
      fi
      ;;
    s3-unavailable|acme-unavailable)
      if negative_issue_selected "$scenario" >"$workspace/provider.log" 2>&1; then
        error 'unavailable provider returned unexpected success'
        return 65
      fi
      ;;
    route53-unavailable|s3-put-reject)
      if negative_issue_foreign_name "$scenario" >"$workspace/provider.log" 2>&1; then
        error 'new certificate unexpectedly succeeded through failed provider'
        return 65
      fi
      ;;
    acme-order-rejected)
      # Pebble rejects the identifier at the *newOrder* API, after genuine
      # account restoration and HTTPS ACME directory verification. This is
      # a real ACME policy refusal, not the gateway-down preflight case.
      if negative_issue_foreign_name "$scenario" blocked.e2e.test \
        >"$workspace/provider.log" 2>&1; then
        error 'Pebble accepted forbidden new-order identifier'
        return 65
      fi
      ;;
    *)
      error 'unknown negative test scenario'
      return 64
      ;;
  esac

  if [[ "$scenario" == s3-put-reject ]]; then
    [[ -f /tmp/.certbotbot-e2e-put-rejected &&
      ! -L /tmp/.certbotbot-e2e-put-rejected &&
      "$(cat /tmp/.certbotbot-e2e-put-rejected 2>/dev/null)" == synthetic-s3-put-rejected ]] ||
      { error 'rejected S3 PutObject boundary was never reached'; return 65; }
  fi
  if [[ -f "$workspace/provider.log" ]] &&
    grep -Fq 'published=true' "$workspace/provider.log"; then
    error 'failure path emitted misleading publication success'
    return 65
  fi

  object_metadata "$workspace/after.meta" || return $?
  cmp -s "$workspace/before.meta" "$workspace/after.meta" ||
    { error 'original S3 object metadata changed during failed operation'; return 65; }
  fetch_archive "$workspace/after.tar.gz" || return $?
  actual="$(sha256sum "$workspace/after.tar.gz" | awk '{print $1}')" ||
    return 74
  [[ "$actual" == "$expected" ]] ||
    { error 'original remote archive mutated during failed operation'; return 65; }
  verify_account "$workspace/after.tar.gz" || return $?
  verify_certificate "$workspace/after.tar.gz" "$workspace" || return $?
  printf 'local-first-issue: negative_scenario=%s; remote_unchanged=true; provider_success=false\n' "$scenario"
}
