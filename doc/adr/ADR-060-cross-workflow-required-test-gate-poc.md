# ADR-060: Proof of Concept for Declarative Cross-Workflow Required Test Gate

Date: 2026-11-11

## Status

Accepted

## Context

GitHub rulesets and classic branch protection require enumerated status check
names, not a wildcard naming expression. Certbotbot's normal pull request
verification is spread across independent workflows. Under ADR-036, full Bats,
Bash 4.3, and encryption validations run in parallel inside the Test workflow
with explicit fail-closed aggregation. ADR-048 retains push-only execution
for the heavyweight Test and OCI acceptance workflows, while MegaLinter runs
on pull requests. The isolated local protocol E2E workflow also runs on push.

Requiring every job by name is brittle as new matrix legs and workflows
are added. A stable check called `test-gate` could observe an explicitly
marked set of required workflows without changing their triggers, job graphs,
or parallel scheduling.

GitHub workflows can be disabled in the web UI without changing their
repository files. A successful check from an older revision or a skipped
job also must not be mistaken for current mandatory verification.

## Decision Drivers

- Supply one stable `test-gate` check name as an eventual ruleset input.
- Keep each existing CI workflow independent and preserve parallelism.
- Use easily reviewed, YAML-comment metadata without new workflow parsers.
- Reject disabled workflows, missing runs, skipped jobs, and stale evidence.
- Prevent a PR from removing an existing requirement for its own evaluation.
- Avoid adding privileged tokens, secrets, or write authority to PR CI.
- Make readiness and security limitations explicit during proof of concept.
- Defer workflow immutability and administrative bypass design.

## Decision

### Required metadata

A workflow MAY declare its participation with a top-level YAML comment:

```yaml
## test-gate:required=true
```

Only lowercase `true` and `false` are accepted. Whitespace is permitted
around the comment prefix and around `test-gate`, `:`, `required`, and
`=`; the declaration must occupy a line by itself. An absent declaration
defaults to `false`. Duplicate, malformed, or unsupported `test-gate`
declarations are errors, not optional requirements.

The POC parses files directly beneath `.github/workflows/` with `.yml`
or `.yaml` extensions. Paths are used as workflow identities instead of
human-facing workflow display names.

For each pull request, the required inventory is the union of
`required=true` declarations found at the exact protected base revision and
the candidate head revision. A candidate cannot silently disable a
base-required workflow by removing its marker, renaming the file, or deleting
it. A newly required workflow is required immediately, and may fail to pass
until its GitHub workflow registration and automatic run exist.

A declaration does not itself trigger a workflow. A required workflow that
cannot run for a PR is a validation failure, not an implicit exemption.

### Runtime evidence

The `test-gate` job runs on `pull_request` events using read-only
`contents`, `actions`, `checks`, and `pull-requests` permissions.
It examines the Git object contents at exact base and head SHAs as data,
then uses `gh api` and `jq` to:

1. Find the GitHub workflow registered for each required path.
2. Confirm the workflow's current state is `active`.
3. Find an automatic `push` run matching the exact head SHA and branch,
   or a `pull_request` run explicitly identifying the same PR head SHA.
4. Wait for completion without affecting scheduling of any other workflow.
5. Reject unsuccessful workflow conclusions and any non-successful,
   missing, skipped, or cancelled constituent job.
6. Return success only if all required workflows have succeeded.

The inspector uses bounded polling (60 attempts, 30 seconds apart by
default, plus a 35-minute job timeout). The POC supports same-repository
PRs only. Fork PRs fail closed rather than guessing at push-run ownership.
A job inventory exceeding one API page fails closed instead of silently
ignoring jobs. A workflow with a path filter that legitimately skips a PR
must be excluded explicitly or redesigned before being marked required.

The selected workflows for the initial POC are `test.yml`,
`local-protocol-e2e.yml`, `oci-runtime.yml`, and `megalinter.yml`.
Other workflows, including CodeQL, continue operating under their own
configured policies and may be considered for explicit inclusion later.

### Proof-of-concept safety boundary

This PR SHALL NOT add `test-gate` to branch protection or a ruleset, and
SHALL NOT remove or replace any existing required check. No existing test
workflow's triggers, jobs, matrix strategy, credentials, or release behavior
change. The new gate is an additional read-only diagnostic.

**The POC is not a trusted enforcement mechanism.** Because the
`pull_request` workflow and its script are read from the candidate
revision, a PR could alter its own gate logic. Before adopting `test-gate`
as the sole required check, its evaluation logic must execute from a trusted,
reviewed revision or independent GitHub App, with a verified source identity.
A hardened design must also establish correct check-suite attachment,
freshness, and semantics for PR merge commits and required-check source
restrictions. A repository ruleset must then require the check from an
appropriate trusted source.

This POC does not establish that all GitHub APIs or event combinations work
in live CI. Successful and failing GitHub Actions runs are required before
claiming end-to-end validation.

## Trust Boundary and Threat Analysis

The workflow reads untrusted PR metadata and YAML content, plus GitHub API
responses, but must never execute candidate scripts or treat their comments
as commands. The GitHub token is read-only and no credentials are passed to
the inspected workflows. The tested commit, PR identity, workflow path, run
event, and branch are checked rather than trusting the latest successful run.

An attacker could remove a required marker from their PR. Unioning with the
base prevents that evasion while leaving intended removals to a later
governed change. Disabled workflows, skipped jobs, workflow registration
failure, cancellation, and missing results fail closed.

Remaining risks include:

- The candidate can modify the POC gate itself; this is why it is not
  authorized as a required security gate.
- An unusually large Actions run history or test matrix can exceed the
  POC's first-page query. Missing target runs time out; truncated job
  inventories fail.
- Workflow dispatch and scheduled runs are deliberately ineligible as
  substitutes for automatic PR/push validation.
- Push-only checks on fork branches are not covered by this initial design.
- GitHub API eventual consistency, retry behavior, and synthetic PR merge
  SHA relationships require live testing before production enforcement.
- A manually disabled workflow is not re-enabled by the gate, since doing
  so could override a deliberate administrator decision.

## Alternatives Considered

### Require every matrix job in the ruleset

Rejected for the dynamic goal because each newly introduced job or workflow
would require administrator changes. Existing required checks remain intact
during this POC.

### Discover by filename or display name alone

Rejected because the workflows to validate need not start with `test`,
and a workflow name is not the identity of its emitted job checks.

### Trust only metadata from the candidate revision

Rejected because removing a required declaration would weaken the same PR.

### Treat an absent or disabled workflow as optional

Rejected because the absence of a failing check is not evidence of success.

### Convert all tests to one serial workflow

Rejected because it contradicts the scheduling benefits and verified artifact
boundaries established by ADR-036 and ADR-048.

### Require a third metadata field for immutability

Deferred explicitly. The POC implements only the optional Boolean
`required` declaration. Protected-file mutation and administrative
bypass remain separate design subjects.

### Use pull_request_target or a GitHub App immediately

Deferred. Trusted evaluation needs separate authorization and hardened
event/permission design. The POC uses `pull_request` and is explicitly
non-enforcing until that trust boundary is established and reviewed.

## Consequences and Compatibility

A new read-only check and a small Bash inspector are added. Four existing
workflows receive comment-only metadata; their scheduling and semantics
remain unchanged. Bats tests provide offline fixture coverage for malformed
metadata, base/head policy union, disabled workflows, old SHA reuse,
missing checks, failure, skip, and bounded waiting.

The POC introduces an extra concurrent workflow and associated GitHub Actions
usage. While it runs in parallel, it may remain active until the slowest
required workflow succeeds. The gate's own runner time and API requests are
new costs and must be measured before adopting it broadly.

There is no product CLI, published Bash artifact, credentialed staging,
release job, registry publisher, live provider, or consumer behavior change.
No JSON ruleset or administrative bypass is installed by this PR.

## Expected Outcomes and Graduation Criteria

The POC should demonstrate one stable job name, correct cross-workflow
success aggregation, explicit disablement failures, bounded timeout
behavior, and unchanged upstream parallelism. The team should inspect
at least one real successful PR run and relevant failure scenarios.

Promotion to an enforced required check requires a separately approved
design and PR addressing trusted execution, exact-commit identity,
synthetic-merge compatibility, workflow registration, missing jobs and
pagination, observable CI evidence, and the actual enforced ruleset.

## Related Decisions

- ADR-016 governs security and trust-boundary review.
- ADR-018 governs adopted external coding standards.
- ADR-019 governs issue approval, which this PR does not replace.
- ADR-036 governs parallel producer verification and fail-closed matrices.
- ADR-043 governs separately authorized staging acceptance.
- ADR-046 and ADR-047 govern isolated local E2E evidence.
- ADR-048 governs single-event push/PR workflow triggers.
- ADR-057 keeps local E2E negative scenarios serial pending further evidence.
