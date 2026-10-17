# certbotbot Full Implementation Plan

Date: 2026-10-15

Status: Documentation-first implementation plan; work described here is not yet complete.

## Baseline and principles

Repository: `wesley-dean/certbotbot`, default branch `main`, derived from `template-bash`.  Start each change by reviewing `README.md`, `AGENTS.md`, `doc/decisions.md`, applicable Accepted ADRs, `doc/standards/`, and the project specification.  Keep reviewable scoped PRs.  Adopt the existing three-flavor build and Make target contracts rather than rewriting infrastructure needlessly.

`certbotbot.bash` is the product.  Docker, Jenkins, and GitHub Actions invoke it as optional wrappers.  No ACME, Certbot, or producer script is installed on consuming TLS servers.

## Phase 0: Documentation and governance (this PR)

- Import the complete verified latest stable coding standards snapshot and record its version/digest.
- Make project-specific policy mandatory in agent/contributor-facing docs.
- Accept ADR-018 through ADR-024; update `doc/decisions.md`.
- Publish a normative product specification and explicit STRIDE threat model.
- Produce this plan and a handoff document.
- Keep template executable and tests unchanged until a subsequent implementation PR.
- Confirm existing `.github/workflows/static.yml` continues to generate GitHub Pages documentation, and avoid hard-coded counts of ADRs.
- Review stale template references in support, security, issue, and release materials before first release.

Acceptance: new docs are internally consistent, `doc/standards/` matches the released standards tag, `.codingstandardrc` has concrete provenance, and a PR against `main` is available for review.  CI documentation generation may require prepared dependencies.

## Phase 1: Build foundation and dependency convergence

- Update `PROJECT_NAME` and generated metadata names to `certbotbot`, retain `SHELL := /bin/bash` and strict shell flags.
- Retain the pinned, checksum-verified bashdeps bootstrap in Make; do not put bashdeps in its own manifest.
- Add pinned, digest-verified manifest dependencies: bash-doxygen, mktext, Bash-Minifier, adrctl, bashlog.
- Define which bashlog and mktext source portions may be safely embedded; keep documentation/build dependencies out of runtime artifacts.
- Define explicit core source order and lexically discovered leaf provider modules; remove the starter noop plugin before release.
- Make three release artifacts and `.sha256` companions deterministic, standalone, and functionally equivalent.
- Keep `make deps` network-capable; `make deps-check`, `make build`, `make docs`, and `make test` consume prepared dependencies offline.

Acceptance: `make deps`, `make deps-check`, `make build`, `make check`, and a smoke Bats suite validate all release flavors, with no unexpected network in offline targets.

## Phase 2: Core CLI, provider registry, and mocked operations

- Implement explicit `CERTIFICATES` input parsing and positional equivalence, whitespace-safe handling, wildcard-only first token, deterministic SAN sets, and archive-name validation.
- Separate DNS provider and storage backend contracts; build-time discover `route53` and `s3`, register implementations internally, fail for unknown providers.
- Use bashlog for diagnostics without secrets, define stdout/stderr and exit status contracts.
- Provide isolated filesystem workspace and host-local lock.
- Mock certbot/AWS CLI/GPG and assert call arguments, selected lineage scope, error handling, and no `eval`/globbing.
- Add Bash 4.3 representative runtime tests and minimum-version check.

Acceptance: no real network required, negative tests verify no provider dispatch or remote writes after invalid input, all three artifacts exhibit the same behavior.

Phase 2 may be split into a preflight/registry PR and a follow-up for local serialization and mocked external commands.  The first PR deliberately leaves DNS/storage adapters inert and avoids claiming issuance.

## Phase 3: Certbot/Route53 issuance and renewal

- Implement common account restore, conditional registration with `REGISTER_ACCOUNT=true`, `AGREE_TOS=true`, and `EMAIL` on registration.
- Implement one named lineage per requested group, DNS-01 Route53 plugin, and exact SAN reconciliation through current supported Certbot flags.
- Use Certbot's built-in renewal decision; no hard-coded 90/60/45-day thresholds.
- Generate both `live/<name>/combined.pem` and `combined/<name>.pem` as fullchain followed by private key.
- Test fresh issuance, no-op renew, changed SAN set, omitted lineage untouched, wildcard-only input, and failed DNS authorization.

Acceptance: integration tests against Let's Encrypt staging with scoped Route53 credentials and test DNS names; ensure no production-rate-limit assumptions.

## Phase 4: Split archives and object-store persistence

- Restore common account state once; restore and discard each domain lineage independently.
- Implement confirmed-missing vs unauthorized/failed object lookups, archive layout, extraction safety and symlink/member validation.
- Implement S3 `BUCKET` and optional `S3_ENDPOINT_URL` support (including MinIO-compatible test service).
- Package archives so domain-only extraction into `/etc/letsencrypt` makes regular TLS paths usable; common archive remains producer-only.
- Stage and validate every output before any publish.  Document partial-write recovery and S3 versioning advice.
- Use mktext for archive-pattern support only after defining collision-safe pattern substitutions in the specification and ADR; keep default latest names stable.

Acceptance: extract two independently produced domain archives into one fresh directory and verify keys/certs/relative symlinks, combined PEM ordering, and non-overlapping members; no Certbot on consumer.  Test unsuccessful storage reads and uploads.

Phase 4 may be split into a strict per-domain tar manifest preflight
(ADR-026), safe staged extraction and post-extraction verification, shared
ACME account state handling, and S3 publication.  The manifest preflight
is not a production restore implementation and must never be treated as
such.

Phase 4B adds isolated per-domain staging and independent verification of
the extracted filesystem (ADR-027).  It deliberately stops before merging
into active Certbot state; common-account restoration, renewal metadata
portability, and cryptographic verification remain separate work.

Phase 4C adds an account-only common archive staging contract under ADR-028.
It does not yet trust or select an ACME account, perform renewal metadata
portability adjustments, merge restored state, or publish objects.

### Cross-environment portability release gate

Before enabling the public issuer, prove continuity across three fresh,
distinct workspaces representing Jenkins, GitHub Actions, and EC2: first
issuance, account reuse/no-op renewal, and subsequent SAN change or due
renewal.  Compare restored ACME account identity, verify live links and
renewal metadata after moving workspaces, and confirm consumers can use
the domain archive without the common archive.  Delete each producer
workspace between invocations.  Test failure on missing or corrupted
shared account state when a domain lineage exists.  Execute serially
until storage-backed locking is available.

### Pre-publication certificate verification and environment selection

Issue #12 is a release-critical runtime verification gate.  An internal
OpenSSL validator is introduced under ADR-029 and MUST be wired into
the eventual producer after PEM assembly and before publishing any
objects.  Test valid EC/RSA keys, incorrect key pairs, expired/malformed
certificates, untrusted/intermediate chains, and corrupt combined outputs.
Add an orchestration-level negative test showing verification failure
leaves existing S3 state unchanged.

Issue #11 adds an explicit opt-in Let's Encrypt **staging** mode with
production as the default.  Treat staging and production as separate
certificate/account namespaces, even for an identical requested lineage.
Ensure the correct ACME server and CA trust context are selected, and
include both modes in fresh-workspace integration tests.  This is a
pre-release requirement if staging is used for safe end-to-end testing;
it does not justify opening arbitrary ACME URLs in the first release.


### Issue #11: production/staging mode selection

Implement a production-default selector, a fixed Let's Encrypt staging
endpoint, and storage key separation without renaming production archives.
The explicit staging option and `ACME_ENVIRONMENT` variable select
`staging/<archive-key>`; production remains unprefixed.  Reject cross-mode
reads/writes in the built-in S3 provider and unknown ACME endpoints.
An internal implementation and Bats tests are staged under ADR-030.

Before live issuance, verify selected Certbot account/renewal metadata
belongs to that ACME server, provide isolated staging test trust roots
for ADR-029, and run complete cross-environment portability tests.  A
valid staging certificate is not publicly trusted and must never replace
the production archive with the same lineage identity.


### Phase 4D: verify restored account/environment identity

ADR-031 adds an internal read-only check that a staged lineage renewal
file references the exact selected production/staging Let's Encrypt
server and a complete restored account in the correct authority
directory.  Duplicate critical fields, missing account files,
unknown authentication, and unsafe hook metadata fail closed.

This check must be used by the future issuer before Certbot, but it does
not itself select the account or solve renewal path portability.  The
next integration step must prove account selection, safe renewal metadata,
and fully portable paths across freshly created runner workspaces.
No live issuer or release gate is enabled by this step.


### Phase 4E: isolated candidate renewal path rebase

A testable internal preview now validates that all five standard
path-bearing renewal keys agree on one original root and lineage,
after checking the correct restored account and ACME environment.
It produces a separate private file pointing to the new ephemeral
workspace, without touching original archive bytes or invoking Certbot.
ADR-032 documents this constrained experiment.

The portability strategy cannot become an active issuer step until
real supported Certbot files demonstrate registration continuity,
no-op renewal and SAN replacement in independent workspaces, plus
safe archival after renewal.  These tests remain a release blocker
under ADR-025.  The preview alone does not close that gate.


### Phase 4F: supported Certbot read-only loader verification

An isolated GitHub Actions workflow pins Certbot 5.8.0 and checks that
its actual local `certificates` command can inspect a complete, synthetic
lineage after the source workspace has been deleted and path-bearing
renewal values have been relocated.  The harness uses the staged
domain/common archive helpers, verifies original key bytes, and exercises
all three standalone artifact variants.  ADR-033 permits test-only
installation of the otherwise non-activating ADR-032 preview.

This verifies only local Certbot loader compatibility.  The release
still needs integration with **Certbot-issued** accounts and certificates,
working Route53 staging DNS-01 challenges, no-op renewal, intended SAN
changes, and preserved external state across Jenkins, Actions, and EC2.
No public issuance or publication path is activated.

### Phase 4G: real Certbot no-op decision on restored state

ADR-034 permits CI-only invocation of actual Certbot 5.8.0
`renew --cert-name` for a 90-day locally issued fixture restored
under a different private workspace root.  The original workspace
must be removed, Python socket connection APIs must be blocked by a
test-specific guard.  Certbot 5.8.0 may request ARI DNS resolution despite
correctly deciding that no renewal is due; this DNS attempt is blocked,
and any other socket use must fail.  Certificate/key bytes and core
renewal settings must remain unchanged.  Certbot may append a
validated ARI retry-after value despite a no-op.  Test local repackaging
of that metadata, without publishing it.  Both the common-account archive and the selected
domain archive must be restored before this check, with account-key
identity preserved.  All three release artifact flavors run the test.

This does **not** close the release gate for real ACME account reuse,
due renewal, SAN changes, or publication.  Those require environment-
protected staging credentials and independent end-to-end validation.

### Phase 4H: repeated fresh-run continuity of ARI metadata

Extend the real Certbot 5.8.0 compatibility job to three independent
workspaces.  B restores the initial account and lineage, records a
guarded ARI scheduling change while making a no-op renewal decision,
and repackages the domain archive.  C validates and stages only
the common archive from A and the updated domain archive from B.
After A and B have both been destroyed, C must inspect the lineage
and make another real no-op decision with the original account,
certificate/key material, and retained ARI scheduling metadata.

ADR-035 governs this isolated testing extension.  A successful
test does not implement remote publication of ARI-only changes or
satisfy due-renewal, SAN update, and real account requirements.


### Phase 4H: exact DNS SAN verification before publishing

ADR-036 establishes a second independently testable OpenSSL gate that
compares the actual leaf's DNS SAN set with the current normalized
request.  It rejects missing, unexpected, duplicated, malformed,
and non-DNS identities; the CN cannot substitute for an absent SAN.
The apex/wildcard identities are independently required, and
additional SANs are neither inferred nor silently retained.

Before live issuance or any state-only archive update becomes active,
the issuer must run **both** this check and ADR-029's chain/private-key
check against the current request.  Negative integration tests must
prove every failed check prevents all S3 writes.  The current helper
does not enable public issuance.

## Phase 5: Optional symmetric encryption and migration

- Honor `GPG_PASSPHRASE` unset/empty plaintext `.tar.gz`, nonempty GPG AES-256 `.tar.gz.enc`.
- Pass passphrase through controlled descriptor/pipe, never command arguments or logs.
- Enforce uniform mode for common and domain archives; fail closed on wrong format and GPG errors.
- Add clear README procedures for plaintext-to-encrypted and encrypted-to-plaintext migrations and recovery/cleanup considerations.
- Test passphrase secrecy, archive round trip, corrupt ciphertext, mismatched mode, and failed encryption blocking uploads.

Acceptance: encrypted S3 objects contain no intentionally uploaded plaintext tar state; restoring ciphertext reproduces the expected deployable layout.

## Phase 6: Optional execution environments and documentation site

- Add `examples/Jenkinsfile` with multi-line Jenkins `CERTIFICATES` parameter and `disableConcurrentBuilds()`; secure AWS credentials and passphrase injection.
- Add `examples/certbotbot.yml` using `workflow_dispatch` multi-line string, OIDC-capable AWS auth, and GitHub Actions concurrency controls.
- Add optional Dockerfile/image with Certbot, Route53 plugin, AWS CLI, tar, GPG, and released Bash executable; publish image only in a later explicitly authorized change.
- Validate `.github/workflows/static.yml` Pages generation and references for the new ADR collection.
- Finalize README installation, runtime prerequisites, deploy-only example, migration, failure/recovery, and support docs.

Acceptance: reproducible native execution, CI example lint/review, container smoke test, published documentation build, no Docker requirement for CLI operation.

## Phase 7: Production readiness and release

- Test all three artifacts with checksum verification, ShellCheck, shfmt, Bats, offline build boundaries, and Bash minimum-version runtime.
- Add provider/storage integration tests against dedicated nonproduction accounts and endpoints; document required IAM/Route53 policies.
- Verify tar path handling, private-key modes, no unexpected secret output, installation into common `/etc/letsencrypt` for two lineages, and recovery from interrupted/mismatched state.
- Review code scanning, supply-chain permissions, dependency provenance, and the project threat model.
- Update project-facing inherited template files; generate Doxygen and GitHub Pages output.
- Only after checks succeed, tag a release and publish the three artifacts and hashes via existing release governance.

Acceptance: documented supported environment matrix, reviewed release artifacts, real staged issuance evidence, consumer install evidence, and no unresolved critical threat-model gaps.

## Backlog after first release

1. Storage-backed distributed lease/lock, fencing tokens, and stale-lock recovery across native/Jenkins/GitHub Actions writers.
2. Additional reviewed DNS-01 backends; no runtime third-party plugin loader.
3. Non-S3 object stores as proven necessary.
4. Archive rotation/history with fully specified mktext templates, retention, and rollback.
5. GPG passphrase rotation, alternate encryption/signing, optional publisher authentication, and key-management guidance.
6. Stronger multi-object generation coordination (manifest/version pointer) if concurrent publishing and consumer consistency require it.
7. DockerHub image publication, version pinning, and provenance attestations.
8. Additional deployment sample wrappers or integrations; service reloads remain consumer-owned.

## Handoff readiness conditions

Before each phase, review branch baseline and inherited governance, capture assumptions, and create/update accepted ADRs for consequential behavior changes.  Never claim an example, unit test, or mocked result proves successful production issuance without end-to-end verification.

### Phase 4I: controlled active-import boundary (ADR-037)

Staged account and domain archive assessment remains non-activating while genuine ACME evidence is incomplete. Existing identity, archive, and path-preview validators may be composed into test-only preparation, but no preview is installed into active Certbot configuration. Before active import, demonstrate Let's Encrypt staging account registration and reuse, no-op renewal, and due renewal or changed SANs across independent workspaces. Review the complete renewal-option trust boundary. A subsequent Accepted ADR must define the active import and rollback mechanism. Normal issuance continues to fail with status 69, and automatic releases remain gated.

### Phase 4I: restored renewal-option allowlist (ADR-038)

The internal archive-to-assessment flow now checks the entire supported
Certbot 5.8.0 Route53 renewal configuration profile, including optional
DNS-only tuning and recognized ARI retry scheduling, before preparing a
non-activating renewal-path preview.  This complements ADR-031's account
identity and ADR-032's canonical path requirements but does not replace
live account registration evidence.  Unsupported persisted settings,
hooks, installer options, foreign credentials, and renewal timing controls
fail closed.  Three artifact flavors, negative Bats tests, and the
three-workspace network-guarded Certbot smoke test exercise the boundary.
Normal issuance and object-store publication remain disabled.

### Phase 4J: classified S3 retrieval (ADR-039)

The internal S3 read path can now stage the entire selected common/domain
object collection using the fixed production or staging namespace and
typed object-presence results.  The only currently recognized missing-object
signature is AWS CLI GetObject NoSuchKey; denied, ambiguous 404, and
transport errors fail closed.  Newly requested domains may be absent when
their common account exists, but a missing common archive alongside any
existing domain is inconsistent.  Private bytes are not valid Certbot
state until all existing archive and account identity checks succeed.
The public issuer, GPG handling, S3 publication, and automatic release
remain disabled until their separate prerequisites are met.

### Phase 4K: remote collection assessment (ADR-040)

The producer now has a private, non-activating path from selected
production/staging S3 object names through typed retrieval to complete
archive assessment. Common state is validated whether or not requested
lineages already exist. All present lineages pass the existing batch
validators before confirmed-missing domain names are reported. Failed
retrieval, corrupted state, foreign account identity, unsupported renewal
options, and unsafe active workspaces must leave no retained downloads or
partially imported Certbot state. This is preparatory only: authenticated
ACME account reuse, active state import, new issuance, encryption, and
multi-object S3 publication remain separate release gates.

### Phase 4L: optional encrypted archive format (ADR-041)

The original ADR-021 symmetric encryption contract is now implemented
in the internal local preparation and private retrieval boundary:
GPG uses AES-256 with a non-argv passphrase FD; source and destination
files remain owner-private, and a disposable GnuPG home avoids persistent
runner keyring state. A nonempty `GPG_PASSPHRASE` selects the
`.tar.gz.enc` format for both common and domain objects. No-passphrase
mode selects plaintext `.tar.gz`. The retrieval path probes a missing
selected-mode key for a conflicting opposite-mode object but never
treats that alternate as a valid fallback. Failed or partial decryptions
cannot authorize account registration or a fresh collection.

New Bats tests exercise local encryption, wrong passwords, damaged
ciphertext, encrypted two-lineage restoration across independent
workspaces, format mismatch, and cleanup in every standalone artifact.
A manual migration guide covers complete collections and recoverability.
GPG-enabled **publication** remains blocked by the unfinished producer
orchestrator and ADR-022 remote failure/rollback protocol.

### Phase 4M: verified local publication candidate (ADR-042)

An internal pre-publication coordinator now snapshots a complete local
common/lineage archive collection and verifies each selected certificate
against the exact authorized apex/wildcard SAN request. Trust-chain,
private-key match, combined PEM, account identity, renewal-option, and
lineage portability failures prevent candidate completion. Successful
candidates contain deterministic common-first S3 keys and privately
frozen plaintext or AES-256 encrypted object bodies, but no AWS PutObject
operation occurs.

CI tests use locally CA-signed certificates, trust bundle overrides for
controlled fixtures, and assert no cloud mutation in all three standalone
artifacts. Publication itself remains a separate guarded milestone with
partial-write recovery and last-known-good version retention. Real
Let's Encrypt staging registration, due renewal and SAN changes across
independent runners must precede activating restored Certbot state.

### Phase 4N: exact-byte remote recovery checkpoint (ADR-043)

The local publication candidate now binds its original S3 bucket and
environment, and a new internal read-only checkpoint retrieves and
validates the complete previous common/domain collection.
A successful checkpoint records per-key existence, SHA-256 digests,
and exact prior object bytes in a private directory. Encrypted
archives retain their original ciphertext for potential restoration;
their separate decrypted copies are used only for validation.

A complete absence remains distinct from corrupt or denied state,
and a missing common account alongside an existing domain remains
fatal. Tests use only local mock AWS reads across all three standalone
artifacts; no PutObject call or release is authorized. This prepares
a later remotely durable publication and partial-failure recovery
design, but is not itself sufficient after a runner crash.

### Phase 4O: inactive staging portability evidence example (ADR-044)

An opt-in, **non-installed** GitHub Actions example documents a
four-runner investigation of real Certbot 5.8.0 Route53 staging
issuance, encrypted split-state handoff, account reuse, no-op renewal,
changed SANs, and independent final restoration. It resides under
`examples/github-actions/real-staging-evidence.yml` rather than
`.github/workflows/`, and does not create an operational workflow
upon merge. The harness remains at
`tests/integration/live-staging-portability.bash`.

Only a deliberate operator installation in a controlled repository
with protected staging credentials, OIDC DNS scope, CA trust, and
manual authorization can initiate the real test. Normal CI exercises
only credential-free guards. This example is **not live evidence**,
does not relax ADR-037, and requires no Checkov exception in the
maintained operational workflows. S3 crash recovery, two coexisting
active lineages, and failure-atomic activation remain separate gates.

### Phase 4P: non-activating complete import candidate (ADR-045)

The private preparation path now assembles one fully validated
common-account tree with any explicitly selected, unique lineages
into a fresh, inactive Certbot-shaped candidate directory.
All source archive bytes are frozen before assessment, and the
existing account/renewal validators and candidate-relative path
preview gate each member. Failed validation or assembly discards
the candidate without touching the active config.

This closes a local multi-lineage composition gap, not the production
active-import gate. Synthetic test fixtures cannot verify registered
Let's Encrypt account continuity, live renewals, SAN changes, or
rollback under a failed active install. Those requirements and
durable S3 publication remain outstanding under ADRs 037 and 022.

### Phase 4Q: local pre-publication recovery manifest (ADR-046)

A private, read-only plan records the exact S3 keys and byte hashes
of both the proposed cryptographically verified collection and its
validated previous-state checkpoint. It distinguishes existing,
missing, and newly proposed objects without accepting a failed
GET as evidence of absence. The plan's manifest and both byte
collections are rehashed before the internal plan is trusted.

This milestone is strictly offline; it does not issue, upload, or
grant release authorization. The next operational publication
decision must establish durable remote backup generations,
verification after writes, crash recovery from an independent
runner, explicit handling of previous absence, and ordered latest
aliases under ADR-022. Genuine staging evidence and ADR-037's
activation ban remain unchanged.

### Phase 4R: write-once durable S3 recovery generations (ADR-047)

A guarded internal helper can now preserve exact validated previous
account/domain object bytes under generation-scoped S3 backup keys,
using conditionally created PUTs, read-back hashing, and a manifest
committed last. The verifier can run on a fresh host with only
the bucket, environment, generation ID, and trusted manifest SHA-256.
The retained ciphertext (or plaintext when configured) matches the
original remote bytes; fully absent prior keys remain explicit.

This is the first **remote mutation** milestone, but it writes only
to the reserved recovery prefix, requires affirmative internal
authorization, and never touches latest archive aliases or the
product entrypoint. Failure can leave incomplete orphaned backups
but cannot claim a completed generation. The next publication ADR
must cover current-state checks, safe latest writes, partial failure
and crashed-writer recovery, and external serialization. Real ACME
staging evidence and active Certbot import remain blocked.

### Phase 4S: remote latest-state freshness precondition (ADR-048)

A non-publishing S3 preflight now re-reads the exact previously
selected latest-object keys and compares their raw bytes or
confirmed absence against the ADR-043 checkpoint. It first
revalidates ADR-046's proposed/prior manifest to ensure that
no local input changed. Any remote drift, changed archive
mode, or denied/indeterminate fetch aborts without cloud writes.

This closes stale-remote-read detection as a preparatory step,
not an atomic remote lock or compare-and-swap. Cross-platform
writers still need external serialization, and the next S3
publication milestone must govern conditional latest writes,
partial failure recovery, and independent runner restoration
under ADR-022. Active Certbot use still requires real staging
evidence and a separately accepted ADR.

### Phase 4T: read-only ETag-bound S3 publication predicates (ADR-049)

A new internal helper captures complete common-first S3 condition
tokens for the selected publication keys after verifying the local
plan and rerunning the ADR-048 remote drift precondition. For each
previously present object it binds a server-issued ETag to an
`If-Match` conditional GET whose downloaded bytes must exactly
match the prior checkpoint. Previously absent objects receive a
distinct no-existing-object predicate, and no partial captures
are returned on failure.

This prepares a future per-key conditional PUT protocol; it does
**not** perform any upload, supply an atomic multi-key transaction,
or replace required external serialization. Publication still
needs tested partial-write rollback and crash recovery before the
latest aliases can be mutated. Real staging evidence and active
Certbot import remain withheld under ADR-037.

### Phase 4U: guarded conditional S3 publication and rollback (ADR-050)

A new explicitly authorized internal protocol links the existing proposed
archive collection, previous-state checkpoint, durable recovery generation,
remote drift preflight, and ETag-bound predicates into one guarded publication
operation. All latest alias PUTs use object-level S3 conditions and byte-for-
byte readback, while an ambiguous or partial failure retains the completed
recovery generation for operator action.

The companion recovery operation works from an independent runner with only
a trusted recovery identifier/checksum and storage credentials. It preflights
every selected current key against old/proposed bytes before any mutation,
then uses conditional reverse-order restoration, including conditional DELETE
for keys that were originally absent.

The internal writer is **not a public feature**. Real AWS/S3-compatible
integration, explicit operator serialization, genuine Let's Encrypt staging
portability, and a separate ADR-037 activation decision are the remaining
end-to-end release gates. Multi-key transactions and distributed storage
locking are not claimed.


### Phase 4V: opt-in real S3 conditional API and independent recovery evidence

The `test-s3-interop` Make target runs both actual S3 API operations and
the internal ADR-047/050 recovery protocol against a disposable,
operator-controlled loopback S3-compatible endpoint. Every release flavor
receives full/partial/first-run/conflicting-writer/crashed-worker scenarios.
A killed worker cannot pass its private filesystem to the recovery process;
only the separately recorded verified recovery generation and manifest
checksum survive. Credential-free Bats guards prevent normal CI from
crossing this network and remote mutation boundary.

ADR-051 adds a digest-pinned, disposable SeaweedFS S3 service in a
read-only-permission GitHub Actions workflow for pull requests and manual
dispatch. It executes this Make target on all three release artifacts without
real AWS, DNS, or ACME authority. A passing run demonstrates tested-emulator
interoperability only, and requires review of the actual GitHub job evidence.
External serialization, real AWS backend behavior, genuine Let's Encrypt
staging continuity, and active-state import remain separate release gates.
See `doc/s3-interoperability.md` and ADR-051.


### Phase 4W: complete the real two-lineage staging evidence harness

ADR-053, as amended by ADR-055, extends the inactive ADR-044 real staging
workflow with a second **base-plus-wildcard** staging Certbot lineage and
a fresh, read-only two-lineage
candidate validation runner. The first certificate retains its previous
three-name SAN set, the second has a separate concrete name in the same
authorized zone, and both must use the exact previously registered staging
ACME account. Archives remain common/account plus **separately
encrypted, disjoint domain objects**, not an all-lineages archive.
Credential-free Bats guards and source packaging tests cover absent
consent and cross-lineage member leakage.

This code **does not establish real staging success by itself**. The
operator must manually install and approve the separately governed example
using a protected staging role and explicitly review all six genuine
runner results. The public issuer remains disabled under ADR-037.


### Phase 4X: end-to-end read-only S3-to-cryptographically-verified import candidate

ADR-054 joins existing typed and optional-GPG S3 collection retrieval to
ADR-045's complete multi-lineage candidate assembler, followed by the
ADR-029/036 chain, key, and exact SAN gates. It performs **one complete
remote retrieval** and checks every selected lineage for presence before
assembly; a fully missing collection retains status 10 and missing
members cannot cause accidental registration. The downloader is cleaned
up even after errors, and any failed verification removes the entire
candidate rather than leaving partially approved private state.

This internal preparation flow is intentionally **non-activating**. Actual
live Let's Encrypt staging evidence, an Accepted activation ADR,
first-run account registration, final producer orchestration, and
real AWS IAM/storage evidence remain separate release gates. Normal
certificate requests continue to return 69.


### Phase 4Y: one-step offline staging IAM preparation

ADR-056 adds a Bash-only, credential-free document generator for a
single protected GitHub OIDC staging environment and three precisely
scoped Route53 DNS-01 TXT record names. Its output is policy JSON,
not changes to IAM, GitHub workflow installation, or staging issuance.
This removes manual permission authoring from Issue #46 while keeping
operator consent and real six-runner evidence as release gates.
