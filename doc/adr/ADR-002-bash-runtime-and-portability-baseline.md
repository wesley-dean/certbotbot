# ADR-002: Bash Runtime and Portability Baseline

Date: 2026-08-19

## Status

Accepted

## Intent and Documentation Posture

This ADR establishes the default Bash compatibility floor for projects created
from this template.  The floor is a starting constraint, not a claim that every
future project must remain on it forever.

## Context

A reusable Bash starter should support a useful range of environments without
forcing every new project to avoid modern Bash indefinitely.  The source projects
that informed this template demonstrate that Bash 4.3 is sufficient for the
common architecture used here, including indexed and associative arrays,
function-based modules, explicit plugin registration, and the build/test
contracts.

Bash 3.2 would improve compatibility with the historical system Bash shipped by
macOS, but doing so would materially constrain implementation techniques and
would diverge from the current family of projects.  Bash 5.x would provide newer
language features, but making it the template floor would reduce portability
before a new project has demonstrated a need for those features.

The template should therefore establish a conservative common denominator while
making it straightforward for an individual project to raise the minimum when a
newer Bash capability produces meaningful engineering value.

## Decision Drivers

- Reuse proven implementation patterns from the existing Bash project family.
- Avoid unnecessary restrictions on Linux distributions and container images.
- Keep the runtime contract explicit and testable.
- Allow future projects to raise the floor deliberately when the tradeoff is
  justified.
- Avoid pretending to support Bash versions that are not exercised by CI.

## Decision

The starter project SHALL target Bash 4.3 or newer.

Maintained source and generated artifacts SHALL avoid features introduced after
Bash 4.3 unless the project records a new architectural decision that raises the
minimum supported version.

Release validation SHOULD execute the generated artifacts under a Bash 4.3
container in addition to the primary CI environment.  Compatibility validation
should exercise representative public behavior rather than only run `bash -n`,
because syntax compatibility alone does not prove runtime compatibility.

The generated artifacts SHALL use `#!/usr/bin/env bash` as their interpreter
line.  Source fragments under `lib/` are assembled into the distribution
artifact and do not need independent shebangs.

A project derived from this template MAY raise its minimum Bash version.  When it
does so, the change should be explicit in its ADRs, tests, user documentation,
and compatibility workflow.

## Operational Constraints

- The default runtime floor MUST be Bash 4.3.
- Source MUST NOT intentionally depend on post-4.3 Bash features while this ADR
  remains in force.
- CI SHOULD execute representative release behavior under Bash 4.3.
- Generated executable artifacts MUST use `#!/usr/bin/env bash`.
- A higher Bash minimum MUST be documented as an intentional project decision.

## Considered Alternatives

### Bash 3.2

This would improve compatibility with older macOS installations.  It was rejected
because it would constrain data structures and implementation patterns used by
the existing project family while still not eliminating the need for users to
install newer tooling in many development environments.

### Bash 5.0 or Newer

This would simplify access to newer language features and reduce compatibility
concerns around older Bash behavior.  It was rejected as the template default
because the starter should not exclude environments merely for convenience when
the established architecture already works on Bash 4.3.

### No Declared Minimum

This was rejected because an unspecified compatibility floor is difficult to
test and encourages accidental reliance on whichever Bash version a developer
happens to have locally.

## Consequences

The starter accepts some constraints associated with an older Bash runtime.
Projects that need newer features must make that tradeoff explicitly rather than
acquiring it accidentally.

The compatibility job adds release validation cost.  That cost is justified by
making the portability promise evidence-based.

## Source Lineage

adrctl, bashdeps, and mktext currently exercise Bash 4.3 compatibility patterns.
Bootstrap historically contains a different Bash tooling decision, illustrating
that the minimum should remain an explicit project-level choice rather than an
unstated assumption.

## Open Questions and Follow-Ups

No open questions remain for the starter.  Individual projects should revisit
this ADR when a concrete Bash 5.x capability would materially improve safety,
clarity, or maintainability.

## Related Decisions

- ADR-004: Modular Source Assembly and Automatically Discovered Plugins
- ADR-009: Observable Behavior Testing Across Shipped Artifacts
