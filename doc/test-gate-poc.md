# Cross-Workflow Test Gate (Proof of Concept)

The new `test-gate` job is an **observational proof of concept**. It provides
one stable check name while independently scheduled test workflows keep their
existing triggers, matrices, and parallel execution. The gate is not yet
configured as an enforced required status check in branch protection or a
ruleset. See [ADR-060](adr/ADR-060-cross-workflow-required-test-gate-poc.md)
for the security decision and graduation criteria.

## Declaration syntax

A workflow file under `.github/workflows/` may include exactly one comment:

```yaml
## test-gate:required=true
```

`required=false` and absence of the declaration both mean that workflow is
not in this gate's mandatory test inventory. This is **not** an instruction
to disable or skip the workflow itself.

The parser accepts liberal whitespace, including:

```yaml
  ###  test-gate  : required = true
```

The `test-gate` key, `required` field, and Boolean literals are case
sensitive. A malformed, duplicated, or unsupported `test-gate` declaration
fails closed. The current POC does not implement `immutable`.

Both the PR's protected base commit and its proposed head commit are inspected.
The required set is the **union** of those declarations. Removing or changing
a base-required marker to `false` in the PR does not exempt that PR; deletion
or renaming of a still-required workflow causes a failed gate. A workflow
that becomes required in the candidate is also required immediately.

## Initial required workflows

| Workflow | Trigger | Existing test evidence |
| --- | --- | --- |
| [Test](../.github/workflows/test.yml) | push | Verified producer and client artifact handoff, full Bats flavor matrix, Bash 4.3, encryption |
| [Local protocol E2E](../.github/workflows/local-protocol-e2e.yml) | push | Pebble/SeaweedFS lifecycle, seven negative scenarios, cleanup |
| [OCI runtime acceptance](../.github/workflows/oci-runtime.yml) | push | Docker and rootless Podman |
| [MegaLinter](../.github/workflows/megalinter.yml) | pull_request | Static analysis and repository linters |

CodeQL and the path-filtered issue-metadata tests remain separately
configured and unmarked for this initial experiment. The manual credentialed
staging workflow and release publication workflows are not PR gates.
This selection is **not** a claim that nonselected checks are unimportant.

## How the POC evaluates a PR

The `pull_request` event starts the POC gate. A read-only GitHub token
retrieves each required workflow's registration and enabled state, then
finds an automatically triggered run matching the PR's exact head commit.

The implementation matches same-repository branch-push runs by event,
head SHA, and branch. It matches PR-triggered runs by the linked PR number,
head SHA, and branch. The workflow-run API identifies the workflow and its
run; the jobs API verifies the actual jobs of the successful run. This avoids
mistaking a display name or one successful matrix leg for a complete suite.

An `active` workflow registration, a completed `success` workflow run,
and a nonempty untruncated list of jobs **all concluded `success`** are
mandatory. A disabled workflow fails immediately. A failed, cancelled,
skipped, or otherwise unsuccessful workflow fails. A missing or incomplete
eligible run is polled until the bounded deadline, then fails. The POC does
not start tests, change their order, re-enable workflows, or bypass checks.

The default poll is 60 attempts, 30 seconds apart, with an independent
35-minute GitHub Actions job timeout. These values are tunable through
`TEST_GATE_MAX_ATTEMPTS` and `TEST_GATE_POLL_SECONDS` for fixture testing.
The full CI behavior depends on GitHub's scheduling, and these defaults are
not a measured wall-time benchmark.

## Running deterministic local tests

```bash
bats tests/test-gate.bats
```

The tests create temporary local Git base/head commits and mock `gh api`
responses. They need Bash, Bats, Git, and jq but do not contact GitHub,
execute certificate workflows, or need credentials.

To examine the declared required workflows in two checked-out commits:

```bash
bash ci/test-gate.bash inventory BASE_SHA HEAD_SHA
```

The live mode runs only inside a GitHub `pull_request` event, and needs the
read-only `GITHUB_TOKEN`, event payload, and both Git objects present.

## Explicit limitations before enforcing the gate

- **Untrusted enforcement:** The POC workflow and Bash script execute from
  the candidate PR revision. A PR can modify them. Do not yet make
  `test-gate` the sole required status check.
- **Forks:** Unsupported for this proof of concept. Missing same-repository
  push verification fails rather than silently passing.
- **Registration:** Newly introduced required workflows may not yet have
  an active registered workflow/run and therefore fail closed.
- **Event identity:** Live PR-run head/merge commit association and API
  pagination require observed validation before promotion.
- **Pagination:** If more than one page of jobs is needed, the POC fails
  rather than silently accepting the first 100 jobs.
- **Conditional triggers:** A required workflow skipped due to its event or
  path filters fails the gate, even when that skip was intentional.
- **Rulesets:** No branch protection or ruleset is modified by this PR.
  Existing required checks still independently govern merge eligibility.

A production revision should run the gate from trusted code or a GitHub App,
verify the exact check identity and revision required by branch protection,
support complete API pagination, and include live success/failure evidence
before an administrator changes the required-check list.
