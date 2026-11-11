#!/usr/bin/env bash
##
## @file test-gate.bash
## @brief Evaluate workflow-level test requirements for one pull request.
##
## @details
##   This proof-of-concept inspector treats workflow YAML files strictly as
##   data. It discovers exact, whitespace-tolerant comment declarations of
##   the form '## test-gate:required=true' or '=false' in both the protected
##   base commit and the proposed head commit. A base-branch requirement
##   cannot be removed by editing the proposed revision.
##
##   For each required workflow, the GitHub Actions API supplies workflow
##   state and the automatic run associated with the PR head revision.
##   Completed success is confirmed against the run's individual job results.
##   Missing, disabled, failed, skipped, cancelled, or ambiguous evidence
##   never counts as success. No workflow or test is launched by this script.
##
##   The POC assumes a same-repository PR, a read-only GitHub token, jq, gh,
##   git, and an existing checkout containing both exact commit objects.
##   Do not treat this candidate-branch workflow as a hardened enforcement
##   boundary until the gate implementation is executed from trusted code.
##
## @usage
##   bash ci/test-gate.bash inventory BASE_SHA HEAD_SHA
##   bash ci/test-gate.bash run
##
set -euo pipefail

## @var GATE_REQUIRED
## Paths from base or candidate that declare required=true.
declare -A GATE_REQUIRED=()

## @var GATE_DECLARATION_PATTERN
## Exact, case-sensitive Boolean metadata with whitespace tolerance.
readonly GATE_DECLARATION_PATTERN='^[[:space:]]*#{2,}[[:space:]]*test-gate[[:space:]]*:[[:space:]]*required[[:space:]]*=[[:space:]]*(true|false)[[:space:]]*$'
readonly GATE_PREFIX_PATTERN='^[[:space:]]*#{2,}[[:space:]]*test-gate'

## @brief Emit a bounded diagnostic and terminate unsuccessfully.
## @param $* Human-readable, nonsecret diagnostic.
gate_die() {
  printf 'test-gate: ERROR: %s\n' "$*" >&2
  exit 1
}

## @brief Enumerate exact workflow files from an immutable commit object.
## @param $1 Commit SHA.
## @stdout One workflow path per line, excluding subdirectories.
gate_files() {
  local revision=${1:?revision required}
  git cat-file -e "${revision}^{commit}" ||
    gate_die "commit object unavailable: ${revision}"
  local path
  while IFS= read -r path; do
    case "$path" in
      .github/workflows/*.yml | .github/workflows/*.yaml)
        # Reject a subdirectory; GitHub workflows live in this exact directory.
        [[ "${path#.github/workflows/}" != */* ]] && printf '%s\n' "$path"
        ;;
    esac
  done < <(git ls-tree -r --name-only "$revision" -- .github/workflows/)
}

## @brief Read and validate test-gate metadata at one commit.
## @param $1 Commit SHA.
## @param $2 Workflow path.
## @stdout 'true', 'false', or 'absent'.
gate_declaration() {
  local revision=${1:?revision required}
  local path=${2:?path required}
  local line count=0 result=absent

  git cat-file -e "${revision}:${path}" ||
    gate_die "workflow file unavailable at ${revision}: ${path}"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $GATE_PREFIX_PATTERN ]]; then
      [[ "$line" =~ $GATE_DECLARATION_PATTERN ]] ||
        gate_die "malformed or unsupported test-gate directive: ${path}"
      ((count += 1))
      ((count == 1)) ||
        gate_die "duplicate test-gate declarations: ${path}"
      result=${BASH_REMATCH[1]}
    fi
  done < <(git show "${revision}:${path}")

  printf '%s\n' "$result"
}

## @brief Build required path union from base and candidate.
## @param $1 Protected base commit.
## @param $2 Candidate head commit.
## @stdout Sorted required workflow paths.
gate_inventory() {
  local base=${1:?base required}
  local head=${2:?head required}
  local revision path directive paths
  GATE_REQUIRED=()

  for revision in "$base" "$head"; do
    paths=$(gate_files "$revision") ||
      gate_die "unable to enumerate workflow files: ${revision}"
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      directive=$(gate_declaration "$revision" "$path") ||
        gate_die "invalid workflow declaration: ${path}"
      if [[ "$directive" == true ]]; then
        GATE_REQUIRED["$path"]=1
      fi
    done <<< "$paths"
  done

  ((${#GATE_REQUIRED[@]} > 0)) ||
    gate_die 'no required workflows found in either revision'

  for path in "${!GATE_REQUIRED[@]}"; do
    git cat-file -e "${head}:${path}" ||
      gate_die "base-required workflow removed or renamed: ${path}"
    printf '%s\n' "$path"
  done | LC_ALL=C sort
}

## @brief Read one GitHub Actions API response with read-only token.
## @param $1 Relative API endpoint including query string.
## @stdout JSON response.
gate_api() {
  gh api --method GET -H 'Accept: application/vnd.github+json' "$1" ||
    gate_die "GitHub API request failed: ${1%%\?*}"
}

## @brief Reject disabled or unavailable workflow registrations.
## @param $1 Repository owner/name.
## @param $2 Expected workflow path.
gate_require_active() {
  local repo=${1:?repo required}
  local path=${2:?path required}
  local response state actual
  response=$(gate_api "/repos/${repo}/actions/workflows/${path##*/}")
  state=$(jq -er '.state' <<< "$response") ||
    gate_die "workflow state unavailable: ${path}"
  actual=$(jq -er '.path' <<< "$response") ||
    gate_die "workflow path unavailable: ${path}"
  [[ "$actual" == "$path" ]] ||
    gate_die "workflow registry identity mismatch: ${path}"
  [[ "$state" == active ]] ||
    gate_die "required workflow disabled or inactive (${state}): ${path}"
}

## @brief Select the latest automatic run for an exact PR head commit.
## @param $1 Repository owner/name.
## @param $2 Workflow path.
## @param $3 Candidate head SHA.
## @param $4 Candidate branch name.
## @param $5 PR number.
## @stdout Selected run JSON or empty string when absent.
gate_latest_run() {
  local repo=$1 path=$2 head=$3 branch=$4 pr=$5 response
  response=$(gate_api "/repos/${repo}/actions/workflows/${path##*/}/runs?per_page=100")
  jq -cer --arg sha "$head" --arg branch "$branch" --argjson pr "$pr" '
    [.workflow_runs[]?
      | select(.head_branch == $branch)
      | select(
          (.event == "push" and .head_sha == $sha)
          or
          (.event == "pull_request" and
            ([.pull_requests[]? |
              select(.number == $pr and .head.sha == $sha)] | length > 0)
          )
        )
    ] | sort_by(.run_started_at // .created_at, .run_attempt) | last // empty
  ' <<< "$response" || true
}

## @brief Validate every job in one completed, successful workflow run.
## @param $1 Repository owner/name.
## @param $2 Run ID.
## @returns Success only if the entire untruncated job inventory passed.
gate_jobs_succeeded() {
  local repo=$1 run_id=$2 response
  response=$(gate_api "/repos/${repo}/actions/runs/${run_id}/jobs?per_page=100")
  jq -e '
    (.total_count | type == "number") and
    (.total_count > 0) and
    (.total_count == (.jobs | length)) and
    all(.jobs[]; .status == "completed" and .conclusion == "success")
  ' <<< "$response" >/dev/null
}

## @brief Poll all required workflows without changing their scheduling.
gate_run() {
  command -v gh >/dev/null || gate_die 'gh is required'
  command -v jq >/dev/null || gate_die 'jq is required'
  [[ -n "${GH_TOKEN:-}" ]] || gate_die 'GH_TOKEN is required'
  [[ -r "${GITHUB_EVENT_PATH:-}" ]] ||
    gate_die 'readable pull_request event payload required'
  local repo base head branch head_repo pr attempts interval
  repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}
  base=$(jq -er '.pull_request.base.sha' "$GITHUB_EVENT_PATH") ||
    gate_die 'PR base SHA missing'
  head=$(jq -er '.pull_request.head.sha' "$GITHUB_EVENT_PATH") ||
    gate_die 'PR head SHA missing'
  branch=$(jq -er '.pull_request.head.ref' "$GITHUB_EVENT_PATH") ||
    gate_die 'PR head branch missing'
  head_repo=$(jq -er '.pull_request.head.repo.full_name' "$GITHUB_EVENT_PATH") ||
    gate_die 'PR head repository missing'
  pr=$(jq -er '.pull_request.number' "$GITHUB_EVENT_PATH") ||
    gate_die 'PR number missing'
  [[ "$head_repo" == "$repo" ]] ||
    gate_die 'fork PRs require a separate workflow identity policy'
  [[ "$base" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ ]] ||
    gate_die 'invalid commit identity'
  [[ "$pr" =~ ^[1-9][0-9]*$ ]] ||
    gate_die 'invalid PR number'

  attempts=${TEST_GATE_MAX_ATTEMPTS:-60}
  interval=${TEST_GATE_POLL_SECONDS:-30}
  [[ "$attempts" =~ ^[1-9][0-9]*$ && "$attempts" -le 100 ]] ||
    gate_die 'TEST_GATE_MAX_ATTEMPTS must be in 1..100'
  [[ "$interval" =~ ^[0-9]+$ && "$interval" -le 60 ]] ||
    gate_die 'TEST_GATE_POLL_SECONDS must be in 0..60'

  local inventory
  local -a required=()
  inventory=$(gate_inventory "$base" "$head") ||
    gate_die 'required workflow inventory invalid'
  [[ -n "$inventory" ]] || gate_die 'no required workflow inventory'
  mapfile -t required <<< "$inventory"
  local path response run status conclusion id pending round
  for path in "${required[@]}"; do
    gate_require_active "$repo" "$path"
  done

  for ((round = 1; round <= attempts; round++)); do
    pending=0
    for path in "${required[@]}"; do
      # Check enablement on each round: UI changes are relevant during polling.
      gate_require_active "$repo" "$path"
      run=$(gate_latest_run "$repo" "$path" "$head" "$branch" "$pr")
      if [[ -z "$run" ]]; then
        printf 'test-gate: pending (no eligible run): %s\n' "$path"
        ((pending += 1))
        continue
      fi
      id=$(jq -er '.id' <<< "$run") ||
        gate_die "run ID missing: ${path}"
      status=$(jq -er '.status' <<< "$run") ||
        gate_die "run status missing: ${path}"
      conclusion=$(jq -r '.conclusion // ""' <<< "$run")
      if [[ "$status" != completed ]]; then
        printf 'test-gate: pending (%s): %s\n' "$status" "$path"
        ((pending += 1))
        continue
      fi
      [[ "$conclusion" == success ]] ||
        gate_die "required workflow did not succeed (${conclusion}): ${path}"
      gate_jobs_succeeded "$repo" "$id" ||
        gate_die "required jobs missing, skipped, cancelled, or failed: ${path}"
      printf 'test-gate: passed: %s (run %s)\n' "$path" "$id"
    done
    if ((pending == 0)); then
      printf 'test-gate: all %s required workflows succeeded for %s\n' \
        "${#required[@]}" "$head"
      return 0
    fi
    ((round < attempts)) && sleep "$interval"
  done
  gate_die "timed out with ${pending} required workflow(s) pending for ${head}"
}

## @brief Entry point for real and fixture-driven evaluations.
main() {
  case "${1:-}" in
    inventory)
      (($# == 3)) || gate_die 'usage: inventory BASE_SHA HEAD_SHA'
      gate_inventory "$2" "$3"
      ;;
    run)
      (($# == 1)) || gate_die 'usage: run'
      gate_run
      ;;
    *)
      gate_die 'usage: test-gate.bash inventory BASE_SHA HEAD_SHA | run'
      ;;
  esac
}
main "$@"
