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

## Certbot 5.8 Renewal Directory Metadata

The selected Certbot provider supplies explicit private `--config-dir`,
`--work-dir`, and `--logs-dir` arguments.  Certbot 5.8 may persist
corresponding `config_dir`, `work_dir`, and `logs_dir` fields under
`[renewalparams]`.  ADR-051 permits only `finalize` to recognize them,
verify exact invocation-private workspace values, and omit them before
archiving.  Canonical `verify` and private `prepare` refuse those keys.
Mapping tests must check optional exact matches, mixed subsets, duplicate
and foreign path refusals, no input mutation on failure, and normal
reversible five-field path translation.  A mocked native renewal fixture
cannot replace independent full real Certbot/Pebble/SeaweedFS acceptance in
milestone 16 PR #260.

## Native Certbot Registration Contact Compatibility

Real Certbot 5.8 writes native registration state with an empty `regr.json`
body and the account URI, not necessarily a literal `mailto:` contact.
The standalone register mock must reproduce that storage shape while returning
a distinct `show_account` response for the exact selected CA. Test exact
single-email acceptance, missing and extra emails, a changed contact,
unavailable account query, and no-PutObject refusal, including reuse of a
previously archived account. Mocked output is not proof of real ACME
compatibility; milestone #16's isolated Pebble CI remains the independent
genuine Certbot/ACME gate. See ADR-050 and issue #261.

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

## Isolated negative local E2E coverage (milestone #16)

The approved local failure-isolation suite is
`bash tests/e2e-local/first-issue-host.bash run-faults`. It runs only
**after** an independent successful positive `run` has stored a genuine
Pebble-issued certificate in the disposable private SeaweedFS bucket.
Seven literal fail-closed cases exercise the unchanged checksum-verified public
producer at external-provider and archive boundaries, with an independent
current-object SHA-256 readback after every scenario. The suite requires no
real AWS credentials or public ACME provider. Mocked Route53 failure and
Pebble's challenge-validation bypass must **not** be represented as genuine
DNS-01 or AWS interoperability. See
[the local E2E harness guide](local-protocol-e2e-harness.md) for scenario
semantics, preconditions and their specific limitations.

Static Bats tests verify the fault-mode allowlist, hard-coded private
endpoints, real-CLI delegation except for explicit rejected PutObject, host
cleanup, and refusal cases. They are **not** a substitute for an engine-backed
negative run. A separate CI runtime gate remains task #247; the manually
authorized real-provider staging gate remains milestone #4.

## Certbot One-Element Challenge Tuple Compatibility

The native milestone-16 Pebble run on PR #260, using the merged ADR-051
adapter, reported a bounded `renewal-pref_challs` rejection after genuine
Certbot issuance. Public Certbot renewal-file examples document
`pref_challs = dns-01,` for one preferred DNS-01 challenge; the run did
not expose the actual value, so the trailing-comma explanation remains an
integration hypothesis until rerun. ADR-052 permits only the two exact
single-DNS-01 values for `pref_challs`. Tests require reversible
prepare/finalize, read-only verify, rejection of HTTP/multiple/malformed
challenges, unchanged bytes on failure, and no accidental widening of
`preferred_challenges`. The E2E test must still prove genuine ACME order,
publication, restore, negative isolation, and cleanup. This is not proof
of real Route53 propagation or AWS/Let's Encrypt interoperability.

## Bounded Renewal-Parser Diagnostics (Milestone 16)

A real Certbot 5.8 issuance can be rejected by the selected renewal
metadata adapter with the generic `unsupported renewal configuration` error.
The adapter now also emits a bounded, fixed-category
`renewal rejection category=...` diagnostic. Categories identify the
parser check (for example, `renewal-config_dir`,
`renewal-unknown-field`, or `canonical-path-cert`) without displaying
any field value, unknown field name, renewal line, account identifier,
or private filesystem path. Recognized field names come exclusively from
the adapter's literal allowlist; unknown field names receive one generic
category. This is **diagnostic evidence**, not permission to accept
previously unsupported metadata.

All refused metadata remains unchanged, and the existing generic error
and nonzero exit status remain authoritative. Tests check confidentiality
and byte preservation under rejected cases in all three shipped producer
flavors. A green mocked Bats run does not identify the actual reason
for the failed Pebble E2E invocation or establish real-provider compatibility.
The isolated real-protocol test must classify the generated renewal
configuration *without* exporting raw Certbot or archive contents and
still require every positive, negative, isolation, and cleanup acceptance
condition before merging the parent E2E PR.

## Critical DNS SAN Extension Compatibility

The real local Certbot/Pebble run reached genuine issuance, then failed
the SAN-reader predicate. A bounded diagnostic on attempt 2 of
[run 41775450237](https://github.com/wesley-dean/certbotbot/actions/runs/41775450237)
identified `san_header=critical`, without exposing actual SAN identities,
PEM data or OpenSSL output. ADR-053 permits only the exact OpenSSL
`X509v3 Subject Alternative Name: critical` header in addition to the
previously accepted noncritical spellings. Unsupported SAN types,
duplicate names, multiple lines, incorrect DNS identities and malformed
header attributes must continue to fail closed. This change does not
relax expiry, chain, key correspondence or archive publication checks.

Bats tests verify exact critical-header acceptance, and refusal of non-DNS
and repeated entries, identity drift and alternate header attributes,
across the three shipped producer flavors. Mocked tests do not establish
real protocol success. The full Pebble/SeaweedFS lifecycle, second genuine
ACME order, seven negative cases, isolation, and cleanup must pass on the
PR #260 integration branch after merge.

## Bounded Selected-Certificate Verification Diagnostics

When selected certificate material fails the prepublication verifier, a fixed
`certificate verification stage` diagnostic identifies one of three refused
predicates: `sans` (exact DNS SAN set), `expiry` (OpenSSL `-checkend 0`),
or `chain` (OpenSSL chain PEM parsing). The prior generic refusal and
exit status remain unchanged. No certificate bytes, private keys, SAN
identities, account data, pathnames, or OpenSSL output are emitted. These
categories are diagnostic only and never relax verification, expiry, or
chain acceptance requirements.

The real local Pebble/SeaweedFS E2E run must still establish which predicate
fails for its native Certbot certificate. Mocked Bats cases exercise the
three literal categories and ensure that private fixture content is not
emitted. A green mocked check does not constitute real-protocol acceptance.

## Mandatory local protocol E2E CI gate (milestone #16)

The separate workflow
[`Local protocol E2E (challenge validation bypassed)`](../.github/workflows/local-protocol-e2e.yml)
runs on push and manual dispatch, without cloud secrets or credentials.
Unlike the static Bats suite, it builds all checksum-verified producer
flavors, starts pinned Pebble and SeaweedFS images on a private Docker
network, and drives actual ACME registration, first issuance, independent
SeaweedFS readback, one independently verified native metadata-only stabilization,
three strictly nonpublishing fresh-runner no-ops, an intentional second real
ACME order/renewal, and independent replacement verification.

The workflow also requires **all seven** negative scenarios to preserve
the authoritative current object, and active non-egress and trusted
local-staging TLS probes both before and after lifecycle execution. The
single shell entry point is
`bash tests/e2e-local/ci-local-e2e.bash`. Dependencies and immutable
OCI images are fetched **before** private network startup; every failed
runtime scenario, skipped proof receipt, or incomplete project cleanup is
a failed gate. The script has bounded timeouts and prints only nonsecret
phase receipts; no private provider logs, certificates, account keys, or
S3 archives are uploaded.

This is challenge-validation-bypassed **Pebble** plus a bounded Route53
stub and **real SeaweedFS** protocol acceptance. It does not establish
actual Route53 DNS-01 challenge propagation, real Amazon S3 IAM, or
Let's Encrypt staging compatibility. The separately governed live
milestone #4 workflow remains necessary. See the
[local E2E harness and CI guide](local-protocol-e2e-harness.md) and
ADRs 046, 047, 048 and 049. A merged test workflow without at least one
successful engine-backed run must **not** be reported as validated E2E
behavior.




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


### Focused local protocol debugging (issue #275)

The required push-triggered `Local protocol E2E` workflow remains full and
unmodified: its default, argument-free runner proves all positive stages,
three artifact-flavor no-ops, seven negative cases, isolation, and cleanup.
For iterative debugging of the genuine second Pebble ACME order, invoke
`bash tests/e2e-local/ci-local-e2e.bash --debug-second-order` on a native
Linux Docker host (or through the separate manual debug workflow). This
**partial development** mode retains real initial registration/issuance,
independent first readback, native post-issuance stabilization with independent
readback, the second real ACME order and renewed certificate validation,
both active no-egress probes, and complete container teardown. It skips the
three unrelated stable-flavor no-ops, the final post-renewal no-op, and seven
unrelated negatives. A partial result never prints the required
`full_protocol_gate=passed` receipt and must never substitute for final-head
full acceptance. Per-stage elapsed seconds are bounded nonsecret diagnostics;
provider logs and account material stay private. This debug mode is not a
performance guarantee; the full CI gate still runs on every candidate push.

A named negative case may be isolated in partial mode using
`--debug-negative=NAME` with exactly one of `ca-production`,
`s3-unavailable`, `corrupt-archive`, `acme-order-rejected`,
`route53-unavailable`, `s3-put-reject`, or `acme-unavailable`.
This builds a genuine initial certificate fixture and verifies native
metadata stabilization before the selected rejection. The case still
performs an independent unchanged-object readback. The temporary Pebble
outage is unpaused under the existing cleanup trap. Full CI never accepts
a selective-case success as a replacement for its seven mandatory negatives.
