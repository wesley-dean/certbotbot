# Bash Starter Repository

This repository is a starter for maintainable, documented, tested, and
releasable Bash projects.  It consolidates engineering patterns proven across
adrctl, bashdeps, Bootstrap, mktext, and bashlog while keeping the starter small
enough to adapt rather than turning it into a framework.

The maintained source is modular.  `make build` assembles that source into three
standalone consumer representations.  The starter also demonstrates deterministic
plugin discovery and runtime registration, but that plugin model is an example to
evaluate rather than a requirement every derived project should preserve.

## certbotbot container deployment

The optional [Docker and rootless Podman producer](doc/container-deployment.md)
runs a verified one-shot certbotbot executable with private ephemeral state;
the existing S3 archive and Let's Encrypt account remain operator-provided.
See the [quick-start commands](doc/examples/docker-podman.md) for local smoke
checks. Container registries and downstream certificate installation have
separate acceptance and responsibility boundaries. Docker and Podman are not
required to run the standalone Bash executable.

## Adapt the Starter

A new project should normally begin by changing `PROJECT_NAME` in the Makefile,
replacing the example CLI and noop behavior as appropriate, and reviewing the
starter ADRs to decide which decisions remain applicable.  `PROJECT_NAME` must
be one non-empty whitespace-free word; conventional names such as `my-tool`,
`my_tool`, or `my.tool` keep generated filenames and Make targets predictable.
Maintained Bash source filenames, including plugin filenames under
`lib/plugins/`, must also be whitespace-free as documented by ADR-004.

The CI and release workflows discover generated Bash artifacts from `dist/`
rather than hard-code `template-bash`, so changing `PROJECT_NAME` does not
require corresponding artifact-name edits in those workflows.

Delete starter behavior that does not belong in the derived project; do not
preserve it merely because it came from the template.  The template intentionally
provides starter files rather than placeholder-only empty directories.

Before a derived project's first release, review repository-facing files such as
`README.md`, `CONTRIBUTING.md`, `SUPPORT.md`, `SECURITY.md`, issue templates, and
the pull-request template.  These are part of the project surface and should not
retain stale template names, unrelated links, or policies copied from another
repository.

## Engineering Posture

The reusable engineering philosophy is documented in
[`doc/engineering-philosophy.md`](doc/engineering-philosophy.md).  It is guidance
for areas where a more specific Accepted ADR does not already govern.

Recurring principles include:

- respect developer agency and make important policy choices explicit;
- prefer bounded contracts and explicit APIs over hidden inference;
- state both promises and non-promises for consequential behavior;
- apply UNIX composition principles deliberately rather than ceremonially;
- keep stdout, stderr, files, exit status, and side effects intentional;
- treat readability and auditability as correctness properties;
- distinguish modular maintained source from product-specific runtime plugin
  architecture;
- keep public surfaces conservative;
- treat every dependency as an expansion of the trusted computing base and a new
  attack surface;
- make network and external-command boundaries visible; and
- avoid claiming boundaries the Bash runtime does not actually provide.

These principles are not substitutes for project-specific decisions.  When a
derived project needs a different contract, record the divergence rather than
preserving a starter convention by inertia.

## Threat Modeling

[`doc/threat-modeling.md`](doc/threat-modeling.md) provides a reusable exercise for
projects that handle sensitive data, untrusted input, destructive operations,
privileged files, network access, release credentials, dynamic loading, or other
security-relevant authority.

The exercise asks projects to identify assets, trusted computing base, trust
boundaries, data and authority flows, threat actors and failure sources,
mitigations, evidence, residual risk, and review triggers.  It includes a Mermaid
trust-boundary diagram template so maintained Markdown can keep architecture and
security reasoning reviewable as text.

Threat modeling is not a blanket declaration that a project is secure.  Its value
is making assumptions and changes in trust or authority visible before they are
normalized as ordinary implementation details.

## Build Lifecycle

The canonical orchestration interface is Make:

- `make deps` synchronizes repository dependencies and may use the network.
- `make deps-check` verifies prepared dependency state offline.
- `make build` creates release artifacts from maintained source and prepared
  dependencies without synchronizing dependencies.
- `make all` runs `deps` and then `build`, so it may use the network.
- `make check` runs Bash syntax validation and ShellCheck.
- `make format` runs shfmt with `-i 2 -bn -ci -sr -kp`.
- `make test` runs Bats against every artifact flavor.
- `make test-report` writes JUnit reports under `test-results/`.
- `make adr-index` generates linked ADR navigation from prepared adrctl state.
- `make docs` generates Doxygen HTML under `doc/reference/` from prepared
  dependency state.
- `make clean` removes build, test-report, generated ADR-navigation, and
  reference-documentation output.
- `make distclean` additionally removes prepared repository dependencies.

Repository dependencies are scripts, libraries, filters, and assets.  bashdeps
does not install system tools or operating-system packages.  The Makefile
bootstraps only bashdeps directly; bashdeps manages Bash-Minifier, the
bash-doxygen filter, and adrctl through `dependencies.txt`.

Dependency acquisition and dependency trust are distinct questions.  Pinning and
checksums help establish that expected bytes were acquired; they do not establish
that those bytes are behaviorally safe or appropriately trusted with project data
and authority.  See ADR-005 and ADR-015.

## Source Modularity

The starter demonstrates an explicit core source order plus deterministic
additive discovery under `lib/plugins/`.  The more general architectural lesson is
that maintained implementation should be split into responsibility-focused
modules, semantically important ordering should remain explicit, and assembled
consumer artifacts should remain deterministic and standalone.

The runtime registry and noop plugin are teaching material for projects that need
name-to-implementation dispatch.  A derived project may remove the registry,
reinterpret additive modules, enumerate every module explicitly, or eliminate
plugin discovery when direct functions are clearer.  Modularity does not imply a
runtime extension system.

See ADR-004 and ADR-014.

## Release Artifacts

For the default project name, `make build` creates **eight** files:

```text
dist/certbotbot.dev.bash
dist/certbotbot.dev.bash.sha256
dist/certbotbot.bash
dist/certbotbot.bash.sha256
dist/certbotbot.min.bash
dist/certbotbot.min.bash.sha256
dist/certbotbot-client.bash
dist/certbotbot-client.bash.sha256
```

The producer retains its three existing representations: documented development,
ordinary/comment-stripped and minified. The consumer is a **separate, single
ordinary-style executable**, not a fourth producer flavor. Each script ships
with a conventional, independently verified SHA-256 checksum companion.
Generated version/build-date/commit metadata remains deterministic for the
same source and chosen version. Only the selected release files (not `vendor/`
or the checkout) are attested and published after all release checks pass.

Historical `.256` checksum companions remain supported only for older
releases confirmed to lack a `.sha256` companion. New releases contain only
`.sha256` companions.

### Standalone certificate client quick start

A certificate-consumer host can download the standalone
`certbotbot-client.bash` and its `.sha256` companion from the
[project releases](https://github.com/wesley-dean/certbotbot/releases)
without installing Certbot, its Route53 plugin, or the issuer. On a trusted
Linux host, first install **Bash 4.3+**, **AWS CLI v2**, **GNU tar**, **gzip**,
and standard GNU core utilities. Configure an existing AWS identity with
read access to the selected bucket/object; credentials and IAM policy remain
the operator's responsibility. Verify the downloaded files *before*
execution:

```bash
sha256sum -c certbotbot-client.bash.sha256
chmod 0755 certbotbot-client.bash
mkdir -m 700 "$HOME/certificate-states"
./certbotbot-client.bash \
  --s3-bucket my-existing-certificates \
  --s3-key latest.tar.gz \
  --destination "$HOME/certificate-states/current-2026-10-25"
```

The chosen destination **must not already exist**. Its parent must exist,
be owned by the invoking user, and not be group/world-writable or
symlink-ambiguous. The example destination uses an arbitrary new
operator-chosen name, not an automatic rotation scheme. On success, the
command prints only the absolute destination pathname and leaves a private
complete Certbot archive tree (including accounts, renewal files, preserved
relative PEM links and all supported lineages).

The term **"latest" means exactly the object currently stored under the
configured S3 key**. The client does not list backups, compare timestamps,
select lineages, choose S3 versions, upload, renew, install or execute hooks.
For a date-derived key, use `--s3-key-template 'archive-{YEAR}{MONTH}{DOM}.tar.gz'`;
the template uses one frozen UTC date. The default literal key is
`latest.tar.gz`. The shared nonsecret `.env` file, environment settings,
and CLI flags follow CLI > environment > literal file > defaults. An
explicit `--config FILE` replaces the implicit `./.env` source.

The client supports either **plaintext gzip-compressed tar**, or the
producer's exact versioned **GnuPG AES-256/OCB authenticated archive**.
Decoded content is limited to 32 MiB and 2,048 members, including
full-state and symlink safety checks. Encrypted restoration additionally
requires trusted **GnuPG 2.4.7+ with actual OCB support** and an
operator-provided exported `GPG_SYMMETRIC_KEY`. The key must never
be placed in a literal `.env`, a CLI argument, a checked-in file,
or a log. Use `--archive-encryption gpg-ocb` to explicitly require
encrypted input, or `auto` (default) to select it when an exported key
is present. Without a key, `auto` uses plaintext and needs no GnuPG.
There is **no format, key, alternate S3 object or legacy OpenPGP
fallback**, and plaintext mode plus an exported key is rejected.

For example, after injecting the secret securely into the environment,
use a fresh absent destination:

```bash
./certbotbot-client.bash \
  --s3-bucket my-existing-certificates \
  --s3-key latest.tar.gz \
  --archive-encryption gpg-ocb \
  --destination "$HOME/certificate-states/authenticated-restore"
```

The operator must configure AWS read-only permissions and obtain the
matching key independently. Coordinate producer-format changes and key
rotation with all consumers; the client cannot migrate, re-encrypt,
or discover old versions. On success it restores **all** validated
account and lineage state to a private, new destination; it never
overwrites an existing destination or independently verifies
certificate-chain trust, installs certificates or restarts services.

The **encrypted client is release-qualified** only when a separate
real-GnuPG shipped-client suite passes without skips against the
exact eight verified release files, alongside the existing three
producer suites, Bash 4.3 checks, attestation and late publication.
A normal runner that skips cryptographic fixtures is not proof of
successful encrypted restoration.

See the [complete client settings reference](doc/client-settings.md),
[secure encrypted and plaintext examples](doc/examples/certbotbot-client.md),
[separate-client contract](doc/separate-client-contract.md),
[retrieval](doc/client-retrieval.md),
[archive activation and threat boundary](doc/client-extraction.md),
[release verification](doc/release-verification.md),
and [ADRs 035 and 037](doc/decisions.md) for detailed options,
failure codes, runtime limits, security assumptions and tests.

## Documentation and Architectural Decisions

This project deliberately treats documentation as part of the engineering
architecture.  Different documents have different jobs:

- `README.md` provides public orientation and starter lifecycle guidance;
- `doc/engineering-philosophy.md` summarizes reusable engineering posture;
- `doc/decisions.md` provides a concise architectural discovery map;
- ADRs under `doc/adr/` preserve durable reasoning, alternatives, tradeoffs,
  consequences, and operational constraints;
- a project specification describes normative observable behavior when a derived
  project needs one;
- `doc/threat-modeling.md` provides a reusable security-analysis exercise;
- `AGENTS.md` is the concise contributor-oriented operational map;
- maintained Bash follows the normative Doxygen standard in
  `doc/documentation-standard.md`; and
- tests provide executable evidence for documented contracts.

Generated Doxygen output is written to `doc/reference/` and is not committed.  The
Doxygen landing page at `doc/adr/README.md` is also generated state: maintained
framing lives in `doc/adr/README.intro.md` and `doc/adr/README.outro.md`, while the
linked ADR list is derived from the current corpus by the pinned adrctl release.
The generated README may therefore be absent from a fresh checkout.

ADR-012 defines the current `.sha256` checksum companion naming and historical
`.256` read-compatibility policy.  ADR-013 treats repository-facing documentation
as maintained product surface.  ADR-014 separates modular source assembly from
runtime plugin architecture.  ADR-015 treats dependencies as explicit attack
surface.  ADR-016 establishes threat-modeling expectations for security-relevant
changes.  ADR-017 governs the ephemeral ADR landing-page model.

Use `doc/decisions.md` as the always-present concise ADR map.  `make adr-index` or
`make docs` generates the linked `doc/adr/README.md` used by the published
reference site.

## Testing

Bats tests live under `tests/` and are intentionally behavior-oriented.  The
starter tests its example help/version interface, plugin discovery and dispatch,
artifact executability, checksum companions, and invalid input behavior.  A
derived project should add focused tests for its real contracts rather than grow
a few oversized fixtures.

The default compatibility floor is Bash 4.3.  Release CI should validate
representative behavior under that version in addition to the primary runner.

Security-sensitive behavior should use negative assertions where appropriate.
Proving that an expected value appears is not enough when the contract also
requires that sensitive, unsafe, or forbidden output never appears elsewhere.

## Releases and Conventional Commits

The release workflow uses Conventional Commits with
`bitshifted/git-auto-semver`.  `feat` increments the minor version,
`BREAKING CHANGE` increments the major version, and supported maintenance commit
types increment the patch version.  The workflow calculates the version without
creating a tag, validates and attests the exact release artifacts, and creates
the release/tag only after validation succeeds.

## Existing Repository Tooling

The upstream template's MegaLinter, CodeQL, Scorecard, Dependabot, issue
management, and related configuration is intentionally retained unless it
conflicts with the Bash build architecture.  Projects may tune those controls to
match repository visibility and available GitHub features.

## License and Contributions

This project is dedicated to the public domain under CC0 1.0 Universal.  See
`LICENSE` and `CONTRIBUTING.md` for details, `SUPPORT.md` for ordinary support,
`SECURITY.md` for vulnerability reporting, and `CODE_OF_CONDUCT.md` for the
project's expectations for respectful collaboration.

## Project Planning Research and Adopted Standards

The research record from the earlier rebuild lives under
[`doc/research/`](doc/research/README.md). The previous implementation
is preserved in [certbotbot-research](https://github.com/wesley-dean/certbotbot-research).
This new repository is the planning destination for an intentionally small
one-domain, one-archive Phase 1. The research documents are **draft or
historical**, not independent implementation authorization. Product scope and
issue backlog are being finalized separately.

The repository adopts a concrete released snapshot of
[wesley-dean/coding_standards](https://github.com/wesley-dean/coding_standards)
under [`doc/standards/`](doc/standards/). The project-root
[`.codingstandardrc`](.codingstandardrc) pins the release version,
source, and archive SHA-256 digest. Applicable general, cross-cutting,
and language-specific standards are governing requirements unless an
Accepted project-specific ADR or explicit local policy refines them.
The bundled examples are illustrative. Imported files must not be edited
locally; project exceptions belong in local governance (ADR-018).

### Opt-In Three-Phase Development

This repository **explicitly opts in** to the three-phase development
governance introduced in coding standards v2.2.0, as recorded by
`three_phase_development = true` in `.codingstandardrc`. The
[governing standard](doc/standards/general/three-phase-development-governance.md)
defines separately approved stages:

1. **Project planning:** Product Owner-approved user stories, measurable
   acceptance criteria, scope, and priorities; Project Manager support.
2. **Technical planning:** Linked engineering tasks, reviewed ADRs,
   dependencies, and Technical Architect approval for development.
3. **Development:** Implement approved tasks, link PRs, and independently
   verify acceptance criteria before marking stories complete.

GitHub Issues, issue links, milestones, and labels record the backlog
and handoff between phases. No GitHub Projects board is required.
The current `approved` label is the authoritative and sufficient workflow
approval record for an individual issue's scope and phase. The Product
Owner decides story approval, and the Technical Architect decides task
approval; authorized humans may apply labels or direct agents to do so
for identified issues. A separate approval comment is not required.
Approvals do not transfer between issues or phases, and materially changed
scope must lose its label until reapproved. Agents cannot self-approve.
Labels do not replace security, ADR, or PR review controls (ADR-019).
Research drafts do not constitute such approval.
