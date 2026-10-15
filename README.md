# Bash Starter Repository

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
