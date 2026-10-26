#!/usr/bin/env bash
# shellcheck shell=bash
## @file tests/oci-lifecycle.bash
## @brief Compare mocked certificate lifecycles on the host and OCI engine.
## @details
## Reuses the established public-lifecycle synthetic account, local S3
## mock, and Certbot mock. The host first issues a synthetic self-signed
## lineage into its modeled S3 archive; each test case receives a clean copy
## via a read-only bind mount. Only the image's UID-owned private tmpfs is
## writable. No real AWS, ACME or DNS calls and no image rebuilds occur.
##
## The same exact Docker-built image must be used by Docker and rootless
## Podman. Dockerfile and runtime CLI identity checks remain the separate
## tests/oci-runtime.bash suite; this tests the ordinary producer lifecycle
## with a controlled test driver as entrypoint to stage private mock state.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## One nonsecret acceptance summary per engine.
## @par STDERR
## Nonsecret diagnostics identifying the failing scenario.
## @retval 0 Every required mocked scenario passed for the selected engine.
## @retval 1 A lifecycle scenario or runtime assertion failed.
## @retval 64 Invalid caller inputs.
## @retval 69 Required local verification tools were unavailable.

set -euo pipefail
(( $# == 3 )) || {
  printf 'usage: %s ENGINE IMAGE HOST_PRODUCER\n' "$0" >&2
  exit 64
}
engine=$1 image=$2 producer=$3
case "$engine" in docker|podman) ;; *) exit 64 ;; esac
[[ -f "$producer" && ! -L "$producer" ]] || exit 64
for tool in "$engine" openssl tar cmp sha256sum mktemp; do
  command -v "$tool" >/dev/null || exit 69
done
producer="$(realpath "$producer")"
fixture_script="$(realpath tests/oci-lifecycle-case.bash)"
[[ -f "$fixture_script" && ! -L "$fixture_script" ]] || exit 64

if [[ "$engine" == podman ]]; then
  [[ "$(id -u)" != 0 ]] || exit 1
  [[ "$(podman info --format '{{.Host.Security.Rootless}}')" == true ]] || exit 1
fi

# The same fixture underpins the exhaustive standalone Bats contract.
source tests/helpers/lifecycle-fixture.bash
lifecycle_fixture_setup
trap 'rm -rf -- "$ROOT"' EXIT

# A host-local first issue creates a valid selected lineage using the
# existing Certbot mock and OpenSSL. Its archive is then frozen as input
# for all no-op and failure scenarios; neither engine can edit that seed.
status=0
TMPDIR="$ROOT/runner-temp" "$producer" --s3-bucket fixture-bucket \
  example.com >"$ROOT/issue.out" 2>"$ROOT/issue.err" || status=$?
[[ "$status" == 0 ]] && grep -Fq 'published=true' "$ROOT/issue.out" &&
  grep -Fxq 'certbot:certonly' "$LIFECYCLE_CALLS" &&
  grep -Fq 'aws:put-object:fixture-bucket:latest.tar.gz' "$LIFECYCLE_CALLS" &&
  tar -tzf "$LIFECYCLE_REMOTE" | grep -Fq './renewal/example.com.conf' || {
    printf 'oci lifecycle: synthetic host seed issuance failed\n' >&2
    exit 1
  }

fixture="$ROOT/readonly-fixture"
mkdir -m 0755 "$fixture" "$fixture/bin"
cp -- "$ROOT/bin/aws" "$ROOT/bin/certbot" "$fixture/bin/"
cp -- "$LIFECYCLE_REMOTE" "$fixture/seeded-remote.tar.gz"
cp -- "$fixture_script" "$fixture/drive.bash"
chmod 0555 "$fixture/bin/aws" "$fixture/bin/certbot" "$fixture/drive.bash"
chmod 0444 "$fixture/seeded-remote.tar.gz"

if [[ "$engine" == podman ]]; then
  private_tmpfs=(--mount type=tmpfs,destination=/run/certbotbot,tmpfs-mode=0700,U=true)
else
  private_tmpfs=(--tmpfs /run/certbotbot:rw,nosuid,nodev,uid=65532,gid=65532,mode=0700)
fi

for scenario in no-op wildcard forced cli-false env-true \
  missing denied corrupt partial bad-option; do
  hostwork="$ROOT/host-$scenario"
  mkdir -m 0700 "$hostwork"
  OCI_FIXTURE_ROOT="$fixture" OCI_RUN_ROOT="$hostwork" \
    bash "$fixture_script" "$producer" "$scenario" \
    > "$ROOT/host-$scenario.result" || {
      printf 'oci lifecycle: host fixture failed: %s\n' "$scenario" >&2
      exit 1
    }

  "$engine" run --rm --pull=never --network=none --read-only \
    --cap-drop=ALL --security-opt=no-new-privileges \
    "${private_tmpfs[@]}" \
    --mount "type=bind,source=$fixture,target=/fixture,readonly" \
    --entrypoint /bin/bash "$image" \
    /fixture/drive.bash /usr/local/bin/certbotbot.bash "$scenario" \
    > "$ROOT/image-$scenario.result" || {
      printf 'oci lifecycle: image fixture failed: %s on %s\n' \
        "$scenario" "$engine" >&2
      exit 1
    }
  cmp -s "$ROOT/host-$scenario.result" "$ROOT/image-$scenario.result" || {
    printf 'oci lifecycle: host/container outcomes diverged: %s on %s\n' \
      "$scenario" "$engine" >&2
    exit 1
  }
done
printf 'oci lifecycle: %s passed 10 host-matched offline scenarios\n' "$engine"
