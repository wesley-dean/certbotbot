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

### ADR-018: Adopt a Verified Released Coding Standards Snapshot

The repository initially adopted `coding_standards@v2.2.0` as a fully
committed, externally managed snapshot under `doc/standards/`, with source and
artifact SHA-256 recorded in `.codingstandardrc`. Applicable general,
cross-cutting, and language-specific standards are binding unless
an Accepted project ADR or explicit local policy refines them.
Standards examples are non-normative, and repository-specific exceptions
belong in local governance, never in the imported snapshot.
The historical research under `doc/research/` remains non-governing
until individual requirements are explicitly approved.

The project explicitly opts into three-phase development using
`three_phase_development = true` in `.codingstandardrc`.
Story planning, Technical Architect approval of linked tasks, and
engineering execution have separate authorization boundaries;
completion requires verified acceptance. ADR-019 supersedes ADR-018's
original approval-evidence rule following the v2.2.1 upgrade.

See [ADR-018](adr/ADR-018-adopt-released-coding-standards.md).

### ADR-019: Treat Current GitHub Approval Labels as Authoritative

With the adoption of `coding_standards@v2.2.1`, each issue's current
`approved` label is the authoritative and sufficient workflow approval
for that issue's current scope and phase. The responsible human makes
the approval decision, and may apply the label or direct an agent to
apply it to identified issues; a separate dated approval comment is
not required. The label does not confer repository permissions or waive
security, accepted ADRs, dependency checks, or PR review gates. Scope
changes require removal of `approved` and renewed authorization.

See [ADR-019](adr/ADR-019-authoritative-approval-labels.md).

### ADR-020: One Selected Certificate and One Durable Archive

The MVP selects one DNS identity, resolves an explicit or deterministic certificate
lineage name, and restores a required seeded account from one existing S3 archive.
Configuration files are literal data and never executed. Durable changes cause
validated publication; an explicit upload override may republish a successful
unchanged operation, and external writer serialization remains the operator's
responsibility.

See [ADR-020](adr/ADR-020-one-selected-certificate-and-one-durable-archive.md).

### ADR-021: Fail-Closed Read of the Seeded S3 Archive

The S3 adapter reads only the configured existing bucket/key into a private
workspace, using an installed AWS CLI v2 and the operator's existing IAM
credentials. A HeadObject 404 must be corroborated with a successful
HeadBucket check before reporting a missing seeded object; all ambiguous
errors fail closed. Successful download is a staging result, not archive
validation, Certbot execution, or authorization to publish. Writer races
and snapshot consistency remain explicit operational limitations.

See [ADR-021](adr/ADR-021-fail-closed-seeded-s3-read.md).


### ADR-022: Portable Certbot State Archives and Isolated Restoration

The MVP stores the relative contents of Certbot's configuration root in one
ordinary \`.tar.gz\` object and accepts account-only archives before first
issuance. Certbot's live certificate symlinks are relative, but renewal metadata
can reference absolute paths; safe independent-runner operation therefore
requires a verified, reversible mapping between canonical persisted paths and
private runner paths. Untrusted tar members and executable hook configurations
must be rejected before activation, and neither archive validation nor host
fallback is implied by a successful S3 read. Format validation and mapping
require separate implementation evidence before the public lifecycle is enabled.

See [ADR-022](adr/ADR-022-portable-certbot-state-archives.md).


### ADR-023: Fail-Closed Preflight of Restored ACME State

Restoring an archive cannot itself establish a registered or suitable ACME
account. The MVP therefore requires one unambiguous Let's Encrypt production
account with mandatory files and either no issued certificate lineage or
exactly the complete selected lineage. Unexpected accounts, conflicting
lineages, incomplete PEM links, and archived renewal hooks fail closed without
Certbot or S3 mutations. A successful local preflight is not remote account
verification and cannot enable issuance until the separate Certbot and renewal
path-mapping gates have passed.

See [ADR-023](adr/ADR-023-fail-closed-restored-acme-preflight.md).


### ADR-024: Selected-Only Certbot and Route53 Execution Boundary

The first-party provider invokes an operator-installed Certbot and Route53
authenticator only within private configuration, work, and log directories.
For a missing selected certificate, it verifies that the installed Certbot
recognizes the one restored production account before requesting exactly
the approved SANs with an explicit stable lineage name. No account
registration, arbitrary archived hook execution, implicit global renewal,
or host-state fallback is authorized. The provider remains separate from
public orchestration, post-issuance assertions, and archive publication,
which each require their own verification gates.

See [ADR-024](adr/ADR-024-selected-only-certbot-route53-provider.md).


### ADR-025: Selected-Lineage Renewal and Observable No-Op Results

For an existing restored certificate, the provider invokes Certbot renewal
only with an explicit selected certificate name and an exact match between
the current certificate DNS SANs and the requested set. Unsupported SAN
drift is refused until the separately approved reconciliation work can
preserve the intended lineage. Ordinary due-renewal behavior and a
deterministic private before/after state comparison distinguish actual
certificate replacement from metadata changes and a successful no-op.
The provider restores canonical renewal paths and validates resulting
local state before reporting success; public orchestration and
publication remain separate gates.

See [ADR-025](adr/ADR-025-selected-renewal-noop-contract.md).

### ADR-026: Controlled SAN Reconciliation on an Existing Certbot Lineage

A restored selected lineage is updated in place only when the existing and requested DNS SAN sets use the same apex identity and fit the MVP apex/wildcard policy. Matching names continue through ordinary selected renewal without forced issuance; a supported change invokes named `certonly --renew-with-new-domains` with the existing account and private paths. Post-issuance identity, exact SAN, and canonical-path checks must pass before local success can be reported; failures discard the candidate without S3 publication. ADR-026 supersedes only ADR-025's temporary ban on changing SAN sets, preserving the other no-op and safety requirements.

See [ADR-026](adr/ADR-026-controlled-existing-lineage-san-reconciliation.md).


### ADR-027: Verified Candidate Archive Before Single-Key Publication

The publisher receives only a locally verified candidate archive produced
from a complete selected lineage and the existing production ACME account.
The packaging boundary verifies canonical renewal metadata without rewriting
the source, serializes the full supported Certbot configuration tree using
standard GNU tar/gzip, and validates the precise staged bytes before exposing
one candidate in a private workspace. Unsupported content, private-key
permissions, failed compression and occupied output paths prevent acceptance
without changing the authoritative S3 archive. Certificate cryptographic
checks, upload policy and remote persistence remain separate gates.

See [ADR-027](adr/ADR-027-validated-candidate-before-publication.md).


### ADR-028: Verified Single-Key S3 Publication and No-Op Policy

Only a successful selected-certificate lifecycle may ask the publisher
to write durable state, and the publisher itself builds and validates
the private candidate before one S3 PutObject to the already selected
bucket/key. A successful unchanged no-op skips publication by default;
a real durable-state change or explicit UPLOAD_NO_RENEWAL override
requires the same validated candidate and exact one-object upload.
Failures before PutObject protect known-good S3 state, while an
interrupted/failed PutObject leaves remote state uncertain rather than
providing a false rollback guarantee. Caller verification of previous
retrieval, successful Certbot, selected name and exact same bucket/key
remains mandatory before public dispatch may be enabled.

See [ADR-028](adr/ADR-028-single-key-s3-publication.md).

### ADR-029: Arbitrary DNS SAN Sets on One Stable Certificate Lineage

One selected certificate may contain multiple validated DNS SANs from
unrelated zones; the complementary apex/wildcard rule applies exactly once
to each explicitly supplied name when enabled. A repeatable CLI `--san`
setting or one source-selected `ADDITIONAL_SANS` list adds names without
changing stable selected lineage identity, its registered account, or the
single authoritative S3 object. Matching sets retain normal renewal/no-op
behavior, while valid drift uses verified same-lineage reconciliation;
malformed existing SANs must fail before Certbot. This decision broadens
only ADR-020's MVP input cardinality and ADR-026's same-apex restriction;
multi-lineage archives require the separate approved story #56.

See [ADR-029](adr/ADR-029-arbitrary-multi-san-selected-lineage.md).

### ADR-030: Multiple Independent Certificate Lineages in One Shared Archive

A single existing S3 tar.gz object may contain multiple independent, unrelated
Certbot certificate lineages while each ordinary invocation still targets
**one exact selected lineage**. The preflight validates all restored lineage
triplets and account state, the provider modifies only the selected lineage,
and the publisher packages the complete validated configuration without
altering other lineages. Existing account-only and one-lineage archives remain
compatible; no implicit bulk renew, orphan deletion, additional S3 objects,
or concurrent-writer protection is introduced. This decision narrowly
supersedes the MVP extra-lineage prohibition in ADR-023 and selected-only
eligibility in ADR-027, retaining their other security obligations.

See [ADR-030](adr/ADR-030-shared-archive-multiple-lineages.md).

### ADR-031: Opt-In Authenticated GnuPG Encryption of the Shared Archive

The one existing S3 archive may optionally be wrapped in a versioned,
authenticated GnuPG AES-256/OCB ciphertext envelope; its decrypted gzip/tar
contents and selected-only multi-lineage semantics remain unchanged.
A nonempty `GPG_SYMMETRIC_KEY` exported secret enables encryption by default,
while nonsecret mode and migration settings use established CLI > environment >
literal file precedence. A plaintext-to-encrypted transition is deliberately
one-way and requires explicit migration authorization plus operator attestation
of a recoverable external backup; unknown formats, wrong keys and broken
authentication never fall back or authorize publication. This narrowly extends
ADRs 022/028's transport boundary, retaining their one-key, fail-closed
validation and uncertainty guarantees.

See [ADR-031](adr/ADR-031-opt-in-authenticated-gpg-archive-encryption.md).

### ADR-032: Deterministic and Safe Archive Filename Templates

The existing `S3_KEY` remains a literal, backward-compatible authoritative
current object key, defaulting to `latest.tar.gz`; an opt-in
`S3_KEY_TEMPLATE` may replace its selection at a higher configuration tier,
and a distinct `BACKUP_KEY_TEMPLATE` describes optional recovery-copy naming.
Certbotbot supplies a single frozen UTC date as YEAR/MONTH/DOM and uses pinned
mktext only for nonrecursive literal substitution, enforcing strict basename,
extension, unknown-token, and current/backup collision safety before remote
operations. This decision does not authorize second-object publication or
destructive retention, which require separate governance under #81/#84, and
it does not claim future alternate backend/format support.

See [ADR-032](adr/ADR-032-deterministic-safe-archive-filename-templates.md).

### ADR-033: Opt-In Dated Backup Publication After Current-State Success

An explicitly enabled dated recovery copy is published only after the normal
authoritative current-key write succeeds, using exactly the same complete
validated shared archive bytes and encrypted envelope when configured.
The default remains one current S3 object with the existing no-op policy,
while a frozen UTC template determines the additional backup key.
Same-date replacement is conditional on matching certbotbot-managed metadata
and S3 ETag preconditions; unknown objects are never overwritten by name alone,
and accepted-current/failed-backup is reported as nonzero partial success.
This narrowly extends ADR-028/031's single-key restrictions without
authorizing backup deletion, which requires task #84's independent decision.

See [ADR-033](adr/ADR-033-opt-in-dated-backup-publication.md).

### ADR-034: Scoped, Conditional Retention of Managed Dated Backups

Dated-backup retention is separately enabled through a canonical decimal count;
zero preserves all copies, while positive N keeps the newest N provably eligible
backup keys **only after** verified current-plus-backup publication. The initial
S3/gzip-tar deletion scope requires an anchored, unambiguous date-template
namespace, full paginated listing, exact-key v1 metadata verification, strict
protection of the current key and newly published backup, and ETag-conditional
per-object deletion. Ambiguous inventories or identities prohibit all deletion;
any failed or uncertain delete stops further work and reports partial success.
This decision authorizes no immediate destructive behavior and does not migrate
old templates, prune historical versions or grant alternate backend support.

See [ADR-034](adr/ADR-034-scoped-conditional-managed-backup-retention.md).

### ADR-035: Standalone Read-Only Certificate Consumer and Additional Release Artifact

The approved separate-client design introduces one independently runnable
`certbotbot-client.bash` and its `.sha256` companion, expanding the current
certbotbot release to eight files while retaining the existing six producer
artifacts and their checks.  The client reads only the current configured S3
object, supports plaintext validated full-state archives, and extracts into a
new private destination without renewal or remote writes. ADR-037 subsequently permits optional authenticated client GnuPG decryption, replacing only this original plaintext-only exclusion.
It preserves the producer's current-key selection rules and uses late staging
activation to avoid overwriting existing targets; encrypted objects require a
separately approved client extension.

See [ADR-035](adr/ADR-035-standalone-read-only-certificate-client.md)
and [the separate-client contract](separate-client-contract.md).

### ADR-037: Authenticated Decryption for the Standalone Client

The read-only standalone client may opt into producer-compatible authenticated
GnuPG AES-256/OCB decryption using the exact versioned ADR-031 envelope and a
secret-manager-provided exported key.  Key-based `auto` or explicit mode selection
fails closed on mismatch; decryption must authenticate completely before the
existing bounded archive validator, private extraction and absent-destination
activation run. GnuPG 2.4.7+ is conditional on encrypted operation and must pass
real packet and roundtrip probes. This narrowly supersedes ADR-035's initial
plaintext-only exclusion while retaining its S3 read-only authority and exact
eight-file release contract; ADR-031's producer format is unchanged.

See [ADR-037](adr/ADR-037-authenticated-standalone-client-decryption.md)
and [the client encryption threat model](client-encryption-threat-model.md).

### ADR-036: Parallel Producer Validation with Verified CI Artifact Handoff

Producer validation will use one checksum-verified build per GitHub Actions
workflow run, distribute its exact files through a short-lived same-run
handoff, and run the development, ordinary and minified executable
contracts in independently scheduled Bats, Bash 4.3 and authenticated
encryption jobs.  A stable aggregate check must reject any missing,
skipped, cancelled or failed required job rather than reporting partial
success.  The release pipeline must validate and attest those same
intended bytes before a separately privileged final job creates the
tag/release; local three-flavor Make commands and the distinct
separate-client testing contract remain intact.

See [ADR-036](adr/ADR-036-parallel-producer-verification-and-handoff.md)
and [the parallel CI validation contract](parallel-ci-validation-contract.md).

### ADR-038: Verified OCI Producer Images for Docker and Podman

The producer will be distributed in a separately tested, least-privilege
Alpine 3.24 OCI image (per ADR-039) whose entrypoint invokes the verified ordinary
certbotbot executable without changing its public CLI or S3/ACME behavior.
Docker and rootless Podman share the same image, with an initial
linux/amd64-only contract, nonroot execution, ephemeral private state,
digest-pinned base, bounded stable-branch package versions and recorded transitive dependencies, and no baked secrets.
Image publishing follows the already attested eight-file GitHub release
through a separately gated trusted event and the reviewed publish_image
action; both GHCR and operator-confirmed Docker Hub must show matching
provenance and correct tags, including explicitly validated v0.x handling.
The image is a producer distribution rather than a ninth Bash asset, and
runtime, engine and registry support are not claimed before tests.

See [ADR-038](adr/ADR-038-verified-oci-producer-images.md).

### ADR-039: Alpine 3.24 Runtime and Bounded Package Updates

Alpine 3.24 replaces the Debian 13 and dated-APT-snapshot assumption for
the OCI producer, with an explicitly pinned Alpine 3.24.3 linux/amd64
base manifest and only the supported v3.24 main/community APK repositories.
AWS CLI v2, Certbot/Route53 and GnuPG dependencies use fuzzy package-version
constraints so compatible patch updates remain possible, while every built
image preserves its complete installed package/version inventory and must
pass the actual toolchain and Docker/Podman acceptance gates. This does
not guarantee byte-identical rebuilds; changed dependencies require a
new reviewed image identity. The decision **partially supersedes ADR-038**
only for the base distribution and OS package update policy; its verified
producer, security, runtime and release contracts remain authoritative.

See [ADR-039](adr/ADR-039-alpine-oci-runtime.md).

### ADR-041: Explicit ACME Registration and Account-Only Archive Initialization

An operator-invoked `certbotbot register` operation requires an email address,
explicit terms acceptance and a selected Let's Encrypt production or staging
account context, with EFF email signup enabled by default and independently
configurable. Registration never
occurs implicitly during certificate issuance or renewal; explicit registration
alone may initialize a positively missing current S3 object with a validated
account-only archive. Existing suitable accounts are reused without rewriting
their state, while incompatible account contexts, uncertain reads and unsafe
archives fail closed; first writes and updates use conditional S3 publication.
The existing production-only issuance constraints remain in force until a
separate accepted staging/issuer decision.

See [ADR-041](adr/ADR-041-explicit-acme-account-registration-and-state-initialization.md)
and [the registration contract](acme-account-registration-contract.md).

### ADR-040: Release-Gated Dual-Registry OCI Publication

The privileged certbotbot image publisher is triggered only by a successful
OCI release-validation workflow, whose short-lived same-attempt proof is
independently cross-checked against the original successful Versioning run,
the signed stable release and all eight attested Bash assets. An enabled
publisher workflow automatically attempts publication after successful
release validation, with no additional repository flag; a protected
environment contains the only GHCR and Docker Hub authority. The reviewed
publish_image action is pinned to an immutable merge commit with exact v0-safe
source/tag identity, allowlisted build context and nonsecret provenance.
Both registry manifests and pulled source/producer identities must match
the reported digest or publication fails, without claiming transactional
rollback. Alpine stable-branch package resolution can differ between the
no-push gate build and the final publisher build, so detailed remote
runtime, package, SBOM and parity verification remains in task #166.

See [ADR-040](adr/ADR-040-release-gated-dual-registry-oci-publication.md).

### ADR-042: Explicit CA-Bound Staging Selection for Certificate Lifecycle

The ordinary certificate producer explicitly selects either Let's Encrypt production or staging, keeping production as the compatibility default while requiring staging opt-in.  The selected CA identity binds the restored account, Certbot `--server`, issuance, selected renewal, and renewal metadata validation, with no mixed account archives or endpoint fallback.  Milestone 4's privileged E2E workflow separately requires explicit staging-only selection and forbids production contacts, including for negative tests.  This refines only the production-only CA assumptions of ADRs 023–025 and preserves ADR-041's independent registration and account-initialization rules.

See [ADR-042](adr/ADR-042-explicit-ca-bound-staging-issuance.md).

### ADR-043: Manually Authorized Staging-Only Live E2E Workflow

Live milestone 4 acceptance runs only through a manually dispatched workflow on the trusted main branch, with an independent pre-network staging-only admission gate and explicit operator confirmation. A credential-free build supplies one checksum-verified public artifact handoff to two separate credentialed runners for genuine staging issuance and S3 publication followed by independent restoration and the normal selected renewal/no-op decision. Registration, production ACME access, automatic privileged CI, forced renewal, and publication of raw secret-bearing evidence are excluded. The operator retains responsibility for account seeding, scoped resources, recovery, and writer serialization; code and mock CI alone do not prove real interoperability.

See [ADR-043](adr/ADR-043-manual-staging-live-e2e-workflow.md).
