# ADR-008: Documentation-Driven, Test-Second Development

Date: 2026-08-19

## Status

Accepted

## Context

AI-assisted implementation makes it inexpensive to generate code and tests
quickly.  That speed can invert the desired reasoning order: implementation
choices become accidental requirements, and tests then preserve those choices
without anyone first articulating the intended contract.

The source project family increasingly uses a different sequence: document the
interface and reasoning first, write tests that express the intended behavior
second, and implement only after those two artifacts agree about the contract.

This is not a prohibition on exploration.  Small experiments may be useful to
learn whether an approach is feasible.  Exploratory code should not silently
become architecture merely because it already exists.

## Decision Drivers

- Force intent and contracts to become explicit before implementation details
  dominate the design.
- Make tests verify desired behavior rather than accidental implementation.
- Reduce architectural drift during iterative AI-assisted work.
- Preserve room for experiments without confusing them with accepted design.

## Decision

For consequential new behavior or architecture, development SHOULD follow this
sequence:

1. Identify or create the governing ADR and operational constraints.
2. Draft or update Doxygen documentation for the affected interface.
3. Add or update behavior tests that express the documented contract.
4. Implement the smallest coherent change that satisfies the contract.
5. Run validation.
6. Review the completed change against the governing ADR constraints.

For small bug fixes whose intended contract is already documented, steps may be
compressed, but documentation and tests should still be corrected when the bug
reveals that either was incomplete or wrong.

Exploratory spikes MAY precede documentation when they are needed to discover
feasibility.  Such code should be treated as disposable evidence until the
decision is recorded.

## Operational Constraints

- Consequential changes SHOULD identify governing ADRs before implementation.
- Interface documentation SHOULD precede or accompany new implementation.
- Tests SHOULD encode documented behavior rather than implementation accidents.
- Completed changes SHOULD be reviewed against their original ADR constraints.
- Exploratory code MUST NOT become an undocumented architectural constraint by
  default.

## Considered Alternatives

Implementation-first development was rejected as the default because it makes
current code disproportionately influential over future reasoning.  Test-first
without prior contract documentation was rejected as incomplete because tests
can precisely encode the wrong abstraction.  Requiring a new ADR for every code
change was rejected as bureaucratic and counterproductive.

## Consequences

Some changes begin more slowly because intent is written before code.  Later
review and maintenance gain a clearer chain of reasoning, and AI-assisted
iteration has stronger boundaries within which to operate.

## Source Lineage

This formalizes a development sequence used in recent work across the Bash
project family and complements the ADR/documentation model described in Wesley
Dean's writing on AI-assisted development.

## Related Decisions

- ADR-001: Documentation and Decision Hierarchy
- ADR-007: Doxygen-Based Verbose Source Documentation Standard
- ADR-009: Observable Behavior Testing Across Shipped Artifacts
