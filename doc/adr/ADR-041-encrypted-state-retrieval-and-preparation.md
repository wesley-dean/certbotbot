# ADR-041: Encrypted Archive Preparation and Strict Retrieval Mode

Date: 2026-10-16

## Status

Accepted

## Decision

Implement ADR-021's optional symmetric AES-256 archive mode in the private
producer-state lifecycle, without activating certificate issuance or object
publication. `GPG_PASSPHRASE` continues to determine a **single archive
format for the entire selected collection**. An empty or absent value uses
plaintext `.tar.gz` object keys. A nonempty value selects only
`.tar.gz.enc` keys under the same ADR-030 production/staging namespace.
The common archive and every selected domain archive use the same suffix
in one run. The value is never passed as a command-line argument.

The new internal GPG helper takes a prepared, owner-private source file
and a separately allocated, empty, mode-0600 destination inside the
current private producer workspace. Encryption uses a non-interactive
GPG symmetric invocation with explicit `--cipher-algo AES256`,
`--batch`, `--pinentry-mode loopback`, and `--passphrase-fd 0`.
The passphrase is written by a Bash builtin through a private pipeline,
not embedded in argv. The GPG process receives an environment with
`GPG_PASSPHRASE` removed and uses a disposable mode-0700 GnuPG
home rather than a runner's long-lived keyring. GPG stdout and stderr
are suppressed, and an unsuccessful output is truncated. A tracing-enabled
shell or a passphrase containing a line break is rejected before the
secret is expanded. Likewise, AWS CLI child processes have the
archive passphrase removed from their inherited environment.

This local helper is available for preparation of an approved plaintext
archive, but **does not publish** it or decide which object should be
uploaded. The existing S3 `put` primitive remains isolated from the
public issuer. Publication remains subject to separate orchestration,
cryptographic verification, state-only ARI policy, and multi-object
failure handling under ADR-022.

### Encrypted retrieval

The typed S3 retrieval flow chooses the object keys before any remote
request. Upon a successful GetObject of an encrypted archive, GPG
decrypts it to a second, owner-private mode-0600 temporary file. All
existing common-account, lineage, renewal-option, and path validators
consume the decrypted plaintext bytes and apply **exactly the same**
archive rules as unencrypted mode. Both downloaded ciphertext and local
plaintext are discarded with the private retrieval stage. The
decryption helper never installs active Certbot state.

On confirmed selected-mode `NoSuchKey`, the S3 retrieval boundary
performs a *presence-only* GetObject check for the exact opposite-mode
object key. It does **not** process those alternate bytes or fall back
to that format:

- If the alternate object exists, return status 65: a format mismatch
  that requires explicit operator-guided migration.
- If both mode-specific keys are explicitly confirmed absent, the
  existing ADR-039 missing-object contract applies.
- If the alternate check fails ambiguously, return the typed fatal
  retrieval status (69 or a local error) rather than guessing.
- If the selected encrypted key exists but GPG fails (including wrong
  passphrase, corruption, or unsupported ciphertext), return status 65
  and never treat it as a missing or first-run archive.

A common archive must remain present and usable whenever any selected
lineage is present. Inconsistent common/domain state never triggers
replacement ACME account registration.

## Context and constraints

The persistent split-state common archive is the portable authority for
ACME account identity across independent Jenkins, GitHub Actions, and
EC2 workspaces. It contains sensitive account-key material. Individual
lineage archives also contain TLS private keys. ADR-021 already permits
symmetric encryption and prohibits transparent cross-mode fallback.
ADR-039 established typed S3 object retrieval, and ADR-040 established
non-activating validation of the complete retrieved collection.
These decisions permit encryption and decryption as a strictly local
transformation before storage publication and after storage download,
without changing the archive member layout.

The first release supports only the bundled S3 and Route53 providers.
This change does not broaden the runtime plugin or external-tooling
contract beyond requiring GPG for encrypted mode. The CI test job
installs GnuPG; plaintext operation does not require it.

## Assumptions

- The operator supplies the same high-entropy GPG passphrase independently
  to every runner managing an encrypted collection, without recording
  it in build logs or tracked repository files.
- The workspace and archive input have owner-private permissions and
  no attacker sharing the operating-system identity replaces staged
  files during a transformation.
- GPG's symmetric ciphertext integrity checks apply to the supported
  encrypted output; symmetric possession of a passphrase is *not*
  proof of the publisher's identity.
- The selected `GPG_PASSPHRASE` value is immutable during one request.
  A caller that mutates environment variables mid-run violates this
  assumption and must not be treated as a supported producer.
- A returned ciphertext can be subject to tampering, and a malicious
  but decryptable plaintext archive is still untrusted tar input.
- The S3 backend remains sequential, and independent writers remain
  externally serialized under ADR-022.

## Considered alternatives

Automatically fall back to plaintext when encrypted lookup or decryption
fails was rejected because it permits an unintended downgrade and
silent format migration. Attempting all available formats and selecting
whichever decrypts was rejected for the same reason. Passing a passphrase
on a GPG command line was rejected because process arguments can be
observed by other users and logged by tracing. Reusing the user's
persistent GnuPG home was rejected to avoid mixing operator keyring
state into an ephemeral producer. Using an arbitrary GPG recipient,
plaintext in-object metadata, or AWS-managed encryption as a substitute
was rejected by ADR-021's selected symmetric mode. Enabling S3 uploads
within this step was rejected because publication ordering, recovery,
and full certificate integrity gates remain incomplete.

## Promises and non-promises

For successful private GPG operations, output is mode-0600, nonempty,
and confined to the producer workspace. No passphrase appears in
generated GPG argv, in the AWS CLI environment, or in this module's
diagnostics. A configured passphrase never triggers plaintext retrieval
as a successful fallback. Raw S3 ciphertext is never evaluated as tar.
Staged plaintext is discarded after the existing full state assessment.

The implementation does not guarantee secure deletion from swap,
filesystem snapshots, runner crash dumps, or physical flash storage.
Environment variables can be inspected by privileged users of a CI
host; a host compromise is outside this boundary. GPG encryption does
not authenticate the original publisher, prove ACME registration, or
replace storage-level IAM protections. No supported producer yet
uploads objects, and production Certbot issuance remains disabled.
An ordinary request continues to exit 69.

## Compatibility, migration, and verification

Plaintext mode keeps the original `.tar.gz` keys and existing
consumers. Encrypted mode adds `.enc` without changing tar member
paths or domain extractability after decryption. Neither a new nor a
partially migrated collection may be silently interpreted as empty
state. Operators must perform a supervised, reversible whole-collection
migration with all writers stopped. The maintained manual procedure
is documented in `doc/encryption-migration.md`.

Bats tests against all three executable artifact flavors must prove
round-trip private encryption/decryption, wrong-passphrase and corrupted
ciphertext refusal, malformed destination and tracing rejection,
two-lineage encrypted restoration across new workspaces, absent selected
lineages, isolated staging namespaces, mixed-mode rejection, and no
accidental AWS inheritance of the secret. The other existing S3
absence/error tests must continue to pass in plaintext mode.

Before release, real S3 and intended S3-compatible storage must be
tested with scoped nonproduction credentials. The blocked public
issuer, real Let's Encrypt staging account reuse, renewal/SAN changes,
cryptographic publication gate, and multi-object recovery plan remain
separate acceptance requirements.

## Related decisions

ADR-019 defines the split-state archives; ADR-021 controls symmetric
encryption and manual migration; ADR-022 governs serialization and
publication; ADR-028 protects shared ACME account state; ADR-030
isolates production and staging object names; ADR-037 restricts active
import; ADR-039 classifies S3 retrieval; and ADR-040 composes remote
retrieval with read-only validation.
