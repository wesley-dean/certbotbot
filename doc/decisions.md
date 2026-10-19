# Architectural Decisions

This document is a concise map of template-bash's Architecture Decision Records.
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
