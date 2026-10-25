#!/usr/bin/env bash
# shellcheck shell=bash
## @file ci/verify-oci-publish-event.bash
## @brief Require a successfully validated, same-attempt OCI release gate.
## @details
## This validator consumes an untrusted workflow_run event and the exact
## run-scoped, short-lived proof uploaded AFTER both image engines passed.
## It also queries the upstream Versioning run independently. No registry
## credential, asset publication, shell evaluation of proof, or build occurs.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @retval 0 Trusted OCI gate and Versioning identity are consistent.
## @retval 64 Caller supplied an invalid proof argument.
## @retval 65 Gate/Versioning event or proof identity is ineligible.
## @retval 69 Required GH/JQ tools or read permissions unavailable.
set -euo pipefail

fail() {
  printf 'oci publisher gate: %s\n' "$1" >&2
  exit "${2:-65}"
}
(( $# == 1 )) || fail 'expected exact downloaded gate-proof path' 64
proof=$1
[[ -f "$proof" && ! -L "$proof" && -s "$proof" ]] ||
  fail 'missing or unsafe gate proof'
[[ "${GITHUB_EVENT_NAME-}" == workflow_run &&
  -f "${GITHUB_EVENT_PATH-}" &&
  "${GH_REPO-}" == wesley-dean/certbotbot ]] ||
  fail 'unexpected publication event or repository'
for tool in jq gh sed grep; do
  command -v "$tool" >/dev/null 2>&1 || fail 'required verifier unavailable' 69
done
[[ -n "${GH_TOKEN-}" && -n "${GITHUB_OUTPUT-}" ]] ||
  fail 'missing read-only run API or output context' 69

jq -e --arg repo "$GH_REPO" '
  .action == "completed" and
  .repository.full_name == $repo and
  .workflow_run.name == "OCI release validation" and
  .workflow_run.event == "workflow_run" and
  .workflow_run.head_branch == "main" and
  .workflow_run.head_repository.full_name == $repo and
  .workflow_run.conclusion == "success" and
  (.workflow_run.id | type == "number" and . > 0) and
  (.workflow_run.run_attempt | type == "number" and . > 0)
' "$GITHUB_EVENT_PATH" >/dev/null ||
  fail 'untrusted or incomplete OCI release-validation event'

# Require a fixed inventory of scalar lowercase identity values, not shell
# code. Restrict syntax first, before using any value as an API argument.
[[ "$(wc -l < "$proof")" -eq 8 ]] ||
  fail 'unexpected gate proof inventory'
mapfile -t fields < "$proof"
expected=(gate_run_id gate_run_attempt source_run_id source_attempt source_sha release_version handoff_manifest_sha256 producer_sha256)
for i in "${!expected[@]}"; do
  [[ "${fields[i]}" == "${expected[i]}"=* ]] || fail 'incorrect gate proof field'
  [[ "${fields[i]}" != *$'\r'* ]] || fail 'invalid proof line ending'
done
gate_id="${fields[0]#*=}"
gate_attempt="${fields[1]#*=}"
source_run_id="${fields[2]#*=}"
source_attempt="${fields[3]#*=}"
source_sha="${fields[4]#*=}"
version="${fields[5]#*=}"
manifest_sha="${fields[6]#*=}"
producer_sha="${fields[7]#*=}"

[[ "$gate_id" =~ ^[1-9][0-9]*$ &&
  "$gate_attempt" =~ ^[1-9][0-9]*$ &&
  "$source_run_id" =~ ^[1-9][0-9]*$ &&
  "$source_attempt" =~ ^[1-9][0-9]*$ &&
  "$source_sha" =~ ^[a-f0-9]{40}$ &&
  "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ &&
  "$manifest_sha" =~ ^[a-f0-9]{64}$ &&
  "$producer_sha" =~ ^[a-f0-9]{64}$ ]] ||
  fail 'invalid proof identity format'
jq -e --argjson gate "$gate_id" --argjson attempt "$gate_attempt" '
  .workflow_run.id == $gate and .workflow_run.run_attempt == $attempt
' "$GITHUB_EVENT_PATH" >/dev/null ||
  fail 'proof belongs to a different gate run or attempt'

run="$(gh api "repos/$GH_REPO/actions/runs/$source_run_id")" ||
  fail 'cannot inspect completed source Versioning run' 69
jq -e --arg repo "$GH_REPO" --arg sha "$source_sha" \
  --argjson attempt "$source_attempt" '
  .name == "Versioning" and
  .event == "push" and .head_branch == "main" and
  .head_repository.full_name == $repo and
  .head_sha == $sha and
  .run_attempt == $attempt and
  .status == "completed" and .conclusion == "success"
' <<< "$run" >/dev/null ||
  fail 'source Versioning run does not match passed OCI gate'

{
  printf 'source_sha=%s\n' "$source_sha"
  printf 'source_run_id=%s\n' "$source_run_id"
  printf 'source_attempt=%s\n' "$source_attempt"
  printf 'release_version=%s\n' "$version"
  printf 'manifest_sha=%s\n' "$manifest_sha"
  printf 'producer_sha=%s\n' "$producer_sha"
} >> "$GITHUB_OUTPUT"
