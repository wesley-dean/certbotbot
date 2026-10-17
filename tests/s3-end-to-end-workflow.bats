#!/usr/bin/env bats

## @file tests/s3-end-to-end-workflow.bats
## @brief Check that enabled S3 CI has no production or secret authority.
## @details
## This source-level regression check complements real API integration.
## Networked tests run only in the specifically scoped S3 workflow.
## The conditions below prevent accidentally changing its trigger or
## privilege boundary when updating the dependency or execution wrapper.
## @see doc/adr/ADR-051-disposable-s3-end-to-end-ci.md

setup() {
  export E2E_WORKFLOW="$BATS_TEST_DIRNAME/../.github/workflows/s3-end-to-end.yml"
  [ -f "$E2E_WORKFLOW" ]
}

@test "storage E2E is an installed PR and manually runnable workflow" {
  grep -Fxq '  pull_request:' "$E2E_WORKFLOW"
  grep -Fxq '  workflow_dispatch:' "$E2E_WORKFLOW"
  ! grep -Eq '^[[:space:]]*pull_request_target:' "$E2E_WORKFLOW"
  ! grep -Eq '^[[:space:]]*schedule:' "$E2E_WORKFLOW"
}

@test "storage E2E has no privileged GitHub access or persistent checkout token" {
  grep -Fxq 'permissions:' "$E2E_WORKFLOW"
  grep -Fxq '  contents: read' "$E2E_WORKFLOW"
  grep -Fxq '      contents: read' "$E2E_WORKFLOW"
  grep -Fxq '          persist-credentials: false' "$E2E_WORKFLOW"
  ! grep -Eq 'id-token:[[:space:]]*write' "$E2E_WORKFLOW"
  ! grep -Fq 'secrets.' "$E2E_WORKFLOW"
  ! grep -Fq 'role-to-assume' "$E2E_WORKFLOW"
  ! grep -Fq 'aws-actions/configure-aws-credentials' "$E2E_WORKFLOW"
}

@test "storage E2E image is pinned to an immutable digest, and S3 binds loopback" {
  grep -Eq 'image=chrislusf/seaweedfs@sha256:[a-f0-9]{64}$' "$E2E_WORKFLOW"
  grep -Fq -- '--publish 127.0.0.1:8333:8333' "$E2E_WORKFLOW"
  grep -Fq -- '--no-new-privileges' "$E2E_WORKFLOW"
  grep -Fq '      S3_ENDPOINT_URL: http://127.0.0.1:8333' "$E2E_WORKFLOW"
  ! grep -Eq '^[[:space:]]*image=.*:latest([[:space:]]|$)' "$E2E_WORKFLOW"
}

@test "storage E2E runs the Make integration contract rather than product issuance" {
  grep -Fq 'make test-s3-interop' "$E2E_WORKFLOW"
  grep -Fq 'CERTBOTBOT_S3_INTEROP_CONFIRM: "yes"' "$E2E_WORKFLOW"
  grep -Fq 'ACME_ENVIRONMENT: staging' "$E2E_WORKFLOW"
  grep -Fq 'AWS_EC2_METADATA_DISABLED: "true"' "$E2E_WORKFLOW"
  ! grep -Fq 'GPG_PASSPHRASE:' "$E2E_WORKFLOW"
  ! grep -Fq 'CERTBOTBOT_RELEASE_ENABLED:' "$E2E_WORKFLOW"
  [ ! -e "$BATS_TEST_DIRNAME/../.github/workflows/real-staging-evidence.yml" ]
}
