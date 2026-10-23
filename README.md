# Certbotbot

Certbotbot manages **one selected Let's Encrypt certificate** using
Certbot's Route53 DNS-01 authenticator and one pre-existing Amazon S3
archive object. The archive stores complete portable Certbot account and
certificate state, so a later invocation can run on a different host.

## MVP runtime contract

**Prerequisites:** install AWS CLI v2, Certbot with `dns-route53`,
OpenSSL, GNU tar/gzip and Bash 4.3+. Configure AWS credentials with
S3 ListBucket/GetObject/PutObject access and Route53 permissions.
The configured bucket and selected object key must **already exist**
and contain a supported `.tar.gz` archive with a previously registered
Let's Encrypt production account. The MVP neither creates an account
nor initializes the missing S3 object.

```bash
certbotbot --s3-bucket my-existing-bucket example.com
certbotbot --s3-bucket my-existing-bucket --cert-name example.com \
  --include-subdomains false example.com
certbotbot --s3-bucket my-existing-bucket \
  --upload-no-renewal true example.com
```

The default object key is `latest.tar.gz`, and
`INCLUDE_SUBDOMAINS=true` requests both `example.com` and
`*.example.com`. Settings resolve as CLI > environment > literal
`.env` file > defaults. The command retrieves the existing archive,
restores it privately, issues or renews the selected certificate,
validates the certificate/key and canonical state, and publishes a
validated archive to **that same key** when needed. Successful
unchanged no-ops skip publication unless the Boolean override is true.

**Operational warning:** A valid invocation can make **live**
AWS/Route53 and ACME requests using existing credentials. It never
invokes global renew-all, registers an account, silently renames a
lineage or generates backup archive objects. The operator must
serialize concurrent writers. An interrupted PutObject may have
modified remote state even when the CLI reports an error; there is no
transactional rollback. Current MVP testing uses **mock** external
services and real local cryptographic/archive tools; actual
AWS/Let's Encrypt/Route53 compatibility remains for a later
end-to-end milestone. The strict renewal metadata dialect may
reject some installed Certbot versions. See
[public lifecycle contract](doc/mvp-public-lifecycle.md) and
[ADR-029](doc/adr/ADR-029-public-selected-certificate-lifecycle.md).

## Maintainer build and engineering guidance

The following build and governance conventions were inherited from
`template-bash` and continue to govern the release artifacts.

This repository is a starter for maintainable, documented, tested, and
releasable Bash projects.  It consolidates engineering patterns proven across
adrctl, bashdeps, Bootstrap, mktext, and bashlog while keeping the starter small
enough to adapt rather than turning it into a framework.

The maintained source is modular.  `make build` assembles that source into three
standalone consumer representations.  The starter also demonstrates deterministic
plugin discovery and runtime registration, but that plugin model is an example to
evaluate rather than a requirement every derived project should preserve.

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

For the default project name, `make build` produces:

```text
dist/template-bash.dev.bash
dist/template-bash.dev.bash.sha256
dist/template-bash.bash
dist/template-bash.bash.sha256
dist/template-bash.min.bash
dist/template-bash.min.bash.sha256
```

The `.sha256` files use conventional SHA-256 checksum-file syntax.  New builds
and releases publish only `.sha256` checksum companions.  Historical releases
that contain `.256` companions remain valid for those release versions; consumers
that automate across release generations should prefer `.sha256` and use `.256`
only when the preferred companion is confirmed absent.

The development artifact retains the verbose Doxygen commentary used for
maintenance.  The ordinary artifact removes full-line comments while preserving
the shebang and behavior.  The minified artifact is derived from the ordinary
artifact with the pinned Bash-Minifier dependency.  All three include executable
version, build-date, and build-commit provenance and are expected to satisfy the
same behavior tests.

For reproducibility, the default build date comes from the current Git commit
rather than the wall clock.  Local builds made while maintained source is dirty
mark the build commit with a `-dirty` suffix so generated provenance does not
imply that modified bytes came solely from the named commit.

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
