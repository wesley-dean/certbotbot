# ADR-050: Guarded Conditional Latest Publication and Fresh-Runner Recovery

Date: 2026-10-16

## Status

Accepted

## Decision

Implement one cohesive, **internal** S3 latest-object publication and recovery
protocol. A publication requires a complete, cryptographically verified
ADR-042 proposed object collection, ADR-043 exact previous-state checkpoint,
ADR-046 local plan, ADR-047 durable previous generation, ADR-048 fresh remote
drift check, and ADR-049 ETag-bound conditional predicates. The producer's
public certificate issuance and renewal entrypoint is still disabled and
this internal coordinator cannot activate Certbot.

A caller must set the explicit internal `CERTBOTBOT_LATEST_WRITE_CONFIRM=yes`
and `CERTBOTBOT_RECOVERY_WRITE_CONFIRM=yes` approvals. It must separately
retain and acknowledge the completed recovery generation ID and exact manifest
SHA-256 using `CERTBOTBOT_LATEST_RECOVERY_ACK=<generation>:<sha256>`
**before** the first alias mutation. That recovery token must be stored in
trusted operational records that remain accessible after losing the entire
runner, not solely in memory or on local storage. If this precondition is
not met, the implementation must fail before any latest-key mutation.

The writer revalidates local candidate/checkpoint/plan inputs and re-verifies
the durable prior generation from S3. It refuses any incomplete or mismatched
conditional-token list. It then conditionally uploads the entire selected
replacement, **common account first** followed by selected domain archives,
using S3 `PutObject --if-match <actual-opaque-ETag>` for previously existing
keys and `--if-none-match '*'` for keys explicitly confirmed absent.
It MUST NOT fall back to the existing unconditional S3 adapter put operation.
After each successful server response it reads the object again and verifies
the exact proposed SHA-256 and byte count. Any denied, ambiguous, timed-out,
conflicting, unsupported conditional write, or changed readback aborts further
publication. The result is recorded as `partial` from the moment writes
begin and `complete` only once every selected object has been verified.

**There is no automatic rollback after an ambiguous publication failure.**
A successful S3 write can be followed by a lost response, and another writer
could have changed a key while the producer was failing. The durable recovery
generation is retained. An operator must investigate and deliberately invoke
the separately guarded recovery path from an independent environment.

The recovery entrypoint
`certbotbot_latest_recover BUCKET ENVIRONMENT GENERATION EXPECTED_SHA256`
requires `CERTBOTBOT_LATEST_ROLLBACK_CONFIRM=yes`, explicit trusted
out-of-band recovery identity, and an empty private workspace. It first
calls ADR-047's verifier to authenticate the completed, durable previous
generation, then downloads and checks its manifest by the expected hash.

**Before changing any object**, recovery reads every selected latest key
using exact NoSuchKey classification, an opaque ETag, and an ETag-conditioned
body GET. Each current object must unambiguously equal either its manifest's
previous bytes or the fully verified proposed new bytes. If any selected
object is unrelated to both, or any previously present old key is missing,
recovery aborts the *entire attempt* without modifying other keys.

Already-restored keys are skipped. For an object still containing the proposed
new bytes, recovery re-checks its current ETag and exact content, then:
- For a previously existing key, reads the identical saved prior body from
  the immutable generation and restores it with an S3 `PutObject --if-match`
  condition on the verified *current new* ETag.
- For a previously absent key, removes the newly created object using
  `DeleteObject --if-match` with that exact new ETag. No unconditional delete
  or empty-object placeholder is an acceptable substitute.

The rollback happens **in reverse order**, restoring domain objects before
the shared common account. Every rollback mutation is followed by a new
remote observation proving the requested prior bytes or actual absence.
Partial rollback failure is explicitly reported; a fresh invocation can
resume by skipping already restored keys and reconsidering any remaining new
keys. A conflict caused by another writer is never silently overwritten.

The recovery generation is not deleted after publication or rollback.
Retention, manual investigation, and removal are operator-governed.

## Context and compatibility

ADR-019 defines the portable common/domain latest aliases that consumers
already understand. ADR-022 documents that S3 does not offer atomic
multi-object transactions and requires serialization across Jenkins,
GitHub Actions, EC2, and other independent writers. ADR-047 provides a
remote backup that persists after a worker disappears; ADR-049 provides
verified S3 object-level conditional write tokens.

The complete protocol closes the previously missing **internal guarded
multi-object write and independent-runner rollback capability** without
altering consumer keys, extending plugins, installing a GitHub workflow,
enabling real ACME issuance, or claiming impossible transactionality.

The first release still requires **operator-managed external writer
serialization** for a selected account/archive namespace, including any
rollback operation. Conditional writes prevent blindly replacing an
object that has changed since the captured ETag, but do not atomically
commit several keys. Mixed old/new state may be observable during a
multi-object update or after a crash. Consumers have no magic
transactional snapshot across common and domain keys.

## Trust, assumptions, and operational responsibilities

- A trusted operator is responsible for persisting a completed generation
  identifier plus manifest digest **before** initiating publication. If the
  generation is not discoverable after a crash, this milestone cannot
  guarantee unattended recovery. It requires an explicit acknowledgement;
  it does not itself implement an off-host audit database or message bus.
- Recovery permissions include `s3:GetObject`, conditional
  `s3:PutObject`, and `s3:DeleteObject` for selected latest keys. The
  latter is needed to restore genuinely absent first-run objects.
  Restrict delete authority to these known latest prefixes and keep
  recovery-generation deletion unauthorized.
- The backend must support AWS S3 compatible conditional PutObject
  with `If-Match` and `If-None-Match`, conditional GetObject, and
  conditional DeleteObject with an ETag, and must preserve the expected
  read-after-write visibility. Unsupported S3-compatible deployments
  **fail closed**. Real backend integration remains a release gate.
- S3 ETags are opaque concurrency predicates, not cryptographic hashes.
  Exact body identity is established with SHA-256 and byte length.
- Some S3 versioning and Object Lock configurations may retain older
  versions or forbid a conditional delete. An API rejection prevents
  completion and requires operator review, never an unconditional retry.
- S3 error codes 409/412, timeouts, or a lost success response require
  re-observation and explicit recovery instead of automatically
  overwriting with a newly acquired ETag.
- The authority selector and proposed encryption format remain fixed.
  A remote `NoSuchKey` does not, on its own, authorize ACME account
  registration or inference of a new installation.
- Concurrent or malicious writers sharing the same filesystem user,
  bucket ownership, or S3 credentials can still bypass this module.
  IAM/bucket policies should deny unconditional writes and deletes
  to the protected latest namespace where supported.
- Tests use real locally signed TLS fixtures but synthetic ACME account
  metadata. They prove state transitions in mock S3, not real CA
  continuity or compatibility with every S3-compatible backend.

## Alternatives considered

**Unconditional latest writes after a fresh preflight** were rejected.
The interval between GET and PUT is a time-of-check/time-of-use race.

**Automatic rollback on any failed PUT** was rejected. A remote response
may be lost after the service successfully commits, and concurrent
object changes can make a blind reversal destructive.

**Delete the entire latest namespace after failure** was rejected.
Some objects were present before publication, some were correctly
absent, and unrelated object keys may belong to other lineages.

**Use a mutable remote pointer/manifest as a new consumer interface**
was deferred because current consumers require stable common and
domain latest aliases. Introducing a new pointer schema changes
consumer interoperability and requires a separate decision.

**Commit every latest alias in one transaction** is not supported by
S3. Object-level conditional operations cannot give atomic multi-key
visibility, even with serialized writers.

**Restore previous objects without checking current proposed bytes**
was rejected because it could destroy a newer or unrelated
publication. Whole-collection preflight plus each mutation's
conditional ETag is mandatory.

**Derive the recovery token solely from the current runner's private
files** was rejected. An independent runner needs a trusted off-runner
reference after the original process crashes.

**Enable the issuer during this milestone** was rejected under
ADR-037. Genuine staging account registration, real no-op renewal,
changed-SAN issuance, and two real lineages must be demonstrated,
reviewed, and separately authorized.

## Failure semantics and test requirements

The normal Bats matrix across all three standalone artifacts must
simulate conditional write success, failure before writing a later
domain, a lost response after a domain write, rejection of a
third-party modification, and first-run rollback to *true absence*
using conditional deletes. It must prove original old bytes are
restored from a new private workspace after all earlier local
candidate/plan/checkpoint files have been deleted.

The AWS mock must reject unconditional PUT/DELETE operations.
Every retained remote recovery generation must be write-once and
readback-verified under ADR-047. The tests must verify that
forward publication is not reachable from the normal executable
entrypoint, which still returns status 69.

This protocol remains internal and explicitly operator-authorized.
Real S3-compatible backend end-to-end tests, crash injection across
independent processes, least-privilege IAM review, external runner
serialization procedures, and the ADR-037 live Let's Encrypt
staging account-continuity evidence are required before enabling
normal unattended certificate issuance and remote publication.

## Related decisions

ADR-019 split portable archives; ADR-020 S3 adapter boundary;
ADR-022 execution serialization and failure-safe publication;
ADR-037 active Certbot import gate; ADR-039 typed missing-state
classification; ADR-042 validated proposed collection;
ADR-043 recoverable previous-state snapshots; ADR-046 local plan;
ADR-047 remotely durable generations; ADR-048 latest-state drift
preflight; ADR-049 ETag-bound conditional tokens.
