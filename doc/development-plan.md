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
