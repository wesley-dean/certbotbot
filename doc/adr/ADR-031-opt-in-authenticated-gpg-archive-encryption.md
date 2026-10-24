# ADR-031: Opt-In Authenticated GnuPG Encryption of the Shared Archive

Date: 2026-10-23

## Status

Accepted

## Context and Decision Drivers

Approved story #14 and technical task #41 introduce optional **client-side**
encryption of the one authoritative S3 archive containing the existing ACME
account and all certificate lineages.  The archive is presently a portable,
validated gzip-compressed GNU tar file, fetched from and published to one
operator-selected existing S3 bucket/key (ADRs 020–022 and 027–030).
A successful decrypt must produce exactly that same ordinary archive format.
Decryption may not reinterpret any untrusted Certbot configuration as shell
code, skip archive validation, or select additional lineages.

The operator previously proposed an optional `GPG_SYMMETRIC_KEY` setting:
an empty/unset value retains plaintext compatibility, while a nonempty value
enables encryption.  Existing `.env` support is intentionally literal
configuration data, not shell source.  A noninteractive runner must be able
to provide a secret through its secret manager without placing it in process
arguments, repository files, build artifacts, AWS API parameters, or logs.

Encrypted ciphertext is an untrusted input.  Wrong keys, corrupted payloads,
missing software, wrong format/version, and interrupted provider operations
must fail closed.  Changing the one S3 object is not a transaction; existing
ADR-028 uncertainty and externally serialized writers remain in force.

## Decision

### Selected cryptographic format and dependency

The first supported encryption format is **GnuPG symmetric OpenPGP with
AES-256 and OCB authenticated encryption**, not GnuPG's default legacy
CFB+MDC format.  The adapter invokes the installed `gpg` executable with
`--symmetric --force-ocb --cipher-algo AES256`,
`--s2k-mode 3 --s2k-digest-algo SHA512`, and an explicitly configured
iterated/salted S2K count of **16777216**.  GnuPG's native per-message
salt, random session material and authentication tags remain under its
control.  These settings are part of the format contract for newly
written objects; a decrypter MUST enforce the expected authenticated
ciphertext mode rather than silently downgrade to legacy MDC or another
cipher when invoking a different GnuPG version.

Require **GnuPG 2.4.7 or newer with proven AES-256/OCB symmetric encryption
and decryption support** on any runner that reads or writes encrypted
archives. The minimum is a tested operational baseline, not a guarantee
that every distro build supports the feature. GnuPG 2.2.21 introduced
**AEAD decryption** support; the newer `--use-ocb-sym` encryption flag was
only added in **2.5.19 (2026-04-24)**. The portable `--force-ocb` option
has been verified with symmetric encryption on GnuPG 2.4.7, which produced
OpenPGP AEAD packet tag 20 with AES-256 (cipher 9), OCB (AEAD 2) and
iterated/salted S2K SHA-512. A noninteractive **encrypt/decrypt roundtrip
and authenticated packet-format probe** must succeed before encryption is
authoritative; checking the version string alone is insufficient.  Missing GnuPG,
incompatible crypto flags, unsupported OCB or an invalid authentication
result is a hard error; no automatic use of `openssl enc`, legacy CFB+MDC
or plaintext is authorized.  AES-OCB is an authenticated encryption mode,
but OpenPGP's iterated/salted S2K is **not memory-hard**.  Operators must
supply a high-entropy, randomly generated secret (recommend at least
256 bits of entropy), not a human password.  No secret strength meter
can reliably establish this and no password-recovery service exists.

GnuPG is a **new runtime trusted dependency**, reviewed under ADR-015.
The existing three Bash artifacts remain self-contained *as scripts*,
but encrypted operation also requires the external `gpg` binary and the
host operating system's crypto libraries.  No vendored crypto implementation,
network key registration, shell-evaluated key material, or silent crypto
algorithm negotiation is approved.

Primary upstream references (reviewed when adopting this decision):

- <https://gnupg.org/documentation/manuals/gnupg/OpenPGP-Options.html>
  for `--force-ocb`, cipher and S2K options;
- <https://www.gnupg.org/documentation/manuals/gnupg24/gpg.1.html>
  for `--passphrase-fd`, loopback pinentry and no-cache behavior.

### Versioned transport envelope and object identity

Encrypt the *complete already-validated compressed tarball*, not
individual certificates or tar entries.  A newly stored encrypted object
has the following exact byte layout:

```text
CERTBOTBOT-GPG-OCB-V1\n
<binary GnuPG OpenPGP symmetrically encrypted OCB payload>
```

The first line is a fixed ASCII byte-string discriminator, **not** a
shell-script header or encrypted metadata.  The remainder is one
GnuPG-produced binary ciphertext containing the complete gzip tar file.
The fixed header is not itself an AEAD associated-data field; changing it
must fail version recognition, never cause a plaintext fallback.
No extra metadata, plaintext tar member names or secret values are added
to the S3 object.  Unknown headers/versions, missing payloads and
unexpected raw OpenPGP ciphertext are unsupported.  An encrypted-mode
reader MUST reject anything that is not a supported encrypted envelope;
a plaintext-mode reader MUST reject a recognized encrypted envelope.
Neither mode guesses or automatically converts the other representation.

The configured `S3_BUCKET` and `S3_KEY` remain the **same exact
authoritative object** on fetch and upload, including migration.  The
default key remains `latest.tar.gz` to preserve ADR-028's one-key
contract.  The *local* ciphertext candidate uses the extension
`candidate.tar.gz.enc`; the `.enc` suffix may also be part of an
**explicitly operator-selected** S3 key, but the tool never silently
appends `.enc` to or renames the configured S3 object key.  No second
remote object, split archive, manifest or automatic backup is created.

After authenticated decryption succeeds, the resulting file must be
validated through the **existing** bounded pre-extraction gzip/tar
validator, restored under an isolated 0700 workspace and subjected to
the existing full account/lineage/security preflight.  GnuPG can write
partial plaintext before detecting an authentication error; the caller
MUST keep that output in a private staging file and NEVER expose,
validate as authorized state, extract or publish it until GnuPG exits
successfully **and** gzip/tar validation completes.  On failures, discard
the staging file.  Never send plaintext content to S3 in encrypted mode.

### Operator settings and secret-delivery boundary

Introduce one public nonsecret setting:

- `ARCHIVE_ENCRYPTION=auto|none|gpg-ocb`, resolved as CLI
  `--archive-encryption` > exported environment > literal `.env`
  > default `auto`.  Under `auto`, an unset/empty
  `GPG_SYMMETRIC_KEY` selects plaintext and a nonempty key selects
  `gpg-ocb`.  An explicitly selected `gpg-ocb` without a nonempty
  key is an error.  Explicit `none` **with** a nonempty key is also
  an error: the program refuses to silently send plaintext while an
  encryption secret is present.  Changing settings is not permission
  to change the format of an existing object.

`GPG_SYMMETRIC_KEY` is accepted **only from the current process's
exported environment**, supplied by the operator's secret manager.
It is never accepted in CLI arguments, literal `.env` files or the
archive.  The existing precedence model governs **nonsecret
settings**; this restricted secret source is an explicit exception
under ADR-015/016, not a reason to source a file or expose a password.
Reject empty, newline/carriage-return or otherwise unrepresentable
keys in encrypted mode rather than truncate them at the first line.

Supply the passphrase to `gpg --batch --no-tty --pinentry-mode loopback
--passphrase-fd 3 --no-symkey-cache` on a private non-argument file
descriptor.  Never use `--passphrase PASSWORD`, echo the secret,
construct an `eval` command, place the secret in an AWS parameter, or
allow status output to print it.  Use a private GnuPG home and
`--no-options` to avoid loading the operator's arbitrary GnuPG
configuration; do not assume that a trusted `gpg` executable or
privileged same-user process is isolated by Bash.  Private environment
and process memory remain visible to host administrators and some
same-user debugging tools; POSIX shell memory cannot be securely
wiped.  The operator is responsible for secret distribution, secure
runner isolation, access controls, and independent key backup.

### Explicit, recoverable migration and stable mode

Plaintext MVP archives remain fully supported when encryption is not
selected.  **No automatic archive format migration** occurs merely
because `GPG_SYMMETRIC_KEY` becomes present.  To convert a validated
plaintext object into encrypted form at the **same existing S3 key**,
the operator must:

1. Retain an **independently recoverable, access-restricted backup** of
   the existing plaintext S3 object (e.g., verified S3 Versioning
   recovery or a secure offline copy); independently safeguard the new
   secret.  The program cannot verify the recoverability of a backup.
2. Explicitly set `ARCHIVE_MIGRATION=plaintext-to-gpg-ocb` (CLI
   `--archive-migration` > environment > literal `.env` > default
   `none`) and separately confirm
   `ARCHIVE_MIGRATION_BACKUP_CONFIRMED=true` using the same
   nonsecret configuration precedence.  This assertion is operator
   attestation, **not** a machine-verified backup or guarantee.
3. Supply `GPG_SYMMETRIC_KEY`, fetch the existing plaintext object,
   and complete normal archive/account/lineage validation.  Run the
   permitted selected-only lifecycle, build and validate the candidate,
   encrypt it in the private workspace, decrypt a local copy using the
   supplied key, and verify it matches the original candidate byte for
   byte and passes archive validation.
4. Perform **one** PutObject to the originally configured key only
   after the above gates succeed, even if the selected certificate
   itself was a normal no-op.  Do not delete the original S3 version,
   claim remote rollback, or declare publication successful on a
   failed/uncertain PutObject response.

Migration is **one-way within this milestone**: `gpg-ocb` ciphertext
to plaintext, key rotation from old key to a new key, and key recovery
are not implemented by toggling the environment.  Encryption mode,
version and migration intent are checked against the actual
downloaded object **before provider operations**.  A key change or
missing key must not silently reissue certificates or overwrite an
unreadable object.  A lost key is irrecoverable without the previous
key or a separately held recoverable backup.  Deliberate future
key rotation must use an independently reviewed two-key rewrap
workflow with recovery evidence; no automatic rotation is promised.

### Operations and failure semantics

In ordinary encrypted operation, the one existing key is fetched as
ciphertext; only after authenticated decryption and original archive
validation may any Certbot action occur.  A normal no-op without
`UPLOAD_NO_RENEWAL=true` remains a no-PutObject path.  On a changed
certificate, metadata change or explicit no-op upload, package and
validate the entire shared archive, encrypt locally, verify a
decrypt-and-compare before publication, and send only the private
ciphertext staging file to `aws s3api put-object --body`.  Do not
copy selected-only fragments or remove unselected lineages.

A wrong/missing key, unrecognized encrypted format, tampered payload,
GnuPG failure, failed local roundtrip, archive validation error,
selected Certbot failure and partial candidate **never intentionally
call PutObject**.  Preserve the last authoritative remote object
unless S3 independently changes it.  Keep static redacted diagnostics
and nonzero exit statuses; never reveal password, plaintext, GnuPG
diagnostic paths, raw stderr, the decrypted tar or key material.
If PutObject is refused or its response is lost, the remote result
remains **uncertain** as defined by ADR-028; encryption adds no
distributed transaction, rollback or concurrency protection.

Ciphertext confidentiality does not hide the bucket/key name, object
size, update time, access patterns or fact that an encrypted file
exists.  OpenPGP authenticated encryption detects modification with
the current secret; it cannot detect **replay of an older valid
ciphertext object** or compromise of a trusted runner, GnuPG
executable, AWS credentials or key distributor.  Encrypting a
compressed archive also retains compression/size side channels.
The local plaintext workspace and preexisting unencrypted backups
remain sensitive.

## Alternatives Considered

**Keep plaintext / use only S3 server-side encryption:** rejected for
the opt-in story because S3 must not receive plaintext when enabled;
still supported explicitly by default.

**GnuPG symmetric AES-256 with default CFB+MDC:** rejected as the new
encrypted format because the product requires authenticated encryption
and GnuPG supports the modern OCB symmetric mode.  No downgrade is
allowed when OCB is missing.

**Use `age -p` passphrase mode:** rejected for this milestone because
the standard CLI intentionally requests passphrases interactively;
noninteractive automation would require the separate batchpass
plugin or a different key-based interface, expanding dependencies
and operator key contracts.  Native age recipients/identities remain
a viable separate design if the product changes its key model.

**Use `openssl enc -aes-256-gcm`:** rejected; the usual `enc`
interface does not provide authenticated-GCM archive encryption.
Custom encrypt-then-MAC framing and manual KDF design would create
a bespoke protocol and significant review burden.

**Use GnuPG's default S2K/SHA-1 or a human password:** rejected in
favor of an explicit SHA-512 iterated/salted S2K and a documented
random high-entropy key requirement.  The OpenPGP S2K is still not
memory-hard; we do not claim resistance to all offline guesses.

**Allow a secret in `.env` or on the command line:** rejected due to
repository, shell-history, process-list and logging disclosure
surfaces.  Nonsecret mode/migration settings retain ordinary
configuration precedence; secrets are environment-only.

**Auto-migrate on first encrypted run:** rejected because it could
overwrite the only remotely durable recoverable plaintext object
without an operator-approved backup.

**Automatically switch S3 keys to `.enc` or create a migration copy:**
rejected because one exact configured object remains authoritative;
a second key introduces ambiguous recovery/selection and changes
ADR-028's publication model.

**Decrypt directly into a selected live Certbot configuration tree or
stream unchecked output to tar:** rejected.  Auth failure can occur
after partial plaintext has been emitted; staging and archive
validation must complete before extraction or Certbot authority.

**Disable encryption when decryption fails or silently fall back to
plaintext on unknown data:** rejected as a dangerous downgrade that
could overwrite encrypted state or activate attacker-supplied
material.

**Automatic old-key/new-key rotation:** rejected from the three-task
milestone because it requires an additional key-supply, recovery and
atomicity contract.  Address in a separate approved story if needed.

## Compatibility and Migration Implications

Unencrypted account-only, single-lineage and multi-lineage tar.gz
objects remain readable/writable exactly as before with no encryption
secret.  The plaintext interior of a decrypted encrypted object is
the same approved archive layout; existing tar/link/account/cert
validators do not change their meaning.  The external encryption
envelope **supersedes ADR-022's "unencrypted" transport-only
restriction** when explicitly enabled, and **extends ADR-028's
single-key publishing gate** to require ciphertext validation
before PutObject.  Neither ADR's safe extraction, exact one-key
selection, no-fallback or fail-closed boundaries are weakened.

Operators selecting encryption need a supported installed GnuPG
binary, a high-entropy symmetric key distributed to every runner, a
key-recovery plan, and a separately retained backup before the
explicit plaintext-to-encrypted migration.  The original existing
object is never guessed, duplicated or renamed automatically.
Unencrypted targets continue to consume direct plaintext tar.gz
unless deliberately provided a decrypting client (future work).

## Expected Outcomes and Evidence

Task #42 will implement only the reviewed config/crypto adapter and
single-key transport integration, preserve all unselected lineages,
stage secret material privately, and use no live AWS/ACME credentials
during development.

Task #43 will exercise encrypted and plaintext flows through all
three generated executables across clean runners, negative
wrong/missing-key/auth-tag/tampering/unknown-version tests, migration
acknowledgement and backups, no-op and uncertain PutObject paths,
and static no-secret-output assertions.  Include a deterministic
GnuPG OCB capability probe and fail closed when unavailable.  Mocked
AWS/Certbot results cannot prove real S3 atomicity, upstream ACME
trust, memory zeroization or host-process isolation.

## Related Decisions

- ADR-015: external runtime dependencies are an attack surface.
- ADR-016: security boundary and residual risks require threat modeling.
- ADR-019: issue `approved` label authorizes the design and review.
- ADRs 020–022: one selected certificate and one protected portable
  underlying gzip/tar archive, with seeded-account compatibility.
- ADRs 027–028: validate candidate before one-key S3 publication;
  preserve no-op and remote uncertainty semantics.
- ADR-030: preserve all nonselected certificate lineages in the same
  archive during each selected-only operation.
- Story #14 and tasks #41–#43: optional encryption design,
  implementation and verification; future rotation is separate.
