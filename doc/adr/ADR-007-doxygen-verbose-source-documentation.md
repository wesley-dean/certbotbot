# ADR-007: Doxygen-Based Verbose Source Documentation Standard

Date: 2026-08-19

## Status

Accepted

## Context

Bash is highly expressive but provides little native structure for communicating
contracts, types, failure semantics, invariants, or architectural intent.  Code
that is straightforward to execute can still be expensive to maintain when the
reasoning behind it must be reconstructed from control flow.

The projects that informed this starter use Doxygen-compatible Bash comments to
make source code carry a rich maintenance narrative.  This is especially useful
for AI-assisted work: generated code can be syntactically plausible while
silently drifting from the assumptions that made an earlier design safe.

Verbose source documentation does not impose a distribution-size penalty here.
The ordinary release artifact removes full-line comments, and the minified
artifact is smaller still.  The development artifact intentionally preserves the
commentary needed to maintain and review the generated single-file form.

## Decision Drivers

- Preserve local reasoning near the implementation that depends on it.
- Make Bash interfaces and failure behavior explicit.
- Generate browsable reference documentation without maintaining duplicate API
  prose manually.
- Support human and AI-assisted maintenance with enough context to avoid
  inference from code alone.
- Prefer maintainability over source-file brevity.

## Decision

All maintained Bash source SHALL use the project's Doxygen-based documentation
standard described in `doc/documentation-standard.md`.

The standard is normative.  It is not a suggestion to add comments only when
convenient.  The project explicitly prefers a "more is more" posture: additional
source documentation is desirable when it preserves intent, assumptions,
contracts, edge cases, examples, failure modes, interactions with other modules,
or reasons that would otherwise require a future maintainer to reverse-engineer
the implementation.

Doxygen comment lines SHALL begin with `##`.  Maintained Bash files SHALL include
`@file`, `@brief`, and substantive `@details` documentation.  Functions SHALL be
documented with `@fn`, `@brief`, `@details`, parameters when present, observable
output when relevant, return semantics, and examples for non-trivial public or
architecturally significant interfaces.

Documentation SHALL describe why a function or module exists and the contract it
preserves, not merely restate individual shell commands in English.

Private helpers MAY use shorter blocks when their contract is genuinely narrow,
but brevity must not hide non-obvious assumptions or failure behavior.

The `.dev.bash` artifact SHALL retain this commentary.  The `.bash` and
`.min.bash` artifacts SHALL not require maintainers to reduce documentation to
optimize consumer size.

## Operational Constraints

- Maintained Bash files MUST use Doxygen-compatible `##` documentation.
- File blocks MUST include `@file`, `@brief`, and substantive `@details`.
- Significant functions MUST document contract, parameters, outputs, return
  semantics, and examples as applicable.
- Documentation MUST preserve reasoning and assumptions rather than merely
  paraphrase code.
- Source documentation MUST NOT be reduced solely to shrink release artifacts.
- `.dev.bash` MUST retain maintained documentation comments.

## Considered Alternatives

Sparse conventional comments were rejected because they do not provide a
consistent interface vocabulary or generated reference output.  External-only
API documentation was rejected because implementation rationale drifts when it
is separated from source.  Minimal comments plus AI inference were rejected
because plausible inference is not evidence of original intent.

## Consequences

Maintained Bash files are intentionally longer.  Reviews must evaluate comment
accuracy along with executable behavior.  The benefit is a substantially richer
maintenance surface with no requirement that consumer artifacts retain the same
volume of prose.

## Source Lineage

The standard consolidates documentation practices used across Bootstrap,
adrctl, bashdeps, and mktext and is informed by:

- https://wesleydean.com/blog/bash_help_documentation_project/
- https://wesleydean.com/blog/documentation_and_ai/

## Related Decisions

- ADR-001: Documentation and Decision Hierarchy
- ADR-008: Documentation-Driven, Test-Second Development
- ADR-010: Generated Reference Documentation Is Ephemeral
