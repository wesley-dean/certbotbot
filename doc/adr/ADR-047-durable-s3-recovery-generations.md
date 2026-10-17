# ADR-047: Write-Once, Remotely Verifiable S3 Recovery Generations

Date: 2026-10-16

## Status

Accepted

## Decision

Authorize a narrowly scoped, **internal recovery-only remote write**
that durably preserves the *previous* object bytes already validated in
ADR-043 and described by the completed ADR-046 local publication plan.
This milestone does **not** authorize modifying any common or per-lineage
`*-latest` object, activating Certbot, requesting an ACME certificate,
or publishing newly issued certificate state.

The producer must receive explicit `CERTBOTBOT_RECOVERY_WRITE_CONFIRM=yes`
and a completed, unchanged ADR-042 candidate, ADR-043 previous-state
checkpoint, and ADR-046 plan before beginning. It does not treat a
missing object or an unverified return value as publication permission.
All remote writes target a reserved, generation-scoped namespace:

```text
recovery/v1/<32-hex-generation>/<index>.prior
recovery/v1/<32-hex-generation>/manifest.tsv
```

For staging, the whole namespace is prefixed `staging/`. The
generation is generated from 128 bits of operating-system randomness,
not from a lineage name, timestamp, process ID, or user-supplied token.
Only indices 0 through 32 and `manifest.tsv` are accepted as
recovery-object paths. These names never overlap the stable
`common-latest.tar.gz[.enc]` or domain latest keys.

The module records a possibly incomplete generation identifier as
soon as it is chosen, for operator inspection of abandoned objects.
It creates each present old object using S3 `PutObject` with
`If-None-Match: *`, which must refuse overwriting a current object
at the same generation key. No fallback to unconditional PutObject
is permitted. Any service-side conflict, denied call, transport
error, unsupported API, or lost response is a failure. Failed
attempts are **not** interpreted as proof of object absence.

After each conditional PUT, the module performs GetObject back to
a separate private, owner-only file and verifies its exact SHA-256
against the already captured prior object. A missing old object
has no `<index>.prior` body; its confirmed absence is represented
only in the checked manifest.

**The manifest is written last**, after the old objects are uploaded
and checked. The manifest contains the complete ordered latest-key
plan, old-object presence, old/new digests, byte counts, selected
bucket, and ACME environment. It is also written conditionally and
read back to verify the expected checksum. The producer then checks
the whole generation through the independent verifier before
exposing `CERTBOTBOT_RECOVERY_GENERATION` and
`CERTBOTBOT_RECOVERY_MANIFEST_SHA256` as a completed result.

A fresh runner can call
`certbotbot_recovery_verify BUCKET ENVIRONMENT GENERATION EXPECTED_SHA256`
using only new AWS credentials, a private workspace, and a **trusted
out-of-band manifest checksum** from the completing producer. It
downloads the generation's manifest, verifies its expected digest,
strictly parses the fixed-size record grammar, and verifies every
present old object by reading it from S3 and hashing its bytes.
No predecessor filesystem, candidate, checkpoint, or active Certbot
configuration is required. The verifier never uploads.

This is a deliberately non-publishing interim boundary. The public
issuer continues to return status 69 and there is no code path from
the normal command to these internal remote-write functions.

## Context and design pressures

ADR-019 separates a shared ACME account archive from independently
consumable domain archives. ADR-022 requires a recoverable last-known
good state before risking partial multi-object publication.
ADR-043 supplies exact previous bytes and confirms missing selected
objects, but admits that a local checkpoint is lost if the worker
crashes. ADR-046 combines those snapshots into an inspectable plan
that binds the expected old/new states and their digests.

The missing capability is a **durable, independently retrievable**
representation of the prior state. That prerequisite can be tested
without implementing the unsafe final alias update or prematurely
approving real ACME account restoration.

## Trust model and important limitations

- Operators must serialize independent writers to the same selected
  account/key collection, including Jenkins, GitHub Actions, and
  EC2. There is no distributed lease or fencing token.
- The selected bucket has adequate space and permissions to retain
  prior account and TLS private keys. A plaintext configuration
  retains plaintext archives in its recovery objects; enabling
  GPG retains the exact previous ciphertext without re-encryption.
- A successful recovery generation is *available* remotely, but not
  an immutable WORM archive against privileged operators who can
  delete or replace it. Object Lock, versioning, retention policy,
  and cross-account controls are operational hardening choices,
  not falsely implied by `If-None-Match`.
- The checksum used by the fresh verifier must come from a trusted
  separate source. A remote manifest and remote data altered
  together are not authenticated by a checksum fetched from that
  same compromised remote location.
- A generation does not serialize concurrent updates, create an
  atomic transaction spanning latest keys, or show that the latest
  collection is unchanged since the initial ADR-043 read.
- S3-compatible endpoints must support conditional PutObject with
  `If-None-Match: *`. Unsupported conditional writes are fatal;
  weakening that condition to improve compatibility is prohibited
  without a new decision and threat review.
- AWS credentials must be confined to the required bucket and
  recovery prefix. Temporary AWS errors and GetObject errors
  remain fatal, with no missing-state inference.
- The reference AWS CLI can handle `--if-none-match '*'` for
  `s3api put-object`. The source is the AWS S3 conditional write
  documentation and AWS CLI command reference.
- The downloaded bytes and temporary manifests are owner-private
  local files; same-user process compromise, memory inspection,
  snapshots, and storage administrator privileges remain outside
  this module's protection.
- Garbage collection is intentionally deferred. Orphaned
  generation objects resulting from an interrupted attempt are
  not automatically deleted, because a broad or wrongly scoped
  delete could destroy evidence or someone else's recovery data.

## Publication and recovery state semantics

**Absent prior collection:** The previous-state checkpoint supplies
zero presence flags; the persisted generation consists of a complete
manifest with explicit absent entries and no prior-object bodies.
This is not proof that ACME registration is allowed or that another
runner did not concurrently publish new state.

**Partially failed generation creation:** No successful result is
returned. Some reserved keys may have been written, possibly even
the manifest if the service response was lost after accepting it.
The incomplete identifier remains available to operators for
audit; the writer must not assume it is safe to reuse, overwrite,
or delete that generation. A consumer must require a trusted
expected checksum and successful full verification before using
any generation as a rollback source.

**Completed generation:** The uploader has validated every previous
object and performed full manifest readback and verification. It
returns an opaque generation ID and matching checksum. This is a
durable recovery *input*, not an instruction to restore it or
a guarantee that production latest aliases are now safe to mutate.

## Alternatives considered

**Keep only local recovery files** was rejected because independent
runners cannot recover after a worker crash.

**Enable bucket versioning and rely solely on VersionId values**
was deferred: ordinary S3-compatible backends may not have
versioning enabled or stable version semantics. It may later become
an additional protection, but does not replace the explicit
cross-platform recovery contract.

**Use raw CopyObject from latest to recovery keys** was rejected for
this milestone because the source might change between local
validation and copying, and conditional copy support differs across
S3-compatible servers. Uploading the exact frozen, validated
bytes avoids introducing a different source snapshot.

**Allow unconditional PUTs to a unique path** was rejected because
random collision, accidental retry, or another writer could
silently destroy a prior backup at that key.

**Upload new candidate bytes as latest immediately afterward** was
rejected: backup durability alone is insufficient to decide
whether current latest state still matches the original read,
how mixed generations are detected, and what to do after a
partial write or crash. That future coordinator requires a
separate Accepted ADR.

**Delete or overwrite incomplete remote generations** was rejected
as a default recovery action, because deletion is destructive
and may race other operators. Operator-audited cleanup may be
specified separately.

**Use remote manifest SHA-256 as its own trust anchor** was rejected
because tampered metadata and bodies could otherwise corroborate
each other falsely.

## Consequences, tests, and acceptance

The normal three-flavor Bats matrix must test mock S3 write-once
conditional creation, exact bytes, unchanged latest aliases,
common-first index ordering, manifest-last publication, confirmed
first-run absence, denial of a prior-object PUT, denial of the
manifest PUT, a corrupted readback, and absence of a committed
result after failure. It must also create a new private workspace
after deleting the producer workspace and prove an independent
verification using only the generation and expected checksum.

The suite must confirm that missing explicit authorization prevents
even attempting S3 operations. Neither real ACME, Route53, nor
uncontrolled AWS accounts are accessed by normal CI. Manual real
S3/MinIO integration tests and crash injection remain necessary
before remote alias mutation is connected.

The next publication ADR must define (a) optimistic/current-state
matching before latest-key writes, (b) ordering and post-write
verification, (c) idempotent retries after lost service responses,
(d) partial and crashed-writer recovery from a fresh worker,
(e) handling of formerly absent objects, and (f) the operator
serialization and rollback permissions model. This ADR does
not satisfy those future requirements by itself.

ADR-037 still blocks product active Certbot state import until
reviewed real Let's Encrypt staging account continuity has been
demonstrated and a separate activation decision is accepted.

## Related decisions

ADR-019 split-state archive contract; ADR-021/041 encryption;
ADR-022 execution serialization and publication; ADR-030 staging
isolation; ADR-037 active account boundary; ADR-039 typed reads;
ADR-042 complete proposed-state verification; ADR-043 exact prior
snapshot; ADR-046 local manifest and checkpoint; ADR-045 inactive
multi-lineage assembly.
