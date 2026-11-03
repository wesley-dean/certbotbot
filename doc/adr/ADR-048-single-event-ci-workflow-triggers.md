# ADR-048: Single-Event CI Workflow Triggers for Push Tests and PR Lint

Date: 2026-11-03

## Status

Accepted

**Implementation status:** This decision accompanies approved one-off
technical task #256. By repository convention, the status of an ADR
submitted for merge is `Accepted`; only review and merge make it
operative. This ADR governs the two named test workflows and confirms the
already-correct MegaLinter event policy. It does not supersede any
product, E2E trust-boundary, or security-analysis ADR.

## Decision

The broad, credential-free public-producer **Test** workflow
(`.github/workflows/test.yml`) and the independent **OCI runtime
acceptance** workflow (`.github/workflows/oci-runtime.yml`) shall
run on repository `push` and explicit `workflow_dispatch` events,
but **not** directly on `pull_request` events.

The **MegaLinter** workflow
(`.github/workflows/megalinter.yml`) shall run on
`pull_request` events for `main` and `master`, plus optional
`workflow_dispatch`, but **not** on `push`. This is already the
actual configuration at the time of this decision, so no change to the
MegaLinter workflow is necessary.

The Test and OCI job definitions, matrices, artifact handoffs,
permissions, executable validations, and manual-dispatch behavior
remain unchanged. `push` retains its existing unrestricted branch
selection: repository-owned feature/agent branches and default-branch
commits both receive the corresponding tests. CodeQL, release/publish
workflows, manual privileged staging E2E, and narrowly scoped
metadata-synchronization tests retain their existing triggers.
CI duplication must not be addressed by disabling meaningful test
coverage, weakening branch protection, or silently changing the
release or staging acceptance criteria.

## Context and Decision Drivers

Before this change, the two large test workflows each listened to both
`push` and `pull_request`. Pushing a commit to a branch with an
open same-repository PR could therefore schedule **two runs of each
workflow for the same head commit**, incurring duplicate compute,
longer check lists, additional artifacts, and potentially
confusing failure/approval signals.

The Product Owner explicitly asked that tests run on push while
MegaLinter runs on pull requests. Inspection confirmed MegaLinter
already has only `pull_request` and `workflow_dispatch`;
its comments mentioning `push` describe possible event and
autofix modes rather than an active trigger.

The intended operational model is an internal, same-repository
`agent/*` branch submitted through a PR. A push to that branch
starts Test and OCI, and the PR runs MegaLinter. A subsequent push,
including a reviewer-requested correction, naturally re-runs the
tests. A merge onto `main` generates a *new* push and receives
post-merge tests, which is not a duplicate test of the earlier PR
head commit.

## Assumptions and Constraints

- Contributors use same-repository branches for the normal approved
  task/PR workflow. PRs from forks are **not guaranteed** to have
  equivalent test-run coverage in the destination repository.
- Required status checks are evaluated for a specific commit/context.
  We expect checks produced by an authorized same-repository branch
  `push` to appear on that PR's head commit, but the current
  repository's rulesets, merge queue behavior and status-check
  source restrictions must be verified independently. An ADR is
  not evidence that all branch protection checks are satisfied.
- The Test workflow retains manual dispatch to support controlled
  explicit reruns. Manual runs are not a substitute for verifying
  automatic push-event coverage.
- The MegaLinter workflow retains the existing
  `APPLY_FIXES_EVENT: pull_request` behavior and existing
  permissions, GPG and autofix rules. No new write permission or
  secret exposure is authorized.
- CodeQL intentionally runs PR analysis, main-branch push
  analysis, scheduled analysis and manual dispatch. Their subjects
  differ enough that removing events without separate analysis
  would diminish security coverage.
- The separately scoped OCI workflow exercises Docker and
  Podman behavior against a prepared artifact; it is not the
  credentialed live-provider test in milestone 4 or the
  uncompleted engine-backed local protocol test in milestone 16.

## Security and Failure Considerations

| Risk | Control or explicit limitation |
| --- | --- |
| Fork-only PRs do not trigger push workflows in this repository | Do not claim Test/OCI status on a foreign fork; reassess if external PR support is required |
| A required check remains pending because of changed event policy | Inspect branch protection/ruleset check contexts against the actual PR-head push run before claiming review readiness; do not remove the check merely to make merging possible |
| A push to any branch consumes CI resources | This is intentional; no branch filters are added, and the previous duplicate PR runs are removed |
| An attacker changes a workflow in a submitted branch | Push-event execution already exists today; preserve read-only test permissions and do not increase PR/push workflow authority |
| MegaLinter automatically commits fixes under its existing rules | Keep existing PR-only trigger and restrictions; a fix pushed to the branch naturally causes the next push-triggered test run |
| Live credentials are exposed by new event routes | No credentialed workflow, secret mapping, trigger or permission is changed; manual staging workflow remains independently gated |
| Test or OCI result is mistaken for real ACME/DNS/S3 E2E evidence | Preserve ADR-047 and milestone #16 proof requirements; this ADR concerns scheduling only |
| Concurrent or cancelled runs mask failures | Existing concurrency and status checks remain as-is; review the final head SHA and full required-check set |

The approach deliberately changes only *when* a test starts, not
what it validates or which external dependencies it trusts.

## Considered Alternatives

1. **Keep both push and pull_request events for both tests:** rejected
   because it duplicates a large amount of CI work for the same
   same-repository head commit.
2. **Run Test/OCI on PR only and MegaLinter on push:** rejected
   because the Product Owner specifically chose push-based tests
   and PR-based linting. It also would not offer the requested
   normal branch-push feedback before a PR is opened.
3. **Only remove Test's pull_request trigger:** rejected because
   OCI runtime acceptance has the same dual-event duplication.
4. **Also remove PR triggers from CodeQL and specialized workflow
   tests:** rejected as unrelated; these workflows have distinct
   security or file-scoped responsibilities.
5. **Remove push from MegaLinter:** no operation necessary. The
   workflow already lacks that event, and editing its comments
   or auto-fix rules would be unrelated cleanup.
6. **Filter pushes to main or a subset of agent branches:** rejected
   for now. That would reduce existing branch-push coverage and
   extend beyond the requested scheduling change.
7. **Rely on concurrent-job cancellation alone:** rejected.
   Cancellation does not prevent creating two workflow runs and
   can leave confusing or inconsistent check outcomes.

## Consequences, Evidence, and Compatibility

The proposed implementation changes exactly two `on:` maps.
`Test` and `OCI runtime acceptance` each retain `push`
and `workflow_dispatch`, with `pull_request` removed.
MegaLinter's already-PR-only trigger is inspected but not edited.

After merge, a push to a same-repository feature branch should
produce one Test run and one OCI runtime acceptance run for that
commit (plus other independent workflows such as CodeQL where
applicable). Creating or synchronizing the PR without a new
branch push should not create a duplicate Test or OCI run, while
MegaLinter should respond to the PR event. Manual runs remain
available. These are expected behaviors to confirm with actual
GitHub Actions event histories, not claims about tests already
executed.

Maintainers must verify that existing required status contexts
still resolve on PR heads from branch push checks. If external
fork PRs, GitHub merge queue, repository rulesets, or release
policies subsequently require PR-triggered validation, that
compatibility change requires separate approval and a review
of cost versus event coverage.

This ADR has no effect on the one-task/one-PR model, the
`approved` label, product artifacts, storage, Certbot, live
staging workflow, or project milestone accounting. Task #256
is a one-off CI-maintenance issue, not a new milestone #16
technical task.

## Related Decisions

ADR-003 (Make orchestration), ADR-015 (dependencies as attack
surface), ADR-016 (threat modeling), ADR-018 (coding standards
and approval governance), ADR-043 (manually gated live staging),
ADR-046/047 (isolated local E2E proof boundaries).
