# Manual archive encryption migration

This guide implements the migration rules in
[ADR-021](adr/ADR-021-optional-symmetric-encryption-and-migration.md)
and [ADR-041](adr/ADR-041-encrypted-state-retrieval-and-preparation.md).
It is a **manual administrative procedure**, not an automated producer feature.
The first version of certbotbot still has no live issuance or S3 publication.

## Collection boundaries

Each archive collection contains one authoritative producer
`common-latest.tar.gz` and zero or more independently selectable
`<lineage>-latest.tar.gz` objects. Encrypted counterparts append
`.enc`; the staging ACME environment keeps its separate `staging/`
prefix. All members of a collection must be migrated together.
The common archive contains ACME account private keys, and domain
archives contain private TLS keys and historical lineage state.

Do not mix production and staging data, and do not move state between
different account authorities as a side effect of migration.

## Preparation and recovery point

1. **Stop every writer** to the exact selected bucket, key namespace,
   and ACME environment. Jenkins and GitHub Actions concurrency guards
   do not coordinate with each other; suspend or otherwise serialize
   all independent writers, including manually invoked native runs.
2. Confirm the desired direction (plain to encrypted, encrypted to
   plain, or encrypted with a new passphrase). Identify all common and
   lineage objects, not merely certificates selected in one run.
3. Capture a consistent, separately recoverable checkpoint of every
   source object, with its object version/ETag and SHA-256 digest.
   Preserve bucket version IDs where available, and ensure that the
   recovery copy cannot be overwritten by this migration.
4. Download the entire collection to an owner-private workspace on a
   trusted workstation. Keep archive and account-key files mode 0600
   and directories mode 0700. Do not log the contents or unpack into
   a live Certbot configuration.
5. Check that **every** expected source object exists and can be read.
   A failed or ambiguous retrieval is a stop condition, not permission
   to create an empty new collection.

## Transform and inspect locally

For each plaintext `.tar.gz` archive being encrypted, use GPG
symmetric mode with explicit AES-256, `--batch`,
`--pinentry-mode loopback`, and `--passphrase-fd 0`.
For each ciphertext `.tar.gz.enc` being decrypted, use GPG's
`--decrypt` command with the same safe passphrase channel.

Passphrases belong in an injected secret or a trusted interactive
prompt, not process command arguments or recorded terminal history.
The following *local-only example* demonstrates the pattern for one
prepared file; it intentionally performs **no cloud operation**:

```bash
set +x
umask 077
read -r -s -p 'New archive passphrase: ' passphrase
printf '\n'

plain=/private/collection/common-latest.tar.gz
encrypted=/private/collection/common-latest.tar.gz.enc
printf '%s\n' "$passphrase" |
  env -u GPG_PASSPHRASE gpg --batch --yes --pinentry-mode loopback \
    --passphrase-fd 0 --cipher-algo AES256 --symmetric \
    --output "$encrypted" -- "$plain"
unset passphrase
```

Use equivalent loopback decryption with `--passphrase-fd 0` when
moving in the other direction. Use a new empty destination for
every transform. The example assumes the paths are already private
and the workstation's GPG installation is trusted.

After each transformation, independently decrypt the encrypted output
with the intended secret and verify the resulting bytes against the
original SHA-256 digest. Then validate the entire archive member list,
lineage structure, relative symlinks, account references, and allowed
renewal options using the project validators. GPG decryption success
alone does not establish that an archive is valid or trustworthy.

## Stage, verify, and switch

1. Upload the complete transformed collection under the **new suffix**
   without deleting or overwriting the recoverable source collection.
   Validate that all destination objects exist and match the expected
   uploaded ciphertext/plaintext digests.
2. Set `GPG_PASSPHRASE` consistently for every future producer
   environment and configure consumers with the corresponding
   decryption procedure. No program should automatically try both
   formats on a missing object.
3. Confirm the new format can be retrieved and, when encrypted,
   decrypted into private staging. Verify the account and selected
   lineages with the existing read-only validators. Perform an
   independently provisioned runner test before resuming producers.
4. If any object fails verification, leave writers stopped and revert
   their configuration to the previously verified format and recovery
   snapshot. Do not initialize new ACME accounts to compensate.
5. Resume exactly one writer for the collection only after the new
   complete mode has been tested. Retain the source checkpoint until
   rollback is no longer needed and organizational retention policy
   authorizes its removal.

S3 object versioning, replication, backups, access logs, and lifecycle
rules may retain historical **plaintext** even after the visible keys
are removed. Review and remediate those copies separately if the purpose
of migration includes elimination of previously exposed keys.

## Scope limitations

Encryption protects archive confidentiality against readers without
the passphrase; it does not authenticate who wrote the archive, secure
a compromised CI runner, create atomic multi-object publication, or
eliminate plaintext temporary files. It also does not replace scoped
IAM credentials, external writer serialization, TLS trust validation,
or the real Let's Encrypt account continuity tests required before
operational issuance.
