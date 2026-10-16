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
