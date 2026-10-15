# ADR-003: Make as the Canonical Orchestration Interface

Date: 2026-08-19

## Status

Accepted

## Context

The source projects use Make as the stable interface between developers, CI,
dependency tooling, documentation generation, tests, and release construction.
The value of that interface is semantic consistency: a CI workflow should not
quietly implement a different build than a maintainer runs locally.

A starter repository benefits from carrying the contract while avoiding a large
framework of reusable Make includes or a generator that future projects must
learn before they can change their own build.

## Decision Drivers

- One understandable orchestration surface for humans and CI.
- Explicit target semantics and network boundaries.
- Minimal project-specific machinery.
- Generated artifacts should be reproducible from maintained source.
- Local and CI workflows should invoke the same project commands.

## Decision

GNU Make SHALL be the canonical orchestration interface.

The starter SHALL provide at least `all`, `build`, `check`, `format`, `deps`,
`deps-check`, `docs`, `docs-clean`, `test`, `test-report`, `clean`, and
`distclean` targets.

`all` SHALL perform dependency convergence and then build artifacts.  The order
must remain explicit under parallel Make.

`build` SHALL assemble generated artifacts from maintained source and prepared
dependency state without synchronizing dependencies or intentionally accessing
the network.

`check` SHALL validate Bash syntax and run ShellCheck against maintained Bash
source.  `format` SHALL run shfmt with `-i 2 -bn -ci -sr -kp`, matching the
repository's MegaLinter policy.

CI SHOULD call Make targets instead of duplicating their implementation.

## Operational Constraints

- Make MUST be the canonical project orchestration surface.
- `all` MUST run dependency convergence before `build`.
- `build` MUST NOT repair or acquire dependencies.
- `format` MUST use `-i 2 -bn -ci -sr -kp`.
- CI SHOULD reuse Make targets rather than reimplement them.

## Considered Alternatives

Shell-only build scripts were rejected because they would create another
project-specific command surface.  A reusable Make include framework was
rejected because it would turn a starter repository into infrastructure that
must itself be versioned and learned.  Literal copying of a mature project's
Makefile was rejected because accidental complexity should not become a template
contract.

## Consequences

Projects inherit a familiar and inspectable lifecycle.  Make remains a required
system development tool, but it is not a bashdeps-managed repository dependency.

## Source Lineage

This consolidates the Make lifecycle used by Bootstrap, adrctl, bashdeps, and
mktext while preserving the newer explicit dependency/build boundary.

## Related Decisions

- ADR-005: Dependency Management and Explicit Network Boundaries
- ADR-006: Three Release Artifact Flavors, Metadata, and Checksums
