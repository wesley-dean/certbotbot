# ADR-044: Reconcile GitHub Issue Relationships and Optional Project Status

Date: 2026-10-29

## Status

Accepted

## Decision

Introduce a repository-local, event-dispatched GitHub Actions workflow that invokes two independently usable Bash scripts. The parent-child script maps an explicitly declared parent story in a `type:task` issue's "Parent" section to GitHub's native sub-issue relationship. It never overwrites an existing disagreeing native parent; that case is reported for human review. A second script optionally mirrors an issue's live labels and closure reason to the Status field of a configured GitHub Projects v2 board. Neither script changes issue approval, issue state, milestone membership, or product acceptance.

Both programs obtain credentials from the standard `GH_TOKEN` environment variable and take `--issue NUMBER` or `--all`, with the target repository supplied through `GH_REPO` or `--repo`. The workflow supplies dispatch inputs, while the scripts are independent of GitHub Actions. Events synchronize the affected issue; a parameterless manual dispatch and a weekly schedule reconcile the entire repository.

`PROJECT_NUMBER` is an optional GitHub Actions repository variable. If unset, empty, or zero, the project job is skipped and parent-child reconciliation still runs. Other values must be positive decimal integers. `PROJECT_OWNER` is optional and defaults to repository owner. In Actions, native parent-child updates use the built-in `github.token` with
`issues: write`, supplied to the script as `GH_TOKEN`. Only the optional
Projects job uses the separately configured `GH_TOKEN` Actions secret. Project Status option IDs are discovered from the target Project rather than hard-coded.

## Context, Boundaries, and Assumptions

GitHub issue descriptions currently contain parent-story references but native sub-issue relationships have not been consistently created. Native structured relationships enable GitHub's own hierarchy and progress displays. Projects Status likewise represents issue state already recorded in labels and closure reason, and should not require independent manual maintenance.

An accepted coding-standards snapshot still recommends milestones on product stories only. This integration does not modify that snapshot or synchronize milestone fields. Repository issue membership was separately reconciled to the owner's new story-and-task convention, which remains a distinct standards-adoption decision.

Scripts require the GitHub CLI and jq. The caller owns provisioning a suitable `GH_TOKEN`; no script invokes `gh auth login` or stores credentials. The GitHub Actions workflow checks out only the default-branch revision for issue events, uses no manually supplied dispatch inputs, and pins third-party actions to immutable commits. It does not run arbitrary code from issue descriptions. Only explicit, validated issue number references are interpreted as identifiers. Any conflict or API failure must produce a diagnostic and a nonzero result for the affected reconciliation.

Project updates require access to the target Project, including project field mutation. Status mapping is intentionally minimal: approved open issues map to Todo or In Progress based on `in-progress`; unapproved open issues map to Backlog if available; issues closed as completed map to Done; other closure reasons are skipped. An unavailable status option is skipped rather than inventing one. An issue not yet in the configured Project can be added. Existing conflict and concurrency management outside these metadata fields are out of scope.

## Alternatives Considered

1. **Manually maintain native relationships and status:** rejected due to recurring administrative cost and drift.
2. **Implement a webhook-hosted GitHub App:** deferred; it adds hosting and operational requirements without changing the two synchronization contracts.
3. **Embed API logic inside workflow YAML:** rejected because it impedes local invocation, mock testing, and maintenance.
4. **Always configure a Project:** rejected because repository-only issue relationships are useful without a board.
5. **Automatically replace conflicting native parents:** rejected because issue descriptions may be stale and existing structured relationships may be intentional.
6. **Broaden to governance enforcement and approval mutations:** rejected for this iteration; no automatic workflow authorization or acceptance decisions are delegated.

## Consequences and Verification

The repository gains one event-driven workflow, two independent Bash commands, and offline mock verification. An initial manual dispatch can backfill native relationships; future events and weekly sweeps maintain consistency. Credentials and Projects configuration remain operator-owned, and failure to grant Projects permissions cannot prevent the independent parent-child job from completing. Checkov's user-input restriction is respected through a parameterless manual dispatch. No live API mutation is performed by mocked tests.

The scripts must remain idempotent; tests cover creation and rerun of a relationship, Projects opt-out, and invalid project configuration. Production deployment requires no additional secret for parent-child updates.
If Projects synchronization is enabled, the operator must configure the
`GH_TOKEN` secret and positive `PROJECT_NUMBER` (and optionally `PROJECT_OWNER`),
then review a test run. Future enhancements, such as milestone propagation, PR traceability, and governance enforcement, require separate scope review.

## Related Decisions

ADR-016 governs threat modeling, ADR-018 the pinned standards snapshot, and ADR-019 the authoritative approval label. This decision adds metadata synchronization without changing their approval boundaries.
