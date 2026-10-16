# ADR-023: Standalone Release Artifacts, Pinned Dependencies, and Optional Runners

Date: 2026-10-15

## Status

Accepted

## Intent and Documentation Posture

Reuse the inherited Bash project build lifecycle and make the script, not Docker or a particular CI platform, the product.

## Context

The predecessor required Docker.  The replacement must be usable as a downloaded release artifact without a container or a CI agent.  The template already provides three artifact flavors, generated SHA-256 sidecars, offline build targets, Bats tests, bashdeps bootstrapping, adrctl documentation, and GitHub Pages workflow infrastructure.

## Decision Drivers

- The executable must be a self-contained Bash file.
- Development modules and bundled provider code must assemble deterministically.
- Dependencies and provenance must be verified and inspectable.
- Docker, Jenkins, and GitHub Actions are optional wrappers around identical CLI semantics.
- Documentation and release tooling must preserve existing network boundaries.

## Decision

Release `certbotbot.dev.bash`, `certbotbot.bash`, and `certbotbot.min.bash` with corresponding `.sha256` companions under `dist/`.  The development flavor retains documentation; the ordinary flavor removes full-line comments while preserving shebang and behavior; the minified flavor is produced from the ordinary artifact.  Every variant must pass the same behavioral suite and expose version/build provenance.

Use the existing Makefile's pinned, digest-verified direct bootstrap of `vendor/bashdeps.bash`; `vendor/bashdeps.bash` does not appear in `dependencies.txt`.  Bashdeps shall acquire pinned/verified releases or commits of bash-doxygen, mktext, Bash-Minifier, adrctl, and bashlog into `vendor/`.  Only runtime library code from reviewed bashlog/mktext dependencies that is actually needed may be embedded into generated release artifacts; documentation and build tools must not become runtime dependencies.  `make deps` may access the network, while `make deps-check`, `make build`, `make docs`, and tests after preparation remain network-free.  Runtime system commands (Certbot, DNS plugin, AWS CLI, GPG when configured, tar) are prerequisites of issuer execution and not bashdeps-managed system packages.

The initial `examples/Jenkinsfile` and `examples/certbotbot.yml` demonstrate passing line-oriented `CERTIFICATES`, secrets, and serialization to the same release executable; neither contains duplicate certificate logic.  The existing `.github/workflows/static.yml` publishes generated documentation to GitHub Pages using prepared bashdeps/doxygen/adrctl.  Docker packaging is optional, includes the shipped DNS plugin and GPG, and is not automatically published by the first implementation.  Docker image publishing is deferred.

## Promises

- All three release flavors include the same reviewed, built-in DNS/storage implementations.
- No `vendor/`, source checkout, or injected runtime Bash plugin directory is required to execute an artifact.
- A native executable, CI wrapper, and Docker image invoke equivalent certificate logic.
- SHA-256 companions identify their corresponding published artifact bytes.

## Non-Promises

- A standalone Bash artifact does not bundle system commands, shared libraries, or host AWS credentials.
- Checksums identify exact bytes; they do not independently authenticate a publisher or certify safety.
- The presence of Docker or CI examples does not make those runtimes mandatory.
- The initial Docker image is not promised to have a DockerHub release.

## Adversary and Failure Model

Build dependency substitution, corrupted release assets, accidental runtime code downloading, stale template references, executable flavor divergence, token exposure in CI, dependency transitive authority, and publishing before checks complete create risk.  Pin dependencies, verify digests, run the entire artifact behavior matrix, and keep release credentials separate from untrusted PR evaluation.

## Operational Constraints

- Make SHALL directly bootstrap only pinned bashdeps.
- Bashdeps SHALL manage bash-doxygen, mktext, Bash-Minifier, adrctl, and bashlog.
- Build and documentation targets SHALL remain offline after dependency preparation.
- CI and Docker MUST be optional execution environments.
- The existing Pages workflow MUST continue to publish generated documentation.
- Released plugins SHALL be included at assembly time, not fetched at runtime.

## Considered Alternatives

A Docker-only workflow was rejected as an unnecessary execution constraint.  CI-specific certificate scripts were rejected because they would multiply behavior and tests.  Embedding entire external build tools in releases was rejected because it expands the runtime trust surface.  Publishing one script flavor only was rejected in accordance with inherited ADR-006.

## Consequences

System prerequisite installation is documented separately from repository dependency synchronization.  The Makefile and manifest require adaptations during implementation, but the inherited build architecture remains authoritative.

## Related Decisions

This decision specializes inherited ADR-003, ADR-005, ADR-006, ADR-009, ADR-012, and ADR-017.
