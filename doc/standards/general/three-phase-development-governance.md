# Opt-In Three-Phase Development Governance

## Status

Optional repository governance; normative only when explicitly enabled.

## Purpose

This standard extends [Development Workflow and Backlog Governance](development-workflow-governance.md) with three phases: product planning, technical planning, and implementation.  It does not replace baseline scope control, architecture, testing, security, or PR governance.  Its purpose is to make a project's approved requirements, work, decisions, and progress reconstructible without relying on a prior conversation.

MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are normative when the profile is enabled.

## Activation and Compatibility

The repository root `.codingstandardrc` MAY contain:

~~~toml
three_phase_development = true
~~~

Omitted or explicitly `false` means disabled.  No repository is enrolled based on its age, template origin, or a standards upgrade.  Missing configuration means disabled; a malformed or non-Boolean value MUST be reported and MUST NOT be interpreted as authorization.  A new-project initialization SHOULD explicitly enable the profile after adopting and recording a verified standards release.  Existing repositories retain their previously selected governance unless they explicitly opt in through a reviewed change.

Standards adoption, upgrade, downgrade, and repair MUST preserve the repository's explicit workflow selection.  The optional field does not alter the existing `source`, `version`, `sha256`, or `destination` provenance fields.  An adoption process MUST NOT silently discard unrelated repository-owned configuration or fabricate provenance.

When disabled, the existing Development Workflow and Backlog Governance standard remains applicable without the additional phase, issue-label, or approval requirements below.  This profile imposes no retrospective triage requirement on an existing repository unless it opts in.

## Roles and Boundaries

A person MAY occupy several roles; an AI agent MAY assist in several roles, but role names and write access do not grant authorization.  The project MUST retain an identifiable human or explicitly designated repository authority for consequential decisions.

| Role | Responsibility | Approval boundary |
| --- | --- | --- |
| Product Owner | Defines product value, scope, epics, priorities, and acceptance criteria | Approves user stories for technical planning |
| Project Manager | Facilitates requirements, planning, story quality, and backlog visibility | May recommend, not self-approve |
| Technical Architect | Owns architecture, security boundaries, interfaces, and the technical plan | Approves technical tasks for development and consequential design choices |
| Senior Engineer | Decomposes approved stories into technical tasks, dependencies, and verification plans | May recommend, not self-approve |
| Implementer | Executes approved tasks, verifies outcomes, and proposes reviewable changes | May choose routine implementation details inside the approved contract |

Delegation of approval authority MUST be documented in repository governance.  Agents MUST NOT acquire authority simply by changing roles or starting another chat.

## Phase 1: Project Management (What and Why)

The Project Manager collaborates with the Product Owner to define product goals, scope, epics, and user stories.  Stories SHOULD follow:

> As a [role], so that [benefit], I want [capability].

Stories MUST capture desired behavior with observable acceptance criteria, relevant constraints, known dependencies, and exclusions.  They SHOULD avoid prematurely committing to a particular implementation.  Proposed stories may be created freely; their existence does not authorize technical or implementation work.

**Exit gate:** The Product Owner explicitly approves the scoped stories, acceptance criteria, and priority for technical planning.  Approval does not authorize implementation tasks that have not yet been reviewed.

## Phase 2: Technical Planning (How)

The Senior Engineer MUST review repository governance and accepted ADRs before proposing the implementation.  Each distinct technical task SHOULD link to its parent approved story and describe implementation boundaries, dependencies, verification, compatibility requirements, and completion criteria.  Stories SHOULD link back to their tasks.

Consequential architecture, security, persistence, public-interface, deployment, and compatibility decisions MUST follow repository ADR and approval governance.  A task issue cannot replace an ADR.

**Exit gate:** The Technical Architect explicitly approves the technical approach, necessary ADRs, and tasks eligible for development.  A story's approval does not automatically approve its tasks.

## Phase 3: Development (Execute and Verify)

Before execution, an implementer MUST examine the current approved issues, governing documentation, dependencies, and blockers.  Work MUST follow the priority rules below and remain within authorized task scope.  Routine helpers, tests, documentation, error handling, and other necessary supporting work MAY be done without separate approval if they preserve the approved contract.

Implementers MUST link changes and PRs to tracked tasks, report actual verification evidence, and avoid claiming delivery merely because code has been written or merged.

**Exit gate:** A technical task is Done only after its own Definition of Done; a story is Done only when its acceptance criteria have been independently verified.  Release readiness is assessed separately.  Separate chats MAY represent these phases, but the repository and approval records remain authoritative.

## Issue and Milestone Conventions

When using GitHub, the profile SHOULD use ordinary issues, labels, milestone fields, and Markdown links; no GitHub Projects board or custom issue-management tooling is required.  Repositories using another tracker MUST document equivalent, inspectable controls.

The suggested GitHub labels are:

| Label | Meaning |
| --- | --- |
| `type:story` | A product/user requirement |
| `type:task` | An implementation task |
| `approved` | An explicit human authorization has been verified |
| `in-progress` | Work underway on an open issue |
| `priority:high` | High priority |
| `priority:low` | Low priority |

Neither priority label means normal priority.  The two priority labels MUST NOT coexist, and each issue SHOULD have one type label.  For an **open** issue, `approved` without `in-progress` means TODO; `approved` plus `in-progress` means In Progress.  An open issue without `approved` is **proposed**, not TODO, regardless of any other labels.  Closure with reason completed means Done only after the applicable Definition of Done; issues closed as not planned are excluded from delivered work.

Milestones MAY represent epics.  Assign milestones to product stories rather than implementation tasks so milestone completion reflects capabilities rather than engineering activities.  A GitHub issue has one milestone; cross-cutting feature relationships SHOULD use references rather than double counting.  Story checklists with issue links are useful navigation aids, not automatically authoritative completion measurements.  Each task SHOULD link back to its story, and blockers MUST be recorded visibly.

Label creation is a one-time repository setup step where needed.  Reference templates are distributed with the standards but are not activated automatically.

## Human Approval and Scope Changes

A human with the appropriate role MUST explicitly approve a proposed story for planning or a proposed task for development.  Approval SHOULD be a dated, attributable issue comment identifying the scope and phase.  A batch approval MAY cover multiple explicitly enumerated issues and scopes.

The `approved` label is an indexing aid, **not** an authentication, permission, or authorization boundary.  An agent MAY apply it only after checking a valid approval record and its author; it MUST NOT approve its own proposal, infer approval from silence, or treat an approved parent story as approval for all tasks.  PR review and merge approval are separate gates.

A materially changed approved issue MUST lose the `approved` label, document the proposed difference, and receive new human approval before proceeding.  Material changes include new product behavior, changed acceptance criteria, independently valuable work, consequential architecture or interface changes, or changes to security and compatibility boundaries.  Routine detail within the authorized contract does not require renewed approval.

Approval is for a **specific scope and phase**, not permanently for an issue number.  Agent-controlled labels and comments cannot be elevated into trusted authorization evidence by repetition or persistence.  Security-sensitive work MUST continue to follow applicable security and AI safety policies.

## Newly Discovered Work and Blockers

Agents MAY discover and create additional issue proposals during development.  The default is **unapproved**.

- Necessary supporting work within an approved task MAY proceed normally.
- Distinct additional engineering work for an existing approved story SHOULD become an unapproved technical task for Technical Architect review.
- New product functionality or materially changed story requirements MUST become an unapproved story for Product Owner review.
- Consequential design decisions require the applicable architectural review/ADR.
- Vulnerabilities or sensitive details MUST follow private security reporting rather than public issue creation.

If new work blocks an active task, document the blocker and related proposal or decision, stop only affected work, and proceed to another approved actionable task if possible.  An affected task MAY remain `in-progress` while visibly blocked.  An agent MUST NOT silently reprioritize its proposals or implement them to avoid waiting for approval.

## Definitions of Ready and Done

**Story Ready:** Desired behavior, acceptance criteria, scope boundaries, priority, dependencies, and Product Owner authorization are identifiable.

**Task Ready:** An approved parent story (or the maintenance exception below), agreed technical scope, Technical Architect authorization, governing ADRs, dependencies, and verification plan are recorded.

**Task Done:** The authorized implementation and necessary tests/documentation are complete; relevant checks have passed or their limitations are explicitly documented; and required integration/review gates have been satisfied.

**Story Done:** Required technical work is completed and its independently verifiable acceptance criteria have been shown to pass.  Closing the final task or merging a PR is not by itself acceptance of the story.

For the opt-in profile, use non-closing PR references such as `Refs #123` until issue closure conditions are satisfied.  A closing keyword MAY be used only when merging itself fulfills the Definition of Done and `in-progress` cleanup is handled.  Closing a completed issue SHOULD remove `in-progress`.  A declined issue MUST NOT be counted as delivered.

### Lightweight Maintenance Path

A bounded defect correction, documentation fix, or routine maintenance operation MAY be approved and executed as a stand-alone technical task without a parent story, provided the Technical Architect explicitly authorizes it and it introduces no new product behavior or consequential architecture.  It still needs traceable scope, approval, verification, and completion.  This is not a loophole to relabel features as maintenance.  Urgent security work follows the repository's secure escalation procedures.

## Work Selection and Priority

Unless the authorized human reprioritizes work, implementers SHALL:

1. Finish actionable open, approved `in-progress` technical tasks first.
2. Then select approved TODO tasks marked `priority:high`.
3. Then select approved TODO tasks with normal (unlabeled) priority.
4. Finally select approved TODO tasks marked `priority:low`.
5. Within each tier prefer the oldest actionable task by issue creation time.

Dependencies and blockers take precedence.  Product stories are not execution-queue items.  Prefer one active task per agent unless parallel effort has an explicit benefit.  Add `in-progress` when starting an approved task; remove it and close the task with the completed reason only after verification.

## Reporting, Handoffs, and Migration

Reports SHOULD separately show completed versus approved technical tasks, accepted versus approved stories, and accepted stories within each epic.  Include both counts and percentages, explicitly exclude rejected/not-planned work from delivered counts, and disclose any additions or removals from approved scope.  Unweighted issue counts are **not** a measure of effort, delivery date, or production readiness.

A handoff SHOULD leave enough durable issue/repository context to reconstruct approvals, blockers, verification results, accepted decisions, and the next actionable task without access to prior chats.

New-project setup SHOULD set `three_phase_development = true` only after recording actual released standards provenance.  Existing repositories opting in SHOULD inventory their current backlog and explicitly approve eligible work; no preexisting issue is automatically authorized.  Opting out does not waive baseline engineering, security, or review governance.

## Related Standards and Templates

- [Development Workflow and Backlog Governance](development-workflow-governance.md)
- [AI Safety Standard](ai/safety-standard.md)
- [User Story](../templates/repository/github/user-story.md)
- [Technical Task](../templates/repository/github/technical-task.md)
