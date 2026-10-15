# Testing

The starter uses Bats for behavior-oriented tests and exercises every generated
artifact flavor.  The goal is to validate what consumers execute rather than
assume concatenation, comment stripping, minification, packaging, or other build
transformations cannot change behavior.

Tests live under `tests/`.  Prefer a larger number of focused tests over a small
number of broad fixtures.  A failing test should normally identify one primary
contract.

## Test the Contract, Not an Incidental Snapshot

Tests should derive from documented behavior, ADR constraints, and explicit
security properties.  They are evidence for the intended contract rather than the
source of architectural intent.

Prefer durable invariants over mutable suite snapshots.  For example:

```text
every shipped artifact receives the same behavior contract
```

is a useful maintained requirement.  A statement such as:

```text
the suite contains 137 tests
```

is ordinarily transient CI output unless an exact count is itself somehow part of
the contract.

## Positive and Negative Assertions

Positive assertions prove that expected behavior occurs.  Security, privacy,
output-separation, destructive-operation, and fail-closed contracts often require
negative assertions as well.

When the contract says something must not happen, test that absence explicitly.
Examples include:

- protected data does not appear in stdout, stderr, diagnostics, or generated
  artifacts;
- a failed safety check does not modify files;
- stdout remains free of diagnostics when it is a data channel;
- a machine-readable format does not contain terminal control bytes;
- invalid input does not silently trigger a fallback path; and
- a network-free build does not acquire dependencies.

Observing the intended replacement, error message, or success value is not enough
if forbidden behavior could still occur through another observable path.

Threat-model findings should drive tests for important mitigations and residual
boundaries where executable evidence is practical.  See `doc/threat-modeling.md`.

## Artifact Matrix

`make test` runs the suite against the development, stripped, and minified
artifacts.  `make test-report` repeats the suite and writes JUnit XML under
`test-results/` for CI reporting.

The starter suite covers its own example behavior: help and version output,
build metadata, plugin discovery, noop execution, invalid plugin handling,
artifact shape, `.sha256` checksum companions, absence of stale `.256`
companions, and standalone runtime behavior.  A derived project should replace
or extend these examples with tests for its actual public contracts.

Generated artifacts are products.  A change that affects assembly, comment
stripping, minification, embedded dependencies, provenance, or checksums should be
validated against the artifact bytes and behavior rather than only against
maintained source.

## Build and Compatibility Evidence

CI plants legacy `.256` companions before a rebuild and verifies that a successful
`make build` removes them while preserving deterministic executable bytes and
valid `.sha256` companions.

Syntax validation and ShellCheck are part of `make check`, not substitutes for
behavior tests.  Release verification additionally checks exact artifact hashes
and minimum-Bash compatibility.

The minimum supported Bash version is a runtime contract.  Exercise
representative behavior under that floor rather than relying on modern-runner
syntax validation alone.

## Documentation Generation Evidence

Documentation generation has its own observable boundary.  `make docs` and
`make adr-index` consume prepared repository dependencies and must not acquire or
repair them.  CI should therefore include a negative case that withholds adrctl
while otherwise satisfying the earlier documentation prerequisite and verifies
that documentation generation fails without bootstrapping dependency state.

A successful documentation build should verify that `doc/adr/README.md` exists,
contains the current ADR corpus, and is ignored by Git; that
`doc/reference/index.html` exists and is ignored; and that tracked repository
state remains clean.  These checks distinguish maintained source from generated
navigation and rendered reference output rather than relying on ignore rules as
an undocumented convention.

See ADR-010 and ADR-017 for the generated-documentation ownership model.
