# ADR-033: Opt-In Dated Backup Publication After Current-State Success

Date: 2026-10-23

## Status

Accepted

## Decision

An explicitly enabled dated recovery copy will be published **after** successful
publication of the current authoritative archive. `DATED_BACKUP_ENABLED` (CLI
`--dated-backup-enabled`) is a literal Boolean, default `false`, resolved by
CLI > exported environment > literal `.env` > default. Naming follows ADR-032:
the same frozen UTC snapshot resolves the unchanged current key, default
`latest.tar.gz`, and distinct backup key, default
`archive-{YEAR}{MONTH}{DOM}.tar.gz`. For 2026-10-20 the backup name is
`archive-20261020.tar.gz`. Configuring a backup template does not enable backups.

This decision **narrowly supersedes ADR-028's prohibition of additional S3
objects**, only for opt-in backup publication after current-state success.
ADR-031's prohibition of an additional encrypted-mode object is similarly
narrowed: current object identity, encrypted transport format, and the original
migration safeguards remain unchanged. This design task #81 does not itself
implement a second write. The destructive retention policy is reserved for
task #84's independently reviewed Accepted ADR.

## Context, constraints, and assumptions

- ADR-020/021 mandate one existing S3 current object and fail-closed fetch;
  no restoration or fallback from an arbitrary dated key is automatic.
- ADR-027/028 validate the whole candidate before one current PutObject;
  a normal successful unchanged no-op skips publication unless
  `UPLOAD_NO_RENEWAL=true` or the approved encryption migration requires a write.
- ADR-030 requires preservation of the original ACME account and **every
  complete stored lineage**, not a selected-only export.
- ADR-031 requires locally verified authenticated GnuPG AES-256/OCB encryption
  for every published object when selected. Both current and dated copies must
  hold the **same exact encrypted candidate bytes**, with no implicit `.enc`
  key renaming. A new encrypted backup does not meet ADR-031's separate
  **pre-migration** recovery-copy prerequisite.
- ADR-032 establishes safe single-component names, frozen UTC context,
  literal mktext rendering, preserved legacy `S3_KEY`, and collision refusal.
- Only S3 plus gzip tar is implemented. Stories #63 and #65 remain open;
  the design does not presume SFTP, ZIP, bzip2, or generic backend support.
- Writers of the authoritative object remain externally serialized. S3 does
  not provide a two-object transaction, rollback, or automatic versioning.

## Publication sequence

1. Resolve literal nonsecret configuration and freeze the UTC date and
   **both** exact object identities before any remote operation. Reject
   invalid values, collisions, unsupported combinations and ambiguous names
   before any remote mutation.
2. Retrieve the mandatory current key, validate and restore the complete
   account/lineage archive, perform the successful selected-only Certbot
   operation and verify all stored state according to existing ADRs.
3. Apply the established no-op policy. If current publication is skipped,
   backup publication is also skipped; enabling backups is not an automatic
   daily snapshot schedule. An explicit `UPLOAD_NO_RENEWAL=true` can force
   a validated publication even if Certbot made no durable change.
4. For a required publication, package and validate the complete tar.gz **once**
   within the owned private workspace. When encrypted, wrap and locally
   authenticate/roundtrip-verify it **once**. Freeze the same validated
   plaintext/ciphertext payload and content type for both destinations.
5. When backups are enabled, perform an **exact-key** safety preflight
   before writing current: a missing backup key must be provably absent;
   an existing key must pass the v1 managed-object identity rules below.
   An unknown or conflicting object fails before either PutObject.
6. Write the protected authoritative current key **first** through the
   existing PutObject contract. If AWS rejects it or its response is lost,
   **do not attempt** the backup write. Current state remains uncertain
   on an ambiguous failed call, as before.
7. Only after a positive current PutObject response, conditionally publish
   **the exact same local candidate bytes** to the resolved backup key,
   then perform an exact-key HeadObject metadata/size verification.
8. Report full opt-in success only when both puts and backup confirmation
   succeed. A backup failure following accepted current publication
   returns **nonzero partial success** with accurate stage diagnostics.
   Do not attempt rollback, speculative deletion or current-key rewriting.

This order makes "backup published but current failed" unreachable within
one invocation. A failure in local Certbot, tar validation, GnuPG,
preflight, naming, or private staging prevents **both** remote writes.

## Same-day collision, ownership and conditional-write policy

The chosen same-day policy is **conditional replacement of a prior managed
backup belonging to the same current-key identity and UTC date**. An arbitrary
object sharing a date-shaped name must never be overwritten on its appearance
alone. In the initial S3 implementation, managed backup PutObject includes
the following nonsecret S3 user metadata:

| Metadata key | Exact meaning |
| --- | --- |
| `certbotbot-backup-schema` | Literal `v1` |
| `certbotbot-utc-date` | Frozen `YYYYMMDD` UTC date |
| `certbotbot-current-key-sha256` | Lowercase hex SHA-256 of the exact current key bytes |
| `certbotbot-archive-format` | Literal `tar.gz` for the supported payload interior |
| `certbotbot-encryption` | Literal `none` or `gpg-ocb` matching payload |

The current-key hash is a scope identifier, **not** a secret or a signed
ownership proof. A principal authorized to write arbitrary S3 metadata may
forge it. Restricting access to managed backup keys remains an operator
responsibility and an explicit residual threat.

Preflight only the exact selected backup key. On confirmed absence, use
`aws s3api put-object --if-none-match "*"`, so another writer cannot quietly
install a different object before creation. On existence, accept replacement
only when all managed metadata match schema, date, current-key identity,
archive format and encryption mode. Capture the existing ETag and use
`aws s3api put-object --if-match ETAG` for an atomic key-level precondition.
**ETag is a conditional identity token, not an SHA-256 checksum.**
A nonmatching ETag, ambiguous S3 error, unsupported conditional operation,
unrecognized historical metadata, inconsistent format/encryption or changed
template means failure; never fall back to unconditional overwrite.

The accepted backup PutObject uses `--checksum-algorithm SHA256`, matching
content type and user metadata. Afterwards an exact-key HeadObject must
confirm the required metadata and nonzero expected payload size. If it fails,
the backup is **unverified** and cannot authorize later retention. This is
not an independent full-download integrity proof, complete remote
durability proof, or cross-object atomic commit. S3 conditional headers
protect a single key at a time, and ETag plus metadata cannot authenticate
the archive body. No retry may turn a lost-response failure into an
unconditional overwrite. S3 Versioning, if independently enabled, may retain
previous same-day versions; certbotbot does not enable or manage it.

A changed template or explicit current key may create another current-key
identity or backup namespace. This design does not silently adopt, rename,
overwrite or enumerate former backup objects. Task #84 must define retention
eligibility independently before any deletion code is written.

## Reporting and failure semantics

| Situation | Current | Dated backup | Command result |
| --- | --- | --- | --- |
| Backup disabled; no-op | Skip | Skip | Existing successful no-op |
| Backup disabled; upload needed | Existing PutObject policy | Never | Existing outcome |
| Enabled; no-op without forced write | Skip | Skip | Success; no new backup |
| Unsafe candidate/key or definite unknown backup collision | No PutObject | No PutObject | Prepublication failure |
| Current PutObject fails or has lost response | Failed/uncertain | Not attempted | Nonzero current failure |
| Current accepted, backup PutObject fails/conflicts | Accepted | Failed/uncertain | Nonzero partial success |
| Current accepted, backup Put accepted but HeadObject fails | Accepted | Unverified | Nonzero partial success; no retention |
| Current accepted, backup Put and Head verified | Accepted | Confirmed within stated checks | Success |

Static, nonsecret diagnostics must distinguish a current transfer failure
from a partial success caused by the backup. Never echo raw AWS output,
candidate filenames from private staging, GnuPG secrets, certificate
contents, or credentials. The exact implementation return variable names
and stdout presentation belong to #82, but they must faithfully express
skipped/accepted/unverified outcomes; not claim a two-object transaction.

## Manual operator-directed recovery

A dated object is a candidate for **manual** recovery, not the next normal
restore target. The operator must identify and download the exact recovery key
into an independently owned, private workspace, retain the object as evidence,
authenticate/decrypt it where required, and validate its archive, ACME account
and every lineage **before** accepting it as recovery state. The operator must
separately back up newer current state, coordinate writers, and explicitly
authorize any later replacement of the current key. Do not recommend
invoking normal, **write-capable** certbotbot with a backup key as `--s3-key`
as a read-only recovery command; that could overwrite the backup itself.
No automatic restoration, rollback, backup key auto-discovery, scheduler,
plaintext fallback, account creation, IAM provisioning or key recovery is
part of this story.

## Rejected alternatives and consequences

**Unconditional overwrite of same-day key:** rejected: a matching basename
might contain unrelated data. Exact managed metadata and S3 conditional
writes reduce accidental replacement without pretending metadata is signed.

**Reject every second run on one date:** rejected: later successful renewal
would be unable to update the same day's recovery point. The consequence of
conditional replacement is possible loss of earlier same-day state unless
the operator configured S3 Versioning.

**Timestamp/random suffix for every run:** rejected: the product's
documented date-only default and retention identity would change.

**Publish backup before current:** rejected: it could advertise future
state when current publication subsequently fails.

**Always back up successful unchanged no-ops:** rejected: would silently
introduce automatic snapshot behavior; the existing forced republish
option remains explicit.

**Copy current S3 object into backup:** rejected: a copy could race with
an external writer and need not match the locally validated payload.
Reuse the original private candidate instead.

**Implicitly switch current to a backup after failure:** rejected:
unverified remote state and unrelated historical certificates could be
activated by inference.

**Use ETag as an archive integrity digest:** rejected. ETag does not
generally equal the content SHA-256; the tool uses its existing
local validation, S3 SHA256 transfer checksum, and separate post-write
metadata confirmation.

**Implement SFTP, ZIP, retention or general backup discovery here:**
rejected as outside the two-object S3/tar.gz publication scope; future
adapters must prove equivalent naming and guarded writes or fail explicitly.

## Threats, compatibility, verification and limitations

The new trusted authority is additional exact-key S3 HEAD/conditional PUT,
not global bucket listing or deletion. Threats include unsafe filename
interpretation, unknown same-day object overwrite, leakage of plaintext
while encryption is enabled, state truncation, remote write uncertainty,
stale rollback and misleading full-success reporting. Mitigations are
ADR-032 preflight, complete state candidate validation, one payload reused
for both PUTs, authenticated encryption, guarded exact-key object identity,
stage-specific errors and explicit operator recovery steps.

Pinning libraries and verifying local data do not protect compromised AWS
executables, stolen credentials, forged user metadata, wrong runner UTC date,
uncoordinated writers, or remote state changes after HeadObject.
This is **not** a two-object transaction or automatic cloud durability proof.

Task #82 must implement this design with actual supported AWS CLI conditional
calls. Task #83 must verify both ordinary and encrypted publication, repeated
UTC date, rollover, forced/no-op policy, clean-runner operator recovery,
rejected unrelated keys, ambiguous failures, all three public executable
flavors, Bash 4.3 and appropriate real-GnuPG tests. Mocked tests must not
be represented as live S3/ACME validation. Task #84 then governs any
future managed-backup deletion separately.

## Related decisions and references

- ADR-020/021, ADR-027/028: seeded S3 current object and verified publisher;
  only ADR-028's *no second key* prohibition is narrowed for opt-in backups.
- ADR-030: complete multi-lineage state.
- ADR-031: full GnuPG envelope; narrowed only for additional encrypted copies.
- ADR-032: validated current/backup keys and UTC filename templates.
- ADR-005/015/016/019: dependency, trust, threat and approval governance.
- Story #67, design #81, implementation #82, verification #83;
  retention story #68 and tasks #84–#86.
- AWS S3 conditional PutObject and ETag behavior:
  https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html
- AWS S3 conditional requests and their limitations:
  https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-requests.html
