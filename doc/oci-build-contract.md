# OCI Build Contract and Local Smoke Checks

Status: approved task #161 under [ADR-038](adr/ADR-038-verified-oci-producer-images.md). Required Docker/rootless-Podman CI evidence belongs to #162. Release-correlated image publication belongs to #164–#166. This file is a short build contract; task #163 owns the full container deployment guide.

## Provenance and runtime

The root [Dockerfile](../Dockerfile) builds **one** Linux/amd64 image for the ordinary producer, not the read-only client or a certificate-serving daemon. The published [Debian 13.7 slim amd64 manifest](https://github.com/docker-library/repo-info/blob/master/repos/debian/remote/13-slim.md) is pinned to SHA-256 4876fdea29cac1a33a3195f1eb1952feb1fca7dd6dd00be3e2f1879cf20d34d2. Both Debian and Debian-security APT repositories are resolved at the fixed snapshot 20261020T213255Z with Debian package-signature verification. The archive's time-expired index checks are intentionally disabled because snapshots are historical. The image also retains an auditable complete installed package/version inventory at /usr/local/share/certbotbot/packages.lock. Package input pinning does **not** itself prove byte-for-byte reproducibility, platform compatibility, or absence of CVEs.

The build checks actual Bash, AWS CLI v2, Certbot Route53 plugin, OpenSSL, GNU utilities and GnuPG 2.4.7+ with real authenticated AES-256/OCB packet and decrypt behavior. It embeds the already verified producer script, with no unverified network Bash download or runtime package installation.

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

Output is an **allowlisted** context containing Dockerfile, .dockerignore, oci/debian.sources, and oci/producer/certbotbot.bash, its checksum and nonsecret provenance. Dockerfile independently checks the copied script digest, source short commit, version, build kind and handoff digest. A raw Git checkout without this prepared producer is not a valid image build context.

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
  --tmpfs /run/certbotbot:rw,nosuid,nodev,uid=65532,gid=65532,mode=0700 \
  certbotbot:local --version
~~~

Help/version must report the same build metadata and output contract as the original producer script, without S3 or issuer calls. The image default command is --help, with the exact public producer executable as exec-form ENTRYPOINT. No implicit scheduler, host deployment, secret generation or account registration is provided.

If a snapshot mirror, pinned package, runtime tool or verified script check fails, **do not** bypass its guard to force a successful build. Docker and Podman are **not installed in the current development runtime**, so none of these engine builds are claimed as executed or successful. Task #162 will add mandatory engine-specific acceptance gates, including rootless Podman, permissions, UID mapping and SELinux-sensitive mounts.

After review, remove your own temporary local context; it contains only the public verified producer and nonsensitive provenance data. The caller owns cleanup and any mounted runtime secrets.
