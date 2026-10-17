# Architectural Decisions

This document is a concise map of certbotbot's inherited and project-specific Architecture Decision Records.
It is a discovery aid, not a substitute for the ADR corpus.  When a summary and a
governing ADR appear to conflict, read the ADR and surface the conflict rather
than silently choosing the shorter wording.

The reusable engineering posture behind these decisions is summarized separately
in [`doc/engineering-philosophy.md`](engineering-philosophy.md).  ADRs remain the
binding architectural record when a concrete decision exists.

## Accepted Decisions

### ADR-000: Capability Scope, Epistemic Honesty, and Separation of Concerns

Accuracy, explicit capability limits, evidence-oriented reasoning, separation of
concerns, and resistance to performative agreement are foundational project
constraints.  The template prefers truthful, reviewable boundaries over claims
made mainly to sound helpful or complete.

See [ADR-000](adr/ADR-000-capability-scope-and-epistemic-honesty.md).

### ADR-001: Documentation and Decision Hierarchy

ADRs preserve durable reasoning; `doc/decisions.md` summarizes current decisions;
`AGENTS.md` remains a concise operational map; specifications describe normative
public behavior when needed; Doxygen comments own implementation contracts; and
tests provide evidence without superseding architectural intent.

See [ADR-001](adr/ADR-001-documentation-and-decision-hierarchy.md).

### ADR-002: Bash Runtime and Portability Baseline

The starter targets Bash 4.3 or newer and avoids newer runtime features unless a
later decision intentionally raises the floor.  Portability should be revisited
when a newer Bash version materially improves correctness, security, readability,
or auditability rather than merely convenience.

See [ADR-002](adr/ADR-002-bash-runtime-and-portability-baseline.md).

### ADR-003: Make as the Canonical Orchestration Interface

GNU Make is the canonical local and CI orchestration surface for dependency
preparation, build, checks, formatting, tests, documentation, and cleanup.  Stable
Make targets keep developer and CI behavior aligned.

See [ADR-003](adr/ADR-003-make-as-canonical-orchestration-interface.md).

### ADR-004: Modular Source Assembly and Automatically Discovered Plugins

The starter demonstrates explicit core source ordering plus deterministic lexical
plugin discovery and runtime registration.  ADR-014 clarifies that the runtime
registry/noop model is executable starter behavior rather than a requirement that
every derived project must preserve.

See [ADR-004](adr/ADR-004-modular-source-and-plugin-discovery.md) and
[ADR-014](adr/ADR-014-modularity-as-maintenance-and-assembly-architecture.md).

### ADR-005: Dependency Management and Explicit Network Boundaries

bashdeps manages pinned repository dependencies such as scripts, libraries,
filters, and assets, while system packages remain outside bashdeps scope.  Network
acquisition is explicit: dependency synchronization may use the network, while
build and verification consume prepared state.

See [ADR-005](adr/ADR-005-dependency-management-and-network-boundaries.md).

### ADR-006: Three Release Artifact Flavors, Metadata, and Checksums

Builds produce development, ordinary, and minified standalone Bash artifacts with
version/build provenance and adjacent SHA-256 checksum companions.  All artifact
flavors are expected to satisfy the same public behavior contract.

See [ADR-006](adr/ADR-006-release-artifact-flavors-and-metadata.md).

### ADR-007: Doxygen-Based Verbose Source Documentation Standard

Maintained Bash uses the exact bash-doxygen-compatible `##` Doxygen model.  Source
documentation is intentionally verbose enough to preserve implementation
contracts, assumptions, edge cases, failure behavior, and examples near the code
they govern.

See [ADR-007](adr/ADR-007-doxygen-verbose-source-documentation.md).

### ADR-008: Documentation-Driven, Test-Second Development

Consequential behavior should be documented architecturally and at the interface
level before tests encode the intended contract and implementation follows.
Exploration may precede documentation, but exploratory behavior should not become
architecture silently.

See [ADR-008](adr/ADR-008-documentation-driven-test-second-development.md).

### ADR-009: Observable Behavior Testing Across Shipped Artifacts

Bats is the default behavior-testing framework, and every shipped artifact flavor
receives the same public behavior suite.  Tests should be focused enough that a
failure normally identifies one primary contract.

See [ADR-009](adr/ADR-009-observable-behavior-testing.md).

### ADR-010: Generated Reference Documentation Is Ephemeral

Doxygen reference output is generated from maintained source comments and is not
committed.  Maintained comments and ADRs remain authoritative while generated
reference documentation may be rebuilt or published by automation.  ADR-017
extends this model to the assembled ADR landing-page Markdown.

See [ADR-010](adr/ADR-010-generated-reference-documentation.md).

### ADR-011: Conventional-Commit Semantic Releases and Late Tagging

Release versions derive from Conventional Commits, and tags/releases are created
only after the exact intended artifacts have passed checks, tests, checksum
verification, compatibility validation, and attestation.  Publication is the
result of successful validation rather than a prerequisite for it.

See [ADR-011](adr/ADR-011-conventional-semver-and-late-tagging.md).

### ADR-012: Standardize SHA-256 Checksum Companion Filenames

Current builds and releases use `.sha256` companions and do not publish duplicate
`.256` files.  Historical `.256` release assets remain valid, and consumers may
fall back only after the preferred `.sha256` companion is confirmed absent.

See [ADR-012](adr/ADR-012-standardize-sha256-checksum-companion-filenames.md).

### ADR-013: Repository-Facing Documentation and Template Hygiene

Repository-facing documentation and GitHub templates are maintained starter
assets, not disposable boilerplate.  The template provides a concise decision
map, richer ADR prompts for consequential decisions, Bash-oriented support and
issue guidance, coordinated security-disclosure wording, and documentation
freshness rules that avoid unrelated-project residue and needless mutable
snapshots.  ADR-017 refines the documentation hierarchy by making the assembled
ADR README generated navigation while keeping its authored framing maintained.

See [ADR-013](adr/ADR-013-repository-facing-documentation-and-template-hygiene.md).

### ADR-014: Modularity as Maintenance and Assembly Architecture

The reusable modularity pattern is responsibility-focused maintained source,
explicit core dependency order, deterministic additive assembly, and standalone
consumer artifacts.  Runtime registries, noop plugins, dynamic loading, and other
extension machinery remain product-specific choices rather than requirements
implied by modular source.

See [ADR-014](adr/ADR-014-modularity-as-maintenance-and-assembly-architecture.md).

### ADR-015: Dependencies as Explicit Attack Surface

Every dependency expands the trusted computing base and is reviewed according to
the code it executes, data it can observe, authority it inherits, inputs it
parses, side effects it can produce, transitive surface, supply-chain posture,
and failure behavior.  Checksums and pinning establish acquisition integrity; they
do not prove behavioral safety.  Runtime, build, CI, documentation, and release
dependencies all remain security-relevant according to their authority.

See [ADR-015](adr/ADR-015-dependencies-as-explicit-attack-surface.md).

### ADR-016: Explicit Threat Modeling for Security-Relevant Changes

Projects derived from the starter should perform and preserve an explicit threat
model when their domain handles sensitive data, untrusted input, destructive or
privileged operations, network authority, release credentials, dynamic loading,
or similar security-relevant boundaries.  Threat modeling identifies assets,
trusted computing base, data and authority flows, mitigations, evidence, residual
risk, and review triggers.  The exercise is intended to expose assumptions rather
than manufacture a blanket claim that a project is secure.

See [ADR-016](adr/ADR-016-explicit-threat-modeling-for-security-relevant-changes.md)
and [`doc/threat-modeling.md`](threat-modeling.md).

### ADR-017: Generate ADR Navigation Ephemerally

The linked ADR landing page is generated from maintained intro/outro framing and
the current ADR corpus with a pinned adrctl release.  The assembled
`doc/adr/README.md` is ignored build input rather than maintained source, while
`doc/decisions.md` remains the always-present concise architectural map.
Documentation generation stays offline, graph-free for routine ADR navigation,
and independent of template runtime and release artifacts.

See [ADR-017](adr/ADR-017-generate-adr-navigation-ephemerally.md).

## certbotbot Product Decisions

### ADR-018: Certificate Identity, SAN Groups, and DNS-Only Issuance

Each requested group identifies one lineage and an authoritative SAN set.  The primary name always includes its apex and wildcard, while additional SANs remain literal.  Only DNS-01 challenges are supported, and Certbot controls renewal eligibility.  Unspecified lineages are not modified.

See [ADR-018](adr/ADR-018-certificate-identity-and-dns-issuance.md).

### ADR-019: Composable Common and Per-Certificate State Archives

Shared ACME account state is published separately from self-contained certificate lineage archives.  Each domain archive is directly extractable beside other domain archives, with valid symlinks and prebuilt combined PEM files.  Consumers need neither the common account archive nor Certbot.  Service post-install hooks remain the consuming server's responsibility.

See [ADR-019](adr/ADR-019-composable-state-archives-and-consumer-boundary.md).

### ADR-020: Build-Time Discoverable, Bundled DNS and Storage Backends

Core modules are explicitly ordered, while built-in DNS and storage modules are discovered deterministically at build time.  The first distribution bundles only Route53 and S3, with an optional S3-compatible endpoint URL for services such as MinIO.  No external runtime plugin loading or third-party plugin API is supported.  All shipped backends share one process's trust boundary.

See [ADR-020](adr/ADR-020-bundled-backend-discovery-and-storage-contract.md).

### ADR-021: Optional Symmetric GPG Encryption and Manual Format Migration

A nonempty GPG passphrase selects local symmetric AES-256 encryption and the .tar.gz.enc suffix for all archive objects.  Absent or empty passphrases select plaintext .tar.gz storage.  Mode mismatch and decryption errors fail closed rather than silently falling back.  Migration between formats is an explicit, documented administrator procedure.

See [ADR-021](adr/ADR-021-optional-symmetric-encryption-and-migration.md).

### ADR-022: Serialized Runs, Explicit Storage Limitations, and Failure-Safe Publication

Work is sequential within one invocation, with local and CI-specific concurrency safeguards.  Independent writers to a shared archive collection must be serialized operationally because the first release has no distributed lock.  All selected objects must validate before any publication begins.  Multi-object commits remain non-atomic, and a genuine storage-backed lease is future backlog work.

See [ADR-022](adr/ADR-022-execution-serialization-and-publishing.md).

### ADR-023: Standalone Release Artifacts, Pinned Dependencies, and Optional Runners

The standalone Bash executable is the primary product; Docker, Jenkins, and GitHub Actions are optional wrappers.  The three release flavors and their SHA-256 companions follow inherited template rules.  Make directly bootstraps pinned bashdeps, which manages bash-doxygen, mktext, Bash-Minifier, adrctl, and bashlog.  Runtime provider modules are bundled, and documentation continues to publish through GitHub Pages.

See [ADR-023](adr/ADR-023-build-artifacts-dependencies-and-execution-examples.md).

### ADR-024: Govern Maintained Content by a Verified Released Coding Standards Snapshot

The project adopts coding_standards@v2.1.0 as a complete committed snapshot, with version and digest recorded in .codingstandardrc.  Relevant imported standards are mandatory unless an Accepted local ADR or explicit policy refines them.  Imported files must remain unmodified, and future updates require a reviewed release-specific refresh.  The standards do not become runtime dependencies or automatic update jobs.

See [ADR-024](adr/ADR-024-released-coding-standards-governance.md).

### ADR-025: Certbot State Portability and the Staged Issuance Boundary

The built-in Route53 adapter constructs a DNS-only, named Certbot certonly invocation using a complete explicit SAN set and renewal-aware flags.  Producer workspace paths must be private, and archived renewal metadata must remain portable when restored on another host or into another transient directory.  A mocked adapter alone does not authorize public certificate issuance or publishing.  Real restore, no-op renewal, and changed-SAN integration evidence are required before enabling the production workflow.

See [ADR-025](adr/ADR-025-certbot-state-portability-and-issuance-boundary.md).

### ADR-026: Strict Pre-Extraction Validation of Domain Archive Manifests

Domain archives are inspected with a strict GNU tar metadata allowlist before any extraction.  The preflight permits only the requested lineage's expected directories, versioned PEM files, renewal metadata, and four canonical relative live symlinks, while rejecting unexpected links, traversal, duplicate members, and unsafe private-key-bearing modes.  This validation is a necessary but insufficient prerequisite to restoration because it neither extracts files nor proves their contents or renewal-state portability.  The common account archive and safe extraction require separate reviewed contracts.

See [ADR-026](adr/ADR-026-validated-domain-archive-manifests.md).

### ADR-027: Isolated Restoration of Validated Certificate Lineages

Only a privately copied domain archive that passes ADR-026 manifest inspection
may be extracted into a fresh, isolated producer staging directory.  Every
resulting filesystem entry must independently match the expected lineage
structure, including safe types, targets, and private-key permissions.
Successful staging does not install data into active Certbot state or prove
renewal portability or cryptographic certificate validity.  The common
account archive and producer orchestration remain future work.

See [ADR-027](adr/ADR-027-isolated-domain-archive-restoration.md).

### ADR-028: Isolated, Account-Only Common ACME State

The common archive may hold only complete Let's Encrypt ACME v2 production
or staging account records and never certificate lineages, hooks, or
arbitrary Certbot configuration.  Strict manifest validation, private
copying, isolated extraction, and independent filesystem inspection
protect the producer from malformed account archives.  Account JSON is
not automatically trusted or selected after staging; actual ACME account
verification and renewal portability are future release gates.  Consumers
of issued certificates do not require or receive this common archive.

See [ADR-028](adr/ADR-028-isolated-common-acme-account-state.md).

### ADR-029: Pre-Publication Cryptographic Certificate Verification

Certificate archives cannot be published solely because Certbot succeeded
or the files match the expected directory layout.  An OpenSSL runtime gate
must validate current X.509 validity, the private-key/public-key match,
TLS-server certificate-chain trust, and exact combined PEM outputs.
The gate accepts explicit trusted roots for staging while retaining the
normal system trust configuration for production.  Its isolated presence
does not enable issuance: the producer must later invoke it on every
publication path, with failure blocking all object mutations.

See [ADR-029](adr/ADR-029-pre-publication-cryptographic-verification.md).

### ADR-030: Production-Default Let's Encrypt Staging Selection and Storage Isolation

The public CLI defaults to Let's Encrypt production but supports a fixed
staging mode for nonproduction certificate testing.  Production preserves
existing unprefixed S3 object keys, while staging uses a fixed `staging/`
prefix for both common and domain archives, enforced at the S3 adapter
boundary.  The two ACME directory URLs are fixed and cannot be replaced
with arbitrary operator-supplied endpoints.  Actual issuance and
publication still require account selection, trust-chain verification,
and cross-workspace integration tests.

See [ADR-030](adr/ADR-030-isolated-letsencrypt-environments.md).

### ADR-031: Read-Only Account and Lineage ACME Identity Validation

A restored lineage's renewal metadata must agree with the selected
production or staging Let's Encrypt endpoint and reference a complete
private account record under the matching authority.  Ambiguous
identity values, unexpected sections, or hook directives fail closed.
This internal validation does not interpret account JSON, repair
absolute renewal paths, or actually select the account in Certbot.
Further integration and portability testing remain mandatory before
issuance or publication.

See [ADR-031](adr/ADR-031-restored-acme-account-and-lineage-identity.md).

### ADR-032: Validated, Non-Activating Renewal Path Rebase Preview

An internal helper may generate a separate private preview of the five
Certbot renewal path values relocated to the current producer
workspace only after restored account/environment identity validation
and an exact old-root/lineage consistency check.  It rejects ambiguous
or unsafe source paths, inherited directory overrides, and duplicate
fields while leaving the archived renewal file unchanged.  This is a
testable candidate mechanism rather than permission to edit active
Certbot state.  ADR-025 still requires real-version no-op renewal,
SAN changes, and account continuity before activation.

See [ADR-032](adr/ADR-032-validated-renewal-path-preview.md).

### ADR-033: Read-Only Certbot Portability Compatibility Test

A dedicated CI job may use a real, version-pinned Certbot binary to
inspect a locally generated lineage after it has been archived,
restored, and relocated under an independent ephemeral configuration
root.  This is a narrow test-only exception to ADR-032's rule against
presenting path previews to Certbot; the product still cannot install
them or invoke issuance.  Synthetic ACME account metadata and
self-signed certificates mean that a successful listing does not
demonstrate real registration, renewal, or SAN changes.  Those remain
mandatory integration gates under ADR-025.

See [ADR-033](adr/ADR-033-readonly-certbot-portability-test.md).

### ADR-034: Network-Guarded Certbot No-Op Renewal Compatibility Test

The portable-state integration suite may run pinned Certbot's real
`renew --cert-name` command against an independently reconstructed
lineage when the locally signed certificate is clearly not due.
The test guards Python socket connections, disables directory hooks,
and tolerates only an intercepted ARI DNS lookup while requiring a
recognizable no-op decision without altering certificate/private-key
bytes or critical identity/path settings.  A narrowly verified ARI
retry-after addition is accepted and re-archived locally for testing.  Synthetic account JSON
cannot prove actual registration, and this permission is confined to
disposable CI fixtures.  Live ACME renewal, SAN changes, and archive
publication remain separate release gates.

See [ADR-034](adr/ADR-034-network-guarded-certbot-noop-renewal.md).

### ADR-035: Three-Runner Continuity for State-Only Renewal Metadata

A credential-free CI sequence may test three independent ephemeral
Certbot workspaces, with the second runner repackaging a validated ARI
retry scheduling update despite no certificate issuance.  The third
runner must restore the resulting domain archive and original common
account archive, preserving identity, key/certificate fingerprints,
and ARI state while completing another real no-op decision.  The
extension remains test-only, without S3 publication or real ACME
account continuity.  Live due renewal, SAN changes, and a reviewed
state-only publication policy remain separate gates.

See [ADR-035](adr/ADR-035-three-run-ari-state-continuity.md).

### ADR-036: Exact Requested DNS SAN Set Before Certificate Publication

Every deployable leaf certificate must contain exactly the requested
normalized DNS SAN set for its lineage, including both the explicit
apex and wildcard.  The independent OpenSSL validator treats DNS
name case and certificate entry order as irrelevant, but refuses
missing, extra, duplicate, malformed, or non-DNS identities.
Certificate CN matching and a successful Certbot exit status do
not satisfy this contract.  The producer must invoke this check
alongside the existing cryptographic verifier before any object
mutation, including state-only archive publication.

See [ADR-036](adr/ADR-036-exact-dns-san-verification.md).

### ADR-037: Gate Active Certbot State Import on Verified Portability

Isolated account and lineage restoration does not authorize installation into active Certbot configuration. Preparation and assessment remain non-activating until genuine staging account reuse, renewal and SAN-change evidence across independent workspaces, and a separate Accepted import/rollback decision. The public issuer and release gates remain disabled.

See [ADR-037](adr/ADR-037-gated-active-certbot-import.md).

### ADR-038: Strict, Non-Activating Restored Renewal-Option Policy

Before a restored lineage passes private import assessment, the producer must
validate the complete persisted Certbot renewal-option profile, not merely its
account identity and five historical paths.  The initial Certbot 5.8.0
Route53 allowlist accepts only explicitly reviewed fields, rejects unknown
options and executable/plugin overrides, and permits the narrowly documented
ARI retry scheduling update.  The policy does not authorize account import,
Certbot execution, or S3 publication; those release gates remain closed.

See [ADR-038](adr/ADR-038-restored-renewal-option-policy.md).

### ADR-039: Typed S3 Retrieval and Private Collection Staging

A producer must distinguish confirmed missing S3 objects from authorization,
transport, and ambiguous service failures before treating storage as new.
A bounded, non-activating retrieval operation downloads the common archive and
selected domain objects into private staging, returns explicit presence flags,
and rejects any orphaned domain archive without its common account.  Only
an exact reviewed AWS CLI GetObject NoSuchKey signature confirms absence;
a generic 404 remains fatal.  Archive validation, account reuse, issuance,
and publication require separate evidence and remain disabled.

See [ADR-039](adr/ADR-039-typed-s3-state-retrieval.md).

### ADR-040: Non-Activating Assessment of Retrieved S3 State

A selected remote common archive must be independently validated even when
every requested lineage is confirmed absent. All present lineages are
assessed as one batch against the downloaded common account state, including
archive shape, account/authority references, renewal settings, and portable
path previews. Missing requested lineage names are reported only after the
whole existing collection passes, never as authorization for issuance.
Remote bytes and private staging are discarded on success and failure;
active Certbot state, account registration, and publishing remain disabled.

See [ADR-040](adr/ADR-040-remote-state-assessment-boundary.md).

### ADR-041: Encrypted Archive Preparation and Strict Retrieval Mode

Optional GPG symmetric AES-256 encryption now has an internal private
archive-transform helper and a strict encrypted retrieval path.
A nonempty `GPG_PASSPHRASE` selects only `.tar.gz.enc` common/domain
objects, with no plaintext fallback on failed retrieval or decryption.
An absent selected-mode key triggers a presence-only check for the
opposite suffix, and any existing opposite-mode object is a fatal
migration mismatch. Both decrypted and downloaded secret bytes are
discarded after non-activating assessment, and neither issuance nor
S3 publication is enabled.

See [ADR-041](adr/ADR-041-encrypted-state-retrieval-and-preparation.md).

### ADR-042: Frozen, Cryptographically Verified Local Publication Candidates

A non-publishing preparation helper now freezes a complete common/domain
archive collection before validation, rather than checking mutable inputs
and subsequently re-reading them. Every existing lineage must pass the
isolation, account, renewal-option, X.509 chain/key, combined PEM, and
exact requested DNS SAN checks before any local candidate is exposed.
The approved candidate uses one plaintext or AES-256 encrypted format
with fixed common-first S3 object keys and owner-private file bodies.
No PutObject is called, and active Certbot import or issuance remains blocked.

See [ADR-042](adr/ADR-042-local-publication-candidate-gate.md).

### ADR-043: Verified, Exact-Byte Remote Recovery Checkpoints

A verified local publication candidate must be paired with a
bucket- and environment-bound, complete read-only snapshot of its
previous S3 common and selected domain objects before any future
publication can be considered. The new checkpoint validates restored
account and renewal state, preserves exact original encrypted or
plaintext remote bytes and presence flags, and records SHA-256 digests.
Denied, missing-common, corrupt, or mixed-format remote inputs fail
closed, and no S3 writes are enabled. A later publication ADR must
provide durable **remote** rollback generations because a local
checkpoint alone cannot survive a worker crash.

See [ADR-043](adr/ADR-043-recoverable-s3-publication-checkpoint.md).

### ADR-044: Operator-Authorized Real ACME Staging Portability Evidence

A four-runner Let's Encrypt staging portability protocol is supplied
as a deliberately **inactive example** under `examples/github-actions/`,
alongside credential-free guard tests and an integration harness. It
is not registered as an executable workflow by this repository; an
operator must separately review, install, authorize, and configure it
in a controlled GitHub environment to request real DNS-01 validation.
The design protects split-state transfers with encryption and keeps
test-only Certbot state import outside the product entrypoint.
No Checkov rule exception is needed in this repository, and real
staging evidence remains outstanding until a complete manually
authorized run succeeds.

See [ADR-044](adr/ADR-044-opt-in-real-acme-portability-evidence.md).

### ADR-045: Complete, Non-Activating Multi-Lineage Import Candidates

An internal preparation helper freezes common-account and selected lineage
archives once, runs the full batch assessment, and assembles a complete
multi-lineage Certbot-shaped candidate in a separate owner-private directory.
Validated renewal paths are rebased only to this private candidate, never to
the active configuration. Any rejected later lineage discards the entire
candidate, with no Certbot, DNS, or S3 side effects. This establishes local
**preparation atomicity** only; ADR-037 still forbids product activation
pending reviewed live staging evidence and a separate activating ADR.

See [ADR-045](adr/ADR-045-nonactivating-multilineage-import-candidates.md).

### ADR-046: Local Manifest of Proposed and Previous Publication Bytes

Before any future remote mutation, the producer can now pair its
cryptographically verified proposed object collection with its exact
validated previous-state checkpoint and create a private manifest.
That manifest records the common-first key order, previous existence,
old and new SHA-256 hashes, and byte lengths without writing to S3.
The helper rechecks both collections and manifest integrity before
returning success. It remains an **ephemeral local plan**, not a
remote backup, atomic publication, or permission to activate Certbot.

See [ADR-046](adr/ADR-046-local-prepublication-recovery-manifest.md).

### ADR-047: Write-Once, Remotely Verifiable S3 Recovery Generations

A guarded internal operation can persist the exact previous-state checkpoint
into new generation-scoped S3 keys, using conditional `If-None-Match: *`
writes and byte-for-byte readback verification. It writes a checksummed
manifest last and returns a generation ID and trusted checksum only after
full verification. A fresh runner can verify every retained object without
the original runner's filesystem. The public issuer and all `*-latest`
aliases remain untouched; this is durable recovery *preparation*, not
authorization to publish new certificate state.

See [ADR-047](adr/ADR-047-durable-s3-recovery-generations.md).

### ADR-048: Read-Only Remote Latest-State Drift Preflight

A new internal precondition re-reads every selected S3 latest object
after a complete proposed collection, prior checkpoint, and local
manifest have been validated. It rejects additions, removals,
byte changes, wrong archive modes, and ambiguous S3 reads by
comparing exact raw bytes and presence to the previous checkpoint.
The operation never uploads and always discards its temporary read
stage. This is a **freshness observation**, not an atomic multi-key
snapshot, distributed lock, or permission to publish latest aliases.

See [ADR-048](adr/ADR-048-remote-latest-drift-preflight.md).

### ADR-049: ETag-Bound Publication Preconditions

A read-only internal operation captures S3 conditional-write predicates
for each latest object only after revalidating the complete local
publication plan and fresh remote-state precondition. Existing objects
must survive a GET conditioned on the service's opaque ETag and match
their original checkpoint's SHA-256 and size; missing objects retain
an explicit absent predicate. No partial predicate collection is
exposed on error, and no AWS mutation occurs. These values can become
stale immediately and are not a lock, multi-object transaction, or
authorization to publish certificates.

See [ADR-049](adr/ADR-049-etag-bound-publication-conditions.md).

### ADR-050: Guarded Conditional Latest Publication and Fresh-Runner Recovery

The internal S3 coordinator can conditionally update the validated common
account and domain latest objects only after durable, independently verified
previous-state recovery and explicit operator acknowledgement of the saved
generation identifier and checksum. Every PUT uses an object-level ETag or
absence condition and read-back verification. On an ambiguous partial failure
the system preserves the backup and requires separate, expressly authorized
recovery; a fresh runner restores old bytes or confirmed absence only if
all current keys match saved old or proposed new state. Cross-platform
serialization, real backend tests, and ADR-037's live ACME evidence remain
required before enabling normal issuance.

See [ADR-050](adr/ADR-050-conditional-latest-publication-and-recovery.md).


### ADR-051: Disposable S3 Storage End-to-End CI

The repository installs a deliberately unprivileged, nonproduction GitHub
Actions workflow that provisions a digest-pinned SeaweedFS S3-compatible
service on an ephemeral runner's loopback address. Pull requests and manually
dispatched jobs run the existing `make test-s3-interop` suite on all three
standalone artifacts using only publicly known synthetic test credentials and
no AWS, DNS, ACME, or deployment authority. The workflow tests real S3
conditional writes, independent-runner recovery, conflicts, and a SIGKILL
interruption; results prove compatibility only with the tested S3 emulator and
CLI, not with production AWS, real Let's Encrypt state, or distributed locking.
ADR-037's active-import prohibition, ADR-044's inactive live ACME workflow,
and the ordinary issuer's exit-status-69 gate remain in force.

See [ADR-051](adr/ADR-051-disposable-s3-end-to-end-ci.md).


### ADR-052: Exact AWS CLI 2.37 NoSuchKey Diagnostic Compatibility

The internal ADR-039 GetObject missing-state classifier recognizes the original
anchored `NoSuchKey` diagnostic and the newer AWS CLI 2.37.13 form prefixed
with the literal `aws: [ERROR]: `. The confirmed GetObject operation,
exact `NoSuchKey` service error, and process status 254 remain mandatory;
generic 404s, unexpected prefixes, wrong operations, and failures are never
accepted as evidence of an absent object. This directly addresses an
interoperability failure exposed by ADR-051's real-service CI without
altering the public issuer or any existing active-state restriction.

See [ADR-052](adr/ADR-052-awscli-prefixed-nosuchkey.md).


### ADR-053: Genuine Two-Lineage Staging Evidence Without Active Import

The inactive, manually installed ADR-044 Let's Encrypt staging workflow now includes a
separate real second-lineage issuance phase and an independent, read-only two-lineage
restoration phase. It checks the same genuine staging ACME account across runners,
retains an unchanged first certificate while producing a distinct second
certificate, and exports one separately encrypted account archive plus two
non-overlapping, independently validated lineage archives. The final runner
uses ADR-045's non-activating candidate to check both lineage certificates
without invoking Certbot or AWS and never activates product state. The workflow
remains an opt-in example, real staging evidence is still pending operator
authorization and successful execution, and ADR-037's public-import prohibition
remains binding.

See [ADR-053](adr/ADR-053-two-real-lineage-staging-evidence.md).


### ADR-054: Remote S3-to-Verified Inactive Multi-Lineage Candidate

An internal coordinator fetches a complete selected set of existing common
account and domain archives once from S3, using the existing typed,
namespace-aware, optionally encrypted retrieval contract. It requires
all requested lineage archives to exist, assembles the downloaded bytes
into an ADR-045 owner-private **inactive** candidate, and cleans up the
downloaded stage on all outcomes. A separate explicit gate verifies every
requested certificate chain, matching private key, and exact SAN set
with an operator-supplied staging trust root when needed. Preparation
or verification never authorizes Certbot activation, account registration,
DNS challenges, S3 mutation, or changes to public issuer exit 69.

See [ADR-054](adr/ADR-054-remote-verified-inactive-candidate.md).


### ADR-055: Mandatory Apex-and-Wildcard SANs in the Second Real Staging Lineage

The real staging two-lineage example previously attempted to issue and validate
a bare-name second lineage, even though ADR-018/036 require both the selected
base DNS name and its wildcard for every certificate group. The fifth and
sixth runners now use that exact canonical SAN pair, removing an inevitable
validation failure without weakening the public certificate validator.
This decision supersedes only ADR-053's single-SAN second-lineage clause;
the workflow remains manually installed, staging-only, and prohibited from
activating public issuance. Offline tests with locally CA-signed X.509
fixtures validate the corrected success and bare-name rejection paths.

See [ADR-055](adr/ADR-055-real-staging-second-lineage-sans.md).


### ADR-056: Offline Staging IAM Policy Documents

An offline Bash-only generator produces reviewable OIDC trust and Route53
permissions policies from strictly validated AWS account, GitHub repository,
hosted zone, and three DNS names. The trust policy binds the protected
`acme-staging` environment, and DNS write access is restricted to its
three exact TXT challenge owners with explicit action and type constraints.
The operator still creates and reviews the role and environment, installs
the inactive workflow separately, and explicitly approves real staging.
Neither this generator nor synthetic tests authorize production issuance.

See [ADR-056](adr/ADR-056-offline-staging-iam-policies.md).
