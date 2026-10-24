# Opt-In Client-Side Archive Encryption Contract

Status: **ADR-031 accepted in task #41; implementation in task #42**
with comprehensive interoperability evidence tracked in task #43.
Task #43's evidence map is in [archive-encryption-verification.md](archive-encryption-verification.md).
Governing decision:
[ADR-031](adr/ADR-031-opt-in-authenticated-gpg-archive-encryption.md).
The public interface is implemented as an opt-in transport wrapper.
The complete negative and independent-runner acceptance matrix is task #43.

## Operator intent and configuration

Encryption remains disabled when `GPG_SYMMETRIC_KEY` is absent or empty,
unless an explicitly selected encrypted mode requires it and therefore fails.
The key is an **exported environment secret only**; it may come from a
CI/secret-management system.  Never accept it as a command-line argument
or as a literal `.env` configuration key.

| Nonsecret setting | Values | Default | Resolution |
| --- | --- | --- | --- |
| `ARCHIVE_ENCRYPTION` | `auto`, `none`, `gpg-ocb` | `auto` | `--archive-encryption` > env > literal `.env` |
| `ARCHIVE_MIGRATION` | `none`, `plaintext-to-gpg-ocb` | `none` | `--archive-migration` > env > literal `.env` |
| `ARCHIVE_MIGRATION_BACKUP_CONFIRMED` | `true`, `false` | `false` | `--archive-migration-backup-confirmed` > env > literal `.env` |
| `GPG_SYMMETRIC_KEY` | Secret, one nonempty line | Unset | **Exported environment only** |

For `ARCHIVE_ENCRYPTION=auto`, nonempty key presence selects
`gpg-ocb`; unset or empty selects `none`.  Explicit `none` with
a nonempty key is an error, preventing accidental plaintext
publication.  Explicit `gpg-ocb` without a suitable key is an error.
No mode selection changes an already stored object's format
automatically.

Mode, migration and backup confirmation are literal, case-sensitive,
nonsecret configuration data.  Duplicate/unknown file keys, bad
Boolean values, unsupported mode strings, newline-containing
passphrases, and unsupported runtime tools fail before provider calls.

## Durable wire formats and restoration

```text
Existing plaintext S3 object:
    [gzip-compressed valid GNU tar /etc/letsencrypt contents]

Encrypted S3 object, at the SAME operator-selected bucket/key:
    ASCII "CERTBOTBOT-GPG-OCB-V1" + 0x0A
    GnuPG binary symmetric OpenPGP AES-256/OCB ciphertext
        encrypted plaintext = entire validated gzip/tar bytes
```

GnuPG is required only in enabled encrypted mode.  The minimum is
2.4.7 or newer with working `--force-ocb` symmetric AES-256/OCB.
GnuPG 2.2.21 supports AEAD **decryption**, but `--use-ocb-sym` for
symmetric **encryption** first appeared in 2.5.19. The runtime must
probe actual AEAD packet generation and a successful authenticated
roundtrip instead of trusting a version string or the mere presence
of an option. It must not silently substitute legacy CFB/MDC or an
unauthenticated cipher if the required OCB feature is unavailable.  Newly emitted messages use `AES256`, iterated/salted S2K
mode 3, `SHA512`, and `--s2k-count 16777216`.  Secrets must be
randomly generated with at least roughly 256 bits of entropy because
the OpenPGP S2K is not memory-hard.

S3 retrieval always stages the exact object privately.  A plaintext
reader rejects the known encrypted envelope.  An encrypted reader
requires the exact versioned envelope, successful authenticated GPG
decryption, a complete staged output and the existing safe gzip/tar
pre-extraction validation.  Any unknown version, wrong key, tampered
ciphertext, missing expected envelope, unsupported crypto mode, or
invalid decrypted tar fails before Certbot and PutObject.  No
cross-mode guess or fallback to an empty archive is permitted.

Local files retain private ownership and mode restrictions:
`downloaded.tar.gz` for a fully validated plaintext source,
`candidate.tar.gz` for a fully verified package and
`candidate.tar.gz.enc` for locally staged ciphertext.
An implementation may use additional random private staging paths
without changing the durable wire format.  No plaintext, temporary
partial authenticated-decryption output, secret or account private
key may be written to the remote object in encrypted mode.
`S3_KEY` remains exact and unchanged; `.enc` is not silently appended
to the authoritative object key.

## Publication decision table

| Object already stored | Selected mode | Explicit migration | Result |
| --- | --- | --- | --- |
| Plain gzip tar | `none` | `none` | Existing plaintext lifecycle |
| Plain gzip tar | `gpg-ocb` | `none` | Fail before Certbot/PutObject |
| Plain gzip tar | `gpg-ocb` | `plaintext-to-gpg-ocb` with key and confirmed backup | Verify ordinary state, selected lifecycle, encrypt, decrypt+compare locally, then one same-key PutObject |
| Encrypted v1 | `gpg-ocb` | `none` with correct key | Decrypt+verify, selected lifecycle, conditionally upload ciphertext |
| Encrypted v1 | `none` | Any | Fail before Certbot/PutObject |
| Encrypted v1 | `gpg-ocb` | `plaintext-to-gpg-ocb` | Fail; not a plaintext source |
| Encrypted v1 | `gpg-ocb` with missing/wrong key | Any | Fail before Certbot/PutObject |
| Unknown or corrupted bytes | Any | Any | Fail without fallback or remote write |

The operation continues to require an **existing** S3 object; it
never seeds a missing bucket/key, never makes a second durable
archive and never implicitly registers an ACME account.  Existing
single and multiple lineages roundtrip as one unit.  A normal
unchanged run skips upload according to ADR-028 unless the operator
explicitly overrides it or has deliberately requested the one-time
plaintext-to-encrypted migration.

Before a one-time migration, the operator must retain and verify a
recoverable backup of the **old plaintext object** independent of
the single active key and safeguard the new secret.  The backup
confirmation flag records operator acknowledgement, not an
infrastructure assertion.  If the sole active object is replaced,
recovery requires that operator backup or enabled S3 Versioning; the
tool provides no automatic rollback.  A failed or uncertain PutObject
is never declared a successful format transition.

## Secret and tool boundaries

The passphrase is supplied to trusted GnuPG on a private FD 3 under
`--batch --no-tty --pinentry-mode loopback --passphrase-fd 3` and
`--no-symkey-cache`.  The entrypoint must disable xtrace before accessing the secret, copy
the exported key into a non-exported shell-local value, and unset the
exported `GPG_SYMMETRIC_KEY` variable before spawning AWS CLI, Certbot,
OpenSSL or any other child. Only the trusted GnuPG process may receive
its passphrase via a private FD, never as an inherited environment
variable. The invocation must not use passphrase command arguments,
standard process logs, shell evaluation, stdout or stderr for secret
delivery.  Use a per-runner restricted GnuPG home and
ignore untrusted user GnuPG configuration.  Suppress untrusted GnuPG
errors and report fixed nonsecret diagnostics and status codes.

Validate the GnuPG version/OCB feature.  The implementation MUST
inspect or otherwise enforce the produced **authenticated** packet
format and verify decrypt+compare before using ciphertext as a
publication candidate.  A utility claiming successful decryption
must not authorize state if its output failed archive validation.
Errors never select another Certbot lineage or invoke a global renew.

Authenticated encryption protects ciphertext integrity/confidentiality
against storage readers without the key, **not** against old valid
ciphertext replay, privileged runner compromise, process environment
inspection, secret-manager compromise, weak operator-chosen passwords,
plaintext staging/backups, metadata/size/access leakage, or concurrent
writers.  GPG and AWS CLI remain trusted external dependencies.

## Task implementation and test boundaries

**Task #42:** Only after ADR-031 approval, implement these settings,
private GPG adapter, authenticated mode recognition and migration
gates at fetch/package/publish boundaries.  Avoid changing the
verified inner tar layout, existing AWS key selection, selected-only
Certbot dispatch or unrelated-lineage preservation.  Update Doxygen
for every new config, crypto, error and staging interface.  Use
mocked AWS/Certbot and actual local GnuPG/OpenSSL/tar to verify
fundamental positive and fail-closed behavior.

**Task #43:** Add comprehensive Bats coverage across all three
built artifacts and clean workspaces: mode precedence, exact
ciphertext S3 bytes, no plaintext leakage, encrypted restore with
multiple lineages, wrong/missing key, unsupported GnuPG, tampering,
unknown version, plaintext/encrypted mode mismatch, explicit backup
acknowledgement, missing migration permission, changed/no-op behavior,
key-loss and partial/uncertain PutObject cases.  Tests must distinguish
mock local guarantees from real S3, ACME and host security guarantees.

Production-runbook documentation is deferred to Milestone #13.
