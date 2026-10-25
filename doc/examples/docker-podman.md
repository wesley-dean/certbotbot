# Docker and Rootless Podman: Operator Quick Start

This is the bounded, **example-only** quick start for the production root
[Dockerfile](../../Dockerfile), approved milestone 14 task
[#163](https://github.com/wesley-dean/certbotbot/issues/163). For provenance,
build-input verification and Alpine package policy, consult the
[OCI build contract](../oci-build-contract.md), [ADR-038](../adr/ADR-038-verified-oci-producer-images.md)
and [ADR-039](../adr/ADR-039-alpine-oci-runtime.md).
For deployment requirements, consult the existing
[full container deployment guide](../container-deployment.md) and the
[verified publication contract](../oci-publication-contract.md).

## Scope and prerequisites

The image executes the **producer** as a one-shot command. It is not a
scheduler, server, account registrar, certificate installer, or copy of the
separate read-only client. Current image acceptance is **linux/amd64 only**;
the CI tests Docker and rootless Podman against one transferred image.
Other architectures and live cloud operations have not been qualified by
those tests.

For real issuance or renewal, operators must already have:

- A registered Let's Encrypt production account encoded in a validated
  Certbot archive in an existing S3 bucket, and a suitable Route53 hosted zone.
- An AWS workload identity or separately provisioned, narrowly scoped
  credentials allowing the required S3 reads/writes and DNS-01 Route53 changes.
- A trusted, serialized schedule: do not run competing writers against the
  same S3 object. Repeated invocations may perform remote writes and retention.
- A way to deliver the resulting certificate from S3 to its consumer. The web
  server does **not** need Certbot or the certbotbot producer.

The initial build is **local development evidence**, not an authenticated
registry release. The Dockerfile refuses a bare Git checkout build context:
it requires an independently verified eight-file handoff. Do not put AWS
credentials, a `.env`, ACME material, or private keys in the build context.

## Use an independently verified published image

Official publication is release-gated to both
`ghcr.io/wesley-dean/certbotbot` and
`docker.io/wesleydean/certbotbot`. The image contains the **ordinary
producer**, not the separately shipped certificate client. The
initially supported platform is `linux/amd64`. This section describes
how to **use** an accepted image; it does not assert that a particular
digest is already published or accepted.

First, inspect the completed
[image publication workflow](../../.github/workflows/publish-image.yml),
the actual registry's manifest/digest and image provenance. Select an
**independently verified complete `sha256:` digest** for the intended
stable release and registry. Do not use `latest` as a deployment pin:
the version/major/minor and `latest` tags may move, while the image
digest identifies the selected published artifact. Other published
tags include the exact version and `sha-` followed by the short or
complete verified source commit; they are discovery aids, not substitutes
for independent digest verification. GHCR may require authenticated
pull access depending on package visibility.

For Docker, replace the obvious placeholder with the **actual**
verified GHCR image digest:

~~~bash
# Obtain the full digest by inspecting the actual accepted registry image.
DIGEST='sha256:REPLACE_WITH_VERIFIED_64_HEX_DIGEST'
IMAGE="ghcr.io/wesley-dean/certbotbot@$DIGEST"
docker pull --platform linux/amd64 "$IMAGE"
docker image inspect "$IMAGE" \
  --format '{{.Os}}/{{.Architecture}} {{.Config.User}}'
docker image inspect "$IMAGE" \
  --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'
docker image inspect "$IMAGE" \
  --format '{{index .Config.Labels "io.certbotbot.producer.sha256"}}'
# Offline CLI smoke check: no AWS, Route53 or ACME credentials needed.
docker run --rm --pull=never --network=none --read-only \
  --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /run/certbotbot:rw,nosuid,nodev,uid=65532,gid=65532,mode=0700 \
  "$IMAGE" --version
~~~

For rootless Podman, replace the placeholder with the verified
**Docker Hub** image digest, and use Podman's private tmpfs syntax:

~~~bash
DIGEST='sha256:REPLACE_WITH_VERIFIED_64_HEX_DIGEST'
IMAGE="docker.io/wesleydean/certbotbot@$DIGEST"
podman info --format '{{.Host.Security.Rootless}}'  # require true
podman pull --arch amd64 --os linux "$IMAGE"
podman image inspect "$IMAGE" \
  --format '{{.Os}}/{{.Architecture}} {{.Config.User}}'
podman image inspect "$IMAGE" \
  --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'
podman image inspect "$IMAGE" \
  --format '{{index .Config.Labels "io.certbotbot.producer.sha256"}}'
podman run --rm --pull=never --network=none --read-only \
  --cap-drop=ALL --security-opt=no-new-privileges \
  --mount type=tmpfs,destination=/run/certbotbot,tmpfs-mode=0700,U=true \
  "$IMAGE" --help
~~~

Confirm `linux/amd64`, image UID/GID `65532:65532`, the expected
full source revision and the checksum of the **verified ordinary
producer** from the accepted eight-file release handoff. Inspect
`org.opencontainers.image.version` as well. If checking both registries,
validate the remote digest and labels of each image independently;
do not assume one registry's success proves the other. Keep the
previous known-good digest for rollback.

These smoke checks deliberately use `--network=none`. For **real**
certificate maintenance, remove that restriction and provide the
already-required S3/Route53/ACME access, pre-existing account/archive,
restricted runtime credentials, and one-writer scheduling described
in [section 4](#4-real-credentials-and-operator-controlled-invocation)
and the [full guide](../container-deployment.md). Replace
`certbotbot:local` in the examples below with the verified `IMAGE`
reference and pass the same public CLI flags. Never place credentials
in image tags, build arguments, shell history, or published metadata.

## 1. Prepare a nonsecret development image context

From a trusted checkout on a Linux/amd64 machine with the repo's build
prerequisites installed:

~~~bash
set -euo pipefail
SOURCE_COMMIT="$(git rev-parse --verify HEAD)"
VERSION=0.0.0-dev
make deps
make build "VERSION=$VERSION"
WORK="$(mktemp -d)"
CONTEXT="$WORK/context" # must not exist before preparation
bash ci/prepare-oci-context.bash local dist "$CONTEXT" \
  "$SOURCE_COMMIT" 1 1 "$VERSION"
PRODUCER_SHA256="$(sed -n 's/^producer_sha256=//p' \
  "$CONTEXT/oci/producer/provenance.txt")"
HANDOFF_MANIFEST_SHA256="$(sed -n 's/^handoff_manifest_sha256=//p' \
  "$CONTEXT/oci/producer/provenance.txt")"
~~~

The `1 1` values are non-release development identity placeholders. Do not
substitute this local mode for the release-mode attestation gate.

## 2. Build and inspect with Docker or Podman

Use the **same** source context and arguments with your chosen engine. This
is an engine selection for separate local builds, **not** a claim that those
independently built images are byte-identical:

~~~bash
# Choose docker or podman; Podman is normally run as an unprivileged host user.
ENGINE=docker
"$ENGINE" build --platform linux/amd64 \
  --build-arg "SOURCE_COMMIT=$SOURCE_COMMIT" \
  --build-arg "RELEASE_VERSION=$VERSION" \
  --build-arg "PRODUCER_SHA256=$PRODUCER_SHA256" \
  --build-arg "HANDOFF_MANIFEST_SHA256=$HANDOFF_MANIFEST_SHA256" \
  --build-arg BUILD_KIND=local \
  -t certbotbot:local "$CONTEXT"
"$ENGINE" image inspect certbotbot:local \
  --format '{{.Os}}/{{.Architecture}} {{.Config.User}} {{.Config.Entrypoint}}'
~~~

To demonstrate **the same image** under both engines, build with Docker
once, `docker save -o "$WORK/producer.tar" certbotbot:local`, and then
`podman load -i "$WORK/producer.tar"` as the rootless Podman user.
That transfer path, rather than two builds, is covered by the
[OCI CI acceptance workflow](../../.github/workflows/oci-runtime.yml).
Image IDs may have engine-specific formatting; the provenance manifest and
script digest should be checked rather than inferring equivalence from tags.

## 3. Run the producer with a read-only root filesystem

Docker mounts a private mode-0700 tmpfs using explicit container UID/GID:

~~~bash
docker run --rm --pull=never --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --tmpfs /run/certbotbot:rw,nosuid,nodev,uid=65532,gid=65532,mode=0700 \
  certbotbot:local --help
docker run --rm --pull=never --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --tmpfs /run/certbotbot:rw,nosuid,nodev,uid=65532,gid=65532,mode=0700 \
  certbotbot:local --version
~~~

On **rootless Podman**, `--tmpfs uid=...` is unsupported by the tested
runner. Use its `--mount` form and `U=true` to arrange ownership by the
image's nonroot UID, without opening the mount to other users:

~~~bash
podman info --format '{{.Host.Security.Rootless}}' # must print true
podman run --rm --pull=never --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --mount type=tmpfs,destination=/run/certbotbot,tmpfs-mode=0700,U=true \
  certbotbot:local --help
podman run --rm --pull=never --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --mount type=tmpfs,destination=/run/certbotbot,tmpfs-mode=0700,U=true \
  certbotbot:local --version
~~~

Both examples use the image's exec-form producer entrypoint and default
UID:GID **65532:65532**. The container starts without user-supplied arguments
by displaying `--help`. Each run exits with the producer's status; a
nonzero status must fail its calling job, not be masked by `|| true`.
The tests also run with `--network=none`, which is suitable only for
offline help, version, and mocked contracts. Real ACME, S3, and Route53
operations require operator-approved outbound connectivity.

Do not mount `/var/run/docker.sock`, use `--privileged`, mount host
`/etc/letsencrypt`, or elevate the container to root. The persistent
certificate state remains in the operator-controlled S3 archive, not in
the container filesystem.

## 4. Real credentials and operator-controlled invocation

**No live credentials are provided here.** In cloud environments, prefer a
task/pod/instance role or comparable short-lived identity that the AWS CLI
can obtain at runtime. Where static credentials are unavoidable, inject
them at execution time from a host/orchestrator secret facility into a
**read-only** mounted file or restricted secret path readable by container
UID 65532. Do not add that file to the image context, command line, git,
labels, or stdout. A mount path, ownership, and host UID mapping that
work under Docker may require an explicit rootless Podman user-namespace
configuration. Verify actual permissions first; do not weaken them by
changing a private secret into world-readable input.

An external AWS shared-credentials file may be mounted as
`/run/secrets/aws-credentials:ro` and selected with the nonsecret
`AWS_SHARED_CREDENTIALS_FILE=/run/secrets/aws-credentials`
environment setting. For SELinux-enforcing Podman hosts, bind mounts can
require the appropriate `:Z` private relabel flag, **only** on files or
directories whose labels the operator authorizes changing. Relabeling
is not appropriate for a shared/system path. Cloud role identity may
also need a runtime metadata endpoint and scoped network connectivity.

Use the public producer syntax, for example:

~~~text
certbotbot:local --s3-bucket EXISTING_BUCKET --s3-key latest.tar.gz example.com
~~~

These are literal **placeholders**, not a command to run without verified
credentials, an existing valid archive, and an account. Docker and Podman
append the arguments after the image name in the same order. The supported
`--config FILE` input is for nonsecret literal configuration (read-only
mount recommended); it must not be confused with
`GPG_SYMMETRIC_KEY`, which is an **exported, secret-manager-supplied
environment variable**, never a `.env` file entry or CLI argument.
Environment injection can remain observable to privileged host/container
administrators; it does not provide a VM confidentiality guarantee.

For production, follow the [published image instructions](#use-an-independently-verified-published-image)
above, using the verified registry digest as the image reference and
the same runtime restrictions. Do not infer successful publication
or complete cross-registry parity from a locally built image.
The remaining registry verification contract is tracked in
[task #166](https://github.com/wesley-dean/certbotbot/issues/166).

## 5. Permissions, retries, and lifecycle checklist

- AWS read access to the current object is mandatory. Issuance/renewal
  additionally needs narrowly scoped Route53 TXT-record changes and S3
  writes. Enabled dated backups need extra backup-object write/metadata
  permissions; enabled retention also needs list, conditional delete, and
  any relevant versioning permissions according to the accepted S3 contract.
- Run only one writer against a given archive key at a time. The image
  does not implement distributed locking or scheduling. An orchestrator
  should preserve failures, avoid overlapping retries, and distinguish
  an uncertain remote write from a proven no-op; retries can repeat
  publication or partial backup/retention effects.
- Invalid arguments typically return 64; unsafe archive or certificate
  state, missing expected remote state, unavailable tools, and staging or
  service failures have distinct nonzero codes documented in the
  [product source](../../src/main.bash) and
  [archive contracts](../decisions.md). Do not infer successful renewal
  from a container exit alone without checking its reported outcome.
- Confirm image platform, no root/special capabilities, private tmpfs,
  no inherited unexpected environment variables, no mutable host
  certificate state, and appropriately controlled network egress.
- Consumer hosts separately download and install validated certificate
  material and perform their own reload/rotation. They need neither
  this producer image nor Certbot to use the resulting certificate.

See [the standalone read-only client contract](../separate-client-contract.md)
for the separately shipped client, and
[the full release/build contract](../oci-build-contract.md) for producer
handoff identity. Remove the temporary local context and image tar when
finished; do not place credentials in the example workspace.
