# ADR-035: Three-Runner Continuity for State-Only Renewal Metadata

Date: 2026-10-16

## Status

Accepted

## Decision

Extend the controlled, credential-free Certbot 5.8.0 integration exercise
authorized by ADR-033 and ADR-034 to a **three-workspace sequence** that
verifies the persistence and portability of renewal metadata updated
without certificate issuance.

- Runner A constructs locally issued, short-lived test CA material,
  a 90-day leaf/chain and complete lineage, and a synthetic common
  account; both archives are created using the project's portable
  split-state formats.
- Runner B validates and stages those archives using the shipped
  standalone artifact, creates a validated private renewal-path preview,
  and, inside the disposable test fixture only, allows real Certbot to
  inspect the relocated lineage and make a no-renewal-due decision.  Its
  blocked ARI lookup may record an `ari_retry_after` scheduling value.
- Runner B repackages the accepted local lineage, including the validated
  ARI metadata, into a new domain archive.  Runner B's workspace is
  destroyed before the next run.
- Runner C independently restores the common account archive from A
  and the updated domain archive from B into a **third unrelated absolute
  config root**, validates selected ACME/account identity and its new
  path preview, then reads the lineage with actual Certbot and makes a
  second no-renewal-due decision with the network guard in place.

The test MUST verify that the ARI scheduling value after the rebase is
identical to the value saved by B, and that certificate, private-key,
and common account-key bytes retain their original fingerprints.
A blocked ARI DNS lookup remains tolerated under ADR-034; actual socket
connections or unrecognized APIs remain forbidden in this synthetic
test.  Both predecessor workspaces must be absent before C's
Certbot invocation.  All three standalone artifact flavors must
exercise this sequence.

**No product behavior or publication policy is activated.**  The private
renewal-file import remains test-only, and no S3, DNS, ACME registration,
or actual certificate issuance may occur in this test.

## Context and requirements

The primary product requirement is that independent Jenkins, GitHub
Actions, and EC2 invocations can operate serially against portable
object-store checkpoints, without depending on a predecessor's
filesystem.  Real Certbot 5.8.0 tests in ADR-034 demonstrated an
important trap: its no-op renewal can issue an ARI DNS lookup and
append an `[acme_renewal_info]` / `ari_retry_after` section even
when no certificate is reissued.

The prior test verified only that an updated lineage could be locally
repackaged.  The third workspace verifies that this new archive remains
acceptable to the existing strict staged-restoration and account/path
identity validators and that Certbot can subsequently load and make
another decision using the retained ARI metadata.

## Assumptions

- Certbot 5.8.0 is installed in an isolated CI Python environment.
- The locally signed certificates and JSON account triplet are synthetic
  and cannot establish remote registration.
- Each workspace is private, disposable, and exclusive to the test.
- GNU tar, GNU coreutils, OpenSSL, and the released Bash artifacts have
  the behavior supported by the project's existing test matrix.
- No real AWS, Route53, ACME, or production credentials are configured.
- The test-level Python socket guard is not an operating-system network
  sandbox; this limitation from ADR-034 remains in force.

## Alternatives considered

Stopping after verifying tar member contents was rejected because that
would not exercise a new runner's archive validation or Certbot parsing
of the retained ARI metadata.  Reusing runner B's workspace was
rejected because it would not demonstrate stateless restoration.
Turning this into a live ACME staging issuance test was deferred
because it requires scoped DNS credentials, actual account state,
real registration/renewal, controlled side effects, and stronger
operational isolation.  Implementing S3 publishing in this change was
rejected because multi-object publication, failure handling, and
state-only write policy are still unresolved.

## Promises

- The third runner begins without filesystem state from A or B.
- The selected common and updated domain archives are independently
  validated by the existing production-oriented staging helpers.
- The ARI scheduling state is preserved through archive repackaging,
  restore, and a second path rebase.
- The same synthetic account key and certificate/key bytes persist.
- Real Certbot 5.8.0 can inspect the third reconstructed lineage and
  make a no-renewal-needed decision without successfully reaching ACME.
- All artifacts are disposed; the public issuer still fails closed.

## Non-promises

This test does not establish that Certbot's synthetic account JSON is a
valid registration, that renewed certificates can actually be obtained,
that SAN changes work, or that an S3 publisher safely persists
state-only updates across distributed runners.  It also does not
demonstrate Jenkins/Azure/EC2 runtime parity, distributed locking,
safe revocation, or complete network isolation.  The mock fixtures
test on one CI host with distinct private filesystem roots.

## Security and failure behavior

Any ARI field that violates the accepted renewal grammar or changes
account identity must be rejected by the existing restore/identity
guards.  If C cannot restore, if either predecessor remains available,
if the account/key fingerprints differ, if previously recorded ARI
metadata is lost, or if real Certbot attempts actual renewal or socket
connections outside the narrowly tolerated guarded DNS lookup, the
new integration job fails.  Failure must not trigger a fallback ACME
account registration or S3 write.

## Compatibility and follow-up

The test builds on existing code, archive formats, and workflow.
No public CLI interface, runtime dependency, release gate, consumer
archive structure, or backend implementation is changed.
It follows existing release/artifact CI requirements.

A future ADR must decide whether and how the producer persists ARI-only
state modifications to object storage.  That decision must reconcile
ADR-022's failure-safe publication model with same-lineage versioning,
retries, and externally serialized writers, without overwriting the
last known good archives in an ambiguous partial-write state.
Actual Let's Encrypt staging account registration, due renewal, SAN
changes, and S3 persistence remain required before live issuance.

## Related decisions

ADR-019 governs independent common/domain archives; ADR-022 governs
publication consistency; ADR-025 governs portable renewal;
ADR-027 and ADR-028 govern safe isolated restoration; ADR-030
and ADR-031 govern ACME authority and account identity;
ADR-032 restricts relocation to an internal preview, and ADR-033
and ADR-034 permit disposable real-Certbot inspection and no-op tests.
