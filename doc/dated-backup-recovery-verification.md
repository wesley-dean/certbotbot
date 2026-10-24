# Dated Backup Recovery and Failure Verification

**Status:** Mocked public-CLI acceptance tests and operator recovery procedure for
approved technical task #83, under story #67 and Accepted ADR-033. This document
does not introduce a write-capable recovery command or guarantee a remote S3
transaction. Final acceptance depends on the CI results for the reviewed PR head.

## Current behavior and limits

The authoritative S3 key, default `latest.tar.gz`, is the **only** key that
normal certbotbot retrieves as current state. The optional setting
`DATED_BACKUP_ENABLED=true` publishes one additional dated object only after a
validated current object was successfully published. The default name
`archive-{YEAR}{MONTH}{DOM}.tar.gz` uses one frozen UTC calendar date per
invocation. Backup creation is skipped on an ordinary no-op unless a
publication is explicitly forced through `UPLOAD_NO_RENEWAL=true`.

Both objects receive the **identical validated complete archive bytes**.
The dated object is a recovery candidate, not automatically trusted or selected.
A second invocation on the same UTC day may conditionally replace the
existing same-scope, same-date backup after validating all managed v1 metadata.
S3 does not guarantee the earlier same-day version survives unless the
operator separately enables and controls versioning.

The current implementation supports S3 general-purpose object operations
and the gzip-compressed tar format. Names ending in `.zip` or `.tar.bz2`,
alternate storage options, and untrusted current/backup name collisions are
not silently converted or treated as supported. The accepted ADRs for storage
and archive formats must govern future backends before interoperability can
be claimed. Retention/delete behavior is separately governed by ADR-034 and
tasks #85/#86 and is **not** part of task #83.

## Operator-directed, read-only recovery

Recovery starts with a **chosen exact backup key**. Do not use the backup key
as `certbotbot --s3-key` for "inspection": the public command can write the
selected key and overwrite its recovery evidence. Do not assume that the
presence of a plausible object name, ETag or user metadata authenticates its
archive content. Keep all writers of the current key externally coordinated.

1. Record the bucket, exact dated key, relevant UTC date, expected selected
   lineage, archive mode (`none` or `gpg-ocb`), current-key identity and managed
   metadata separately. Preserve a copy of the **existing** authoritative
   current object before contemplating replacement. Preserve any independent
   pre-encryption-migration recovery evidence required under ADR-031.
2. Allocate a new owned, private mode-0700 workspace on the recovery machine.
   Use IAM credentials restricted to the necessary read operations and
   download the exact dated object as **untrusted bytes**. Do not upload to S3,
   run Certbot/Route53 or extract directly into `/etc/letsencrypt`.
3. Validate the original downloaded payload **before extraction** using the
   same trusted, version-matched archive validation rules. For an encrypted
   object, require the supported `CERTBOTBOT-GPG-OCB-V1` envelope, correct
   GnuPG secret and successful authenticated decryption before inspecting
   the plaintext tar. There is no insecure plaintext fallback.
4. Restore only into another inactive private workspace. Verify the original
   registered ACME account, all stored certificate lineages, canonical
   renewal metadata, acceptable symlinks and key permissions. Do not rely on
   matching one certificate's SANs alone. Independent account/lineage
   validation remains essential even after archive validation.
5. Compare the recovered candidate against the separately preserved current
   archive and obtain explicit operator authorization for any later recovery
   *write*. Coordinate writers, decide whether replacement is appropriate,
   and use a separately reviewed publication procedure. Neither the download
   nor the offline verification automatically replaces the authoritative
   object, performs a renewal, deletes a backup or modifies local Certbot
   installation files.

For the currently supported plaintext gzip-tar archive, this is the
**read-only acquisition** part of the procedure. Substitute an existing
bucket and *exact* known backup key; the example does not search the bucket:

```bash
umask 077
recovery_dir="$(mktemp -d)" || exit 1
chmod 700 "$recovery_dir" || exit 1

aws --no-cli-pager s3api get-object \
  --bucket "$S3_BUCKET" \
  --key 'archive-20261020.tar.gz' \
  --output json \
  "$recovery_dir/downloaded.tar.gz" >/dev/null || exit 1
chmod 600 "$recovery_dir/downloaded.tar.gz" || exit 1
```

The following **version-specific offline validation example** uses internal
functions bundled into a *trusted, checksum-verified* certbotbot artifact.
These are not advertised as a stable external API or a new supported public
recovery mode. Review their contracts against the artifact version before
using them, and invoke them only in the separate recovery workspace.
`CERTBOTBOT_ARTIFACT` points to the trusted standalone executable,
`SELECTED_CERT_NAME` to the known lineage, and `recovery_dir` to the private
directory allocated above:

```bash
bash -c '
  source "$1" --help >/dev/null || exit $?
  certbotbot_archive_restore "$2" "$3" || exit $?
  certbotbot_state_preflight "$3/config" "$4" || exit $?
  certbotbot_state_canonical_all "$3/config" "$4"
' _ "$CERTBOTBOT_ARTIFACT" "$recovery_dir/downloaded.tar.gz" \
  "$recovery_dir" "$SELECTED_CERT_NAME"
```

This example does not write to AWS or launch Certbot; it stages and verifies
an inactive copy. It is applicable to **plaintext** payloads only.
For encrypted payloads, verify and decrypt within an isolated GnuPG home
using the authenticated ADR-031 library path *before* invoking restore.
The original ciphertext, not the decrypted file, should remain preserved as
recovery evidence. The GnuPG secret must not be placed in command-line
arguments, source-controlled files or logs. The tests use a synthetic secret
and the bundled authenticated decryptor; they do not claim an operator-facing
stable decrypt/restore command.

After inspection, preserve any evidence needed for audit or recovery and
securely dispose of only the workspace whose ownership is known to the
operator. Do not infer that an S3 backup was durable from a passing local
test; when recovery is critical, independently verify the real object through
a controlled, authorized live-environment procedure.

## Task #83 black-box acceptance matrix

`make test-report` runs `tests/public-lifecycle.bats` against the development,
stripped and minified standalone artifacts, using instrumented AWS and Certbot
mocks and real GNU tar/OpenSSL (and real GnuPG only when a supported version is
available). The following are expected assertions, not assertions of live AWS
testing.

| Scenario | Required result |
| --- | --- |
| First backup and separate read-only download | Public two-object write succeeds; named backup downloaded into a new 0700 workspace, checked and restored inactive; complete account and certificate lineage retained |
| Fresh independent runner | Normal command reads `latest.tar.gz` only, renews or checks without issuance and skips both writes on unchanged state, even if backup HEAD is unavailable |
| Repeat date | Second same-day publication only replaces managed same-scope backup using conditional ETag; no speculative overwrite of unknown keys |
| UTC boundary | 2026-10-20 and 2026-10-21 select distinct keys; old day's bytes remain untouched; latest remains current |
| Current PUT failed or lost | No backup PUT follows; no false success |
| Backup PUT failed or lost | Current accepted, status nonzero and partial success indicated; no automatic rollback |
| Backup PUT accepted, post-PUT HEAD failed | Current remains; backup may exist but is unverified; return nonzero and do not claim confirmation |
| Backup HEAD denied before current write | Fail before both PUTs, including when client cannot confidently distinguish absence |
| Other current-key scope or unrelated date-name object | Refuse managed ownership assumption and do not mutate either object |
| ZIP/bzip2/alternate storage | Unsupported invocation rejects with 64 before any cloud operation |
| Corrupted downloaded backup | Offline pre-extraction validation refuses untrusted payload; no active state or S3 mutation |
| Encrypted backup | The current and dated objects hold identical authenticated ciphertext; offline recovery with the correct key restores all state, and incorrect secret refuses restoration |

The existing #82 cases additionally prove first creation, same-day conditional
replacement, no-op skips, identity preflight, current failure isolation and
lost-response reporting. Task #83 exercises distinct recovery paths and fault
boundaries to avoid simply duplicating #82's original checks.

**Evidence boundary:** Mocked S3 behavior proves exact key selection and
recorded calls; it does not prove remote durability, full-download integrity,
AWS conditional-write semantics against live concurrent writers, IAM
authorization, S3 Versioning behavior, ACME issuance or Route53 integration.
Those claims require separate authorized live acceptance. A successful
HeadObject after backup PUT verifies metadata and size only, not a complete
independent byte-for-byte S3 readback.

## Cross-references

ADR-020, ADR-022/023, ADR-027/028, ADR-030/031/032/033/034; story #67;
tasks #81–#83; pending storage-backend story #63 and format-backend story #65;
`doc/dated-backup-publication-contract.md`,
`doc/mvp-fresh-runner-continuity.md`, and
`doc/archive-encryption-verification.md`.
