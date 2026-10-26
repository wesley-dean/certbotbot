# OCI Build Contract and Local Smoke Checks

Status: approved task #161 under [ADR-038](adr/ADR-038-verified-oci-producer-images.md), partially superseded by [ADR-039](adr/ADR-039-alpine-oci-runtime.md). Required Docker/rootless-Podman CI evidence belongs to #162. Release-correlated image publication belongs to #164–#166. This file is a short build contract; task #163 owns the full container deployment guide.

## Provenance and runtime

The root [Dockerfile](../Dockerfile) builds **one** Linux/amd64 image for the ordinary producer, not the read-only client or a certificate-serving daemon. The published [Alpine 3.24.3 linux/amd64 manifest](https://github.com/docker-library/repo-info/blob/master/repos/alpine/remote/3.24.3.md) is pinned to SHA-256 c26612752c78b18faacd63c7d50f4592c2e7b0f25e0e20e82bd74e465c57ab0d. APK package resolution is restricted to Alpine **v3.24 main and community**, with version-family constraints for AWS CLI v2, Certbot 5/Route53 and GnuPG 2.4. The image retains an auditable installed transitive APK package/version inventory at /usr/local/share/certbotbot/packages.lock. These stable-branch repositories can receive compatible patch revisions; therefore the fixed base digest and bounded package versions do **not** prove byte-for-byte reproducibility, platform compatibility, or the absence of vulnerabilities. Every changed package set requires a newly reviewed/tested OCI image digest and revision identity.

The build checks actual Bash, AWS CLI v2, Certbot Route53 plugin, OpenSSL, explicitly installed GNU utilities, and GnuPG 2.4.7+ with real authenticated AES-256/OCB packet and decrypt behavior. It embeds the already verified producer script, with no unverified network Bash download or runtime package installation.

Runtime UID:GID is 65532:65532. HOME and TMPDIR are /run/certbotbot. For read-only rootfs, mount a mode-0700 tmpfs there that is writable by this UID. No AWS/GPG/ACME keys, archive or original host /etc/letsencrypt are copied into the image. The caller owns credential distribution, existing accounts/buckets, IAM, serialization and any downstream certificate installation.

## Verified local-development context

Run from a clean, reviewed checkout with Make's pinned dependency prerequisites available. Local mode is **not an authorized published release**:

~~~bash
set -euo pipefail
VERSION=0.0.0-dev
SHA="$(git rev-parse --verify HEAD)"
make deps
make build VERSION="$VERSION"
WORK="$(mktemp -d)"
CONTEXT="$WORK/context"     # path must not already exist
bash ci/prepare-oci-context.bash local dist "$CONTEXT" "$SHA" 1 1 "$VERSION"
~~~

The preparer requires all eight standalone Bash executables and their .sha256 companions, then calls the existing strict ci/producer-handoff.bash to create **and verify** a temporary development manifest. Its release mode instead needs an independently trusted actual workflow manifest digest along with the source commit, run ID/attempt and release version; it re-verifies the exact handoff, not merely a producer checksum. Its release-mode signature is:

~~~bash
# Only in a trusted workflow with independently supplied, verified values:
bash ci/prepare-oci-context.bash release dist "$CONTEXT" \
  "$TRUSTED_SOURCE_SHA" "$TRUSTED_RUN_ID" "$TRUSTED_ATTEMPT" \
  "$TRUSTED_RELEASE_VERSION" "$TRUSTED_MANIFEST_SHA"
~~~

Output is an **allowlisted** context containing Dockerfile, .dockerignore, oci/alpine-repositories, and oci/producer/certbotbot.bash, its checksum and nonsecret provenance. Dockerfile independently checks the copied script digest, source short commit, version, build kind and handoff digest. A raw Git checkout without this prepared producer is not a valid image build context.

## Docker and Podman smoke commands

These separate local builds only demonstrate the shared Dockerfile interface; task #162 must verify Docker and rootless Podman run the **same built OCI image digest**. No live AWS, Route53, Let's Encrypt or production keys are required for help/version smoke tests.

~~~bash
SOURCE_COMMIT="$SHA"
RELEASE_VERSION="$VERSION"
PRODUCER_SHA256="$(sed -n 's/^producer_sha256=//p' "$CONTEXT/oci/producer/provenance.txt")"
HANDOFF_MANIFEST_SHA256="$(sed -n 's/^handoff_manifest_sha256=//p' "$CONTEXT/oci/producer/provenance.txt")"
BUILD_KIND=local

docker build --platform linux/amd64 \
  -f "$CONTEXT/Dockerfile" \
  --build-arg SOURCE_COMMIT="$SOURCE_COMMIT" \
  --build-arg RELEASE_VERSION="$RELEASE_VERSION" \
  --build-arg PRODUCER_SHA256="$PRODUCER_SHA256" \
  --build-arg HANDOFF_MANIFEST_SHA256="$HANDOFF_MANIFEST_SHA256" \
  --build-arg BUILD_KIND="$BUILD_KIND" \
  -t certbotbot:local "$CONTEXT"

podman build --platform linux/amd64 \
  -f "$CONTEXT/Dockerfile" \
  --build-arg SOURCE_COMMIT="$SOURCE_COMMIT" \
  --build-arg RELEASE_VERSION="$RELEASE_VERSION" \
  --build-arg PRODUCER_SHA256="$PRODUCER_SHA256" \
  --build-arg HANDOFF_MANIFEST_SHA256="$HANDOFF_MANIFEST_SHA256" \
  --build-arg BUILD_KIND="$BUILD_KIND" \
  -t certbotbot:local "$CONTEXT"

docker image inspect certbotbot:local --format '{{.Config.User}} {{.Config.Entrypoint}}'
docker run --rm --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --tmpfs /run/certbotbot:rw,nosuid,nodev,uid=65532,gid=65532,mode=0700 \
  certbotbot:local --help

podman image inspect certbotbot:local --format '{{.Config.User}} {{.Config.Entrypoint}}'
podman run --rm --read-only --cap-drop=all \
  --security-opt=no-new-privileges \
  --mount type=tmpfs,destination=/run/certbotbot,tmpfs-mode=0700,U=true \
  certbotbot:local --version
~~~

Docker and rootless Podman use different tmpfs ownership syntax. Docker accepts
`uid=65532,gid=65532,mode=0700` in `--tmpfs`; the Podman `--tmpfs`
parser on the CI runner rejects `uid=`, so use its documented
`--mount type=tmpfs,...,tmpfs-mode=0700,U=true` form to assign ownership
to the nonroot image user. Do not replace the private mount with a
world-writable path or run the image as root. Task #162 verifies the private
directory's owner, mode, and write capability in both engines.

Help/version must report the same build metadata and output contract as the original producer script, without S3 or issuer calls. The image default command is --help, with the exact public producer executable as exec-form ENTRYPOINT. No implicit scheduler, host deployment, secret generation or account registration is provided.

If an Alpine v3.24 package, runtime tool or verified script check fails, **do not** bypass its guard to force a successful build. Docker and Podman have **not been used to validate this image in the current development environment**, so none of these engine builds are claimed as executed or successful. Task #162 will add mandatory engine-specific acceptance gates, including rootless Podman, permissions, UID mapping and SELinux-sensitive mounts.

After review, remove your own temporary local context; it contains only the public verified producer and nonsensitive provenance data. The caller owns cleanup and any mounted runtime secrets.

## Mocked certificate lifecycle parity under OCI (#200)

The tested image's existing CLI and toolchain smoke checks are complemented by
`tests/oci-lifecycle.bash`. It shares the synthetic S3/Certbot fixture with
`tests/public-lifecycle.bats` to create a self-signed seeded archive on the
trusted host and runs ten lifecycle cases against the real ordinary producer
under both Docker and rootless Podman. The identical Docker-built image is
loaded by Podman; no second image build or registry pull is involved.

The trusted fixture is mounted **read-only** at `/fixture`; the only writable
container state is a private UID-owned `/run/certbotbot` tmpfs. No production
credentials, host certificate directory, OCI engine socket or runtime network
access are provided. A short-lived test driver stages the local fake S3 object
in tmpfs and invokes `/usr/local/bin/certbotbot.bash` directly. The regular
`tests/oci-runtime.bash` suite separately verifies the real OCI ENTRYPOINT.

Covered cases are successful selected-lineage no-op renewal; wildcard SAN
selection of the same lineage; CLI and environment precedence for forced and
suppressed no-renewal upload; missing S3 object, denied HeadObject, corrupt and
partial download, and invalid CLI input. Each case enforces exact write/renewal
call counts, preservation of remote bytes when not publishing, redaction of
mock private cloud diagnostics, and host/container result parity.

The no-network suite deliberately **does not** demonstrate actual AWS IAM,
Route53 DNS authorization, Let's Encrypt issuance or real infrastructure
connectivity. Host OpenSSL issues only a synthetic, self-signed certificate
through the established Certbot mock, and tests the ordinary producer's
restoration, renewal and local publication boundary.
