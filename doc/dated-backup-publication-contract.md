# Dated Backup Publication Contract

Status: Implemented S3/tar.gz opt-in dated publication under ADR-033.
Technical task #82 introduces the public option and guarded S3 writes;
#83 provides the broader failure/recovery and release-artifact evidence.
Retention and deletion are not implemented here and remain governed
by ADR-034 and tasks #85/#86.

## Operator settings and identity

`DATED_BACKUP_ENABLED=false` by default (CLI
`--dated-backup-enabled true|false`; CLI > exported environment > literal
`.env`). The name template does not opt into publishing by itself. The current
S3 object remains authoritative, default `latest.tar.gz`, and dated
publication uses the independently configured `BACKUP_KEY_TEMPLATE`,
default `archive-{YEAR}{MONTH}{DOM}.tar.gz`. For the frozen UTC date
2026-10-20, the recovery-copy key is `archive-20261020.tar.gz`.

The keys must be distinct after resolution and provider identity checks.
A rename or date change never silently migrates current state. Only the
implemented S3/tar.gz combination is currently eligible.

## Workflow and status guarantees

When current publishing is required by a durable change, forced republish,
or approved encryption migration, construct and fully validate one complete
archive candidate with the original account and all stored lineages.
Wrap/authenticate it once when encryption is enabled. Preflight the exact
backup destination safely, publish the authoritative current key first,
and after a positive result upload those **same payload bytes** to the
backup key. A skipped no-op performs no backup publication.

An absent backup key requires a conditional PutObject with
`--if-none-match "*"`. An existing key may be conditionally replaced on
the **same frozen UTC date** only after confirming the exact expected v1
managed backup metadata, bound current-key SHA-256, tar.gz interior format
and encryption mode. Capture its ETag and use `--if-match ETAG`; never
unconditionally overwrite an unknown object. An accepted backup PUT
requires an exact-key HeadObject metadata/size confirmation. This is not
an independent payload download or distributed transaction.

| Result | Current key | Backup key | Public outcome |
| --- | --- | --- | --- |
| Disabled | Existing behavior | Not touched | Existing contract |
| Enabled, ordinary no-op | Not touched | Not touched | Success, no new backup |
| Invalid candidate or unsafe destination | Not touched | Not touched | Fail before mutation |
| Failed/uncertain current PutObject | Uncertain | Not touched | Current publication failure |
| Accepted current, failed/unknown backup Put or Head | Accepted | Failed/uncertain | Nonzero partial success |
| Both accepted and backup confirmed | Accepted | Confirmed by defined checks | Success; eligible for separately approved retention |

No failure results in automatic rollback, deletion or switching the next
invocation to a backup key. A failed current write **cannot** be followed
by an attempted backup write.

## Exact status and verification limits

When backups are disabled, the public success line retains its original
`published=true|false` shape. When enabled, the success line also includes
`backup=confirmed` following a validated two-object write or
`backup=skipped` for an unchanged no-op. A failed current write never
attempts the dated PUT. A failed/uncertain dated PUT or unverified HEAD
returns nonzero with a fixed `current accepted` partial-success diagnostic;
no automatic rollback occurs.

The implementation uses the AWS CLI's generated input skeleton to verify
support for both conditional PUT arguments before writing the current key.
For an existing managed same-day object, the HEAD metadata must match
schema, date, exact-current-key SHA-256, format and encryption mode, with a
valid ETag; that ETag conditions replacement. For an absent object, the PUT
uses If-None-Match. A positive backup PUT is confirmed through exact-key
HEAD metadata and byte length, **not** a full payload re-download or a
cross-key transaction.

## Recovery boundary

Operator recovery means selecting and downloading an exact dated key to a
separate private workspace, preserving it, decrypting/authenticating when
needed, validating all Certbot state, and expressly coordinating any
replacement of the current archive. Normal certbotbot is write-capable:
passing the historical backup key as `--s3-key` is **not a safe
read-only recovery operation**. The operator still needs the encryption
secret and an independent pre-migration backup as applicable.

## Dependencies and security limits

Task #82 implements the public setting, exact-key S3 preflight and
conditional publication with post-PUT metadata/length confirmation.
Task #83's [recovery and verification guide](dated-backup-recovery-verification.md)
defines the operator-directed read-only workflow and the mocked cross-feature
test matrix for all three standalone artifacts, with real GnuPG when available.
Other
backends and formats (#63, #65) remain unsupported until separately
implemented. Backup retirement and any deletion require #84's
Accepted destructive-operation ADR and #85/#86 testing. S3 Versioning
is optional; same-day replacement can discard earlier recovery bytes.
