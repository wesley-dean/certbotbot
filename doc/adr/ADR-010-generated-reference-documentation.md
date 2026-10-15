# ADR-010: Generated Reference Documentation Is Ephemeral

Date: 2026-08-19

## Status

Accepted

## Context

Doxygen can turn the source documentation standard into browsable HTML reference
material.  Generated documentation is valuable to readers but creates noisy and
redundant repository history when committed beside the source from which it is
derived.

The documentation build also consumes a Bash-aware Doxygen filter.  That filter
is repository dependency state and should follow the same explicit dependency
boundary as other managed assets.

## Decision Drivers

- Keep maintained source as the documentation source of truth.
- Avoid committing large generated HTML trees.
- Preserve offline documentation generation after dependencies are prepared.
- Make documentation suitable for GitHub Pages deployment.

## Decision

`make docs` SHALL generate Doxygen reference documentation under
`doc/reference/` and SHALL consume the bash-doxygen filter prepared by bashdeps.
It SHALL NOT synchronize dependencies or intentionally access the network.

`doc/reference/` SHALL be ignored by Git and SHALL be removable with
`make docs-clean`.

CI MAY run `make deps` before `make docs`, then publish `doc/reference/` as a
GitHub Pages artifact.  Generated documentation SHALL NOT be committed to the
repository merely to support Pages.

The Doxygen configuration SHALL read maintained Bash source, use the prepared
Bash filter, and include the ADR directory in generated reference material where
practical so architecture is discoverable alongside API documentation.

## Operational Constraints

- `docs` MUST write generated output to `doc/reference/`.
- `doc/reference/` MUST NOT be committed.
- `docs` MUST consume prepared bash-doxygen state and MUST NOT run `deps`.
- CI MAY publish generated reference output to Pages.
- Maintained source comments and ADRs MUST remain the source material.

## Considered Alternatives

Committing generated HTML was rejected because it duplicates source and creates
large mechanical diffs.  Having `make docs` repair missing dependencies was
rejected because documentation generation should respect the same explicit
network boundary as build and test operations.

## Consequences

A local documentation build requires prepared dependencies and system Doxygen.
Pages deployment must regenerate documentation, which is desirable because the
published site then reflects the exact source revision being deployed.

## Source Lineage

Current Bootstrap CI generates `doc/reference/` after dependency synchronization
and verifies that documentation generation leaves the repository clean.  The
bash-doxygen dependency pattern is also used by mktext.

## Related Decisions

- ADR-005: Dependency Management and Explicit Network Boundaries
- ADR-007: Doxygen-Based Verbose Source Documentation Standard
