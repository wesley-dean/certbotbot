# ADR-048: Read-Only Remote Latest-State Drift Preflight

Date: 2026-10-16

## Status

Accepted

## Decision

Add a **read-only remote-state precondition** to compare every selected
common and domain `*-latest.tar.gz[.enc]` S3 object against the exact
previous-state checkpoint already validated under ADR-043 and
represented by the local ADR-046 publication manifest.

The new `certbotbot_publication_precondition_check` function requires
a complete ADR-042 proposed collection, a completed ADR-043 previous
checkpoint, and a verified ADR-046 plan. It accepts **no caller-supplied
bucket or object keys**: the bucket, ACME environment, selected archive
format, and common-first key order are taken exclusively from the
existing prepared candidate and revalidated before network access.

The helper first calls the plan's local verification function so
neither the proposed nor the previous bytes may have changed
since preparation. It then derives canonical selected domain names
from the approved S3 key grammar. A new
`certbotbot_s3_stage_collection` invocation reads the entire selected
collection from the original bucket using the existing ADR-039 typed
GetObject classifier and encryption-mode rules.

Every newly downloaded **raw object body** is hashed and its size
compared with the exact as-downloaded bytes recorded in the
previous-state checkpoint. A previously absent object must still
be confirmed absent. A previously present object must still exist
with the same bytes. Changes in content or size, new objects,
removed objects, changed common account content, or a mixed-format
plaintext/encrypted collection cause rejection with status 65.

A wholly absent collection is accepted as an unchanged observation
*only when every object was confirmed absent in the original
checkpoint*. A missing common object together with a present
domain object is always inconsistent. S3 `AccessDenied`, transport
errors, lost responses, or otherwise ambiguous reads are fatal
and must never be recast as absence or an unchanged first run.

The helper removes the new remote read stage on success or failure.
It does not modify the originally owned publication candidate,
checkpoint, manifest, active Certbot config, or AWS state. It does
not invoke Certbot, DNS plugins, or any upload operation. No new
environment variable or public CLI command enables these reads
automatically.

## Problem being addressed

After ADR-047, the producer has the ability to persist exact
previous bytes into a recoverable generation. However, a runner
may have read the previous latest objects hours earlier.
Meanwhile, a Jenkins job, a GitHub Actions job, or an EC2 process
could have published another generation. A valid backup of
*the old state that this runner saw* does not establish that the
same objects are still current.

ADR-022 explicitly says different runners have no supported
distributed lock and require operator-managed serialization in
version 1. A new read-only comparison creates a useful abort
boundary for stale workers and accidental overlapping runs
without confusing observation with remote synchronization.

## Important assumptions and non-promises

- This is a **best-effort freshness observation**, not a compare-and-
  swap, fence, distributed lock, lease, or atomic multi-object read.
  Another writer can modify state immediately after or during this
  check. Passing it must **not** be the sole authorization for a
  later unconditional S3 latest-key write.
- The fresh reads are sequential. S3 cannot guarantee that several
  distinct object keys were read in one atomic snapshot. A
  cross-object mixed generation remains possible even when each
  read is individually successful.
- The first version still requires **external serialization** of all
  writers sharing an account namespace. A real lock is a separate
  architecture decision requiring fencing/expiry semantics.
- IAM and S3-compatible service behavior must distinguish exact
  `NoSuchKey` from denied or unknown errors as required by ADR-039.
  Unsupported conditional operations must never be guessed from
  successful reads.
- Only selected common and domain object keys are checked. This
  does not enumerate unrelated lineages or detect concurrent
  changes to keys outside the requested collection.
- The selected archive format is determined by the existing
  encrypted/plaintext mode. The function does not fall back from
  encrypted to plaintext archives or vice versa.
- All archive content, account identity, SAN, and certificate trust
  checks remain owned by the earlier ADR-042/043 boundaries. This
  helper compares byte identity to an already validated checkpoint.
- A same-user process with permission to modify the local
  checkpoint and its recorded digests remains outside the stated
  filesystem threat boundary.
- A completed recovery generation may still require manual review
  if the current latest collection has drifted; the recovery
  mechanism must not automatically overwrite newer state.

## Alternatives considered

**Assume the original checkpoint remains current** was rejected
because independent jobs can take long enough for remote state
to change.

**Accept a 404 after an earlier positive GetObject as a first run**
was rejected because a removed object is a detectable conflict.

**Compare only common account state** was rejected because an
individual domain lineage may change while the shared account
archive stays byte-identical.

**Compare only sizes or object ETags** was rejected because sizes
do not prove byte identity and multipart or server-specific ETags
do not universally mean a SHA-256 of the object body.

**Fetch a single object per requested name without using the
existing typed S3 reader** was rejected because that would
duplicate the dangerous missing/denied and mixed-cipher-mode
classification rules.

**Treat the precondition as a distributed CAS or publication lock**
was rejected because a read followed by an unrelated write has a
time-of-check/time-of-use race and cannot fence another runner.
A later publication ADR must specify conditional write operations,
external serialization, partial-write recovery, and the exact
representation of the expected prior state.

## Consequences and verification

The helper returns zero only when the selected remote collection
matches the previous validated checkpoint or its confirmed absences.
It returns 65 on stale or mixed state, 69 on denied/unknown S3
reads, and 64 on unsafe local prerequisites or changed authority.
Status 73 represents private cleanup failures.

The all-artifact Bats suite must cover a byte-identical previous
collection, wholly absent first-run collection, a new common
and domain, an added domain under a stable common, changed
common and domain contents, deleted domains, missing common
with remaining domain state, complete removal of previously
present objects, wrong-mode keys, denied reads, mismatched
ACME environment, changed local candidate bytes, and cleanup.
The test's AWS mock must refuse all mutations.

This module does not expand the public API, open the product
issuance gate, authorize active Certbot account import, or enable
latest-object publication. A subsequent accepted remote publication
decision must use **atomic conditional writes or an equivalent
guarded protocol**, together with documented operator serialization
and recovery across partial failures. ADR-037's genuine staging
ACME evidence and active import restriction remain unchanged.

## Related decisions

ADR-019 portable state identity; ADR-021/041 GPG mode;
ADR-022 serialization and publication; ADR-030 staging isolation;
ADR-037/038 trusted account and renewal state;
ADR-039/040 typed read and state assessment;
ADR-042 cryptographic replacement preparation;
ADR-043 previous-state checkpoint;
ADR-046 local publication/recovery plan;
ADR-047 durable recovery generations.
