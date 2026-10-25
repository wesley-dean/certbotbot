# ADR-039: Alpine 3.24 Runtime and Bounded Package Updates for the OCI Producer

Date: 2026-10-25

## Status

Accepted

## Context

[ADR-038](ADR-038-verified-oci-producer-images.md) chose Debian 13 slim,
a fixed Debian package snapshot, and a reviewed image digest as the initial
distribution for the OCI producer. The source-compatible ordinary Bash
producer requires Bash 4.3+, AWS CLI v2, Certbot with Route53 DNS support,
GNU archive and filesystem utilities, OpenSSL, CA trust, and GnuPG 2.4.7+
with actual AES-256/OCB support. The read-only standalone client does not
belong in the image.

During the review of task #161 / PR #195, the technical lead requested
Alpine rather than Debian. Alpine 3.24 publishes the necessary AWS CLI v2,
Certbot, Route53 plugin, and GnuPG 2.4.9 packages. The release-series
repository model permits bounded maintenance updates without selecting
an archival operating-system package snapshot for every rebuild.

The earlier Debian choice was a conservative assumption about package
availability, **not** a product requirement. The runtime image had not been
successfully built or accepted under Docker or Podman. Existing eight-file
Bash release identity, source/manifest verification, image provenance,
nonroot execution, secret boundaries, release and registry gates must stay
unchanged.

## Decision Drivers

- Reduce package-acquisition and patch-update complexity without losing
  a known supported Alpine release family.
- Keep image base bytes immutable for a specific build by pinning a
  complete, verified Linux/amd64 OCI manifest digest.
- Install only packages from the Alpine v3.24 **main and community**
  repositories; exclude edge, testing, and other branch repositories.
- Retain a bounded explicit major/minor version constraint on the
  compatibility-critical runtime packages.
- Keep installed transitive package versions inspectable after every build.
- Test actual Bash/GNU command semantics, AWS CLI v2, Certbot Route53,
  and real GnuPG authenticated OCB behavior in the resulting image.
- Preserve the existing verified producer handoff, nonroot runtime,
  isolated build context, and no-publishing-until-tested governance.

## Material Assumptions and Verification

The initial image is **linux/amd64**, and its reviewed base is
`alpine:3.24.3@sha256:c26612752c78b18faacd63c7d50f4592c2e7b0f25e0e20e82bd74e465c57ab0d`,
the verified [Alpine 3.24.3 amd64 platform manifest](https://github.com/docker-library/repo-info/blob/master/repos/alpine/remote/3.24.3.md). This is **not** the
multi-platform index digest. All builds and publication gates must explicitly
select linux/amd64 until other platforms pass their own acceptance tests.

Alpine 3.24's `community` repository currently lists
[AWS CLI 2.34.63](https://pkgs.alpinelinux.org/packages?branch=v3.24&name=aws-cli),
[Certbot 5.6](https://pkgs.alpinelinux.org/packages?branch=v3.24&name=certbot),
and the [Route53 plugin 5.6](https://pkgs.alpinelinux.org/packages?branch=v3.24&name=certbot-dns-route53);
`main` lists [GnuPG 2.4.9](https://pkgs.alpinelinux.org/packages?branch=v3.24&name=gnupg).
Package existence is not evidence that musl libc, Python bindings,
Certbot plugins or GnuPG's OCB backend actually function in this image.
Task #161 must fail closed on runtime capability checks; #162 must
exercise Docker **and** rootless Podman with the same image identity.

Alpine repository contents and package revisions may change within
v3.24. A fixed base digest and version-family constraints are **not**
a complete frozen dependency lock, guarantee of reproducible builds,
or guarantee of vulnerability remediation. Preserve an installed
transitive package/version inventory and record image digest and build
identity. Explicitly version any rebuilt OCI image whose packages change
without a new producer release.

## Decision

### Runtime family and package acquisition

Use the official Alpine 3.24.3 image, pinned by the complete reviewed
linux/amd64 platform digest above, in the repository-root production
Dockerfile. Supply an allowlisted, nonsecret `oci/alpine-repositories`
file containing only the official HTTPS `v3.24/main` and
`v3.24/community` repositories. Do not combine this repository family
with edge, a different Alpine release, arbitrary package indexes,
`apk --allow-untrusted`, source builds downloaded during Docker build,
or a transient alternate package manager.

Use `apk add --no-cache` to install the runtime dependencies. Constrain
selected packages to the approved API/behavior family, including:
`aws-cli=~2`, `certbot=~5`, `certbot-dns-route53=~5`, and
`gnupg=~2.4`, while retaining functional verification of the specific
installed versions. Install GNU coreutils, GNU tar, findutils, gawk,
gzip, sed and grep explicitly rather than assuming BusyBox-compatible
tools satisfy the Bash producer's GNU-specific options.

The image SHALL retain the complete installed `apk` package/version
inventory for review, comparison and vulnerability analysis. Runtime
dependencies may receive security/bugfix revisions within these
constraints **only after a new reviewed build**, executed test gates,
and a new OCI image digest/revision identity. An existing tagged
image is not silently overwritten merely because the Alpine branch
received an update. Maintainers shall refresh the base digest and
assess package changes in regular separate reviewable updates.

### Build, runtime, and release boundaries

All other ADR-038 requirements remain operative: consume the
checksum-verified **ordinary** producer from the approved eight-file
handoff, verify its release/source metadata in the build, keep a
minimal default-deny context, and do not compile Bash sources again
inside the image. OCI metadata records the exact source commit,
release version, ordinary producer digest, handoff manifest digest,
Alpine base digest, package branch, and build kind.

Declare a fixed unprivileged UID/GID (initially 65532:65532), an
exec-form producer entrypoint, no network or secret actions on the
default `--help`, private ephemeral HOME/TMPDIR, and an operator-owned
tmpfs for a read-only root filesystem. Neither Docker nor Podman
requires a daemon, engine socket, privileged mode or host
`/etc/letsencrypt` mount **inside** the container. Keep GPG and AWS
secrets runtime-only and never write them into image layers/metadata.

Retain the explicitly gated, release-validated image publication path
described in ADR-038. The separate `publish_image` version/tag context
hazard, dual-registry verification, Docker Hub namespace requirement,
and exact immutable GitHub release handoff remain unresolved until
their assigned tasks complete. This ADR does **not** authorize
publication from an arbitrary `main` or PR build.

### Acceptance

Task #161 must check Alpine branch identity, actual binary paths and
GNU behavior, AWS CLI v2, Route53 plugin discovery and GnuPG 2.4.7+
with a **real AES-256/OCB symmetric encrypt/packet inspection/decrypt
roundtrip**, on the selected platform. No package-version check alone
may replace this evidence.

Task #162 must build the exact candidate and run black-box tests with
Docker and rootless Podman, verify immutable producer identity,
read-only-rootfs/owned-tmpfs behavior, user identity, no leaked
secrets, exit/stdout/argv compatibility, and simulated denied or
malformed provider states without touching production accounts.

If a required package is unavailable or behavior is incompatible,
fail the build or gate. Do not quietly install glibc compatibility
packages, fetch alternate binaries from the internet, or switch
back to Debian; a material dependency or runtime-policy change
requires a new reviewed decision.

## Considered Alternatives

### Retain Debian 13 and its dated APT snapshot

Rejected for this baseline. It offers a clear historical package set,
but increases repository/snapshot maintenance and leaves the project
responsible for selecting refreshed timestamps even when compatible
release-branch updates are available. The producer has no known glibc
dependency that requires Debian, but Alpine must still pass real tests.

### Use Alpine `edge` or a floating `alpine:latest`

Rejected. They can change the package ABI, Python version, plugin
contracts, kernel-facing tools and OpenPGP implementation without a
bounded release-series review.

### Pin every Alpine package to an exact historical revision

Not selected as the default maintenance model. Alpine's rolling stable
branch repositories do not promise historical package revisions remain
available indefinitely. Exact package/version inventories remain
mandatory for each completed build. Teams requiring bit-for-bit
rebuildability may later adopt a reviewed Alpine repository snapshot
or private verified APK cache under a new decision.

### Use only BusyBox command applets

Rejected. The producer's safety checks depend on GNU options, filesystem
behavior and strict tar handling. Explicit GNU utilities are required
and must be tested inside the image.

## Consequences

The image gains a lighter base and avoids Debian snapshot maintenance.
The Python, AWS CLI, Certbot and GnuPG dependencies will still dominate
its final footprint; the tiny Alpine base does **not** imply a tiny
complete image. Musl compatibility and GNU-vs-BusyBox utility selection
are new risks that require concrete tests.

Builds with the same base digest and Dockerfile may resolve different
compatible APK revisions over time. A recorded package inventory and
new immutable image digest describe what was **actually built**; they
do not substitute for full byte-reproduction evidence. Security
patches can be adopted without an ADR change when they remain within
this contract and all required gates pass.

## Expected Outcomes and Migration

Update PR #195 to replace the Debian-only Dockerfile instructions,
`oci/debian.sources`, repository allowlist, context preparer,
OCI labels and build documentation with Alpine 3.24 equivalents.
Leave the Bash producer, eight release scripts/checksums and
runtime interface unchanged. Do not publish the first Alpine image
until independently verified Docker/Podman acceptance succeeds.
Existing host-installed producer and standalone client users need
no migration.

## Supersedes

**Partially supersedes ADR-038**, only its Debian 13 slim base-family
selection and dated Debian APT snapshot/package-policy requirements.
This ADR supplies the approved Alpine 3.24 alternative and package
maintenance tradeoff. All other ADR-038 decisions remain Accepted and
operative, including identity, authority, user, CI, registry, release,
and supported-platform boundaries.

## Related Decisions

ADRs 002, 003, 005, 006, 011, 012, 015, 016, 031, 035, 036, 037
and 038. Milestone 14 stories #158 and #159; technical tasks #160–#167.
