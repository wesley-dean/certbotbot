# ADR-001: Documentation and Decision Hierarchy

Date: 2026-08-19

## Status

Accepted

## Intent and Documentation Posture

This ADR defines how the repository preserves architectural reasoning and how
that reasoning is translated into concise operational guidance.  The decision is
intentionally explicit because AI-assisted development makes it increasingly
possible to produce locally plausible changes that are inconsistent with prior
architectural intent.

The repository therefore needs more than accurate implementation.  It needs a
recoverable chain from intent, to constraints, to implementation, to validation.

## Context

The Bash projects that informed this template use several forms of documentation
for different purposes.  README files orient users.  ADRs preserve durable
choices.  Doxygen comments explain implementation contracts near source.  Tests
capture observable expectations.  AGENTS files help contributors and AI tools
navigate the project.

These forms become harmful when they compete as parallel sources of truth.  A
large `AGENTS.md` can become a second architecture manual that drifts away from
ADRs.  Tests can encode implementation accidents rather than intended behavior.
Comments can explain what code does while silently inventing rationale that was
never decided.  Generated reference documentation can be mistaken for maintained
source documentation.

AI-assisted maintenance increases the importance of preserving decision lineage.
A model can often repair syntax or satisfy a failing test without knowing why a
constraint existed.  Repeated locally-correct edits can therefore cause gradual
architectural drift even when each individual change appears reasonable.

## Decision Drivers

- Preserve reasoning, alternatives, and tradeoffs rather than only outcomes.
- Give contributors and AI-assisted tools a concise way to identify binding
  constraints without duplicating entire ADRs.
- Keep implementation rationale close to code while preventing comments from
  inventing architectural history.
- Make conflicts between implementation and architectural intent visible.
- Support future reconstruction of why the system has its current shape.

## Decision

The project SHALL use a layered documentation hierarchy.

Architecture Decision Records under `doc/adr/` are the canonical record for
durable architectural and process decisions.  ADRs should be intentionally
complete.  They should record the context, decision drivers, selected approach,
considered alternatives, consequences, source lineage, and unresolved questions
that future maintainers would otherwise have to infer.

Each ADR SHALL include an `Operational Constraints` section when the decision can
be translated into concrete implementation or review rules.  This section is a
compact derivative of the full reasoning.  It exists so a contributor or AI tool
can quickly determine what must remain true while still having the full ADR
available when the reason matters.

`AGENTS.md` SHALL remain a concise operational map.  It MAY summarize salient
constraints, repository locations, validation commands, and workflow boundaries,
but it SHALL point to ADRs and normative documentation rather than reproduce
architectural rationale at length.

A project specification MAY be added when a project has sufficiently rich public
behavior to benefit from a normative description independent of implementation.
Specifications describe what the current system promises.  ADRs explain why
important choices were made.

Doxygen comments SHALL preserve implementation-level intent, interfaces,
invariants, assumptions, edge cases, examples, and failure behavior close to the
source.  Comments MUST NOT invent historical rationale that is absent from the
architectural record.  Ambiguity should be surfaced explicitly.

Tests and CI SHALL verify observable behavior and selected architectural
invariants.  Passing tests do not supersede an ADR.  A conflict between a test,
implementation, and governing ADR must be investigated rather than silently
resolved in favor of whichever artifact is easiest to change.

Consequential work SHOULD begin by identifying the ADRs and constraints that
govern the affected area.  Review SHOULD compare the completed change against
those same constraints so that validation includes architectural alignment, not
only syntax and behavior.

## Operational Constraints

- ADRs MUST remain the canonical source for durable architectural reasoning.
- `AGENTS.md` MUST remain concise and MUST link to governing ADRs rather than
  duplicate them wholesale.
- ADRs SHOULD include explicit operational constraints where practical.
- Doxygen comments MUST describe implementation intent without fabricating
  architectural history.
- A conflict between implementation and an ADR MUST be surfaced explicitly.
- Passing tests MUST NOT be treated as proof of architectural alignment.
- Consequential changes SHOULD be reviewed against the ADR constraints that
  governed their implementation.

## Considered Alternatives

### Put All Guidance in AGENTS.md

A single operational document is convenient for tooling because there is only
one place to read.  It was rejected because the document would inevitably become
large, would duplicate ADRs, and would make architectural rationale easier to
silently edit without preserving decision history.

### Use Only ADRs

ADRs can contain every relevant rule.  This was rejected because day-to-day
contributors still benefit from a compact map of repository shape, commands, and
high-frequency constraints.  Requiring every task to rediscover all relevant
ADRs increases cognitive load and makes important operational rules easier to
miss.

### Treat Tests as the Effective Specification

Executable tests are precise and valuable.  They were rejected as the sole
source of truth because tests describe selected observable behavior and can also
encode mistakes, omissions, or implementation details.  They rarely preserve
why an architectural boundary exists.

## Consequences

The repository carries more documentation than a minimal Bash project.  That is
intentional.  Maintainers spend less time reverse-engineering decisions and have
a stronger basis for rejecting plausible changes that violate prior constraints.

The model requires discipline.  A new ADR is unnecessary for trivial changes,
but consequential changes should not bypass the architectural record merely
because code can be changed quickly.

## Source Lineage

This decision consolidates patterns used across Bootstrap, adrctl, bashdeps, and
mktext.  It is also informed by Wesley Dean's writing on ADRs and AI-assisted
development, particularly:

- https://wesleydean.com/blog/adrs_and_generative_ai/
- https://wesleydean.com/blog/documentation_and_ai/

## Open Questions and Follow-Ups

Projects created from this template may add a normative specification once their
public behavior becomes substantial enough to justify one.  The starter does not
create an empty specification merely to satisfy a structural convention.

## Related Decisions

- ADR-000: Capability Scope, Epistemic Honesty, and Separation of Concerns
- ADR-007: Doxygen-Based Verbose Source Documentation Standard
- ADR-008: Documentation-Driven, Test-Second Development
