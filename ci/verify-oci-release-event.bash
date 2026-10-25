#!/usr/bin/env bash
# shellcheck shell=bash
## @file ci/verify-oci-release-event.bash
## @brief Reject untrusted or incomplete Versioning events before OCI validation.
## @details
## All event fields are treated as untrusted. This preflight has no registry
## credentials and is intended only for a workflow_run on completed Versioning.
## It binds the event's repository, branch, conclusion, commit and run identity.
## A subsequent job must verify the actual release tag and eight attestations.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Static failure diagnostics.
## @retval 0 Candidate event has the required trusted metadata.
## @retval 65 Event does not meet the protected release preconditions.
## @retval 69 Required verification tools are unavailable.
set -euo pipefail
fail() { printf 'oci release gate: %s\n' "$1" >&2; exit 65; }
for tool in jq; do command -v "$tool" >/dev/null || exit 69; done
[[ "${GITHUB_EVENT_NAME-}" == workflow_run ]] || fail 'not a workflow_run event'
[[ -f "${GITHUB_EVENT_PATH-}" && ! -L "${GITHUB_EVENT_PATH-}" ]] || fail 'event document unavailable'
jq -e --arg repo 'wesley-dean/certbotbot' --arg sha "${TRUSTED_SOURCE_SHA-}" '
  .action == "completed" and
  .workflow_run.name == "Versioning" and
  .workflow_run.event == "push" and
  .workflow_run.head_branch == "main" and
  .workflow_run.conclusion == "success" and
  .workflow_run.head_repository.full_name == $repo and
  .repository.full_name == $repo and
  .workflow_run.head_sha == $sha and
  (.workflow_run.id | type == "number") and
  (.workflow_run.run_attempt | type == "number") and
  (.workflow_run.id > 0) and (.workflow_run.run_attempt > 0)
' "$GITHUB_EVENT_PATH" >/dev/null || fail 'untrusted or unsuccessful Versioning run'
[[ "${TRUSTED_SOURCE_SHA-}" =~ ^[0-9a-f]{40}$ ]] || fail 'invalid source SHA'
[[ "${TRUSTED_RUN_ID-}" =~ ^[1-9][0-9]*$ && "${TRUSTED_ATTEMPT-}" =~ ^[1-9][0-9]*$ ]] || fail 'invalid run identity'
jq -e --argjson run "${TRUSTED_RUN_ID}" --argjson attempt "${TRUSTED_ATTEMPT}" '
  .workflow_run.id == $run and .workflow_run.run_attempt == $attempt
' "$GITHUB_EVENT_PATH" >/dev/null || fail 'event run identity mismatch'
