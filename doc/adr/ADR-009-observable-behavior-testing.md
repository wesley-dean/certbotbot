# ADR-009: Observable Behavior Testing Across Shipped Artifacts

Date: 2026-08-19

## Status

Accepted

## Context

A build pipeline that transforms maintained Bash through concatenation, comment
stripping, and minification can introduce defects even when the source itself is
correct.  Testing only source fragments therefore leaves the actual shipped
products partially unverified.

The existing Bash projects use Bats as a lightweight behavior-oriented test
framework and JUnit output for CI reporting.  The starter should make that
contract visible without filling the repository with large fixture suites before
a derived project has real behavior to test.

## Decision Drivers

- Verify what users actually execute.
- Keep tests small and focused while allowing the suite to grow by behavior.
- Validate transformations among development, stripped, and minified artifacts.
- Produce CI-readable test reports.
- Avoid coupling tests to internal function layout when public behavior is the
  relevant contract.

## Decision

Bats SHALL be the default behavior test framework and tests SHALL live under
`tests/`.

`make test` SHALL run the same behavior suite against all three generated
artifact flavors.  `make test-report` SHALL do the same while writing one JUnit
XML result file per artifact flavor under `test-results/`.

Starter tests SHALL cover help/version behavior, build metadata, plugin listing
and noop execution, invalid input, executable artifacts, checksum companions,
and independence from vendor state where practical.

Tests SHOULD be numerous enough to isolate behaviors but small enough that a
failure communicates one primary contract.  Derived projects should prefer
adding focused tests over expanding a small number of broad fixtures.

Release validation SHALL additionally run Bash syntax checks, verify checksums,
and execute representative behavior under the minimum supported Bash version.

## Operational Constraints

- Bats tests MUST live in `tests/`.
- `test` MUST exercise `.dev.bash`, `.bash`, and `.min.bash`.
- `test-report` MUST produce JUnit XML for every artifact flavor.
- Tests SHOULD be behavior-oriented and narrowly scoped.
- Release validation MUST verify the exact artifacts that will be published.
- Generated consumer artifacts MUST remain executable without `vendor/`.

## Considered Alternatives

Testing only maintained source was rejected because generated transformations are
part of the product.  A custom Bash test harness was rejected because Bats
provides readable assertions and standard reporting.  Large end-to-end fixtures
as the starter default were rejected because they would impose project-specific
complexity before a derived project has earned it.

## Consequences

Tests run multiple times, once for each representation, which increases CI time.
That cost directly validates the claim that artifact flavors are behaviorally
equivalent.

## Source Lineage

Bootstrap and adrctl provide the strongest examples of multi-artifact Bats
validation and JUnit reporting.  Prior project discussions also favored more
numerous, focused tests over a small number of oversized fixtures.

## Related Decisions

- ADR-002: Bash Runtime and Portability Baseline
- ADR-006: Three Release Artifact Flavors, Metadata, and Checksums
- ADR-011: Conventional-Commit Semantic Releases and Late Tagging
