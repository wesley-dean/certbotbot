# Retention Destructive-Safety Verification

**Status:** Technical task #86 verification contract for Accepted ADR-034 and
the existing S3/tar.gz implementation in task #85. The tests cover the
public standalone executables through Bats using a synthetic S3 command,
not a real AWS account. The associated PR's final checks, review and
merge govern acceptance. This document does not authorize new deletion
behavior or a live-cloud destructive test.

## Safety objective

The current archive is mandatory and always protected. A distinct dated
backup is published and verified first; retention is a **separate** opt-in,
using `BACKUP_RETENTION_COUNT`, and is disabled when the count is zero.
No cleanup is permitted on an ordinary no-op, an unconfirmed or failed
current/backup publication, an unsafe template, a missing AWS conditional
feature, or any incomplete remote identity proof.

After a successful two-object publication, the retention planner must
read and validate **every page** in the narrowly selected S3 prefix,
match exact Gregorian YYYYMMDD names, HEAD every date-shaped candidate
for managed v1 metadata, record a valid ETag and positively identify the
newly confirmed backup. Only then may older verified backups beyond
newest N be conditionally deleted. The freshly published recovery object,
the authoritative current key, other naming formats, previous templates,
and unrelated or uncertain objects must never be deleted.

## Executable evidence

`tests/retention-safety.bats` provides a separate adversarial S3 fixture.
It sources the assembled current artifact in a fresh Bash process, calls
the exact documented retention planner, and exposes an AWS mock that
records each ListObjectsV2, HeadObject, DeleteObject and HeadBucket
request. The mock enforces an exact bucket, literal scope, ETag equality,
and a private disk-backed inventory. It never calls AWS or Certbot.

| Category | What the tests prove |
| --- | --- |
| Complete two-page inventory | Pages are requested with continuation tokens; every matching object is HEAD-validated before the first delete |
| Positive count | Exactly newest N remain visible, including today's confirmed backup; oldest eligible objects are removed first |
| Zero or excess candidates | No deletion if configured N is at least the count of eligible objects |
| Changed namespace | The new bounded template is used; an older template's objects remain untouched |
| Unrelated object | A prefix-sharing but nonmatching name neither consumes retention slots nor becomes a delete target |
| Pagination failures | Denied or malformed list, inconsistent key count, duplicate key, unsafe/escaped key, missing or repeated tokens, denied later page, mismatched prefix, oversized count: no deletes |
| Date restrictions | An impossible Gregorian date or future date-shaped candidate blocks all deletes |
| Newest candidate | Missing fresh backup or mismatched fresh ETag blocks every delete |
| Managed identity | Foreign schema, different current-key SHA-256, different payload format/encryption mode, zero object size and unsafe ETag all block deletion |
| Preflight HEAD | Any candidate HEAD denial prevents every deletion, even after other HEADs succeeded |
| Publication state | Missing current success, failed backup or unconfirmed backup prevent even the retention listing |
| Conditional delete failure | Changed ETag (precondition conflict), lost response, continued object visibility, or denied confirmation stops further deletion |
| Partial cleanup | One confirmed old deletion followed by another failed delete returns nonzero, leaves newer backups intact and reports the partial count; no rollback is attempted |

Each test also checks that no cloud operation unexpectedly targets the
synthetic protected current archive. The tests use explicit fake
`archive-YYYYMMDD.tar.gz` object names, do not rely on S3 LastModified,
and do not inject arbitrary code or private data into the application.
The existing `tests/retention.bats` covers public configuration,
default-off behavior, unsupported template shapes, and the basic
three-candidate success path. The existing full lifecycle tests cover
current/backup PUT ordering and failure isolation.

The Makefile's `make test-report` runs every Bats test against **all three
standalone artifacts** (development, ordinary and minified). CI adds
an early TAP step for these retention tests to make the exact failing
assertion visible before the longer matrix. Bash 4.3, static analysis,
build/checksum reproducibility, and encrypted archive interoperability
remain independent required CI gates. Successful single-artifact TAP
alone is not full acceptance.

## Operator guidance and stop conditions

Operators should distinguish **published current**, **confirmed dated
backup**, and **completed retention**. The third is only possible when
the first two are already confirmed. The final stdout field
`retention=completed; deleted=N` reports positively confirmed deletes;
an error after published current/backup is nonzero partial success.
A failed or uncertain delete must not be retried blindly with a
different ETag, because concurrent writers or unknown remote outcomes
may have changed the selected object.

When cleanup fails, stop, preserve the current archive and newest
confirmed dated backup, and perform a read-only inspection using
qualified operator credentials. Capture the failed stage, review
actual S3 metadata, pagination, IAM boundaries and ETag independently,
then decide how to proceed. Do not automatically delete the remaining
keys or perform a second write merely to "fix" an uncertain prior
response. The separately documented
[dated backup recovery procedure](dated-backup-recovery-verification.md)
describes read-only recovery into an inactive private workspace.

Both S3 Versioning and IAM policy remain operator-controlled. A
conditional delete of the visible key may create a delete marker rather
than physically remove old versions. Only S3 general-purpose bucket
behavior is in scope; live permission enforcement, real concurrent
writers, server durability, version-history costs, cloud conditional
semantics and alternative backends require separately authorized
integration work. Neither object metadata nor an ETag is a proof of
cryptographic ownership. A mock passing does **not** establish a
two-object transaction.

## Traceability

- ADR-034: retention count, protected namespace, complete list/HEAD
  preflight, deterministic date ordering, and conditional deletion.
- ADR-033: a verified dated backup is prerequisite to retention.
- ADR-032: frozen UTC date and strict filename rendering.
- ADR-031: encryption boundaries and independent migration backups.
- #68: configurable managed-backup retention story.
- #84: architecture and security design.
- #85: scoped retention implementation.
- #86: negative/positive destructive-safety verification.
- Story #63 and #65: future alternate storage and archive formats,
  currently unsupported.
