# certbotbot Implementation Handoff

Date: 2026-10-15

## Repository and state

- Repository: https://github.com/wesley-dean/certbotbot
- Origin: `template-bash`; initial repository contains starter executable, noop plugin, Makefile, tests, ADRs 000-017, and existing GitHub Pages `.github/workflows/static.yml`.
- Documentation-pass branch: `agent/docs-architecture-standards-v2.1.0` (subject to review and merge).
- Coding standards target: `coding_standards@v2.1.0`, verified GitHub release asset digest `ee04401441a3206d5cdc2bdc2e6d5130ff278ddc1ecd641f1c01843aa0666020`.
- Documentation-pass scope: governing docs and Pages workflow maintenance only.  The original starter Bash CLI is not the certbotbot implementation.
- First implementation step: after documentation PR merge, re-establish default-branch baseline, update dependency manifest/Makefile and build a bounded CLI skeleton; use small reviewable PRs.

## Accepted decisions

Read `doc/adr/ADR-018` through `ADR-024`, their summaries in `doc/decisions.md`, and `doc/specification.md` before modifying source.  Inherited ADRs remain in effect unless explicitly refined by a project-specific decision.

1. One certificate per input line.  The first hostname identifies lineage and archive, ignoring a leading `*.`.  Always request that apex and wildcard; other SANs are literal.  The complete SAN set is authoritative.
2. Only requested certificates are considered; omitted lineages are not renewed or deleted.
3. Certbot decides renewal timing and supplies DNS-01.  The first provider is Route53; HTTP-01 is excluded.
4. Producer stores one shared account archive plus independently composable per-certificate archives.  Each domain archive contains Certbot lineage and pre-generated combined PEM outputs.
5. Consumers only download chosen domain archives; they do not need the common archive, Certbot, or the producer CLI.  Consumers own post-install scripts and reloads.
6. Symmetric GPG encryption is optional, enabled by nonempty `GPG_PASSPHRASE`, uses AES-256, adds `.enc`, and never silently falls back.  Migration is manual and documented.
7. Storage provider is S3 with configurable endpoint for S3-compatible services including MinIO.  One DNS and one storage backend ship initially.  Source discovery is build-time, and every artifact includes the reviewed implementations.  No public plugin installation contract.
8. Execution is sequential and locally serialized.  Platform concurrency guards exist; no cross-platform lock exists in v1.  Operationally, only one independent writer may manage a collection.  Storage-level locking is backlog work.
9. Native downloadable Bash artifact is first-class; optional Docker/Jenkins/GitHub Actions wrappers must call the same code.
10. Pinned, checksum-verified bashdeps bootstraps direct from Make; manifest owns bash-doxygen, mktext, Bash-Minifier, adrctl, and bashlog.

## Names and shapes

```text
common-latest.tar.gz[.enc]
foo.com-latest.tar.gz[.enc]
bar.com-latest.tar.gz[.enc]

dist/certbotbot.dev.bash
dist/certbotbot.bash
dist/certbotbot.min.bash
dist/certbotbot.dev.bash.sha256
dist/certbotbot.bash.sha256
dist/certbotbot.min.bash.sha256

examples/Jenkinsfile
examples/certbotbot.yml
.github/workflows/static.yml
```

Within `foo.com-latest.tar.gz`, relative `archive/foo.com/`, `live/foo.com/`, `renewal/foo.com.conf`, and `combined/foo.com.pem` are required.  `live/foo.com/combined.pem` must also be generated.  The combined PEM concatenates fullchain then private key.  The live symlinks must resolve after extraction.

## High-risk implementation boundaries

- GPG passphrases, AWS credentials, ACME account keys, and TLS private keys must not be logged.
- Certbot lineage symlinks and restored tar members must be validated before trusting local state.
- S3 `NoSuchKey` differs from denied access, wrong region, bad endpoint, or connection failure.
- Do not publish one object simply because earlier local processing succeeded; verify every selected certificate first.
- Publication of multiple objects is not atomic; preserve previous versions and document recovery.
- A wildcard-only first domain such as `*.foo.com` maps to lineage `foo.com`, covering both `foo.com` and `*.foo.com`.
- The absence of `GPG_PASSPHRASE` deliberately selects plaintext mode, even though plaintext contains private keys.
- No arbitrary code-loading or plugin discovery at consumer runtime.
- A developer may run native, Jenkins, GitHub Actions, or Docker workflows; these workflows cannot independently guarantee cross-platform exclusion.

## Build expectations

Retain the template Make lifecycle and existing Bash 4.3 runtime baseline unless a reviewed ADR explicitly raises it.  The build must be offline once dependencies are prepared and must produce three semantically equivalent, independently executable release artifacts.  Check the project coding standards; they are a separate managed snapshot and not bashdeps manifest entries.

## Implementation phases and evidence

Use `doc/development-plan.md` as the ordered plan.  Phase 1 is build/dependency adaptation, Phase 2 parsing/registry with mocks, Phase 3 Certbot/Route53, Phase 4 composable S3 archives, Phase 5 optional GPG, Phase 6 CI/Docker/Pages integration, and Phase 7 production-ready testing and release.  Test negative conditions and non-promises explicitly.  Use Let's Encrypt staging to validate issuance without relying on production rate limits.

## Remaining technical choices to resolve during implementation

- Exact CLI option for a certificate-list file and stable provider-selection variable names.
- Pinning of released mktext and bashlog artifacts and whether the distribution embeds them by concatenation or validated vendored source.
- Certbot version/flags for SAN removal and renewal no-op behavior under current Certbot releases.
- Historical archive naming and mktext variable substitutions once archives beyond `*-latest` are enabled.
- Minimum supported AWS CLI/GPG/Certbot versions and MinIO integration test matrix.
- S3 object-version recovery protocol after a partial multi-object publish.

These are bounded implementation design points, not invitations to change agreed product behavior without an ADR.

## Phase 1 build foundation status

Phase 1 is proposed through `agent/build/certbotbot-build-foundation`.  It changes the default project/build identity, enables future DNS/storage module discovery paths in Make, adds pinned mktext and bashlog release artifacts to the bashdeps manifest, updates scaffold metadata and tests, and gates automatic releases behind `CERTBOTBOT_RELEASE_ENABLED=true`.  It does not yet embed the new runtime libraries, remove the starter noop implementation, define provider interfaces, or perform ACME/S3 operations.  Do not enable automatic releases until the functional CLI and release validation are complete.

## Phase 2 initial CLI/parser branch

The next proposal `agent/feat/phase2-cli-provider-scaffolding` replaces the temporary starter/noop interface with a fail-closed `certbotbot` preflight.  It implements explicit positional, file, and multiline environment input; apex-plus-wildcard normalization and literal secondary SANs; duplicate lineage rejection; a typed, built-in registry; and statically included `route53` and `s3` placeholder modules.  `--validate` emits tab-separated normalized lineage/SAN records without touching Certbot, AWS, or storage.  Normal issuance requests **always fail 69** until Phase 3/4 are implemented.  Bashlog is embedded from its pinned bashdeps-managed release; mktext remains available as a prepared dependency for later archive templating.

Remaining Phase 2 obligations include designing and implementing native host-local serialization for real operations and argument-preserving mocked external boundary tests.  Those should be completed together with the first actual external-command operations rather than introducing misleading locks around a non-operational scaffold.

## Completion checklist

- Documentation PR reviewed/merged; standards snapshot verified.
- No stale `template-bash` behavior or links in product-facing source and documentation.
- Required dependencies pinned/verified and runtime source assembly deterministic.
- All three artifact variants tested, including failure and integration tests.
- Consumer domain archives verified by extracting multiple separate archives into one TLS tree without Certbot or common archive.
- GitHub Pages documentation generated from maintained ADR corpus.
- Threat model updated to reflect evidence and residual risks prior to release.


## Phase 2B local lock and command boundary PR

The next focused change (`agent/feat/local-lock-and-command-boundaries`)
adds `lib/locking.bash` and `lib/external-commands.bash` to the explicit
Make source order.  The lock is nonblocking, uses the storage bucket and
endpoint for its stable key, and requires an owned private lock directory.
Local contention returns status 75; invalid lock paths or permissions fail
without proceeding.  This is advisory serialization only for cooperating
processes sharing a host and user identity.  The DNS and storage modules
remain statically bundled, and each now exposes narrow, mock-testable
subprocess boundaries: Route53 has a read-only `certbot --version` probe
and fixed DNS challenge options; S3 supports authenticated `s3api get-object`
and `put-object` calls with optional `S3_ENDPOINT_URL`.  Unexpected
operations, unsafe object keys, and endpoint syntax are rejected.

These internal functions can be exercised in isolation under PATH-injected
fakes.  They remain **unreachable from normal issuance execution** until the
renewal, state-restore, archive-validation, and publication steps exist.
The public `--validate` command continues to avoid cloud/Certbot calls, and
a normal issuance request continues to exit 69.  Staged S3 get/put calls
do not yet classify 404 versus authorization/transport errors, and failed
downloads must never be trusted; Phase 4 owns that state machine.
The production workflow must acquire and release the local lock with
appropriate traps.  Storage-backed locking remains backlog work.

## Phase 3A Certbot/Route53 command contract

The next small PR, `agent/feat/certbot-route53-command-contract`, adds the internal Route53 `issue` dispatch with fixed Certbot DNS-01 options, an explicit lineage name, all SANs as individual `-d` arguments, and owned private config/work/log directories.  It uses `--keep-until-expiring` and `--renew-with-new-domains` rather than forcing every renewal.  Input failures and account configuration that the adapter cannot safely honor, including `REGISTER_ACCOUNT=false` without confirmed restored-account selection, fail before contacting Certbot.  Additional fake-Certbot Bats tests cover argv, missing SANs, permissions, and exit-status propagation.

ADR-025 captures the unresolved portability requirement for Certbot's path-bearing renewal configurations.  The production entrypoint remains deliberately fail-closed with status 69, even after this command adapter is merged.  The next phase must securely restore state, select/reuse the ACME account, ensure renewal-config path portability across producer workspaces, and validate combined outputs before enabling public issuance.  Do not enable GitHub release publication yet.

## Phase 3B private workspace and PEM assembly

The next proposed PR `agent/feat/private-workspace-and-pem-assembly` builds
an isolated, owner-private Certbot workspace and implements non-network PEM
assembly from already-existing Certbot lineage files.  It refuses unexpected
relative links, missing/unowned/nonregular archive targets, insecure private
key permissions, symlinked lineage directories, and preexisting combined PEM
symlinks.  `combined/<name>.pem` and `live/<name>/combined.pem` are both
generated as mode-0600 regular files.  Bats tests exercise positive two-domain
composition and negative filesystem cases across all three release flavors.
No raw archive extraction, GPG decryption, publication, or live issuance is
enabled; the normal entrypoint remains fail-closed at status 69.

A subsequent phase must select an archive parsing/extraction strategy that
resists traversal, symlink pivoting, hostile metadata, and unsupported tar
entry types.  Do not interpret the current local PEM link checks as a general
untrusted-archive safety validator.  Cryptographic certificate/private-key
matching and portable Certbot renewal metadata remain outstanding.\n
## Phase 4A domain archive manifest preflight

The PR proposed on `agent/feat/validate-domain-archive-layout` adds
`lib/archive-validate.bash` with a strict GNU tar verbose-manifest
allowlist for a *single* requested certificate lineage, plus hostile-tar
Bats tests and governing ADR-026.  It does not extract, decrypt, download,
upload, or enable issuance.  It rejects unknown member names, traversal,
hard links, special entries, duplicate members, invalid symlinks,
missing required files, unsafe key/combined PEM modes, and unbounded
declared file sizes/counts.  No guarantee of immunity to all compressed
stream denial-of-service attacks is made.

Next implementation work must add an independently reviewed safe extraction
strategy into an isolated, freshly owned staging directory, then verify the
resulting filesystem, cryptographic key/certificate relationships, and
Certbot renewal path portability.  The common account archive requires a
separate structural and secret-handling policy.  Avoid using the manifest
validator as a replacement for these gates.\n
## Phase 4B isolated archive restoration

The proposed branch `agent/feat/isolated-domain-archive-restoration`
introduces `lib/archive-restore.bash` and ADR-027.  A producer-owned
source archive is privately copied and validated before GNU tar extracts
it into a new, empty, mode-0700 staging tree.  GNU find enumerates the
resulting objects, and explicit lineage path/type/mode and PEM-link checks
confirm the real filesystem matches the expected archive contract.
Restoration does not overwrite or join the active Certbot config tree.
A caller must explicitly dispose of accepted staging.

Next: define a safe common ACME account archive contract, verify renewal
metadata portability, test cryptographic certificate/private-key matching,
and only then design the controlled merger into active workspace and
eventual publishing.  No production issuance or object publishing path
has been activated.

## Phase 4C common ACME account archive staging

The proposed PR on `agent/feat/isolated-acme-account-state` adds a separate
strict account-only archive validator and isolated restorer.  It recognizes
Let's Encrypt ACME v2 production/staging account paths containing complete
`meta.json`, `regr.json`, and `private_key.json` triplets.  It refuses
links, unknown config, renewal hooks, duplicate paths, incomplete
registrations, and permissive key storage.  The producer-private copy
is validated before extraction and filesystem-checked afterward.
Stage disposal and negative tests are included.  These changes establish
ADR-028 without connecting account state to the public issuer.

The following production gates remain: actual Certbot account selection,
renewal-config portability, certificate/key cryptographic matching,
integration into active config, GPG encryption/decryption, S3 missing-object
classification, publication sequencing, and live staging issuance.
Do not enable the release gate.

## Fresh-run producer portability acceptance

The common archive exists to make ACME account identity portable between
ephemeral, unrelated producer hosts.  Domain archives carry separate
lineage history.  No machine-local Certbot registration or runner cache
may be a necessary dependency for a later run.  ADR-028 and the product
specification require a three-workspace test of issuance, account reuse,
no-op renewal, and later SAN change or due renewal, with the previous
workspace destroyed between runs.  If additional Certbot shared state
proves necessary, the account-only archive policy must be amended under
review.  Independent writers must remain externally serialized until
storage-backed locking is available.

## Certificate-testing and CA-environment backlog (issues #11/#12)

Issue #12 defines a shipped cryptographic verification gate prior to
object publication, not merely CI testing.  ADR-029 introduces a
standalone OpenSSL-based validator and tests for certificate/key match,
trusted chain, current validity, and exact combined PEMs.  Its presence
is **not** evidence of a working issuer until it is called on the
publication path and a negative S3-preservation test passes.

Issue #11 requests production by default with a deliberate Let's Encrypt
staging toggle.  Staging account identities and certificate objects MUST
not collide with production objects of the same lineage.  A reviewable
follow-up must define mode-specific storage namespaces and trust anchors
before production use.  Do not conflate valid staging certificates with
certificates trusted by production clients.

## Issue #11 staging environment implementation

The proposed `agent/feat/letsencrypt-staging-mode` PR adds
`lib/acme-environment.bash`, CLI `--staging` and
`--acme-environment production|staging`, and
`ACME_ENVIRONMENT` as a CI-friendly configuration input.  The Route53
internal adapter explicitly selects one of two fixed Let's Encrypt URLs.
Production object names remain backward compatible; staging uses
`staging/`-prefixed common and domain keys, with cross-mode keys rejected
by the S3 provider.  ADR-030 governs these contracts and the limitations
of the first implementation.  Tests use fake Certbot and AWS executables
across the three release flavors.

The issuer remains disabled.  The next integration work must verify
restored account/renewal-server consistency, provide a controlled
staging CA bundle for ADR-029 certificate verification, and prove
continuity on independent ephemeral workers.  Staging certificates are
not production-trusted.  Do not enable automatic releases yet.

## Phase 4D account/lineage identity verification

The proposed `agent/feat/verify-restored-acme-environment` PR adds
`lib/state-identity.bash` and ADR-031.  It checks one restored
`renewal/<name>.conf` for unique `server`, `account`, and
`authenticator` values, then verifies the referenced private account
triplet under the selected production/staging authority.  It rejects
cross-environment renewal state, ambiguous identity, missing account
keys, unrecognized sections, and hook directives.  The change is
read-only and tests use synthetic restored state without network calls.

The unresolved release gates remain Certbot account selection and
registration status, renewal-config absolute path portability,
independent workspace integration, certificate SAN validation,
verification invocation before publication, S3 consistency, optional
GPG handling, and release preparation.  Do not enable issuance yet.

## Phase 4E isolated renewal path relocation candidate

The proposed `agent/feat/preview-portable-renewal-paths` PR adds
`lib/renewal-paths.bash`, Bats fixtures, and ADR-032.
The helper reuses the account identity guard from ADR-031, insists
that the five Certbot path-bearing renewal fields share exactly one
former absolute root and lineage, and emits a new private preview
for the current workspace.  It never modifies the archived source,
calls Certbot, or enables the public issuing path.
The preview must not be used as proof that renewal is portable.

Next: test real Certbot-generated config/lineage state across
independent workspace paths, actual account reuse, no-op renewal and
SAN change, without modifying production archives.  Make a new
governing decision before activating any preview in the issuer.

## Phase 4F read-only real Certbot compatibility

The proposed `agent/test/real-certbot-portability-smoke` PR adds
a credential-free GitHub Actions job with pinned Certbot 5.8.0.
The test creates short-lived local certificate fixtures, produces
and validates both archive types, relocates the renewal paths into
another private workspace, destroys the original workspace, and
requires actual Certbot's `certificates` command to list the
lineage.  It runs for every artifact flavor.  ADR-033 authorizes
this read-only **test-only** exception to ADR-032's non-activation rule.

Actual ACME renewal continuity is still unproven: test account JSON
is synthetic and no DNS challenge, renewal, SAN update, or S3 write
is performed.  Continue to fail closed on the normal public command
and leave the release gate disabled.

## Phase 4G credential-free no-op renewal smoke test

The proposed `agent/test/real-certbot-noop-renewal` PR extends
the real Certbot loader job with a second, local test-only operation:
run `certbot renew --cert-name example.com` against the
fully reconstructed lineage after deleting the previous runner.
A locally signed, 90-day certificate should be not due for renewal.
Python network connection APIs are intercepted, directory hooks
are disabled, and the test checks that no cert, key, or renewal config
certificate/key bytes or identity/path settings are changed.
Certbot can append ARI retry metadata, which must survive the local
archive repackaging test.  Certbot 5.8.0 may attempt an ARI DNS lookup even for
a non-due lineage; that DNS attempt is blocked and logged,
while unexpected connect operations fail.  The common account's synthetic key bytes are
preserved into the temporary Certbot config, but cannot authenticate
to Let's Encrypt.  ADR-034 authorizes only this CI use.

True ACME staging account registration, due renewal, SAN change, and
storage publication remain release-blocking.  Do not connect the
test-only import to the public issuer.

## Phase 4H three-run ARI state portability

The proposed `agent/test/three-run-portable-ari-continuity` PR extends
the credential-free Certbot 5.8.0 integration harness.  A creates
synthetic portable archives; B restores those, records a guarded
ARI metadata update during a real no-op decision, repackages its
domain archive, and deletes its workspace.  C restores A's common
archive and B's updated domain archive in another fresh private
workspace and verifies the ARI value, account/certificate/key byte
continuity, read-only Certbot loading, and another no-op decision.
ADR-035 documents the expanded test-only contract.  The public
issuer, live account registration, S3 publication, and release gate
remain untouched.

## Phase 4H exact certificate SAN identity

The proposed `agent/feat/verify-certificate-san-identity` PR adds
`certbotbot_crypto_verify_sans` to the existing OpenSSL verification
module, with independent Bats checks for exact requested DNS SANs,
case/order equivalence, unexpected or duplicate entries, missing
apex/wildcard, extra non-DNS SAN types, and unsafe lineage links.
ADR-036 requires the eventual issuer to invoke this **in addition**
to ADR-029's cryptographic chain/key/combined-PEM checks, against
the newly requested SAN set before any publication, including
state-only archive updates.

The helper does not enable the public issuer or S3 operations.  Real
ACME staging account reuse, due renewal, SAN changes, validated
state-only publishing, and distributed coordination remain unresolved
release gates.

## Phase 4I local archive-to-assessment preparation

The internal `certbotbot_import_assess_archives` helper composes the existing
common-account and single-lineage archive restorers with the ADR-037
non-activating assessment. It rejects any preexisting caller-owned staging
state, then checks privately restored filesystem state, the selected account,
and renewal path portability. Both staging trees and any path preview are
discarded even when validation fails. Tests use synthetic local tar archives
and cover success, damaged domain input, mismatched ACME environment, wrong
lineage, cleanup, and preservation of preexisting staged state across all
three standalone artifact flavors.

The helper does not populate the active Certbot configuration, authenticate
an account with Let's Encrypt, contact S3, or publish certificates. It handles
one lineage at a time; batch-wide assessment and eventual activation require
separate reviewed work, as does real account reuse and due renewal evidence.

## Phase 4I complete-batch non-activating assessment

The internal `certbotbot_import_assess_batch` helper now accepts an explicit
common archive, selected ACME environment, and one or more canonical
lineage/domain-archive pairs. It validates the complete pair list and rejects
duplicate lineage identities, repeated archive paths, missing inputs,
inconsistent ACME environment selection, and preexisting active configuration
or staged state before opening a tar archive.

The helper takes one mode-0600 private snapshot of the common archive and
reuses those exact bytes for every independent per-domain assessment. The
underlying archive-to-assessment helper validates, stages, and disposes each
lineage sequentially. Later failures preserve the active configuration and
leave no successful predecessor's staged state behind. The common snapshot
is discarded on success and failure.

This is not a persistent batch candidate, cryptographic certificate check,
or active importer. The selected lineage identities and paths are passed as
literal Bash arguments, without runtime plugin loading or shell evaluation.
Genuine staging ACME account reuse, due renewal, SAN changes, account JSON
verification, safe candidate assembly, and multi-object publication remain
release-blocking. This work does not enable Certbot issuance or S3 writes.

## Phase 4I: strict persisted renewal-option assessment (ADR-038)

The reviewed internal `certbotbot_renewal_policy_check` applies a narrowly
enumerated Certbot 5.8.0 Route53 renewal-file profile after the staged
account/lineage identity check and before the private renewal-path preview.
It rejects unexpected sections, duplicate fields, executable hooks,
unknown authenticators or plugin parameters, non-DNS challenge options,
unapproved paths, and unsupported renewal timing overrides.  A recognized
ARI-only retry timestamp is accepted, and the real-Certbot three-workspace
smoke test checks the accepted syntax after its no-op metadata update.

This is only static option validation against separately staged archives.
The module deliberately does not parse or authenticate account JSON,
invoke Certbot, install an active renewal file, or publish S3 objects.
There is no new runtime dependency.  The additional checks are exercised
for all three bundled artifacts with negative Bats tests.  Real Let's Encrypt
staging account registration and authenticated three-run portability remain
the next major release-blocking milestone.

## Typed S3 collection retrieval (ADR-039)

The internal `certbotbot_s3_stage_collection` operation now retrieves
`common-latest.tar.gz` and all selected lineage archives into owner-private
local temporary files, deriving production or staging keys exclusively from
the selected environment.  The caller receives an ordered path array and
presence flags.  A valid common archive with absent newly requested domain
objects is distinguishable from wholly empty storage; an orphaned domain
without shared account state fails closed.

Only a GetObject NoSuchKey service error is accepted as confirmed absence.
Authorization problems, generic 404 responses, transport failure, partial
downloads, and empty files are fatal.  No object bytes are extracted or
activated by the retrieval boundary; the separately reviewed archive and
renewal validators remain mandatory.  A caller must discard a successful
private S3 stage.  Real S3/MinIO interoperability and genuine ACME account
continuity remain future integration milestones.

## Phase 4K: assessed remote portable-state collections

The internal `certbotbot_state_assess_remote` composes the typed ADR-039 S3
retrieval with private common-account validation and batch-wide existing
lineage assessment. It retrieves all requested objects before opening
archives, validates the common account even for all-new lineages, and
rejects malformed or mismatched existing state before reporting missing
requested names. The result array is populated only on complete success
and must never be interpreted as permission to register an account.

No downloaded bytes remain staged after return. The active Certbot config
remains empty, and normal issuer requests continue to fail with status 69.
The mocked object-store tests use synthetic account material and do not
prove actual S3 endpoint behavior or Let's Encrypt account ownership.
Before activation, gather real staging account-reuse and renewal evidence
and approve the separate candidate installation/rollback ADR.
