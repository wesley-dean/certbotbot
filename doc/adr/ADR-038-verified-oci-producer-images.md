# ADR-038: Verified OCI Producer Images for Docker and Podman

Date: 2026-10-25

## Status

Accepted

## Intent and Documentation Posture

This architectural decision governs approved milestone 14 stories #158 and #159, and tasks
#160–#167. Its status is Accepted **if this PR merges**; it does not assert that an OCI
image or publishing workflow has been built, tested, or released. This design-only task
makes no runtime changes.

## Context

The existing producer is a one-shot Bash application: it retrieves and validates its
authoritative S3 archive, uses an already-registered Let's Encrypt account and Certbot
Route53 plugin for the selected certificate, and conditionally publishes validated state.
The read-only certificate client is a **different product**. Existing accepted ADRs govern
configuration precedence, multi-lineage archive contents, authenticated GnuPG AES-256/OCB,
safe S3 publication, backup rules and failure semantics. Dockerization cannot silently
change those behaviors.

The release workflow already builds, verifies, attests and publishes **eight** Bash assets:
three producer representations and one standalone read-only client, each with a conventional
.sha256 companion. It binds candidate version, commit, run, attempt and hashes in an
immutable verified handoff. The new image is a separate distribution of the **ordinary
producer**, not another Bash executable release flavor.

The maintained
[wesley-dean/publish_image](https://github.com/wesley-dean/publish_image/blob/main/action.yml)
composite action requires github_ref and repository_name, and supports dockerfile, context,
platforms, explicit GHCR/Docker Hub names and force_release. Its current release-ref
recognition accepts refs/tags/v1... but does not recognize refs/tags/v0... without
force_release. The action uses docker/metadata-action to produce semantic tags using the
actual GitHub event/ref context. A workflow_run triggered by a successfully completed
Versioning workflow normally has the **default branch ref**, not the prior release tag.
Merely passing github_ref or force_release cannot be assumed to correct semantic tag
generation. Published labels must be verified in the true triggering context.

## Decision Drivers

- Preserve the existing Bash CLI, stdout/stderr, exit statuses, one-shot lifecycle and
  read-only consumer separation.
- Base OCI images on exactly reviewed, verified producer bytes, not independent or mutable
  downloads.
- Keep untrusted source, AWS keys, GPG keys, ACME accounts and archive contents outside the
  build/publishing context and OCI layers.
- Default to nonroot, read-only-rootfs, ephemeral private working state, without privileged
  or engine-socket access.
- Support Docker and Podman as runtimes for the **same** image, including rootless Podman
  where proven.
- Pin and inspect OS/runtime supply-chain inputs and respond to CVEs with renewed tests and
  a new image identity.
- Do not publish images before successful source, test, release and image-compatibility
  gates.
- Avoid treating one registry's success or an assumed version tag as successful dual
  publication.

## Material Assumptions

- **Initial platform: linux/amd64 only.** Later ARM variants must pass explicit package and
  run tests first. Never use the publish_image action's default multi-platform list
  implicitly.
- **Initial OS family: Debian 13 (Trixie) slim.** Debian's published package listings
  currently contain [AWS CLI v2](https://packages.debian.org/trixie/awscli), [GnuPG
  2.4.7](https://packages.debian.org/trixie/gnupg), [Certbot 4 and the Route53 DNS
  plugin](https://packages.debian.org/search?arch=amd64&keywords=python3-certbot&suite=trixie).
  Those listings are feasibility evidence, **not a built-image acceptance result**. Task
  #161 must pin the actual Debian OCI manifest digest, validate package availability, select
  and record package/snapshot pins, and prove real GnuPG OCB operation in the selected
  image. An invented digest or vague moving tag is forbidden.
- Operators already own an S3 bucket and current archive, existing Let's Encrypt account,
  Route53 and IAM permissions, and control downstream installation and schedules.
- Docker Hub namespace is **not yet confirmed**. Task #165 must obtain that decision; do not
  infer it from the GitHub username.
- Release provenance, image build identity, tag and registry digests must be observable.
  This ADR alone proves neither byte-reproducible image builds nor OCI signatures.

## Decision

### Image product and command

Create a single root production Dockerfile and restrictive .dockerignore. The image SHALL
set an exec-form ENTRYPOINT invoking the **ordinary assembled producer**, e.g.
/usr/local/bin/certbotbot.bash, with no Docker-only argument wrapper. Docker and Podman MUST
pass CLI options and positional DNS SANs directly and preserve the script's existing
help/version, invalid-input, exit-code and STDOUT/STDERR contracts. Do not add a daemon,
service port, certificate server, cron, target deployment, ACME registration, S3
administration, or host installation behavior.

This OCI image SHALL NOT bundle the separate read-only client and SHALL NOT alter the
release's eight Bash executable/checksum assets.

### Exact producer artifact and build context

Choose **prepared verified producer bytes**, not source assembly inside the Dockerfile. An
unprivileged build preparation step SHALL obtain the ordinary certbotbot.bash and matching
checksum from the same approved **eight-file** candidate handoff, independently verify
source commit/version/run/attempt and every manifest digest, and then prepare an
**allowlisted** Docker build context containing only the Dockerfile, minimal explicitly
approved build support, verified ordinary producer, its checksum and nonsensitive provenance
metadata. The Dockerfile SHALL verify the expected producer digest again before
installation. Runtime and build context MUST NOT contain the source checkout, .git, vendor,
.env, S3 archives, ACME account material, credentials or test-secret directories.

Local developer builds MAY use a validated output of make build with prepared pinned
dependencies; this is **not** automatically an authorized published release image. Published
release images MUST take the immutable release candidate's identical producer bytes. No
floating GitHub latest download, curl-pipe-shell, container-local producer recompilation or
runtime dependency acquisition is permitted.

The base image SHALL be **digest pinned**. Debian package inputs SHALL be constrained
through a reviewed snapshot or equivalent tested explicit package-version lock and
provenance record. A moving apt index combined with a pinned base is not reproducible
enough; a successful build MUST record the base digest, package set, package source,
Dockerfile/input hashes, builder/platform, source commit/version and resulting image digest.
Byte-identical image rebuilds are a goal that requires evidence, not a promise made here.

### Runtime toolchain and patch policy

The final image MUST include functioning Bash >=4.3; AWS CLI **v2**; Certbot and matching
python3-certbot-dns-route53 plugin; GnuPG **2.4.7+ with actual supported AES-256/OCB
authenticated roundtrip**; GNU tar/gzip/coreutils including stat, mktemp, realpath, find, od
and tail; awk, sed, OpenSSL, CA certificates and requisite Python/TLS dependencies. Install
only reviewed runtime dependencies, avoid unnecessary recommendations and remove package
caches/build-only tools. Unit tests must verify command paths, versions, GNU behavior, exact
plugin visibility and the **real** authenticated crypto packets and roundtrip rather than
trusting version output alone.

Each OS/dependency security update requires reviewed new pins, vulnerability and
compatibility assessment, the same image acceptance matrix and a new OCI digest. A change to
runtime components without a change to the producer Bash version needs an explicit OCI image
*revision* identifier (for example a version with -rN), never an opaque silent replacement
of immutable version/SHA tags. Pinning integrity does not prove dependencies behaviorally
safe (ADR-015).

### Nonroot, ephemeral filesystem and engine parity

Use a fixed nonzero UID/GID by default (proposed **65532:65532**, verified under #161).
Never require privileged mode, Docker socket, host-network mode, ambient capabilities or
host /etc/letsencrypt. Favor docker/podman run with **read-only rootfs**, dropped Linux
capabilities, no-new-privileges and explicitly provided private owned writable tmpfs for
TMPDIR, HOME, GnuPG homedir and restored Certbot state. The image SHALL not assume a
writable /root, persist certificates in a container layer, or rely on host files surviving
container exit.

Runtime AWS credentials are supplied by operator-controlled role/workload identity, provider
identity or narrowly scoped read-only mounted credential/secret paths. GPG_SYMMETRIC_KEY is
injected **only at runtime**, using the existing producer secret contract, never as build
arg, Dockerfile ENV value, source file, tag, label, command line, persistent config or CI
log. The operator must account for initial environment visibility to host/daemon/privileged
users: a container is not a VM-like confidentiality guarantee. The host credential
provisioner and rootless Podman UID mapping form part of the threat model.

Rootless Podman may require adjusted UID/GID mappings and SELinux labeling on
*operator-supplied mounts*. Document private versus shared relabel choices and their risks
rather than automatically relabeling secrets. A custom --user must preserve access to the
temporary private state and AWS identity material. No root-only chmod, chown, or global
account assumptions are permitted on the runtime path.

All producer state changes and Certbot private account content remain in **private ephemeral
workspace**. The authoritative durable state is still the existing S3 current archive (with
separately approved backup policy). Writer concurrency must be **serialized by the
operator**. The image SHALL neither introduce new concurrent-writer behavior nor assume
ephemeral storage is a durable rollback mechanism.

### Network and responsibility

Permit outbound AWS S3, Route53, ACME, DNS and reviewed workload-identity endpoints as
actually required by the existing issuer. No listening port is needed. Restrict IAM to
selected object operations and DNS records actually needed, without general S3/IAM or host
administrative rights. The operator supplies initial account and bucket/Route53
prerequisites and separately installs certs into target web servers; target hosts do not
need to run the producer image.

### Release/image provenance and publication trigger

Keep the existing Versioning job authoritative: calculate the version, verify same eight
bytes across its full producer/client/GnuPG/Bash 4.3 suites, attest, **then** publish the
GitHub release/tag. The image must be built/tested from a verified ordinary executable and
the pinned base/dependencies. Required Docker **and** rootless Podman tests of the image and
its contents must succeed in unprivileged CI before any registry credentials become
available. A successful Bash workflow alone is insufficient to publish the image.

For automatic publication, prefer a separately permissioned **workflow_run on completed
successful Versioning**, because GitHub-token-created tag/release events must **not** be
assumed to start another workflow. The publisher MUST verify the completed run belongs to
the trusted repository and main branch, succeeded with the required gates, and corresponds
to the exact expected source commit, run attempt, computed version, already-published GitHub
release/tag and attested eight-file artifact identities. It MUST NOT trust unreviewed
workflow artifacts or trigger on a PR/fork run. An explicitly manually dispatched
release-tag re-publication may be supported as a separately guarded recovery path, never for
arbitrary unvalidated main.

The approved **full immutable commit SHA** of wesley-dean/publish_image is required in the
publishing workflow. Pass **explicit** repository_name, github_ref, Dockerfile/context,
linux/amd64 platform and **both** registry image names. GHCR target is
ghcr.io/wesley-dean/certbotbot. Docker Hub name requires operator confirmation. Use
protected Docker Hub credentials and minimum-scoped GHCR token/package write authority, with
**no** registry secrets on PR jobs. Produce one image build/provenance identity published to
both registries, never independent uncorrelated rebuilds; partial registry success is
reported as failed dual publication and audited for repair.

**v0.x and metadata trap:** the current composite action classifies refs/tags/v1+ as release
by default, not refs/tags/v0. Even force_release=true does **not** establish whether
docker/metadata-action sees an actual tag ref from workflow_run. Before permitting
publication, task #164 SHALL prove the exact action-version/ref/tag output in an isolated
no-push validation on the intended trusted event context; #165 SHALL independently verify
every expected tag/manifest **before** treating push as success. force_release is allowed
only for a confirmed validated v0.x release with a proven semantic-tag context. If the
action cannot produce correct version/commit tags in that context, fail closed and require
separately authorized action changes or a tested trusted tag-context dispatch; do **not**
silently fall back to edge/latest.

Use verified immutable full source SHA and release version tags, with optional latest only
after verified stable release. Do not grant latest to prereleases or failed builds;
distinguish edge as separately approved development policy, not stable release. Registry
**digest** is the primary immutable runtime selection. Label image source commit, version,
selected producer checksum, base/package input identity, supported platform and builder.
Capture SBOM and attestations where actually supported, but do not claim an image has been
cryptographically signed unless a real signature mechanism is implemented and verified.
Verify manifest/index, digest availability, relevant labels/provenance and equivalent
pulled-image behavior at **both** GHCR and Docker Hub. Registry publication is not an
all-or-nothing distributed transaction; partial side effects must be visible and remediated.

### Mandatory acceptance and test matrix

| Area | Required evidence |
| --- | --- |
| Producer identity | Embedded ordinary artifact digest/version matches the verified release handoff; no client flavor, source checkout, secret or archive in image |
| Toolchain | Real Bash, Certbot Route53, AWS CLI v2, GNU utilities, CA trust and full authenticated GnuPG OCB probe |
| Engine behavior | Docker and rootless Podman build/inspect/run the **same** candidate image with matching help/version, argument/exit/stdio and mocked lifecycle |
| Isolation | Nonroot UID, read-only rootfs with private writable tmpfs, no host etc/letsencrypt, unnecessary capabilities, privileged mode, open ports or socket |
| Secrets | No AWS/GPG/ACME secret in image layers, metadata, context, SBOM or build log; secure runtime injection with documented residual host exposure |
| Fail closed | Mocked missing/malformed S3, no account, wrong crypto/key, invalid flags, unsafe paths and failed Certbot, without false success/host state changes |
| CI | Actual image tested with offline mocked cloud boundaries; unavailable **required** Docker/Podman runner fails gate rather than counting a skip as success |
| Release | Same source/commit, correct eight artifact checksums, all existing gates successful, pinned base/package, OCI identity and tested platform |
| Publish | Correct trusted trigger/ref and v0.x tag tests; **both** registry pushes/pulls, digest/labels and SBOM/provenance checked; partial push rejected |

Use mocks for AWS/Route53/ACME changes in CI. Never rely on live production accounts or
secrets for image acceptance. A Linux engine missing from a development laptop may be
explicitly skipped **locally**, but an unavailable required CI engine blocks release
publication.

## Alternatives Considered

- **Build/assemble the producer inside Docker:** rejected because it creates an independent
  compiler/dependency/version path that may diverge from the exact verified release
  executable. Multi-stage packaging of *pinned OS dependencies* remains permissible.
- **Download latest Bash script during Docker build:** rejected because an unverified
  mutable remote dependency breaks release provenance.
- **Root container, privileged mode, host /etc/letsencrypt:** rejected for authority, state
  confusion, sensitive host disclosure and rootless incompatibility.
- **Docker-only wrapper/scheduler:** rejected; Docker and Podman already forward argv and
  the tool is a one-shot producer. Scheduling and writer serialization belong to operators.
- **Floating distro base or startup package installation:** rejected as uncontrolled
  runtime/supply-chain drift.
- **Independently build images for the two registries:** rejected; sources and manifests
  could differ silently. Build once, publish both, verify parity.
- **Assume GitHub-token-created tags automatically launch publisher:** rejected because
  recursive workflow event restrictions must be respected.
- **Assume force_release fixes v0.x tag semantics:** rejected: release classification and
  ambient metadata-action ref context are separate.
- **Publish all architectures offered by the action:** rejected until actual package and
  runtime capability is tested for each.

## Consequences

The image necessarily carries heavier Python/AWS/Certbot crypto dependencies than the
standalone Bash script; package attack surface and patch cycles increase. Explicit upstream
pinning, separate image gates and read-only nonroot workspace requirements add operational
and CI work but preserve auditability. A release may be published to GitHub without
subsequent registries succeeding; such partial completion must be recorded, not hidden.
Docker/Podman portability and reproducibility are test requirements, not automatic
consequences of Dockerfile syntax.

An OCI runtime image is a distribution of the issuer, **not** an alternate ACME
implementation, credential management system or safer-than-host VM. Source and release gates
remain authoritative. Dependable image publication may need adjustments in the maintained
publishing action or event context after exact v0.x tag behavior is verified; that is not
silently authorized by this ADR.

## Migration and Upgrade Implications

Existing users can continue running the published Bash executable unchanged. Operators
selecting the OCI image provide equivalent CLI arguments, credentials, a new private
temporary workspace and external IAM/S3/account prerequisites; no archival format migration
or target-host software installation occurs. New application releases bind image identity to
the corresponding attested Bash release; OS security patch rebuilds require reviewed new
digests and explicit image revisions. Operators should deploy digest-pinned OCI images and
separately handle updates, backups, recovery and certificate installation.

## Implementation and Verification Plan

1. **#160 (this PR):** Accepted ADR-038 and decisions index only; no Dockerfile, builds or
registries.
2. **#161:** root production Dockerfile, restrictive context, pinned Debian 13 base and
packages, exact verified producer input, nonroot and real runtime-tool preflight.
3. **#162:** Docker and rootless Podman offline mock tests, environment/isolation/crypto
checks and required CI gates.
4. **#163:** secure Docker and Podman operator examples and safety checklist; long-form
deployment documentation remains #157.
5. **#164:** validated Versioning-to-OCI trigger identity, release gate and no-push v0.x
tag/metadata tests.
6. **#165:** obtain Docker Hub namespace, pin approved publish_image action, configure
two-registry protected publication with validated tag semantics and platform.
7. **#166:** verify both registry manifests/digests, metadata, SBOM/provenance, pullability,
tag and image runtime parity; report registry skew/partial failures.
8. **#167:** publication, credentials, image upgrades, patch revisions, rollback and
maintainer operating documentation.

New authority, runtime identity, secret source, image platform, release trigger or semantic
tag behavior beyond this contract requires explicit ADR review before implementation.

## Promises

- One reviewable producer image uses the existing public Bash CLI and verified
  source/release artifact.
- Default nonroot, private ephemeral workspace and no unneeded host or engine privileges.
- No image-baked certificate/private AWS/GPG/ACME state; no new issuer or consumer
  authority.
- Docker and Podman support must be **demonstrated** by their required tests, with no silent
  substitution.
- Registry publication follows, rather than bypasses, existing attested release and strict
  validation gates.
- Both registries must be verified against one tested image identity; failures remain
  observable.

## Non-Promises

- Container isolation is not a VM security boundary; host/daemon/privileged monitoring can
  expose runtime secrets.
- There is no in-image scheduler, cert-serving daemon, ACME registration, alternative
  backend, target deployment or concurrency lease.
- No blanket platform portability, vulnerability-free base, byte-identical reproducibility
  or image signing is claimed before proof.
- OCI push to two registries cannot be transactional; partial publication is possible and
  must be reported.
- There is no verified Docker Hub namespace, image digest, new OCI signature or
  automatically functioning v0.x tag in this design-only PR.

## Supersedes

None. This adds a **producer OCI distribution** while retaining all applicable source,
archive, auth, publishing, compatibility and eight-file Bash-release governance.

## Related Decisions

ADR-002/003/005/006/009/011/012 (Bash, build and release), ADR-015/016 (dependency and
threat boundaries), ADR-020–034 (issuer, archive, S3, encryption, backup), ADR-035/037
(separate read-only client) and ADR-036 (verified release handoff and late publication).
Approved stories #158/#159 and tasks #160–#167.
