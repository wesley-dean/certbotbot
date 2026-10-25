# Docker and Rootless Podman: Operator Quick Start

This is the bounded, **example-only** quick start for the production root
[Dockerfile](../../Dockerfile), approved milestone 14 task
[#163](https://github.com/wesley-dean/certbotbot/issues/163). For provenance,
build-input verification and Alpine package policy, consult the
[OCI build contract](../oci-build-contract.md), [ADR-038](../adr/ADR-038-verified-oci-producer-images.md)
and [ADR-039](../adr/ADR-039-alpine-oci-runtime.md).
The comprehensive operator guide is separately tracked under
[task #157](https://github.com/wesley-dean/certbotbot/issues/157);
`doc/container-deployment.md` is its planned path and may not exist yet.

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

For production, pull using a reviewed **immutable registry digest**
(`registry.example/namespace/certbotbot@sha256:<verified-digest>`),
verify the platform and provenance/labels, then apply the same runtime
restrictions. This is a format example: a published GHCR/Docker Hub digest
is **not** asserted to exist yet. Registry publishing and parity verification
belong to tasks #164–#166.

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
