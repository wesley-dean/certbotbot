# ADR-NUMBER: TITLE

Date: DATE

## Status

STATUS

## Intent and Documentation Posture

This Architecture Decision Record is intentionally detailed.  The reasoning is
part of the decision and should be preserved with the same care as the final
outcome.

Prefer a "more is more" documentation posture when additional detail preserves
context, assumptions, alternatives, tradeoffs, failure modes, human factors,
security boundaries, trust claims, or constraints that would otherwise be easy
to lose.  Future maintainers, including AI-assisted tooling, should be able to
reconstruct why the project arrived at this decision rather than infer intent
from implementation alone.

Not every ADR requires every optional section below.  Consequential decisions,
especially those involving security, sensitive data, compatibility, public APIs,
data loss, destructive behavior, trust, or complex failure semantics, should err
toward explicitness rather than brevity.

## Context

Describe the situation that led to this decision.  Include relevant technical,
organizational, operational, historical, and security context.  Explain why the
decision matters now and identify tensions or pressures that shaped the problem.

## Decision Drivers

Document the factors that most strongly influenced the decision.  Include
maintainability, portability, security, trust, operational risk, cognitive load,
compatibility, contributor experience, and other relevant concerns.

## Decision

State the decision clearly and unambiguously.  Define its intended outcome,
boundaries, important non-goals, and preconditions.  Explain how the decision
should be applied in practice.

## Promises

Document the properties this decision intentionally guarantees.  Prefer
observable, bounded, and testable statements where practical.

Ask:

- What must remain true after this decision is implemented?
- Which properties are architectural invariants rather than implementation
  details?
- Under what assumptions do these promises hold?
- Which promises can become automated tests or architecture checks?
- Would a future maintainer know when a refactor violates the decision?

A promise is not an aspiration.  Avoid broad language such as "secure," "safe,"
or "reliable" unless the ADR defines exactly what the term means in this context.

## Non-Promises

Document reasonable-sounding guarantees that this decision explicitly does not
make.  Use this section to prevent future readers from inferring broader
protection, correctness, availability, durability, privacy, or behavior than the
architecture provides.

Ask:

- What might a reasonable reader incorrectly infer from the chosen technology?
- Which related properties are deliberately outside scope?
- Which protections are partial rather than complete?
- Where does the runtime or platform make a stronger guarantee impossible?
- Are implementation details at risk of being mistaken for durable guarantees?

A non-promise is not an apology or a loophole.  If writing a non-promise reveals
that the omitted guarantee is actually required, revisit the design rather than
using this section to disclaim a real requirement.

## Adversary and Failure Model

Describe the failures, hostile conditions, misuse cases, environmental
conditions, and actors the decision is intended to account for.  Also document
important conditions deliberately outside the decision's protection boundary.

"Adversary" need not mean only a malicious human.  Depending on the decision, the
adversary may be malformed input, stale state, a failed network, partial
execution, concurrency, operator error, a compromised peer, hostile input,
unexpected Unicode, a future maintainer misunderstanding an assumption, or an
actual attacker.

Ask:

- What happens when input is malformed?
- What happens when dependencies are unavailable?
- What happens after partial failure?
- What happens under retry or concurrency?
- What happens when state is stale?
- What happens if the caller is wrong?
- What happens if the caller is hostile?
- What happens if the process or host fails?
- Which failures or adversaries are intentionally outside this decision?

The purpose is not to predict every possible failure.  It is to record the model
of adversity that materially shaped the decision and the boundary within which
its promises are intended to hold.

## Operational Constraints

Translate the decision into concise constraints that future implementation and
review work can evaluate directly.  Use normative terms such as MUST, MUST NOT,
SHALL, SHALL NOT, SHOULD, and MAY when they improve clarity.

This section is intentionally shorter than the surrounding ADR.  The full ADR
preserves reasoning; these constraints provide an operational representation of
that reasoning for humans, automation, and AI-assisted development.

## Considered Alternatives

Document alternatives that were seriously considered.  For each alternative,
explain why it was attractive and why it was not selected.  Preserve rejected
ideas that a future maintainer might otherwise reasonably rediscover and propose
again without knowing they were already examined.

## Consequences

Describe expected benefits, accepted costs, new risks, maintenance implications,
and conditions that may justify revisiting the decision.  Include costs created
by the promises themselves, such as fail-closed behavior, compatibility limits,
or additional testing obligations.

## Source Lineage

Record earlier project ADRs, specifications, documentation, articles, or other
material that materially influenced this decision.  Preserve lineage when this
ADR consolidates a pattern that has already survived use in another project.

## Superseded Decisions

When applicable, identify the exact earlier decisions or portions of decisions
this ADR supersedes.  Avoid making readers infer the current effective rule from
contradictory records.

Remove this section when the ADR supersedes nothing.

## Open Questions and Follow-Ups

List unresolved questions, assumptions requiring validation, deferred work, or
signals that should trigger reconsideration.  Explicit open questions are
preferable to letting implementation choose unresolved semantics accidentally.

## Related Decisions

List related ADRs and documentation.  Identify superseding or superseded records
when applicable.
