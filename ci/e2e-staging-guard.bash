#!/usr/bin/env bash
# shellcheck shell=bash
## @file ci/e2e-staging-guard.bash
## @brief Rejects unapproved or non-staging GitHub Actions dispatches.
## @details
## Credential-free, network-free entry guard for milestone 4. The manual
## dispatch itself is the owner's affirmative action. No mutable build
## parameters are permitted (CKV_GHA_7). The workflow
## also repeats an inline guard before checkout, since this file is not yet
## available before the first network-capable checkout operation.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed non-sensitive diagnostic categories; values are never echoed.
## @retval 0 All required admission checks passed.
## @retval 64 Incorrect manual invocation or owner authorization.
## @retval 65 Missing or malformed scoped test resources.
set -euo pipefail
set +x

reject() {
  printf 'staging E2E guard: %s\n' "$1" >&2
  exit "${2:-64}"
}

[[ $# -eq 1 ]] || reject 'expected one phase argument'
case "$1" in
  dispatch|scope) ;;
  *) reject 'unsupported phase' ;;
esac
[[ "${GITHUB_REPOSITORY-}" == wesley-dean/certbotbot ]] ||
  reject 'untrusted repository'
[[ "${GITHUB_EVENT_NAME-}" == workflow_dispatch ]] ||
  reject 'event is not a manual dispatch'
[[ "${GITHUB_REF-}" == refs/heads/main ]] ||
  reject 'workflow ref is not main'
[[ "${GITHUB_SHA-}" =~ ^[0-9a-f]{40}$ ]] ||
  reject 'missing immutable source commit'
[[ "${GITHUB_ACTOR-}" == wesley-dean &&
  "${GITHUB_TRIGGERING_ACTOR-}" == wesley-dean ]] ||
  reject 'dispatch actor is not the authorized operator'
[[ "${E2E_ACME_ENVIRONMENT-}" == staging ]] ||
  reject 'ACME selection is not explicitly staging'
[[ -z "${ACME_ENVIRONMENT-}" ||
  "${ACME_ENVIRONMENT-}" == staging ]] ||
  reject 'conflicting exported CA selection'

if [[ "$1" == scope ]]; then
  [[ -n "${AWS_ACCESS_KEY_ID-}" && -n "${AWS_SECRET_ACCESS_KEY-}" ]] ||
    reject 'missing AWS credential pair' 65
  [[ "${CERTBOTBOT_AWS_REGION-}" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]] ||
    reject 'invalid region identity' 65
  [[ "${E2E_S3_BUCKET-}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] ||
    reject 'invalid bucket identity' 65
  [[ "${E2E_S3_KEY-}" =~ ^[A-Za-z0-9._/-]{1,512}$ &&
    "${E2E_S3_KEY-}" != /* &&
    "${E2E_S3_KEY-}" != *..* ]] ||
    reject 'invalid dedicated current-key identity' 65
  [[ "${E2E_ROUTE53_ZONE_ID-}" =~ ^Z[A-Z0-9]{6,32}$ ]] ||
    reject 'invalid public hosted-zone identity' 65
  [[ "${E2E_DOMAIN-}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ &&
    "${E2E_DOMAIN-}" == *.* &&
    "${E2E_DOMAIN-}" != *..* &&
    "${E2E_DOMAIN-}" != *.-* &&
    "${E2E_DOMAIN-}" != *-.* ]] ||
    reject 'invalid test-only DNS name' 65
fi
