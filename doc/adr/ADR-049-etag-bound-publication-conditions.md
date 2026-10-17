# ADR-049: ETag-Bound Publication Preconditions

Date: 2026-10-16

## Status

Accepted

## Decision

Add a complete, **read-only** capture of object-level conditional-write
predicates for the exact S3 latest keys selected by a validated
publication plan. The capture is neither a public command nor permission
to issue certificates or upload the proposed collection.

For each selected key, the implementation first verifies the local
ADR-042/043/046 proposed and prior bytes, then requires a successful
ADR-048 fresh remote drift precondition. A previously confirmed missing
key receives an explicit `absent` predicate, intended to become
`If-None-Match: *` in a **future** governed writer. No missing state
may be inferred from `AccessDenied`, missing credentials, an unknown
response, or a failed HEAD.

For each previously present key, the module obtains S3's current
opaque ETag via `HeadObject`. It then performs `GetObject` with
`If-Match` set to **that exact quoted ETag**, downloads the raw body
into a fresh private file, and independently compares both its
byte length and SHA-256 with the original ADR-043 checkpoint.
An ETag on its own is **not** accepted as evidence that it identifies
the expected archive bytes; it is an S3 compare-and-swap predicate,
not a portable cryptographic checksum.

The capture publishes its parallel common-first key, predicate-type,
and ETag arrays, together with the reviewed plan digest, **only after
all selected keys succeed**. It discards all temporary download bytes
on both success and error. If a later selected domain fails, neither
a partial array nor a successful common-only predicate is exposed.
The caller must explicitly discard a successful capture.

There is **no `PutObject`, `DeleteObject`, `CopyObject`, Certbot,
DNS update, or active configuration mutation** in this implementation.
The public certbotbot issuer continues to return status 69.

## Context and constraints

ADR-022 requires safe publication across several non-atomic S3
objects while continuing to rely on externally serialized writers.
ADR-047 creates durable verified previous generations. ADR-048
detects remote drift, but its read-then-future-write boundary can
race a different runner. A future conditional writer needs the S3
server's own object-level predicate bound to the bytes whose
recovery has been prepared, not an inferred ETag from a checksum.

S3 `PutObject` supports `If-Match` with an existing opaque ETag
and `If-None-Match: *` to require nonexistence. A failed
precondition returns an error such as 412; a conflict may return
409. The conditional operation MUST be in the **actual PUT**:
a preceding read followed by an unconditional PUT is prohibited.
The official AWS S3 User Guide documents these operations:
<https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html>.
The AWS CLI exposes the corresponding `s3api put-object`
options: <https://docs.aws.amazon.com/cli/latest/reference/s3api/put-object.html>.

S3 ETags may differ from ordinary content hashes (for example,
multipart uploads and encryption behavior); they are treated as
opaque strings and passed through only after bounded validation.
No MD5 or SHA-256 is manufactured as an ETag. A new
`HeadObject` response can be inconsistent with a concurrent
writer's next operation; binding it to an `If-Match` GET and the
checkpoint SHA-256 makes such changes detectably fail for this
specific object at the instant of that conditional GET. It does
**not** create a multi-key atomic snapshot.

## Alternatives considered

**Use the previous archive SHA-256 as `If-Match`** was rejected
because S3 ETags are not generally the SHA-256 of the body.

**Read only current ETags without checking body bytes** was
rejected because the plan may describe a different previous
collection that happens to be associated with an accepted
or stale server token.

**GetObject followed by an unrelated HeadObject** was rejected
because the newer HEAD result might refer to bytes that the
reader never validated. Conditional GET must bind the retrieval
to the HEAD token.

**Use an unconditional PUT after the ADR-048 drift precondition**
was rejected as a classic time-of-check/time-of-use overwrite race.

**Implement full multi-object publication in this step** was
rejected because safe partial-write recovery still requires a
separately reviewed conditional rollback protocol and genuine
backend compatibility tests. An atomic per-object conditional PUT
does not turn several latest keys into one atomic transaction.

**Treat this token capture as a distributed lock or lease** was
rejected: another writer can change the remote object after capture,
and there is no fencing or cross-runner ownership claim.

## Results and explicit non-promises

The arrays describe **proposed conditional request arguments** only.
They may immediately become stale and must never authorize an
unconditional write or assume a whole-collection transaction.
A future coordinator must revalidate the plan, ensure a durable
ADR-047 backup generation, use conditional PUTs with the exact
captured server token on each key, verify completed object bytes,
record ambiguous outcomes, and support controlled recovery from
a fresh runner after partial failure or crash.

An existing-key conflict or a missing-key collision must be reported
as failure without changing the expected token or silently retrying
with the new conflicting object's ETag. Operator-managed external
serialization remains mandatory in the first release.

The all-artifact Bats suite must cover an unchanged existing
collection, wholly absent first-run collection, an existing common
account with a missing requested lineage, failed/malformed HEAD,
conditional GET rejection, changed remote bytes after HEAD, corrupt
conditional download, complete staging cleanup, and **zero AWS
writes**. This milestone does not grant active Certbot state import
under ADR-037 or demonstrate real staging account continuity.

## Relationships

ADR-019 governs the portable archive collection; ADR-022 governs
serialization and publication; ADR-037 maintains the active Certbot
gate; ADR-039 classifies remote reads; ADR-042/043 validate new and
previous bytes; ADR-046 owns the local plan; ADR-047 provides durable
recovery generations; ADR-048 provides the initial remote drift check.
