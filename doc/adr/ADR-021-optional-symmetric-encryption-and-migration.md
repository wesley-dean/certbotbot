# ADR-021: Optional Symmetric GPG Encryption and Manual Format Migration

Date: 2026-10-15

## Status

Accepted

## Intent and Documentation Posture

Allow an archive collection to be stored either as plaintext gzip-compressed tar archives or as locally GPG-encrypted ciphertext, without changing the logical extraction layout.

## Context

The tool stores certificate private keys, account credentials, and historical key material in object storage.  GPG symmetric encryption reduces exposure to object-store readers who lack the passphrase.  Native Bash, Jenkins, Docker, and GitHub Actions need one consistent option.  An earlier asymmetric-key suggestion was corrected to symmetric encryption by project decision.

## Decision Drivers

- Make encryption optional without ambiguous fallback.
- Keep all objects in a run in one format.
- Avoid putting passphrases on command lines or in logs.
- Allow administrators to migrate existing archives in either direction without a project-specific converter.
- Preserve format independence for the consumer's extraction contract.

## Decision

If `GPG_PASSPHRASE` is unset or empty, the tool reads and writes plaintext `.tar.gz` objects.  If nonempty, the tool reads and writes GPG symmetric AES-256 ciphertext using the `.tar.gz.enc` suffix.  The mode applies uniformly to both common and per-certificate archives in the selected collection.  There is no opportunistic plaintext fallback after an encrypted read or write failure and no implicit encryption-mode migration.

Use GPG batch mode with `--pinentry-mode loopback`, a non-argument passphrase channel such as a dedicated file descriptor, and an explicit algorithm compatible with supported GPG versions.  Secrets must not appear in command arguments, shell tracing, diagnostic logs, or persisted CI artifacts.  Encryption occurs locally before storage upload; decryption occurs only in a private temporary workspace after download.  Remove temporary files on normal exit and signal interruption as feasible; do not claim secure erasure.

Document a manual reversible migration: stop all writers, download a consistent archive collection, encrypt or decrypt every archive locally, verify output restoration and content, upload under the new suffix, configure consumers/producers for the new mode, test, and only then remove obsolete objects.  Bucket versioning is recommended but retains old plaintext object versions; administrators need a separate retention and deletion plan if historical plaintext must be eliminated.

## Promises

- A configured passphrase means no plaintext archive is intentionally uploaded by certbotbot.
- Format mismatch, GPG failure, or decryption failure stops the operation instead of initializing fresh state.
- Plaintext and encrypted archives yield the same relative tar member layout after decrypting.

## Non-Promises

- GPG encryption does not authenticate the archive publisher merely because the recipient knows the passphrase.
- Environment-based secret injection cannot hide a passphrase from privileged users or the CI host.
- Temporary key material cannot be guaranteed to be securely erased from swap, crash dumps, filesystem snapshots, or SSD media.
- Object names and metadata remain visible to storage operators.

## Adversary and Failure Model

Misconfigured secret injection, mixed encrypted/plaintext collections, missing objects incorrectly interpreted as first run, shell tracing, GPG failure, compromised runners, leaking temp files, and malicious ciphertext or extracted tar content all matter.  Storage mode must be selected before lookup, and the other-mode object should be checked or the mismatch explicitly surfaced when a selected-mode object is absent.

## Operational Constraints

- `GPG_PASSPHRASE` controls the entire archive collection's mode.
- AES-256 MUST be used for symmetric encryption.
- Encrypted objects MUST have `.enc` appended to the `.tar.gz` name.
- Ciphertext MUST NOT fall back to plaintext automatically.
- Migration MUST be documented and manually supervised for the first release.
- Passphrases MUST NOT be present in child-process command-line arguments.

## Considered Alternatives

Asymmetric recipient keys were rejected after the product requirement was corrected to symmetric encryption.  Transparent dual-mode autodetection was rejected because it would make format errors difficult to diagnose and enable accidental plaintext downgrade.  Encryption in S3/KMS alone was deferred because the requirement is to avoid plaintext objects at the storage boundary independent of storage provider.

## Consequences

Operators must arrange a high-entropy shared passphrase, secret handling, and rotation policies.  Credential compromise affects all archives under that passphrase until migrated; key rotation and signing are future considerations rather than implicit features.

## Related Decisions

ADR-019 governs archive contents.  ADR-022 governs concurrency and publication.  ADR-024 governs imported security standards.
