# Standalone Certificate Client Examples

The separately distributed `certbotbot-client.bash` consumes **one current**
certificate-state archive from an existing S3 bucket/key. It can decrypt the producer's authenticated AES-256/OCB archive but never
issues, renews, installs, or uploads certificates.

These examples require Bash 4.3 or newer, AWS CLI v2 with appropriate
read-only credentials, GNU tar, gzip, and ordinary GNU core utilities.
Authenticated encrypted archives additionally require **GnuPG 2.4.7+**
with verified AES-256/OCB support, `awk`, and GNU `od`/`tail`.
Download the client and `certbotbot-client.bash.sha256` from the **same
verified release** before running:

```bash
sha256sum -c certbotbot-client.bash.sha256
chmod 0755 certbotbot-client.bash
./certbotbot-client.bash --help
./certbotbot-client.bash --version
```

## Retrieve the current literal key

Prepare an owned, private parent (once), choose an **absent** destination,
and execute the client:

```bash
mkdir -m 700 "$HOME/certificate-states"
./certbotbot-client.bash \
  --s3-bucket existing-certificates \
  --s3-key latest.tar.gz \
  --destination "$HOME/certificate-states/2026-10-25"
```

The command writes the **canonical absolute destination pathname only**
on success. A successful result contains the complete supported account
and certificate archive tree. The operator separately decides which
lineages to use and how to deploy them. An existing destination cannot
be reused or overwritten; choose a new absent path for each retrieval.

## Share nonsecret publisher configuration

An optional literal `.env` in the current working directory can select
the same bucket/key as the issuer:

```dotenv
S3_BUCKET=existing-certificates
S3_KEY=latest.tar.gz
```

Then run:

```bash
./certbotbot-client.bash \
  --destination "$HOME/certificate-states/next"
```

A named config file can be selected with `--config FILE`.
CLI values override exported environment values, which override the
literal config file. The current key defaults to `latest.tar.gz`.
`GPG_SYMMETRIC_KEY` is **not** an accepted *literal file or CLI* field;
it is accepted **only as an exported environment secret** supplied by the
operator. Nonsecret `ARCHIVE_ENCRYPTION` may be specified in the literal
file, environment, or CLI.

To resolve a date-based current key using one UTC snapshot:

```bash
./certbotbot-client.bash \
  --s3-bucket existing-certificates \
  --s3-key-template 'archive-{YEAR}{MONTH}{DOM}.tar.gz' \
  --destination "$HOME/certificate-states/date-based"
```

No backup enumeration or S3 object-version discovery occurs.

## Restore an authenticated encrypted archive

The **producer** must already publish `CERTBOTBOT-GPG-OCB-V1`
AES-256/OCB ciphertext at the selected S3 key. A consumer needs the
*same* high-entropy symmetric key, delivered independently and securely.
The key must **not** be placed in argv, `.env`, a checked-in shell script,
or a command copied into shell history. An interactive operator may use
a hidden prompt when a dedicated secret manager is unavailable:

```bash
set +x
read -r -s -p 'Archive symmetric key: ' GPG_SYMMETRIC_KEY < /dev/tty
printf '\n' > /dev/tty
export GPG_SYMMETRIC_KEY
./certbotbot-client.bash \
  --archive-encryption gpg-ocb \
  --s3-bucket existing-certificates \
  --s3-key latest.tar.gz \
  --destination "$HOME/certificate-states/encrypted-restore-01"
unset GPG_SYMMETRIC_KEY
```

For unattended operation, inject `GPG_SYMMETRIC_KEY` via a trusted secret
manager's environment mechanism without tracing or logging the value,
and use the same invocation with explicit `gpg-ocb` mode. Arrange
secret cleanup in your own runner even if retrieval fails; a shell
with `set -e` should use a cleanup trap. The client captures and
unexports its inherited secret before invoking ordinary subprocesses,
but cannot protect its **initial** environment from parent/privileged
host monitoring. GnuPG receives the key only on a private descriptor.

The default `--archive-encryption auto` chooses `gpg-ocb` when the
key is nonempty, or `none` without a key. It does **not** inspect the
downloaded bytes and switch mode. Explicit `none` plus a key and
explicit `gpg-ocb` without a key fail before S3 contact. Wrong keys,
modified/truncated ciphertext, legacy CFB/MDC messages and unknown
envelopes fail without creating the destination. The plaintext path
continues to work without GnuPG when no key is provided.

## Coordinate encryption migration and key rotation

Before switching a producer from plaintext to encrypted storage, provision
all consumers with a trusted compatible GnuPG runtime and the encrypted
mode/key configuration. Publish the encrypted archive to the **same current
S3 key** using the producer's approved migration process; consumer
attempts with stale settings fail closed rather than retrieve older
versions or silently downgrade.

To rotate a key, arrange secure distribution of the **new** symmetric
key to intended consumers, re-publish the authoritative object using the
producer and that key, then transition consumer invocations to the new
key. Allow for an operational window where a mismatched key causes a
failed retrieval. There is no multi-key trial, automatic re-encryption,
key escrow, old object/version lookup, or client-driven migration.
Retain required recovery material and choose separate, *absent*
destinations according to your operator policy. Restoring from S3 does
not install or restart services.

## Operational and security boundaries

Supply a preexisting bucket and IAM identity authorized to retrieve the
selected object. `s3:GetObject` on that key and appropriate bucket-level
read permissions for the absence check are the intended capabilities;
the tool never needs `s3:PutObject`, `s3:DeleteObject`, Route53, or ACME
credentials. Avoid configuring broader AWS authority than required.

Do not point the destination at `/etc/letsencrypt` or a server's live
certificate directory. Instead stage into an absent path under a
trusted, caller-owned, non-group/world-writable parent, then perform
service-specific installation and reload separately. Private PEM and
account data are stored with restrictive permissions. The client rejects unknown, legacy or mismatched encryption rather than
guessing a decryption method or retrieving another object. Authenticated
plaintext is never exposed to GNU tar before GnuPG has exited successfully.

The client uses GNU tar/gzip and Linux-style GNU tools and assumes
the operator serializes cooperating processes running as the same
user against a destination. It does not establish archive authorship,
ACME registration, certificate-chain trust, or transactional deployment.

For failure code details and format constraints, read
[the client contract](../separate-client-contract.md),
[extraction security boundaries](../client-extraction.md), and
[release integrity verification](../release-verification.md).

For complete option precedence, authenticated packet constraints,
exit statuses and limitations, see [client settings](../client-settings.md).
