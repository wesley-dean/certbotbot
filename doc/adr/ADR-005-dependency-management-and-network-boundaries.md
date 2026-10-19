# ADR-005: Dependency Management and Explicit Network Boundaries

Date: 2026-08-19

## Status

Accepted

## Context

The project family uses repository-scoped dependencies such as Bash scripts,
libraries, filters, and build assets.  These dependencies should be pinned,
verified, and reproducible without turning each Makefile into a collection of
custom download recipes.

There is also an important semantic distinction between repository dependencies
and system tooling.  bashdeps manages files the project vendors into prepared
state.  It is not an operating-system package manager and should not install
Make, Bash, Bats, Doxygen, Graphviz, ShellCheck, shfmt, curl, wget, or similar
system commands.

Build reproducibility also depends on a clear network boundary.  A build that
silently downloads missing tools is difficult to audit, difficult to reproduce
offline, and can change behavior without a source change.

## Decision Drivers

- One dependency manager for scripts, libraries, filters, and assets.
- Pinned and digest-verified dependency state.
- Offline build, test, documentation, and verification operations after
  dependencies have been prepared.
- Explicit failure when prepared state is missing.
- No confusion between repository dependencies and system packages.

## Decision

bashdeps SHALL manage repository dependencies declared in `dependencies.txt`.
Those dependencies are scripts, libraries, filters, or assets consumed by the
project.  System tools and operating-system packages are outside bashdeps scope.

The Makefile SHALL bootstrap only bashdeps directly.  bashdeps itself SHALL be
pinned to a released version and verified against a committed SHA-256 digest
before execution.  All other repository dependencies SHALL be acquired and
verified by bashdeps.

The initial manifest SHALL include the Bash-Minifier script used to produce the
minified artifact and the bash-doxygen filter used by Doxygen.

`make deps` is the convergence boundary.  It MAY access the network and MAY
repair missing or mismatched dependency state.  `make deps-check` SHALL verify
prepared state without network access or repair.

`make build`, `make docs`, `make test`, and `make test-report` SHALL consume
prepared dependency state.  Missing required state SHALL produce an actionable
failure directing the maintainer to `make deps` or `make all`; those targets
SHALL NOT silently repair the dependency.

`make all` SHALL run `deps` followed by `build`, and therefore MAY use the
network.

## Operational Constraints

- Only bashdeps MAY be bootstrapped directly by Make.
- bashdeps MUST verify every manifest-managed dependency by digest.
- bashdeps MUST NOT be used to install system packages or system commands.
- `deps` MAY use the network and repair dependency state.
- `deps-check`, `build`, `docs`, `test`, and `test-report` MUST NOT synchronize
  dependencies.
- Missing prepared state MUST fail with an actionable message.
- `all` MUST perform `deps` before `build`.

## Considered Alternatives

Direct Makefile downloads for every dependency were rejected because each new
dependency would duplicate acquisition and verification logic.  Automatic
network repair from `build` or `docs` was rejected because target names should
communicate their side effects.  Installing system packages through bashdeps was
rejected because it conflates repository state with host administration and
would make portability substantially harder.

## Consequences

A fresh checkout needs `make deps` or `make all` before offline targets that
consume managed assets can succeed.  In return, build and documentation behavior
become inspectable and suitable for offline or controlled environments.

## Source Lineage

This consolidates the dependency lifecycle developed in bashdeps and adopted by
Bootstrap, adrctl, and mktext.  The explicit network boundary follows the newer
Bootstrap behavior in which documentation generation consumes prepared state
rather than invoking dependency synchronization implicitly.

## Related Decisions

- ADR-003: Make as the Canonical Orchestration Interface
- ADR-010: Generated Reference Documentation Is Ephemeral
