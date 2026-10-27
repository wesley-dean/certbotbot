#!/usr/bin/env bats

# All cases are credential-free. A false admission must never invoke AWS,
# Certbot, Route53, S3, or any live ACME endpoint.
setup() {
  GUARD="$BATS_TEST_DIRNAME/../ci/e2e-staging-guard.bash"
  WORKFLOW="$BATS_TEST_DIRNAME/../.github/workflows/e2e-staging.yml"
  LIVE="$BATS_TEST_DIRNAME/../ci/e2e-staging-live.bash"
}

dispatch() {
  run env -u ACME_ENVIRONMENT \
    GITHUB_REPOSITORY=wesley-dean/certbotbot \
    GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main \
    GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 \
    GITHUB_ACTOR=wesley-dean \
    GITHUB_TRIGGERING_ACTOR=wesley-dean \
    E2E_ACME_ENVIRONMENT=staging \
    "$@" bash "$GUARD" dispatch
}

scope() {
  run env -u ACME_ENVIRONMENT \
    GITHUB_REPOSITORY=wesley-dean/certbotbot \
    GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main \
    GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 \
    GITHUB_ACTOR=wesley-dean \
    GITHUB_TRIGGERING_ACTOR=wesley-dean \
    E2E_ACME_ENVIRONMENT=staging \
    AWS_ACCESS_KEY_ID=TESTONLYID \
    AWS_SECRET_ACCESS_KEY=TESTONLYSECRET \
    CERTBOTBOT_AWS_REGION=us-east-1 \
    E2E_S3_BUCKET=staging-fixture-bucket \
    E2E_S3_KEY=latest.tar.gz \
    E2E_ROUTE53_ZONE_ID=Z1234567890 \
    E2E_DOMAIN=test.example.invalid \
    "$@" bash "$GUARD" scope
}

@test "maintained guard and credentialed staging scripts pass Bash syntax validation" {
  run bash -n "$GUARD"
  [ "$status" -eq 0 ]
  run bash -n "$LIVE"
  [ "$status" -eq 0 ]
}

@test "owner-dispatched trusted-main fixed staging is admitted without network access" {
  dispatch
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "production and missing CA selection are both refused" {
  dispatch E2E_ACME_ENVIRONMENT=production
  [ "$status" -eq 64 ]
  dispatch E2E_ACME_ENVIRONMENT=
  [ "$status" -eq 64 ]
  dispatch E2E_ACME_ENVIRONMENT=https://acme-staging-v02.api.letsencrypt.org/directory
  [ "$status" -eq 64 ]
}

@test "a conflicting ambient production CA cannot override staging policy" {
  dispatch ACME_ENVIRONMENT=production
  [ "$status" -eq 64 ]
}

@test "untrusted PR, push, fork and non-main refs are refused" {
  dispatch GITHUB_EVENT_NAME=pull_request
  [ "$status" -eq 64 ]
  dispatch GITHUB_EVENT_NAME=push
  [ "$status" -eq 64 ]
  dispatch GITHUB_REPOSITORY=example/fork
  [ "$status" -eq 64 ]
  dispatch GITHUB_REF=refs/heads/agent/feat/staging
  [ "$status" -eq 64 ]
}

@test "manual dispatch requires the repository owner as original and rerun actor" {
  dispatch GITHUB_ACTOR=other-collaborator
  [ "$status" -eq 64 ]
  dispatch GITHUB_TRIGGERING_ACTOR=other-collaborator
  [ "$status" -eq 64 ]
  dispatch GITHUB_ACTOR=
  [ "$status" -eq 64 ]
  dispatch GITHUB_TRIGGERING_ACTOR=
  [ "$status" -eq 64 ]
}

@test "manual dispatch requires an immutable trusted source SHA" {
  dispatch GITHUB_SHA=bad
  [ "$status" -eq 64 ]
}

@test "scope preflight admits a known-safe synthetic resource set" {
  scope
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "scope rejects missing AWS credentials and malformed resource identity" {
  scope AWS_ACCESS_KEY_ID=
  [ "$status" -eq 65 ]
  scope CERTBOTBOT_AWS_REGION=invalid
  [ "$status" -eq 65 ]
  scope E2E_ROUTE53_ZONE_ID=invalid
  [ "$status" -eq 65 ]
  scope E2E_DOMAIN='*.example.invalid'
  [ "$status" -eq 65 ]
  scope E2E_DOMAIN=example..invalid
  [ "$status" -eq 65 ]
}

@test "scope rejects unsafe S3 current keys and bucket names" {
  scope E2E_S3_KEY=../../production.tar.gz
  [ "$status" -eq 65 ]
  scope E2E_S3_KEY=/production/archive.tar.gz
  [ "$status" -eq 65 ]
  scope E2E_S3_BUCKET=Bad_Bucket
  [ "$status" -eq 65 ]
}

@test "workflow has only manual trigger and never imports credential secrets into build" {
  [ -f "$WORKFLOW" ]
  grep -Fxq '  workflow_dispatch:' "$WORKFLOW"
  # CKV_GHA_7: dispatch carries zero inputs. The CA is compiled into the
  # manually selected workflow and the original/triggering actor is checked.
  ! grep -Eq '^[[:space:]]+inputs:' "$WORKFLOW"
  ! grep -Fq '${{ inputs.' "$WORKFLOW"
  [ "$(grep -c "github.actor == 'wesley-dean'" "$WORKFLOW")" -eq 3 ]
  [ "$(grep -c "github.triggering_actor == 'wesley-dean'" "$WORKFLOW")" -eq 3 ]
  ! grep -Eq '^  (pull_request|pull_request_target|push|schedule|release|workflow_call):' "$WORKFLOW"
  ! grep -Fq 'vars.' "$WORKFLOW"
  ! awk '/^  prepare:/{ inside=1; next } /^  issue:/{ inside=0 } inside' "$WORKFLOW" | grep -Fq 'secrets.'
  ! grep -Fq 'secrets.E2E_CONTACT_EMAIL' "$WORKFLOW"
  ! grep -Fq 'secrets.GPG_SYMMETRIC_KEY' "$WORKFLOW"
  ! grep -Fq 'secrets.GHCR_TOKEN' "$WORKFLOW"
  ! grep -Fq 'secrets.DOCKERHUB_TOKEN' "$WORKFLOW"
  grep -Fq "github.ref == 'refs/heads/main'" "$WORKFLOW"
  grep -Fq 'cancel-in-progress: false' "$WORKFLOW"
}

@test "workflow verifies same-run producer before each separate credentialed stage" {
  [ -f "$LIVE" ]
  [ "$(grep -c 'bash ci/producer-handoff.bash verify dist' "$WORKFLOW")" -eq 2 ]
  [ "$(grep -c 'bash ci/e2e-staging-live.bash' "$WORKFLOW")" -eq 2 ]
  grep -Fq 'needs: [prepare, issue]' "$WORKFLOW"
  grep -Fq 'EXPECTED_ARCHIVE_SHA256:' "$WORKFLOW"
  grep -Fq -- '--acme-environment staging' "$LIVE"
  ! grep -Fq -- '--acme-environment production' "$LIVE"
  ! grep -Eq '^[[:space:]]+register([[:space:]]|$)' "$LIVE"
}
