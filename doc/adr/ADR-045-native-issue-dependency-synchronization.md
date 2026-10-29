# ADR-045: Additive Synchronization of Explicit GitHub Issue Dependencies

Date: 2026-10-29

## Status

Accepted

## Decision

Use GitHub's native issue dependency relationship to represent explicit
prerequisites for work. A new standalone Bash script,
`scripts/update_issue_dependencies.bash`, reads issue references in a
level-two `Dependencies` or `Blocked by` section and ensures they exist
as native `blocked by` relationships. It uses `GH_TOKEN`, `GH_REPO`, and
`--issue NUMBER` or `--all` as in ADR-044.

Synchronization is **additive and idempotent**. It does not infer blockers from
issue ordering, story membership, milestones, PR references, or labels. It does
not delete native relationships that are absent from Markdown, and it never
updates issue approval, state, or description. Missing or malformed references,
failed reads, failed posts, and unverified writes are reported without claiming
success. The script rejects self-dependencies and pull requests as blockers.
GitHub's native API remains responsible for further graph-integrity checks.

The existing metadata synchronization GitHub Actions workflow gains an
independent job with `issues: write` and the built-in `github.token`.
Issue events process the affected issue; schedule or parameterless manual
dispatch reconcile the repository. Mock tests run without tokens on PRs.

## Context and Constraints

A technical task belongs to a user story through a parent-child relationship,
but may additionally depend on implementation work in the same or different
stories. Such dependencies should be express, visible, and inspectable.
GitHub's native issue dependencies permit blocked-work views without
maintaining a separate dependency service. The original work in ADR-044 has
been merged; this supplements rather than replaces its two synchronizers.

A human-authored dependency section is interpreted as a request to create
missing native relationships. Once created, native relationships are retained
even if the description changes. Reconciliation cannot resolve whether a
removed textual declaration represents an intentional deletion; that requires
manual review and a separate decision. The script also does not make an
unapproved task actionable or automatically close work.

The GH CLI and jq are existing repository administrative tooling. The
workflow does not accept user-provided workflow_dispatch inputs, execute
arbitrary issue-body text, or require an additional personal access token.

## Alternatives Considered

1. **Use only textual references:** rejected because GitHub would not expose
   blocking relationships in its own issue and project interfaces.
2. **Infer dependencies from task numbering or parentage:** rejected because
   organizational membership is not execution ordering.
3. **Synchronize removals:** rejected because a missing textual reference can
   represent an incomplete edit or intentional manual native relationship.
4. **Build a hosted GitHub App:** deferred in favor of already adopted
   locally callable Bash scripts and GitHub Actions.
5. **Merge this into the parent-child script:** rejected so relationship
   and dependency failures remain isolated and independently testable.

## Consequences and Verification

Offline API mocks cover linking multiple blockers, idempotence, API read and
write failures, and lack of unrelated inferred blockers. A first manual
dispatch can backfill declared dependencies without deleting native links.
Errors fail the dependency job while the parent and project jobs remain
independent. Live state changes occur only after review and merge.

## Related Decisions

ADR-016 (privileged trust boundaries), ADR-018 and ADR-019 (governance and
approvals), and ADR-044 (independent issue metadata synchronizers).
