# ADR-060: Trial a Marketplace Regex Check Aggregator Without Replacing Required CI

Date: 2026-11-11

## Status

Accepted

## Context

Certbotbot already runs important checks across independent GitHub Actions
workflows. ADR-036 specifies parallel producer-flavor validation, shared
verified artifacts, and a strict stable aggregate job named
`Check, build, and test`. ADR-048 keeps broad Test, OCI runtime, and local
protocol E2E acceptance on branch pushes, while MegaLinter runs on pull
requests. Other security, release, and staging workflows have distinct event
and privilege boundaries.

GitHub branch-protection required checks are named individually rather than
selected by a regex. The engineering team evaluated a custom polling and
workflow-metadata mechanism in PR #304; that unmerged experiment was closed.
A smaller trial can delegate check polling to the published
`lewagon/wait-on-check-action` Marketplace action using its documented
`check-regexp` input.

No current primary validation check name starts with lowercase `test`. Existing
check names may be referenced by branch protection we cannot inspect through
the current GitHub integration. Renaming them would risk breaking those gates.

## Decision Drivers

- Try the Marketplace action rather than maintain a bespoke API poller.
- Preserve all existing required-check names, matrices, event triggers,
  coverage, and release/credential boundaries.
- Expose one stable POC job named `test-gate`.
- Select checks using the exact case-sensitive regular expression `^test.*`.
- Restrict accepted conclusions to `success`, with a finite deadline.
- Minimize authority and pin the action by an immutable Git commit.
- Avoid presenting an observed-check aggregator as a trusted completeness gate.
- Keep this proposal separate from ruleset migration and administrative changes.

## Decision

Add a non-enforcing `pull_request` workflow
(`.github/workflows/test-gate.yml`) with one job named `test-gate`. That
job invokes the published action at pinned commit
`369769072fe522a3a8a85c03c96af1e5242a1994`
(release `v1.9.1`) using:

- `ref: ${{ github.event.pull_request.head.sha }}`, to observe branch-push
  checks attached to the exact PR head commit rather than assume the
  synthetic PR merge commit is interchangeable;
- `check-regexp: '^test.*'`, with its literal start anchor;
- `running-workflow-name: test-gate`, to exclude this gate's own result;
- `allowed-conclusions: success`, disallowing the upstream action's
  default acceptance of `skipped`;
- `fail-on-no-checks: true`, with a bounded discovery interval;
- a read-only `GITHUB_TOKEN` and a fixed job timeout.

The action filters **check-run names**, which are primarily
`jobs.<job_id>.name`, not workflow filenames, step names, or top-level
workflow names. The regex is case-sensitive: `test-producer-suite`
matches, while `Test issue metadata synchronization` does not.

Preserve historical primary job names and add one thin `test-*` alias job
inside each of the three push-triggered test workflows:

1. `test-producer-suite`, dependent on the existing Test aggregate job;
2. `test-local-protocol-e2e`, dependent on the isolated E2E acceptance job;
3. `test-oci-runtime`, dependent on OCI runtime acceptance.

Each alias runs with read-only content permission and `if: always()`.
Its only operation is to return success if and only if the upstream
job's result is `success`. This avoids renaming existing check identities
or introducing new product-testing code. It adds one lightweight runner
job per covered workflow execution.

No marker metadata, bespoke workflow discovery, custom polling script,
file immutability, bypass mechanism, ruleset, or branch-protection mutation
is introduced. MegaLinter and CodeQL stay separate and retain their
existing independent merge evidence.

The new workflow is a **non-authoritative trial only**. Its success MUST
NOT be interpreted as proof that all intended tests ran, and the stable
`test-gate` name MUST NOT replace existing required checks on the
strength of this trial.

## Security Objectives, Assets, and Trust Boundaries

The assets are trustworthy PR test evidence, the existing ruleset/branch
protection contracts, the source revision identity, and CI token authority.
The new execution path is:

```text
PR event / untrusted branch SHA
  -> read-only test-gate job
  -> pinned Marketplace action and its Ruby/Bundler dependencies
  -> GitHub Checks API on the PR head SHA
  -> gate check result (not an authoritative merge gate)
```

Three independent branch-push test workflows also publish the
`test-*` aliases. Their upstream test jobs remain authoritative for
their original coverage and independently configured protections.

The third-party action executes with the `GITHUB_TOKEN` granted
`contents: read` and `checks: read`, not repository-write or
credentialed-release authority. The commit pin ensures immutable action
source identity but does not itself establish the absence of malicious
or incorrect behavior in the action or transitive Bundler dependencies.

## Explicit Limitations and Failure Modes

The upstream action collects **currently observable matching check runs**.
Its `fail-on-no-checks` option detects zero matches, but does not establish
that every expected check has appeared. If one `test-*` alias completes
before the others are registered, the POC can report success prematurely.
The aliases may not be created until their upstream workflows complete,
making this race especially relevant. A disabled or deleted workflow that
never reports a matching check can be omitted when another matching check
exists. This fails the earlier proposed strict missing-workflow contract.

The gate does not independently verify all workflow registrations, enabled
states, check-suite provenance, or a baseline of required check identities.
The upstream action's polling and rate-limit behavior, including its
documented pagination limit, also remain third-party dependencies.
A configured discovery timeout applies to finding matching checks; the
GitHub Actions job timeout supplies the overall execution bound.

GitHub may report checks from `pull_request` events against a synthetic
merge SHA. This POC intentionally watches the head SHA to match the three
push-triggered workflows. The PR-triggered MegaLinter and CodeQL checks
therefore remain outside its aggregation. Fork PRs do not necessarily
produce equivalent push checks in the base repository. GitHub merge queues
are not covered by this POC.

The invoking workflow is read from the candidate revision and could be
modified by that same PR. A published Marketplace action does **not**
eliminate this trust boundary. The alias jobs are also candidate-editable.
A trusted source, enforced ruleset, and verified check provenance would be
needed before any replacement of existing required checks.

## Alternatives Considered

### Continue the bespoke API poller and required metadata

Rejected for this experiment: it adds custom code and recurring
maintenance. PR #304 remains closed and unmerged, with no code adopted.

### Rename existing check contexts to `test-*`

Rejected because historical required checks may be configured in classic
branch protection, which the current connector cannot verify. The
new lightweight aliases preserve legacy names.

### Use a broad `^test.*` regex with no matching checks

Rejected because it cannot provide meaningful successful-path evidence.
Aliases give the trial actual check names to observe.

### Aggregate every workflow through a custom expected-inventory layer

Deferred. The user requested the Marketplace action's pattern-matching
model rather than another custom policy engine. An expected-inventory
mechanism may be required for future reliable enforcement, but is not
authorized by this POC.

### Change all tests to one workflow using `needs`

Rejected as incompatible with established cross-workflow scheduling and
parallel CI structure.

### Enable `test-gate` as the only required status check

Rejected because a regex matching observed checks is not equivalent to
proving all mandatory tests ran. Doing so would weaken branch protection.

## Consequences and Compatibility

All existing primary status checks and their established scheduling remain.
Three additional tiny alias jobs and one PR-observational job consume
additional Actions resources. The latter may finish before all suites, and
that is a documented observation rather than a coverage claim.

The producer and client Bash artifacts, package layout, S3 and Route53
behavior, local ACME evidence, live staging, release publishing, CI
credential boundaries, and CODEOWNERS requirements are unchanged.

The trial can be abandoned by removing the new workflow and the three alias
jobs; no data migration or branch protection change is needed.

## Verification and Graduation

Review should confirm that the `test-*` aliases appear against the
candidate head, that the upstream pinned action can find and observe
their conclusions, and that existing check contexts remain unchanged.
CI outcomes must be observed on the proposed commit; source inspection
alone is not execution evidence.

Before `test-gate` can replace any existing required check, a separately
approved design must solve expected-check inventory, missing/disabled
workflow detection, check creation races, fork/merge-queue semantics,
the head-versus-merge SHA distinction, action supply-chain review,
trusted gate execution, and the host's verified branch-protection rules.

## Related Decisions

ADR-000 (honest evidence), ADR-015 (dependency attack surface),
ADR-016 (threat modeling), ADR-018 (released standards),
ADR-019 (approved task governance), ADR-036 (parallel producer checks),
ADR-043 (manual live staging), ADR-046/047 (local protocol acceptance),
ADR-048 (push-only heavy CI), and ADR-057 (serial local negative tests).
