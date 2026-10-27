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

### CI single-flavor test entry points

GitHub Actions matrix jobs can test one prebuilt producer executable without
rebuilding it. The `test-one` and `test-report-one` targets accept exactly
`TEST_FLAVOR=development`, `TEST_FLAVOR=ordinary`, or
`TEST_FLAVOR=minified`. They run the same complete Bats test-file inventory
as the existing all-flavor targets. For example:

```bash
make build
make test-one TEST_FLAVOR=development
make test-report-one TEST_FLAVOR=ordinary
```

The single-flavor targets require the selected executable in `dist/` to be
an executable regular file with valid Bash syntax and a matching, regular
`.sha256` companion containing the exact basename. They reject a missing
or empty test inventory, symlinks, stale `.256` companions and digest
mismatches **before invoking Bats**. No dependency bootstrap or
`make build` runs as a side effect; a caller must arrange and independently
verify a complete trusted cross-job handoff as governed by ADR-036. The selected
suite's Bats exit status remains authoritative.

`test-report-one` writes one report to
`test-results/bats-<flavor>.xml`. The legacy `make test` still
builds and tests all three producer flavors, while `make test-report`
continues to build and emit its historical `bats-development.xml`,
`bats-stripped.xml` and `bats-minified.xml` files. The current
single-flavor names use `ordinary` for the stripped representation;
the older local report name is retained for backward compatibility.
The standalone certificate client is not a fourth producer flavor.

Each complete producer test suite also invokes the **one verified shipped
client executable** using `BASH_STARTER_CLIENT_ARTIFACT`. The two client
Bats fixture suites copy the built binary into an isolated temporary
runtime path, create real gzip/tar archives and mock AWS reads. The client
is never rebuilt in a matrix test job; its SHA-256 and immutable handoff
manifest must match the exact tested bytes. Bash 4.3 compatibility checks
exercise the client's help, version and frozen-UTC filename renderer without
adding another producer matrix flavor. The standalone client is also tested
from a copied directory after `vendor/` has been removed.


## Milestone 4 public E2E inventory and evidence

`tests/milestone-4-public-e2e.bats` uses the shipped producer executable,
synthetic staging account and S3/Certbot mocks to verify selected first
issuance, clean-runner restore/no-op, simulated due renewal, exact stage order,
and failure preservation. These **fixture-only** observations do not prove
actual Let's Encrypt staging, Route53 or Amazon S3 interoperability.

`make verify-m4-e2e-inventory` checks that the suite is a regular,
non-symlink member of the full Bats inventory with at least one executable
test. All `make test`, `make test-report`, `test-one` and
`test-report-one` executions require that check; the PR Test and
Versioning preparation workflows also invoke it before handing artifacts
to the three independent Bats flavor jobs. It does not duplicate the suite,
download dependencies or use live credentials. A missing suite fails the
quality gate instead of silently reducing coverage.

See [milestone 4 release evidence](milestone-4-release-evidence.md) and
[public black-box E2E contract](milestone-4-public-black-box-e2e.md).
Live acceptance stays exclusively under the
[operator-controlled staging procedure](milestone-4-staging-acceptance.md).

## Real-GnuPG Shipped-Client Encryption Acceptance

The standalone certificate client has an independent
`tests/client-authenticated-shipped.bats` black-box suite. It copies the
already-built client and its conventional SHA-256 companion into a private
runtime directory, checks the digest and release provenance, and exercises
that **same executable** without repository `src/`, `lib/`, `vendor/` or
issuer files. The mock AWS CLI accepts only HeadObject and one GetObject for
one expected current bucket/key and rejects unexpected S3 operations; GnuPG
is **not mocked** for positive encryption cases. The GnuPG subprocess
wrapper forwards to the real executable but checks that the symmetric
key was not exported to helpers and that its value never appears in
command-line arguments or captured logs.

The test suite creates fresh AES-256/OCB encrypted archives with GnuPG's
producer-compatible SHA-512 iterated/salted S2K settings and verifies
account-only and multi-lineage restoration, byte-equivalent plaintext
contents, PEM links and restrictive file modes. Negative cases include
wrong/missing key, invalid mode, malformed/future envelope, tampered or
truncated ciphertext, trailing packet data, legacy CFB/MDC or unexpected
S2K, malicious authenticated tar contents, size/member limits, no
fallback reads, and no-clobber destination protections. Each failed
restore must leave no activated state or owned private staging, and
none of the private-key sentinels or passphrases may be emitted.

**A skipped cryptographic fixture is not proof that encryption works.**
On a runner without a real compatible GnuPG 2.4.7+ executable, Bats
reports an explicit `SKIP: ... NOT crypto evidence` rather than
substituting fake-crypto success. This is acceptable for the general
Bats matrices while test infrastructure is being prepared, but **not**
for encrypted-client release qualification. Task #188 must run a
separate required job with proven OCB capability and reject a skipped,
canceled, missing or failing crypto suite before tagging or publication.
These source and shipped-client tests do not replace the existing
three producer flavors, Bash 4.3 tests, eight-file provenance checks
or attestation gates.

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
