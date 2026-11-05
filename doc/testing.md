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

## Bulk archived-lineage acceptance (milestone 15, task #100)

The opt-in `RENEW_ALL` implementation is governed by
[ADR-058](adr/ADR-058-opt-in-archived-lineage-bulk-renewal.md)
and [the bulk renewal contract](renew-all-contract.md).

The `tests/bulk-renewal.bats` suite covers initial implementation-level
routing, exact-name checks, invalid inputs, and changed/no-op publication.
`tests/bulk-renewal-acceptance.bats` independently exercises the *shipped
public producer executable*, not sourced implementation functions, in the
complete Bats matrix of **development**, **ordinary**, and **minified** flavors.
It uses the synthetic first-party AWS/Certbot process doubles, actual
locally generated X.509 certificates, GNU tar/gzip, and fresh private
runner directories.

The acceptance coverage includes:

- Two independent archived lineages (including overlapping SAN sets),
  exact once-per-name enumeration, default selected-only isolation, and
  independently selected issuance exercised by the initial suite.
- Mixed due/no-op outcomes, actual leaf replacement for one lineage,
  unchanged other-lineage certificate/private-key metadata, account
  identity continuity, metadata-only durable changes, and one complete
  current-key publication.
- A later named Certbot failure after an earlier successful local
  renewal, malicious cross-lineage mutation, missing triplets, invalid
  unselected X.509 material, duplicate archive members, invalid account
  material, and remote PutObject uncertainty.
- Separate invocation-owned runner directories for seeding, changing,
  and subsequently checking the durable archive, with no remaining
  ephemeral state and no new account registration or extra publication.
- Boolean/config precedence and an optional GnuPG 2.4.7+ authenticated
  encryption check; `--no-env` and default-false behavior remain covered
  by `tests/bulk-renewal.bats`.

Each failed local run must be nonzero with no `PutObject`, while any
uncertain remote `PutObject` remains a nonzero failure without a
rollback claim. These tests never contact real Route53, AWS, or ACME
servers. Local challenge-bypassed Pebble/SeaweedFS evidence and live
staging verification are **different** acceptance boundaries; a green
mocked test is not proof of DNS propagation, external account access,
or consumer certificate deployment.

The normal CI test-file wildcard includes the acceptance suite without
a new trigger or extra matrix workflow. `make test-one` requires the
exact generated producer and checksum sidecar, and the regular CI
build/handoff verifies artifact provenance, release flavors, and
minimum Bash 4.3 compatibility.

## Destructive orphan reconciliation acceptance (milestone 15, task #97)

`REMOVE_ORPHANS` is an explicit destructive opt-in governed by
[ADR-059](adr/ADR-059-explicit-desired-lineage-orphan-removal.md) and
[the desired-lineage contract](orphan-removal-contract.md). The
implementation-level tests in `tests/orphan-prune.bats` cover basic
false/true paths, input validation, and safe no-op publication. The
separate `tests/orphan-prune-acceptance.bats` adds independent
black-box public-executable verification.

The existing verified-artifact CI matrix executes both files for the
development, ordinary, and minified producer flavors, including
checksums and Bash 4.3 compatibility. Tests use synthetic AWS and
Certbot process doubles, real OpenSSL-generated certificates and
keys, and GNU tar/gzip:

- Default false preserves unrelated lineages. Explicit true with a
  complete desired set prunes only validated excluded lineages,
  including when retained certificates have overlapping SANs or
  the desired name ordering differs from archive member ordering.
- A selected issuance/renewal and deliberate prune can share one
  complete published archive. Surviving unrelated certificate keys,
  history, symlinks and renewal metadata, as well as original account
  material and private-key permissions, are compared before/after.
- A separate fresh runner restores the resulting archive, verifies
  both surviving names and confirmed absence of pruned members, and
  leaves no invocation-owned filesystem residue.
- Missing/invalid/duplicate desired names, unresolved nonselected
  members, conflicting bulk flags, unsafe symlinks and invalid
  certificates must be refused without deleting an invalid lineage
  or publishing partial state.
- Failed selected issuance/renewal, non-target provider mutation
  and failed candidate packaging cannot trigger an intentional S3
  write. Simulated S3 response loss deliberately shows that remote
  publication can have occurred despite a nonzero local status.
- CLI/environment/literal-file collection precedence, `--no-env`,
  encrypted archives (where GnuPG supports authenticated OCB),
  unchanged-republication policy and log privacy are also covered
  across the targeted and earlier lifecycle test suites.

These tests do **not** establish live Route53 DNS/IAM, real S3 behavior,
real Let's Encrypt staging ACME compatibility, certificate revocation,
erasure from historical backups/S3 versions, or distributed locking.
The operator must serialize writers and plan recovery separately;
milestone #4 owns the live staging evidence.

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

## Explicit synthetic Route53 zone selection (issue #252)

The local Route53 bridge requires an explicit synthetic hosted zone selector.
The sealed Compose profile supplies `LOCAL_E2E_ROUTE53_HOSTED_ZONE_ID` with the
fixed local fixture; `LOCAL_E2E_ROUTE53_HOSTED_ZONE_NAME` allows alternative
name-only selection for this *same* fixture. The ID takes precedence when both
are given, and malformed, missing, foreign or unknown selectors fail before the
provider listener starts. Offline Python tests cover normalization, precedence,
synthetic `ListHostedZonesByName`, multi-value TXT compatibility and refusals.
They do not replace the complete real Pebble/SeaweedFS CI gate or prove live
Route53/DNS-01 interoperability. See ADR-055 and the local harness guide.

## Provider extra-argument and no-env regression coverage (milestone #17)

`tests/provider-extra-args.bats` exercises both shipped producer CLI
paths and their shared configuration parser: JSON-array decoding,
whole-collection CLI precedence, empty override, repeated approved
flags, lossless space/quote handling for permitted user-agent comments,
provider-specific allowlists, suppressed invalid input,
mocked AWS, GnuPG and Certbot argument forwarding, skipped malformed `.env` under
`--no-env`, explicit `--config` conflict, disabled environment-only
GPG secret, and unaffected external AWS authentication environment.

The narrow extra-provider options cannot alter CA selection, restored
lineage identity, S3 conditional publication, authenticated GPG packet
requirements or the read-only standalone client. The existing full
three-flavor Bats matrix and isolated Pebble/SeaweedFS lifecycle
remain required. A local mock cannot prove live provider compatibility.
See ADR-056 and the public configuration reference.

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


### Per-negative timing and isolated parallelism assessment (issue #276)

The full, push-triggered Pebble/SeaweedFS local E2E gate retains **serial**
execution of all seven negative cases. Each case now provides one bounded
`negative_timing` observation **only after** expected provider refusal and
independent unchanged-object readback have passed. The host-side CI runner
requires exactly one valid receipt per case, clamps the printed duration to
the existing 2100-second stage bound, and emits only the known scenario name
and elapsed seconds. The aggregate `seven-negatives` timer remains intact;
an elapsed time alone never establishes provider or remote-state acceptance.

The known positive lifecycle, three stable no-ops, genuine second Pebble
order, seven negatives, private recovery and final no-egress remain mandatory.
Focused negative debugging emits a single case's timing under the existing
`partial-development` marker, never a `full_protocol_gate=passed` receipt.

Successful [run 41875100822](https://github.com/wesley-dean/certbotbot/actions/runs/41875100822)
observed 128 seconds for the full seven-negative stage, 171 seconds for
initial positive lifecycle, and 24 seconds for private project startup.
A hypothetical fan-out requiring serial preparation of new full
fixtures **after** the positive lifecycle would add more setup time
than the entire existing negative stage. This is a cost model, **not** evidence of an implemented parallel run
or a measured speedup. See ADR-057 and the
[negative E2E benchmark](e2e-negative-parallelism-benchmark.md) for
observations, limitations and conditions for reconsideration.

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
