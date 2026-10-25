# OCI Release Validation Gate

This document describes task #164's **read-only, validation-only** gate under
[ADR-038](adr/ADR-038-verified-oci-producer-images.md) and
[ADR-039](adr/ADR-039-alpine-oci-runtime.md). It does **not** publish to
GHCR or Docker Hub, create a tag, or replace the existing
[Versioning release pipeline](release-verification.md).

## Trusted sequence

1. The existing `Versioning` workflow completes its protected-main push,
   verifies all eight public Bash assets, attests them, and publishes the
   GitHub release and tag. Its final `versioning` job must succeed.
2. GitHub emits a `workflow_run` completed event independently of whether
   the tag was created using `GITHUB_TOKEN`. The new workflow
   `.github/workflows/oci-release-validation.yml` refuses events that do
   not identify a successful completed `Versioning` **push** from the
   trusted repository and `main` branch, including cross-run ID/attempt/SHA
   changes.
3. The validator checks out the exact release source commit. It requires
   exactly one matching stable release tag on that commit, a published GitHub
   release, GitHub-verified signed commit and an exact eight-asset inventory.
   Every asset is downloaded from the release and individually checked by
   GitHub's cryptographic attestation verifier before its SHA sidecar and
   embedded build provenance are checked by `ci/producer-handoff.bash`.
   Missing or altered assets fail closed.
4. `ci/prepare-oci-context.bash release` independently verifies the bound
   handoff and stages only allowlisted nonsecret inputs. The Dockerfile
   verifies the ordinary producer SHA, source revision and release version.
   Only `linux/amd64` is built. The same no-push image is run under Docker
   and rootless Podman with the existing readonly/no-network fixtures.
5. On any failure, the workflow is red. The gate has `contents: read`,
   `actions: read` and `attestations: read` permissions and **no**
   registry token, AWS secrets, GPG keys or cloud production authority.

The release's independent attestation identity matters: checksum sidecars
alone would allow a compromised release uploader to substitute a matching
script and checksum. Release tags alone also do not prove that a subsequent
OCI build tested the same source. The downstream publisher (#165) MUST
independently check the exact successful gate run and source/tag/release
identity before obtaining registry credentials. An arbitrary successful
workflow run or similarly named artifact never grants publication authority.

## Acceptance and limitations

Synthetic Bats fixtures under `tests/oci-release-gate.bats` cover rejected
failed/cancelled, wrong source, wrong run attempt, wrong repository, wrong
branch and non-push events. A real release-triggered validation run remains
necessary to prove the end-to-end GitHub event/attestation integration.
The existing source CI OCI acceptance uses a development handoff; it does
not substitute for this **release-correlated** gate.

The workflow does not prove that a recreated Alpine image is byte-for-byte
identical to one built earlier. It explicitly labels/records the new
build's installed packages and image identity. The selected Alpine version
family permits compatible package revisions, so a changed dependency set
requires renewed review and a new image digest. This gate does not validate
registry tags, SBOMs, or dual-registry parity, which are assigned to
tasks #165 and #166.

The present tag acceptance requires a stable `vMAJOR.MINOR.PATCH` release.
Prerelease and ambiguous tag policies require an independently approved
contract. The separate `publish_image` action's `v0.x` metadata behavior
must be tested in the *actual* trusted event context before credentialed
publication; this gate must not be treated as proof that the action will
generate correct Docker Hub and GHCR tags.
