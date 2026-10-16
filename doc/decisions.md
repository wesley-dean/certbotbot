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
and requires a recognizable no-op decision without altering renewal
metadata or certificate/private-key bytes.  Synthetic account JSON
cannot prove actual registration, and this permission is confined to
disposable CI fixtures.  Live ACME renewal, SAN changes, and archive
publication remain separate release gates.

See [ADR-034](adr/ADR-034-network-guarded-certbot-noop-renewal.md).
