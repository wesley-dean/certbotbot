# certbotbot

certbotbot is a planned standalone Bash tool for issuing and renewing Let's Encrypt TLS certificates through DNS-01 validation.  It restores shared ACME account state and separately managed certificate-lineage state from object storage, uses Certbot to obtain or renew only the requested certificates, generates combined PEM files, and publishes directly installable per-domain archives.  The current executable supports a deliberately side-effect-free `--validate` mode and statically bundled DNS/storage adapter registration.  **Certificate issuance and S3 persistence are not yet implemented**: a normal certificate request fails with status 69.  The automatic release workflow remains gated by the explicit repository variable `CERTBOTBOT_RELEASE_ENABLED=true`.  See [implementation plan](doc/development-plan.md) and [handoff](doc/handoff.md).

## Certificate inputs

A single invocation may accept `certbotbot.bash foo.com www.foo.com` or `certbotbot.bash "foo.com www.foo.com"`.  A multi-line `CERTIFICATES` input describes one certificate per line:

```text
foo.com www.foo.com
bar.com mail.bar.com
```

The first hostname supplies a certificate name.  Both its apex and `*.` wildcard are always requested, even when the first token is wildcard-only.  Remaining SANs are literal.  Omitted certificates are left alone; the tool will not delete or renew unrelated lineages.  Certbot decides when unchanged certificates need renewal; the wrapper has no fixed expiration threshold.

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

These operations are **not yet connected to normal certificate issuance**.
`certbotbot.bash foo.com` still exits 69 without any remote side effects.
The first implementation release must acquire a lock before reading remote
state, validate every restored archive, and publish only after all requested
certificates succeed.  A local lock does not prevent concurrent producers on
different hosts or CI platforms.

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
