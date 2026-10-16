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