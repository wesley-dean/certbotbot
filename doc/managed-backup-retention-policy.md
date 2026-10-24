# Managed Dated-Backup Retention Policy

**Status:** Scoped S3/tar.gz retention implemented by technical task #85,
governed by [ADR-034](adr/ADR-034-scoped-conditional-managed-backup-retention.md).
Full destructive-failure verification remains tracked under task #86.
Alternate storage backends and archive formats are not implemented. This document
defines intended behavior, not claims of a passing executable feature.

## Configuration and opt-in

The new `BACKUP_RETENTION_COUNT` setting, CLI
`--backup-retention-count`, will follow CLI > exported environment >
literal `.env` > default. Unset or `0` disables all listing and deletion.
Canonical ASCII decimal `1`–`10000` means retain the newest N eligible
dated backup objects. Invalid, signed, fractional, empty, negative,
nondecimal, zero-padded or over-limit values fail before remote work.

A positive count requires `DATED_BACKUP_ENABLED=true` and a supported
S3/gzip-tar backend. Enabling dated backup publication alone does not
enable retention. Retention runs only after a **new** authoritative
current publication and its corresponding dated backup publication both
succeed and pass ADR-033 verification. A normal no-op, a lost PutObject
response or an unverified backup never authorizes deletion.

## Safe namespace and ownership

The default backup template
`archive-{YEAR}{MONTH}{DOM}.tar.gz` is eligible. For retention, accept
exactly one contiguous `{YEAR}{MONTH}{DOM}` marker preceded by a static
prefix of at least four bytes ending in `-` or `_` and followed by a
safe, literal `.tar.gz`-ending suffix. Other valid publication templates
may be used with retention disabled, but are not silently adopted for
deletion. A positive count with an ineligible template is a configuration
error.

List only the exact bucket and anchored static prefix using fully
validated ListObjectsV2 pagination. A candidate key must match the
**complete** selected template with one valid, nonfuture UTC YYYYMMDD
date. HeadObject must verify all five ADR-033 managed metadata fields:
schema v1, date, current-key SHA-256, tar.gz format, and matching
`none` or `gpg-ocb` mode; require positive size and an ETag.
An unrelated key not matching the complete date-shaped name is ignored.
A date-shaped key with missing, ambiguous or inconsistent metadata
**aborts the whole operation with zero deletes**. Never infer
ownership from a filename or metadata alone; operator IAM controls
are essential.

The default `latest.tar.gz`, or any explicitly selected canonical
current key, is always protected. Changing the template, current key,
archive format or encryption mode starts a new retention scope.
Former backups, unknown prefixes, migration recovery copies and
historical S3 object versions are not automatically adopted or removed.

## Ordering and deletion

Eligible objects sort by exact name-encoded UTC YYYYMMDD descending.
S3 LastModified and listing order do not define age. At most one key
per date may be eligible; repeated keys and ambiguous date identities
abort. Keep newest N keys, including the freshly verified backup.
A count at or above the number of eligible keys means zero deletes.

After a complete listing and all candidate HEAD checks have succeeded,
delete the older eligible keys one by one with an **exact-key,
ETag-conditional** S3 DeleteObject using `--if-match ETAG`.
Never use bulk DeleteObjects, wildcard match, unconditional deletion,
bucket lifecycle rules or permanent version-specific deletion.
Any failed/uncertain response or changed precondition stops all
further deletes. Previously successful deletes are not rolled back,
and current and newly published backup state remain unchanged.

## Observable outcome

| Situation | Required result |
| --- | --- |
| Count absent or 0 | No list, no delete; ordinary publication semantics |
| Positive count but disabled backup/unsupported template or backend | Configuration failure before mutation |
| Normal no-op or current/backup publication failure | No retention listing or deletion |
| Listing truncated/incomplete, malformed, denied or ambiguous | Zero deletions and nonzero partial-success reporting after publication |
| Any matching object missing/corrupt metadata or uncertain HEAD | Zero deletions |
| Fully verified list with at most N eligible backups | Success, zero deletes |
| More than N eligible backups, all conditional deletes verified | Only newest N remain visible; report success |
| A delete fails or has lost response | Stop immediately, nonzero partial success, no rollback |

The status must accurately distinguish accepted current, confirmed backup
and incomplete/uncertain cleanup. No user-controlled key, private path,
AWS raw stderr, credentials or GnuPG secret may be included in diagnostics.

## Backend boundary and verification

The initial policy is limited to S3 general-purpose buckets with
ListObjectsV2, HeadObject and ETag-conditional DeleteObject. It requires
scoped `s3:ListBucket`, `s3:GetObject` and `s3:DeleteObject`; the operator
should deny deletion of the authoritative current key and prefer
bucket-policy enforcement of conditional deletes. S3 Versioning can
retain historical versions under a delete marker, so retention is a
count of *visible eligible keys*, not guaranteed reclaimed bytes.

Future backend story #63 and archive-format story #65 must explicitly
satisfy equivalent scoped capability and content contracts. Unsupported
combinations with positive retention cannot silently skip deletion.
See [ADR-034](adr/ADR-034-scoped-conditional-managed-backup-retention.md)
for the threat model, alternatives and residual limitations.

## Implementation and verification boundary

The public CLI exposes `--backup-retention-count N` (or
`BACKUP_RETENTION_COUNT` in the environment or literal `.env`). With N=0,
ordinary publication does not issue any retention ListObjectsV2 or
DeleteObject operation. With N greater than zero, the public status line
adds `retention=completed; deleted=<confirmed_count>` or
`retention=skipped; deleted=0` for an unchanged no-op. Failures after
both publications return nonzero with a fixed `current accepted; backup
confirmed; retention ...` diagnostic and never roll back the current key.

The first-party S3 planner uses AWS CLI v2 `--no-paginate` and a fixed
JMESPath scalar projection to read one complete ListObjectsV2 page at a
time, with URL-encoded object keys, a precisely bounded literal prefix,
response-schema validation, continuation-token cycle detection and a
100,000-object/1,000-page safety limit. A key requiring percent decoding
is refused rather than silently normalized, so an unusual unrelated key
within the narrow prefix can deliberately block cleanup. This is an
intentional fail-closed restriction, not a general-purpose bucket scanner.
A complete exact-key metadata HEAD and ETag verification pass precedes
every conditional delete.

The retention module is assembled into the same three standalone artifacts.
No new executable or runtime library dependency is introduced beyond the
existing trusted AWS CLI and GNU system utilities. `tests/retention.bats`
checks the disabled default, invalid counts, retention-only template rules,
complete preflight before deletion, and fixed nonsecret error handling.
Task #86's [retention safety verification guide](retention-safety-verification.md)
traces adversarial pagination, ambiguous inventory, conditional-failure and
protected-set scenarios, without claiming live-cloud guarantees. Mocked acceptance does not
prove AWS IAM permissions, remote durability or cross-writer transactions.
