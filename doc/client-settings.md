# Standalone Client CLI and Settings Reference

This is the operator-facing reference for the independently released
`certbotbot-client.bash`. The client **reads** one existing current S3
archive and privately restores the complete supported Certbot state. It does
not issue/renew certificates, upload archives, install into system paths,
run hooks, or search backups. The authoritative requirements are
[ADR-035](adr/ADR-035-standalone-read-only-certificate-client.md) and
[ADR-037](adr/ADR-037-authenticated-standalone-client-decryption.md).

## Required runtime and trust boundaries

Use Bash **4.3+**, AWS CLI **v2**, GNU tar, gzip and GNU/Linux file
utilities. The encrypted mode also requires trusted GnuPG **2.4.7+**
with *functionally verified* AES-256/OCB support, plus `awk` and GNU
`od`/`tail`. A version string alone is insufficient: the client probes
encryption packet identity and performs a complete authenticated
roundtrip before contacting S3. Plaintext mode requires **no GnuPG**.

The operator provides an existing bucket, current object, AWS credentials
with read-only access and a secure preexisting destination parent. S3
operations are limited to HeadObject, optional HeadBucket for missing-key
corroboration, and **one GetObject** against the exact selected key. The
operator must arrange AWS credential distribution, encryption key
distribution, and any deployment/restart after restoring state.

Download `certbotbot-client.bash` and its `.sha256` companion from the
**same verified release**, and validate the checksum before execution.
The release includes exactly eight assets: three producer executable
flavors plus the one independent client, each with its checksum. Release
attestation establishes provenance for those bytes; a bare checksum alone
does not authenticate the publisher.

## CLI and nonsecret configuration

| Option | Environment / file key | Default and behavior |
| --- | --- | --- |
| `--destination DIRECTORY` | CLI only | **Required**; new absent immediate child of a preexisting owned private parent |
| `--s3-bucket BUCKET` | `S3_BUCKET` | Existing bucket; required unless a valid lower-tier value supplies it |
| `--s3-key KEY` | `S3_KEY` | Literal selected current key; default `latest.tar.gz` |
| `--s3-key-template TEMPLATE` | `S3_KEY_TEMPLATE` | Date-based key using `{YEAR}`, `{MONTH}`, `{DOM}` from a single UTC snapshot |
| `--archive-encryption MODE` | `ARCHIVE_ENCRYPTION` | `auto` (default), `none`, or `gpg-ocb` |
| `--config FILE` | No equivalent | Select explicit literal configuration in place of implicit `./.env` |
| `--help` | None | Local help; no key, S3, destination, or GnuPG required |
| `--version` | None | Local build provenance; no remote access |

Both `--flag=value` and `--flag value` work for ordinary options.
The source precedence for nonsecret values is **CLI > exported
environment > literal file > defaults**. A `--config` file is data:
it is **never sourced or evaluated**. Only nonsecret recognized settings
may appear there; `GPG_SYMMETRIC_KEY` is expressly forbidden in the file
and on the command line. Duplicate/unknown flags and unrecognized or
conflicting settings fail closed. Producer-only file settings are inert
rather than authorized client operations.

If both a literal current S3 key and a key template are supplied at the
same winning precedence tier, the configuration is invalid. A higher-tier
selection masks a lower-tier alternative. The key is frozen once per run;
there is no second-key read or date-based backup lookup.

## Symmetric key and encryption-mode matrix

The **sole secret source** is an exported `GPG_SYMMETRIC_KEY` supplied
by the operator or an external secret manager. It is *not* subject to
normal nonsecret configuration precedence. Key values with embedded
newlines or carriage returns are rejected; do not use a multiline
passphrase. Generate high-entropy random key material (at least 256 bits
recommended); human-memorable passwords are not recommended because
OpenPGP's S2K is not memory-hard.

| Effective mode | Exported key | Accepted object | Outcome |
| --- | --- | --- | --- |
| `auto` | Absent/empty | Plaintext gzip/tar | Restore with no GnuPG |
| `auto` | Nonempty | Exact authenticated v1 GnuPG/OCB envelope | Require successful authenticated decryption |
| `none` | Absent/empty | Plaintext gzip/tar | Restore with no GnuPG |
| `none` | Nonempty | Not fetched | Reject configuration (64) |
| `gpg-ocb` | Absent/empty | Not fetched | Reject configuration (64) |
| `gpg-ocb` | Nonempty | Exact authenticated v1 GnuPG/OCB envelope | Require successful authenticated decryption |

`auto` chooses from **key presence**, never by sniffing downloaded S3
bytes. When a key is provided and encrypted mode is selected, plaintext
is not a fallback. A raw OpenPGP message, legacy CFB/MDC ciphertext,
unsupported packet parameters, different envelope version, wrong key,
truncation, tampering, corrupted gzip/tar or unsafe filesystem entries
fail without activation. The only supported envelope is the exact
ASCII `CERTBOTBOT-GPG-OCB-V1` followed by LF and producer-compatible
authenticated AES-256/OCB OpenPGP binary data. See
[ADR-031](adr/ADR-031-opt-in-authenticated-gpg-archive-encryption.md).

The client disables Bash xtrace before reading the exported key, moves
it to an unexported shell-local variable, and unsets the original
environment name before launching helpers. Only trusted GnuPG receives
the secret, through file descriptor 3. No raw crypto diagnostics or
archive contents are printed. **Initial inherited environments, host
process memory, privileged monitoring and secure memory erasure are
outside Bash's confidentiality guarantees.** Never use `set -x`
while handling secrets in an operator wrapper.

## Safe restore and output

The destination must not exist. Its **parent** must exist, be owned by
the invoking UID, be writable, and not be group/world-writable or
symlink-ambiguous. The command downloads one archive into an owned
mode-0700 private workspace, validates its whole gzip/tar body (at
most **32 MiB decoded** and **2,048 archive members**), rejects unsafe
paths, duplicate entries, hardlinks, special files or broken/escaping
PEM symlinks, and extracts only into inactive private staging.
Encrypted plaintext cannot enter this validator until GnuPG exits
successfully after complete authentication.

All ordinary restored files are restricted to mode **0600** and
directories to **0700**, and existing relative PEM links are preserved.
A late no-clobber activation moves the complete validated tree into
the absent destination. The operator must serialize cooperating
same-UID retrievals, and separately install/reload any target server.
On success stdout is **only** the canonical absolute destination path,
followed by a newline. No successful pathname is printed on failure.

## Exit status reference

| Exit | Meaning |
| --- | --- |
| 0 | Help/version or complete, validated restoration |
| 64 | Invalid CLI, config, secret format or conflicting/missing mode/key |
| 65 | Unsupported/wrong downloaded format, failed authentication, bad key, corrupt or unsafe archive |
| 66 | Confirmed absent selected S3 object |
| 69 | Missing/incompatible required tooling, denied or ambiguous AWS result |
| 73 | Unsafe, missing, occupied, or untrusted destination |
| 74 | Local staging, extraction, cleanup or activation I/O failure |

Diagnostics are fixed nonsecret messages rather than raw tool output.
A failure leaves any preexisting destination alone and removes
client-owned temporary content during ordinary cleanup. It cannot
guarantee forensic disk erasure or recovery of temporary data after
a host crash.

## Changeovers, rotation and compatibility

The producer and each consumer must agree on the **current object format
and key** before a new archive is fetched. For a plaintext-to-encrypted
changeover, provision a trusted compatible GnuPG 2.4.7+ client and the
high-entropy key **before** configuring the producer to publish the v1
encrypted object. Then invoke the client with a key and explicitly
`--archive-encryption gpg-ocb` (or key-based `auto`).
Plaintext-only clients will deliberately reject that object.

For key rotation, provision the new key securely to consumers,
coordinate a new producer upload encrypted using the new key **to the
same selected current S3 key**, then switch consumer invocations to
the new key. During the transition, mismatched clients fail closed.
The client cannot try multiple keys, decrypt old formats, migrate
existing archives, select historical object versions, or independently
re-encrypt S3. Retain recovery material according to an external
operator policy; the client does not implement key escrow or recovery.
Likewise, changing to plaintext requires coordinated producer/client
mode configuration, not automatic downgrade.

See [standalone usage examples](examples/certbotbot-client.md),
[retrieval behavior](client-retrieval.md), [safe extraction](client-extraction.md),
[client threat model](client-encryption-threat-model.md), and
[release verification](release-verification.md).
