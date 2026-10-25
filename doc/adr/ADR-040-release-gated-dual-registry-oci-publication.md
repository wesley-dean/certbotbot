# ADR-040: Release-Gated Dual-Registry OCI Publication

Date: 2026-10-25

## Status

Accepted

## Decision

Publish the certbotbot OCI producer to GHCR and Docker Hub through a distinct
**successful-OCI-gate-triggered** workflow, using an immutable reviewed
`wesley-dean/publish_image` commit. A release can be eligible for publication
only after its Versioning workflow, public GitHub release/attestations, Docker
runtime check and rootless Podman runtime check have all passed.

This decision implements the authority and image-publishing boundaries from
[ADR-038](ADR-038-verified-oci-producer-images.md), as amended for Alpine by
[ADR-039](ADR-039-alpine-oci-runtime.md). It refines the preferred trigger in
ADR-038: instead of independently racing a second `workflow_run` on Versioning,
publication is chained after the existing no-push OCI acceptance workflow.
It does **not** weaken any Versioning or OCI acceptance gate.

## Context and constraints

The Versioning pipeline validates and attests eight Bash release assets and
creates a release/tag only after its independent client, producer and
Bash 4.3 jobs pass. The ordinary `certbotbot.bash` and its SHA-256 sidecar
are the only producer assets embedded in the OCI image. The OCI acceptance
workflow already consumes `workflow_run: Versioning`, revalidates the
signed source, exact release/tag and all eight attested assets, prepares an
allowlisted build context, and runs the same image in Docker and rootless
Podman without any production credentials.

A tag created by the normal `GITHUB_TOKEN` cannot be relied on to fire a
fresh tag-triggered workflow. The GitHub `workflow_run` event's own
`github.ref` is usually `main` rather than the successful prior release
tag. Neither event field is sufficient to authorize `latest`, semantic
version tags or a registry write.

The independently reviewed
[`publish_image` issue #99](https://github.com/wesley-dean/publish_image/issues/99)
was merged in upstream
[PR #100](https://github.com/wesley-dean/publish_image/pull/100)
with immutable commit
`94d42d58eab435d50991f561f27382c4dc3cedb4`.
Its opt-in `verified_release_ref` and `verified_source_sha` inputs
generate exact `v0.x.y` release tags independent of ambient GitHub
event metadata. It accepts nonsecret Buildx arguments, can require
both registries, and no longer exposes registry passwords or access
tokens through step outputs. Upstream no-push tests validated its v0
tag contract and nonrelease compatibility. Pinning that commit is an
integrity measure, not evidence of trust in arbitrary future revisions.

Material assumptions: the confirmed Docker Hub destination is
`docker.io/wesleydean/certbotbot`; GHCR is
`ghcr.io/wesley-dean/certbotbot`. Initial support remains **linux/amd64**,
and the validated ordinary release producer must be used. The operator
owns protected repository secrets, package permissions, release policies,
registry namespaces and workflow/environment protections. Credentials are
never obtained in unprivileged source or no-push validation jobs.

## Workflow and trust boundaries

1. The `OCI release validation` workflow requires successful completed
   `Versioning`, a trusted main-branch source SHA, exact stable release,
   GitHub-verified source signature, attested eight-file inventory and
   checksummed producer handoff. It builds once and runs the image under
   Docker and rootless Podman in credential-free CI.
2. **Only after** both engines succeed, the gate emits a short-lived
   nonsecret artifact containing its run/attempt, its original successful
   Versioning run/attempt, source SHA, stable release version, handoff
   SHA-256 and ordinary producer SHA-256. If the gate fails or artifact
   upload fails, the gate workflow is unsuccessful and nothing publishes.
   The record is a *locator and consistency proof*, **not a signature**
   or independent provenance authority.
3. `.github/workflows/publish-image.yml` is triggered by a completed
   `OCI release validation` workflow (second workflow_run level).
   It only admits a successful same-repository main-branch gate run.
   The unprivileged preflight downloads the exact named artifact for
   the gate **run ID and attempt**, treats it as untrusted data, validates
   its fixed field inventory and strict scalar formats, and queries the
   corresponding Versioning run through the GitHub API. It checks that
   Versioning was a completed successful main-branch push from this
   repository at the same source SHA and attempt.
4. Preflight checks that the source SHA is an ancestor of the trusted
   current main, then uses `ci/verify-oci-public-release.bash` again
   for the signed commit, exact stable release tag, all eight public
   attested assets, and reconstructed handoff digest. The version,
   manifest SHA and ordinary producer SHA must match the gate proof.
   The validated release must also be GitHub's current **latest**
   stable release, preventing a delayed older gate from replacing
   `latest` under normal repository serialization.
5. The only credentialed job is conditioned on preflight success and
   an available protected `oci-registry-publish` environment, with
   globally serialized registry publication and job-local
   `contents:read`, `attestations:read`, `packages:write`.
   An enabled publisher workflow on the default branch is sufficient
   authorization to attempt publication of an accepted stable release;
   no additional repository enablement variable is needed.
   It independently repeats the release/asset check and produces the
   allowlisted `ci/prepare-oci-context.bash release` build context.
   Nothing is built from a PR artifact, raw repo root or floating
   latest release download.
6. The reviewed action receives the **explicit verified tag ref**,
   **explicit full source SHA**, `repository_name: certbotbot`,
   the allowlisted context and Dockerfile, `linux/amd64`, five
   nonsensitive provenance build arguments, both exact registry names
   and required registry credentials. `force_release` is not used.
   The first push includes only stable release and full/short SHA
   tags; no branch `edge` publication is authorized. Registry
   passwords exist only as action inputs on this protected job.
7. An accepted Buildx push is necessary but insufficient: inspect
   the resulting action digest/expected per-registry refs and query
   **both** registries by digest, pulling and checking architecture,
   source revision and ordinary producer checksum. Missing, partial,
   mismatched or ambiguous remote results fail the workflow. Comprehensive
   registry SBOM, attestation, tag, image-runtime and parity acceptance is
   separately tracked under approved task #166.

The credentialed job rechecks current stable release identity
immediately before invoking the action. This is not an inter-registry
transaction or distributed lock. Operators must coordinate any other
registry publishers and prevent unreviewed workflows from assuming
the same namespace/tag authority.

## Security review

**Assets:** publisher credentials, token privileges, source/release
integrity, eight attested release files, producer private key-free
build context, OCI metadata, both registry tags/digests and immutable
downstream image identities.

**Trusted computing base:** protected branch/review policy; GitHub
Actions workflow-run payload and authenticated GitHub API; signed
source/release/attestation verifier; validated Docker/Podman runner;
pin-reviewed GitHub Actions including publish_image; Buildx, Docker,
registry authentication and both registries.

**Untrusted data:** all workflow_run payload fields, downloaded
artifacts, release responses, names and digests until independently
verified. No proof file is sourced or evaluated. Script arguments,
workflow outputs and API paths are restricted to validated names,
numeric run IDs, exact hashes and canonical versions.

**Mitigations:** two-stage verification without secrets, fixed
same-attempt gate proof, main ancestry and signed-release/attestation
binding, exact checksum match, stable release check, immutable action
SHA, explicit registry names, fail-closed credential checks, no
plaintext credential outputs, environment/repository authorization,
global serialization and independent remote digest inspection.

**Residual risks:** the two registries cannot publish atomically; one
may accept the image before a second fails. The OCI gate and publisher
can build the same allowlisted context at different times; Alpine
stable-branch packages may resolve to later bounded revisions.
Therefore prepublication tests attest the validated gate image and
source handoff, **not automatically the byte-identity** of a rebuilt
publisher image. The publisher must independently check its final
digest and release/producer labels; task #166 must establish complete
pulled-image runtime, package inventory, SBOM/provenance and parity.
A release may precede deployment of the publication workflow.
A missing secret or unavailable protected environment prevents successful
publication. The workflow itself is the explicit operational switch;
maintainers who do not intend automatic publication must disable or
remove that workflow. Registry, GitHub and runner administrators retain
their respective high privileges.

An operator should not mark a real publication accepted merely because
synthetic no-push CI passed. Keep task #165 open until successful
credentialed dual-registry evidence has been reviewed; do not infer
completion from a merged workflow.

## Alternatives considered

- **Tag/release trigger created by GITHUB_TOKEN:** rejected because
  recursive workflow-event restrictions make publication unreliable.
- **Independent publisher triggered directly by Versioning:** rejected
  because that creates a timing race with OCI runtime acceptance and
  requires an additional cross-workflow success query anyway.
- **Trust gate success without validating source and release again:**
  rejected because the workflow_run head SHA can name `main`,
  a gate artifact is not an authenticated release, and reruns/attempts
  must be bound to the exact event.
- **Build separately for GHCR and Docker Hub:** rejected because two
  independent builds can diverge. The reviewed action performs one
  Buildx build/push with both destinations.
- **Use force_release for v0 tags:** rejected because it cannot repair
  metadata-action's ambient `workflow_run` ref by itself. Explicit
  verified release identity is now available upstream.
- **Publish on PRs, arbitrary pushes, or unvalidated merges:**
  rejected because registry write authority requires a verified stable
  release, completed OCI acceptance, and a protected environment.
  Successful accepted releases publish automatically when this workflow
  is installed and enabled on the default branch, without a second flag.
- **Push during the original OCI validation workflow:** rejected to
  retain a clean unprivileged acceptance gate, an independently
  reviewable credentialed boundary and observable partial success.

## Consequences and migration

No changes to the Bash producer, separate client or existing eight-file
release contents. Once the publishing workflow is merged and enabled on the
default branch, a newly verified stable release automatically attempts to
publish through its existing release gates. Maintainers must configure
`oci-registry-publish` protection and registry credentials before such
a run, then inspect a qualifying real release before treating publication
as operational. Consumers should pin
verified image digests rather than moving tags.

The published OCI build is a separately reviewed derivative of the
release's ordinary Bash producer. If package revisions change without
the release source changing, ADR-039 requires an explicit, newly tested
image revision rather than silently overwriting old immutable tags.

## Related decisions

ADR-011, ADR-015, ADR-016, ADR-019, ADR-035, ADR-036, ADR-038 and
ADR-039. Milestone 14 story #159 and tasks #164–#167; upstream
`publish_image` issue #99.
