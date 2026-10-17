# certbotbot

certbotbot is a planned standalone Bash tool for issuing and renewing Let's Encrypt TLS certificates through DNS-01 validation.  It restores shared ACME account state and separately managed certificate-lineage state from object storage, uses Certbot to obtain or renew only the requested certificates, generates combined PEM files, and publishes directly installable per-domain archives.  The current executable supports a deliberately side-effect-free `--validate` mode and statically bundled DNS/storage adapter registration.  **Certificate issuance and S3 persistence are not yet implemented**: a normal certificate request fails with status 69.  The automatic release workflow remains gated by the explicit repository variable `CERTBOTBOT_RELEASE_ENABLED=true`.  See [implementation plan](doc/development-plan.md) and [handoff](doc/handoff.md).

## Portable producer state

The common archive is the portable, authoritative ACME account state, not
an optional backup.  A future working issuer must start from an empty
filesystem on Jenkins, GitHub Actions, or EC2 and function from the
shared common and requested domain archives plus its normal external
configuration and credentials.  The preceding runner's local Certbot files
must never be necessary.  These runners may operate **sequentially**;
cross-platform concurrent writers are unsupported until distributed
storage locking is implemented.

This is an end-to-end release requirement, **not yet implemented** by
the current archive staging helpers.

## Real Certbot read-only portability smoke test

A separate CI workflow installs pinned Certbot 5.8.0 and exercises its
local `certificates` command on the same synthetic lineage before and
after archive reconstruction and renewal-path relocation.  The previous
workspace is deleted before the second inspection, and both workspace
content and key-byte continuity are checked.  The workflow uses no
ACME/DNS/cloud credentials and runs across all three standalone scripts.

The test is **limited to reading an imported lineage**.  Its account JSON
is synthetic, the leaf certificate is self-signed, and it does not test
Certbot account registration, a no-op renewal, SAN replacement, or
deployment.  ADR-033 permits test-only installation of the preview;
the product still cannot activate issuance or publication.

## Certbot no-op renewal across independent workspaces

An opt-in, credential-free CI test reconstructs a domain archive and a
synthetic common-account archive on a completely new workspace after
deleting the predecessor.  It runs real Certbot 5.8.0's selected-lineage
`renew` command for a freshly generated 90-day certificate that is
not due for renewal, and verifies an explicit no-op decision and
unchanged certificate/key bytes and identity/path settings.  Certbot
may legitimately append an ARI retry-after scheduling field without
renewing the certificate; the test validates and locally repacks it.

The harness blocks Python socket APIs.  Certbot 5.8.0 may attempt an
ACME Renewal Information (ARI) DNS lookup even for a not-due lineage;
the test permits that blocked lookup, but rejects unexpected socket calls.  It does not contain real ACME account credentials, send
a DNS challenge, or prove an actual due renewal.  This is a test-only
exception documented in ADR-034; normal public issuance stays disabled.

## Three-workspace ARI continuity test

The real-Certbot integration suite now also models a **third independent
producer run**.  Runner A creates the synthetic account and lineage,
runner B restores those archives and makes a real Certbot no-renewal
decision, and runner C restores B's updated domain archive after
both preceding workspaces have been destroyed.  Certbot must still
recognize the lineage and decide not to renew.  The common account
key, certificate, and private key must remain identical, and any
accepted ARI scheduling state must survive the second archival cycle.

The test remains credential-free and test-only.  It does not prove
real ACME renewal, S3 persistence, SAN updates, or execution across
different cloud providers.  See ADR-035.


## Certificate inputs

A single invocation may accept `certbotbot.bash foo.com www.foo.com` or `certbotbot.bash "foo.com www.foo.com"`.  A multi-line `CERTIFICATES` input describes one certificate per line:

```text
foo.com www.foo.com
bar.com mail.bar.com
```

The first hostname supplies a certificate name.  Both its apex and `*.` wildcard are always requested, even when the first token is wildcard-only.  Remaining SANs are literal.  Omitted certificates are left alone; the tool will not delete or renew unrelated lineages.  Certbot decides when unchanged certificates need renewal; the wrapper has no fixed expiration threshold.

## Production and staging selection (issue #11)

Production is the default.  Use `--staging` or
`--acme-environment staging`, or set `ACME_ENVIRONMENT=staging`, to
select the fixed Let's Encrypt staging ACME API.  The explicit
`--acme-environment production` option selects production.  Invalid
modes or contradictory CLI flags fail closed.

Staging uses separate S3 object keys in the same configured bucket:
`staging/common-latest.tar.gz` and
`staging/<name>-latest.tar.gz` (including `.enc` equivalents).
Production retains existing unprefixed object keys for compatibility.
The S3 adapter refuses cross-mode keys.  Operators may also enforce
separation through IAM or different buckets.

**Staging-issued certificates are not trusted by ordinary browsers or
clients.**  The future verification workflow must use a dedicated staging
CA bundle; never add test roots to an ordinary production trust store.
Mode selection is now present, but actual issuance and publication
remain disabled pending integration and security gates.  See ADR-030.


## Certificate request preflight (Phase 2)

Use `--validate` to normalize and inspect certificate groups without contacting Certbot, AWS, or an ACME server:

```text
certbotbot.bash --validate foo.com www.foo.com
foo.com    foo.com *.foo.com www.foo.com
```

The real output is tab-separated: the first field is the lineage identity, and the second contains space-separated SANs.  `CERTIFICATES` may contain multiple physical lines, or `--certificates-file FILE` may read them from a local file.  Positional arguments, a file, and the environment input are mutually exclusive.  Blank physical lines are ignored, but an entirely empty request is rejected.  Provider identifiers may be selected with `--dns-backend` and `--storage-backend`, or `DNS_BACKEND`/`STORAGE_BACKEND`; only `route53` and `s3` are registered in this version.

Preflight verifies input syntax and backend names only.  It is **not** a dry-run Certbot renewal and does not verify credentials, hosted zones, storage availability, or certificate validity.

## Internal execution seams (Phase 2B)

The build includes internal, mock-testable boundaries for `certbot --version`,
S3-compatible object get/put, and an advisory, per-host `flock` lock keyed by
the selected bucket and storage endpoint.  The S3 wrappers use separate
arguments (never `eval`) and reject unexpected object keys and endpoint
syntax.  The lock directory is private to its owning user and may be set with
`CERTBOTBOT_LOCK_DIR`; by default it is in the user's runtime/state area.

Route53 now also has an internal, mock-testable `certonly` command adapter with named lineages, separate SAN arguments, and DNS-only challenge selection.  This includes Certbot renewal-aware flags but does not yet solve persistent renewal-configuration path portability.  These operations are **not yet connected to normal certificate issuance**.
`certbotbot.bash foo.com` still exits 69 without any remote side effects.
The first implementation release must acquire a lock before reading remote
state, validate every restored archive, and publish only after all requested
certificates succeed.  A local lock does not prevent concurrent producers on
different hosts or CI platforms.

## Private workspace and combined PEM preparation (Phase 3B)

The source now includes an internal private-workspace allocator and a local
Certbot lineage validator/combined-PEM assembler.  A producer workspace has
private `config/`, `work/`, and `logs/` directories.  The PEM assembler
requires all four standard `live/<name>/` links to point to the expected
`archive/<name>/` versioned files and requires private-key permissions that
exclude group/other access.  It writes regular 0600 combined PEM files at
`combined/<name>.pem` and `live/<name>/combined.pem`.

These are internal, testable building blocks.  No live certificate operations
are yet callable through ordinary issuance, and this module does **not**
extract archives, verify cryptographic key-to-certificate matching, or repair
Certbot renewal configuration paths.  Two local output renames are individually
atomic, not a two-file transaction.  The producer must complete all later
checks before remote publication.

## Domain archive manifest validation (Phase 4A)

The internal domain archive validator now inspects the GNU tar manifest
without extracting any contents.  It accepts only the requested lineage's
versioned PEMs, four expected Certbot live symlinks, renewal configuration,
and both combined PEM files.  Unexpected paths, traversal, duplicate
members, special file types, missing symlink targets, and unsafe private-key
modes are rejected.  The validator is covered by hostile-archive tests.

**This does not yet implement archive restoration.**  Preflight listing
does not prove that extraction, renewal metadata, or certificate/key
cryptographic contents are safe.  No public issuance or S3 publication
is enabled.  See ADR-026 for this explicit security boundary.

## Isolated domain restoration (Phase 4B)

An internal helper now copies one domain archive into the active producer's
private workspace, invokes the strict domain manifest validator, and
extracts that copy into a *new*, empty, 0700 staging directory.  It then
independently enumerates the extracted filesystem, checks actual file types
and paths, verifies expected relative Certbot live links, and confirms
private-key-bearing file permissions.  A rejected archive leaves the active
Certbot configuration untouched.  Successful staging must be explicitly
discarded after use.

This is not yet an operational restoration pipeline.  It does **not**
merge staging into the producer's active config, interpret or normalize
renewal configuration, restore the common ACME account archive, verify
certificate/private-key cryptographic matching, or publish any object.
The public issuing command remains disabled.  See ADR-027.

## Shared ACME account archive staging (Phase 4C)

The internal common-state adapter recognizes Certbot's Let's Encrypt ACME
v2 account directories and their three required JSON files.  It rejects
unknown configuration, renewal hooks, symlinks, unexpected entries, missing
account keys, and insecure file modes.  It takes a private copy, validates
the tar contents, extracts into an isolated staging directory, and checks
the real extracted filesystem again.  Accepted staging must be explicitly
discarded after use.

This is not yet an operational account restore.  It neither parses account
JSON contents nor selects an account with Certbot.  It does not merge common
state into active configuration, enable ACME issuance, or upload storage
objects.  No consumer needs the common archive.  See ADR-028.

## Cryptographic certificate validation (pre-publication gate)

The standalone artifact now contains an internal OpenSSL-based certificate
validator.  It checks that the leaf certificate is currently valid, its
private key is consistent and matches the leaf public key, its chain
verifies for TLS server use against trusted roots, and both combined PEM
files contain exactly the expected fullchain-plus-private-key bytes.
This is the explicit cryptographic test requested in [issue #12](https://github.com/wesley-dean/certbotbot/issues/12).
An optional CA bundle supports controlled staging-root tests; ordinary
production verification uses OpenSSL's configured trust roots.

The validator is not yet wired into publication (which remains disabled).
It does not prove SAN correspondence, correct web-server configuration,
or other service-specific usability.  OpenSSL is a native runtime
prerequisite for this eventual publication gate.  See ADR-029.


## Exact certificate DNS SAN verification (Phase 4H)

The standalone artifacts include an additional internal certificate identity
validator.  Given a normalized requested lineage and its SANs, it reads
the actual X.509 leaf certificate and requires exactly those DNS SANs,
with no missing, extra, duplicate, or non-DNS identities.  DNS name
case and certificate ordering are ignored; the apex and leading
wildcard are both mandatory.  This check complements the existing
OpenSSL chain/private-key/combined-PEM validation (ADR-029).

This is not yet wired into the public issuer or storage publisher,
which remain disabled.  Before release, the producer must call **both**
checks on every lineage after Certbot processing and before writing
any archive, including state-only updates.  See ADR-036.

## Cross-environment account/lineage consistency (Phase 4D)

A read-only internal check now inspects restored Certbot renewal metadata
and confirms that it references the selected Let's Encrypt production or
staging URL, a `dns-route53` authenticator, and a matching complete
account directory under that same authority.  Duplicate identity fields,
missing account files, symlinked secrets, and hook directives are rejected.

This is **not** full Certbot account selection or renewal-state portability.
It does not interpret account JSON, repair absolute `archive_dir` or
`live/` references, or execute Certbot.  No production issuance or
publishing becomes available from this change.  See ADR-031.


## Renewal path portability preview (Phase 4E)

An internal helper can now validate the five absolute paths in a staged
Certbot renewal configuration and emit an owner-private copy rebased onto
the current producer's config directory.  It first requires the
restored account/environment identity check and a consistent original
lineage root.  An inconsistent or dangerous legacy path fails closed.
The original restored file remains unchanged, and the preview must be
explicitly discarded.

**This is not operational renewal migration.**  The preview is never
installed into active Certbot configuration or passed to Certbot.
Real Certbot no-op renewal and SAN-change tests across independent
workspaces are mandatory before choosing this as the release strategy.
See ADR-032 and ADR-025.


## Archive format and deployment separation

The producer persists `common-latest.tar.gz` (shared account state) and `<name>-latest.tar.gz` for each certificate lineage.  Domain archives contain complete relative Certbot lineage paths, including `live/` symlinks, `archive/` versions, `renewal/` metadata, and pre-generated `combined/<name>.pem` and `live/<name>/combined.pem` (fullchain then private key).

Deployment hosts need only the selected domain archives.  They extract trusted, validated archives under `/etc/letsencrypt` and run their own service post-install scripts/reloads.  The common archive, Certbot, ACME account, and certbotbot executable are **not required** on those hosts.  Live files require no post-extraction rewriting.

With a nonempty `GPG_PASSPHRASE`, all common and domain objects use GPG symmetric AES-256 and the `.tar.gz.enc` suffix.  Without one, objects remain plaintext `.tar.gz`.  Both modes are explicit, with no silent fallback.  [The full specification](doc/specification.md) defines the intended validation and fail-closed semantics.

## Initial backends and execution

Only Route53 DNS-01 authentication and S3-compatible object storage are planned in the first release.  An optional `S3_ENDPOINT_URL` supports endpoints such as MinIO, subject to integration testing.  Backend source files are discoverable at **build time** and bundled into all three release artifacts.  No arbitrary consumer runtime plugins are supported.

Native standalone execution is first-class.  Optional Jenkins, GitHub Actions, and Docker runners call the same Bash executable.  Examples will live at `examples/Jenkinsfile` and `examples/certbotbot.yml`; the existing `.github/workflows/static.yml` generates reference documentation for GitHub Pages.  Independent writers must be serialized operationally until storage-backed distributed locking is implemented.

## Build and release contracts

GNU Make directly bootstraps one pinned verified `vendor/bashdeps.bash`.  `dependencies.txt` manages the released or pinned bash-doxygen, mktext, Bash-Minifier, adrctl, and bashlog dependencies.  `make deps` may fetch files, while `make deps-check`, `make build`, and `make docs` remain offline after dependency preparation.

The eventual release will contain:

```text
dist/certbotbot.dev.bash
dist/certbotbot.dev.bash.sha256
dist/certbotbot.bash
dist/certbotbot.bash.sha256
dist/certbotbot.min.bash
dist/certbotbot.min.bash.sha256
```

The `.dev.bash` version retains all maintained Doxygen comments; the ordinary artifact removes full-line comments; the minified artifact derives from the ordinary version.  All three must behave equivalently.

## Project governance

This project adopts the verified `coding_standards@v2.1.0` release from [wesley-dean/coding_standards](https://github.com/wesley-dean/coding_standards), materialized at [doc/standards](doc/standards/).  [`.codingstandardrc`](.codingstandardrc) records its immutable version and released archive digest.  Applicable imported standards govern maintained work unless an Accepted local ADR or explicit local policy refines them.  Never edit imported standards locally.

Start with [AGENTS.md](AGENTS.md), [doc/decisions.md](doc/decisions.md), [doc/specification.md](doc/specification.md), [doc/threat-model.md](doc/threat-model.md), and [doc/handoff.md](doc/handoff.md).  The original template decisions remain in `doc/adr/` and project-specific decisions begin at ADR-018.

## Plaintext / GPG migration (planned operational procedure)

Suspend all writers and use a private, restrictive local working directory.  Download **all** affected common and domain archives from a consistent generation.  Convert each with interactive GPG: for plaintext-to-encrypted use `gpg --batch --yes --pinentry-mode loopback --symmetric --cipher-algo AES256 --output foo.com-latest.tar.gz.enc foo.com-latest.tar.gz`; for encrypted-to-plaintext use `gpg --batch --yes --pinentry-mode loopback --decrypt --output foo.com-latest.tar.gz foo.com-latest.tar.gz.enc`.  Verify the converted archive contents in a disposable directory before publishing them with the new suffix, update `GPG_PASSPHRASE` consistently in all producers/consumers, verify restoration, and remove old objects only after confirmation.  Bucket versioning is strongly recommended for recovery, but historical plaintext versions may remain retrievable and need separate retention/deletion controls.  Do not place passphrases in commands or logs.  This is a manual procedure, **not yet a released migration feature**.

## Safety and roadmap

The producer handles TLS and ACME private keys, cloud credentials, and archives containing sensitive materials.  Review [the STRIDE threat model](doc/threat-model.md) before implementation or production use.  The first release will not claim atomic multi-object publishing or cross-platform locking.  [The development plan](doc/development-plan.md) divides work into reviewable phases.  See [CONTRIBUTING.md](CONTRIBUTING.md) for project standards.

## Restored renewal-option safety gate

The internal, non-activating restore assessment now checks the *entire*
supported Certbot 5.8.0 Route53 renewal option profile against ADR-038.
Unknown settings, executable hooks, unrelated plugin options, and unexpected
renewal timing controls are refused; an explicitly documented ARI retry
field is accepted.  This supplements the separate account/environment
identity and historical-path checks.  It does **not** authenticate the
restored account against Let's Encrypt, install Certbot state, or enable
issuance.  Normal certificate requests continue to exit 69.

## Classified S3 state retrieval

An internal, non-activating S3 retrieval module now stages the common account
archive and selected domain archives in a private workspace.  It distinguishes
a confirmed missing GetObject key from denied or indeterminate reads and
refuses a restored lineage when its common account archive is missing.
A common archive may coexist with missing newly requested domain objects.
Staged bytes are **not** interpreted as trusted certificates or an
authenticated account until separate validation.  No public S3 restore or
issuance workflow is enabled yet; normal requests still return status 69.

## Non-activating remote collection assessment

An internal read-only operation now connects classified S3 retrieval with
the existing common-account and per-lineage archive validators. Every
present requested archive is assessed before any selected lineage is
reported missing, and the common account is checked even when all
requested lineages are new. Failures discard downloaded bytes and leave
the active configuration unchanged. The resulting missing-lineage
report is not permission to register an account or issue certificates.
Actual issuance and publishing remain unimplemented; normal certificate
requests continue to exit 69.

## Optional symmetric GPG archive mode

The internal storage preparation and read-only retrieval path now supports
ADR-021's optional GPG AES-256 mode. With nonempty
`GPG_PASSPHRASE`, it reads only `.tar.gz.enc` objects, decrypts them
into private temporary files, and applies the same common-account and
lineage validators as plaintext mode. Without a passphrase, it retains
the existing `.tar.gz` keys. An object found only under the opposite
suffix is treated as a configuration/migration error, not a fallback
or first-run certificate request. Decryption failures are fatal and
all local data are discarded on completion.

This remains internal, non-activating preparation. Certificate issuance
and S3 publishing are not enabled. Operators must migrate *entire*
collections under external writer serialization. See the
[manual migration guide](doc/encryption-migration.md) and
[ADR-041](doc/adr/ADR-041-encrypted-state-retrieval-and-preparation.md).

## Local publication candidate checks

The internal, non-publishing preparation path now builds a frozen
candidate collection only after *all* selected lineages pass isolated
archive/renewal inspection, X.509 chain verification, private-key
matching, combined PEM checks, and exact requested DNS SAN matching.
It selects fixed production/staging S3 keys and owner-private plaintext
or GPG AES-256 local bytes. A failure discards the complete candidate.
No object is uploaded, no certificate is issued, and the public
entrypoint remains disabled. See
[ADR-042](doc/adr/ADR-042-local-publication-candidate-gate.md).

## Read-only recovery checkpoints before publication

An internal recovery step now pairs a cryptographically verified
local publication candidate with the exact prior common and selected
domain bytes retrieved from its original S3 bucket and ACME
environment. It validates existing archive/account identity and
renewal policy, captures old objects and their SHA-256 digests, and
records confirmed-missing keys distinctly. Encrypted mode retains
**original ciphertext** alongside temporarily decrypted validation
bytes; no plaintext fallback occurs.

A private, local checkpoint does **not** protect against a runner
crash after future remote writes. Durable remote generations and
verified partial-write recovery remain necessary before a publisher
can be enabled. The current tool still performs no S3 writes and
normal certificate issuance still returns 69. See
[ADR-043](doc/adr/ADR-043-recoverable-s3-publication-checkpoint.md).

## Inactive example for real staging account portability evidence

The repository provides an **inactive example** at
[`examples/github-actions/real-staging-evidence.yml`](examples/github-actions/real-staging-evidence.yml)
and an independent integration harness at
`tests/integration/live-staging-portability.bash`. The example describes
four separate runners for genuine staging DNS-01 issuance, restored
account/no-op renewal, changed SANs, and final state verification.
**It is not installed under `.github/workflows/` and cannot be
invoked as a repository GitHub Action by merging this PR.**

An authorized operator may explicitly install the example in a
controlled repository after review and configure protected staging
environment approval, scoped Route53 OIDC, an explicit CA trust
anchor, a GPG secret, and manual consent. Only encrypted archive
state is handed between runners. The normal tests use credential-free
guards and do not make staging DNS/ACME calls. See
[the setup/runbook](doc/real-staging-evidence.md) and
[ADR-044](doc/adr/ADR-044-opt-in-real-acme-portability-evidence.md).
No real staging portability evidence exists until a separately
authorized complete run succeeds; issuance and S3 publication remain
disabled.

## Private, non-activating multi-lineage import candidate

An internal helper can now assemble a complete **inactive** private
Certbot-shaped candidate from a frozen common account archive and
multiple independently validated lineages. Each renewal file is
rebased to the candidate's private pathname, and any rejected
lineage causes the entire candidate to be discarded. The recorded
active Certbot configuration remains untouched, with no Certbot,
DNS, or S3 operations.

This is preparation-only behavior governed by
[ADR-045](doc/adr/ADR-045-nonactivating-multilineage-import-candidates.md).
It does not enable real account reuse or issuance, and ordinary
certificate requests continue to exit status 69.

## Read-only pre-publication recovery manifest

An internal, non-publishing planning helper pairs a fully verified
proposed S3 object collection with its validated previous-state
checkpoint. It creates an owner-private TSV manifest describing
common-first object keys, existence flags, exact prior/proposed
SHA-256 digests, and object sizes. The helper detects local
manifest or object-byte changes, and callers must explicitly
discard the plan.

This is an **ephemeral local inspection artifact**, not a durable
remote generation or an atomic S3 transaction. It does not enable
uploads, active Certbot import, certificate issuance, or releases.
See [ADR-046](doc/adr/ADR-046-local-prepublication-recovery-manifest.md).

## Durable, independently verifiable recovery snapshots

ADR-047 introduces a guarded **internal** backup operation that
preserves already verified previous account and domain archives to
write-once S3 recovery-generation keys, not to their stable
`*-latest` aliases. It requires a completed local proposal,
checkpoint, and manifest plus explicit
`CERTBOTBOT_RECOVERY_WRITE_CONFIRM=yes`. Stored old object bodies
are read back and checked; a recovery manifest is written last.
A fresh runner can verify a generation with its independently
recorded identifier and manifest checksum, without any prior
runner filesystem.

This operation **does write to S3 under the reserved recovery
prefix** when deliberately invoked. No public command invokes it,
and it neither issues certificates nor publishes latest aliases.
A remote snapshot does not provide distributed locking,
transactional multi-object writes, or automatic rollback. See
[ADR-047](doc/adr/ADR-047-durable-s3-recovery-generations.md).
The product issuance path still exits status 69.

## Pre-publication S3 drift detection

An internal read-only preflight can now recheck that the selected
common and domain `*-latest` objects still match the exact bytes
or confirmed absence captured in the prior validated S3 checkpoint.
It refuses changed, newly added, or removed objects, unexpected
cipher modes, and indeterminate retrieval failures. Successful
checks discard the private read staging and perform **no upload**.

A successful observation is not a lock or atomic cross-object
comparison; another runner may change the bucket after it
finishes. Independent writers remain externally serialized until
a governed conditional publication protocol exists. See
[ADR-048](doc/adr/ADR-048-remote-latest-drift-preflight.md).
Certificate issuance and latest-object writes remain disabled.

## Read-only conditional publication predicates

An internal ADR-049 helper obtains S3's own ETags for the selected
common/domain latest keys and verifies each ETag with a conditional
GET and exact previous-object checksum. Previously absent keys
receive an explicit absence predicate for a future
`If-None-Match: *` conditional PUT. No partial collection is
returned on failure.

This captures the conditional-write inputs a future publisher will
need, but makes **no remote changes**. ETags are opaque comparison
tokens, not generally content hashes, and may become stale at once.
There is still no distributed lock or multi-object atomic commit.
See [ADR-049](doc/adr/ADR-049-etag-bound-publication-conditions.md).
The normal issuer remains disabled.

## Guarded conditional S3 publication and recovery

ADR-050 adds a tightly gated **internal** latest-object writer and an
independent-runner rollback mechanism. The writer requires a complete
verified candidate and a durable remote backup whose generation identifier
and manifest digest have been retained by the operator. It uses S3
`If-Match` or `If-None-Match` conditional PUTs and verifies every
uploaded body before continuing. Ambiguous results leave a partial
publication requiring review, rather than attempting a blind rollback.

A fresh runner can verify the saved generation and restore a selected
collection in reverse order, after confirming that every current key
contains either the known old or proposed new bytes. A previously absent
key is conditionally deleted, without touching unrelated content.

**These internal operations can mutate S3 latest keys when explicitly
authorized, but the public command cannot invoke them.** Normal
certificate issuance remains disabled pending real Let's Encrypt staging
evidence, backend integration and acceptance of the active-state import
decision. The protocol does not provide an atomic multi-object transaction
or a cross-platform distributed lock.


## Opt-in real S3 interoperability and fresh-worker recovery tests

The repository now has an **explicitly authorized**, loopback-only real
S3-compatible test path under `make test-s3-interop`. A dedicated GitHub
Actions PR/manual end-to-end workflow provisions a disposable, digest-pinned
SeaweedFS instance with synthetic credentials (ADR-051); the Make target
continues to support a separately provisioned local service. It executes the actual internal
conditional-write, remote recovery-generation, and independent-runner
rollback functions for all three standalone artifacts. The test matrix
covers full replacement, partial replacement, first-run absence, simulated
unrelated writes, and an interrupted worker terminated by SIGKILL.
Credential-free refusal tests remain in the normal Bats suite.

This is test-only infrastructure: it does not enable the public certificate
issuer or prove real Let's Encrypt account continuity, real AWS S3 behavior,
a distributed lock, or active Certbot import. See the
[interop and recovery runbook](doc/s3-interoperability.md) for safeguards,
manual setup, and evidence limits.


## Real staging two-lineage portability evidence

The separately authorized, **inactive** staging test example now includes
an extra independent certificate lineage in addition to the existing
genuine issuance/no-op/SAN-change phases. It records the single shared
staging ACME account and packages two separately validated, encrypted
lineage archives before checking both under an **inactive** import
candidate on a fresh runner. This is preparation for ADR-037's live
two-lineage gate, not proof that staging credentials have been used
or permission to enable public issuance. See [ADR-053](doc/adr/ADR-053-two-real-lineage-staging-evidence.md)
and [the real staging runbook](doc/real-staging-evidence.md).


## Read-only remote-state to verified import candidate

ADR-054 connects the existing S3 state reader and multi-lineage import
candidate assembler. For a fully existing account/lineage collection,
it can retrieve encrypted or plaintext archives, reconstruct a
private inactive candidate, and verify all selected certificates
against an explicit CA and the exact requested SAN sets. This is
an **internal integration and testing capability only**. It cannot
register a new account, activate Certbot, issue or renew certificates,
or publish S3 aliases. See [ADR-054](doc/adr/ADR-054-remote-verified-inactive-candidate.md).


## Reviewable IAM setup for real ACME staging

The offline `scripts/staging-iam-policies.bash` helper renders
separate OIDC trust and restricted Route53 TXT permissions JSON for
the inactive six-runner staging evidence workflow. It never
accesses credentials or installs IAM/GitHub resources. See
[ADR-056](doc/adr/ADR-056-offline-staging-iam-policies.md) and
[the staging runbook](doc/real-staging-evidence.md). Real staging
still requires the explicitly authorized setup in
[Issue #46](https://github.com/wesley-dean/certbotbot/issues/46).
