# ADR-019: Treat Current GitHub Approval Labels as Authoritative

Date: 2026-10-21

## Status

Accepted

## Decision

Adopt the changed approval contract in the verified upstream
`coding_standards@v2.2.1` release while retaining
`three_phase_development = true` in `.codingstandardrc`.

For an opted-in GitHub repository, an issue's **current live
`approved` label is the authoritative and sufficient workflow approval
record** for that issue's current scope and phase. On a `type:story`
issue, it means Product Owner approval for technical planning; on a
`type:task` issue, it means Technical Architect approval for development.
The approval applies to that issue only and does not automatically
authorize linked tasks or a separate phase.

An appropriately responsible human, or expressly designated repository
authority, MUST make the approval decision. The authorized person MAY
apply the label directly or explicitly instruct an agent or tool to apply
it to identified issues. Agents MUST NOT decide to approve their own
proposals, treat silence as consent, infer approval from parent issues,
or restore an approval label without a new authorized decision.
A separately recorded approval comment, comment-date audit, or other
parallel approval record is **not required**.

If the scope of an approved issue materially changes, the `approved`
label MUST be removed until the responsible authority approves the
changed scope. Agents MAY remove a stale label to prevent unauthorized
work, but MUST NOT reapply it on their own initiative. Implementers
SHOULD inspect current live labels, accepted ADRs, dependencies, and
blockers immediately before consequential execution.

The label is a workflow authorization record, not a GitHub permission
boundary, a security exception, an amendment to an Accepted ADR, a
replacement for code review, or an authorization to merge a PR.

This decision **supersedes only the historical approval-evidence rule
in ADR-018** that treated labels as indexing aids and required
attributable approval comments. All other provisions of ADR-018
remain in effect.

## Context and Drivers

ADR-018 adopted a pinned v2.2.0 standards snapshot and expressly opted
this repository into three-phase governance. In that release, the
`approved` label could only index a separate human approval record.
Release v2.2.1 changes the governing GitHub workflow contract to make
the issue label itself authoritative while retaining human control
over the approval decision.

This project's technical and product approval boundaries remain distinct.
The change reduces duplicate authorization bookkeeping without granting
agents discretion to approve their own proposals. Research material
under `doc/research/` remains historical, not an approval source.

## Assumptions and Constraints

- The released standards are sourced from
  `https://github.com/wesley-dean/coding_standards.git`.
- The selected stable release is `v2.2.1`, upstream tag commit
  `6e1623635bc2b1bbf7ab05a9660619c405a887bf`.
- Release metadata identifies archive SHA-256
  `86912be04c7208595c70cc8c9db8361c93b35eeb79bd37af3d390af851d64dc4`.
- The `doc/standards/` snapshot is externally managed and must reflect
  the selected release exactly; local policy belongs outside it.
- The repository continues to use GitHub Issues, labels, milestones,
  accepted ADRs, and ordinary PR review rather than requiring a
  GitHub Projects board.
- Authorization evidence follows the **live label state**, not a
  stored issue summary or a prior conversation. Label application must
  remain controlled by the appropriate human decision authority.

## Alternatives Considered

**Retain separate approval comments as mandatory evidence:** Rejected
because it would conflict with the new upstream approval contract
and perpetuate two potentially inconsistent workflow states.
Comments may still explain rationale voluntarily.

**Treat the label as permission for agents to approve work:** Rejected.
Making the label sufficient evidence is distinct from delegating
the approval decision. Unsupervised agent approval remains forbidden.

**Have story approval automatically approve related technical tasks:**
Rejected because the Product Owner and Technical Architect authorize
different scopes and phases.

**Edit the imported standard to keep the previous approach:** Rejected
because imported standards are immutable snapshots. Any deliberate
project-specific exception would need its own explicit local policy.

**Disable three-phase governance during the upgrade:** Rejected
because the repository already opted in, and a standards refresh must
not silently alter that decision.

## Consequences and Verification

Contributors and agents should inspect the live `approved` label to
determine the approval state of each issue. They must still check scope,
dependencies, security obligations, and accepted ADRs. An `in-progress`
label tracks execution state, not authorization. Completion remains
subject to the task and story Definitions of Done, independently
verified acceptance criteria, and PR review gates.

The repository-facing guidance in `AGENTS.md`, `README.md`,
`CONTRIBUTING.md`, and `doc/decisions.md` must be reconciled with
this decision, avoiding claims that comments are required or labels
insufficient. The historical ADR-018 record is retained and marked
as partially superseded rather than rewritten as though its
original policy had never existed.

The initial upgrade changes only standards provenance, the complete
managed snapshot as needed, and related governance documentation.
It does not create or approve any product story, technical task,
application implementation, cloud configuration, or deployment.

To verify adoption, compare all 49 managed file paths and Git blob
SHA values with the exact v2.2.1 tag, inspect the committed
`.codingstandardrc` pin and active three-phase opt-in, and review
the PR diff for governance consistency.

## Compatibility and Migration

Existing issues bearing `approved` are interpreted using their current
live label state under the new standard; comments need not be
backfilled as approval evidence. Proposed issues without the label
remain unapproved. No separate comments are deleted, and no issue
labels are modified by this standards-adoption change.

Approvers must remove and reconsider `approved` when an already
authorized issue undergoes a material scope change. Existing
security, repository-access, ADR, CI, and PR-merge controls are
unchanged.

## Related Decisions

ADR-018 establishes the released-standards adoption process and
three-phase opt-in. ADR-001 defines governance precedence; ADR-013
treats repository-facing documents as maintained surfaces.
This ADR supersedes only the approval-evidence portion of ADR-018.
