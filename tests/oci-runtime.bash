#!/usr/bin/env bash
# shellcheck shell=bash
## @file tests/oci-runtime.bash
## @brief Exercise the same locally verified OCI image under one chosen engine.
## @details
## This acceptance suite deliberately disables network access and drops Linux
## capabilities. It never supplies AWS or ACME credentials. Docker and rootless
## Podman must independently pass against the same loaded OCI image.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Human-readable acceptance results, including the engine and image identity.
## @par STDERR
## Failure diagnostics without credentials.
## @retval 0 All required offline engine assertions passed.
## @retval 1 An image runtime contract was violated.
## @retval 64 Caller supplied invalid arguments.
## @retval 69 Required container engine or local tool was unavailable.
set -euo pipefail

if (( $# != 3 )); then
  printf 'usage: %s ENGINE IMAGE HOST_PRODUCER\n' "$0" >&2
  exit 64
fi
engine=$1
image=$2
producer=$3
case "$engine" in
  docker|podman) ;;
  *) printf 'oci: engine must be docker or podman\n' >&2; exit 64 ;;
esac
command -v "$engine" >/dev/null || { printf 'oci: required %s unavailable\n' "$engine" >&2; exit 69; }
command -v mktemp >/dev/null || exit 69
command -v cmp >/dev/null || exit 69
[[ -f "$producer" && ! -L "$producer" ]] || { printf 'oci: missing verified host producer\n' >&2; exit 64; }
if [[ "$engine" == podman ]]; then
  [[ "$(id -u)" != 0 ]] || { printf 'oci: rootless Podman requires nonroot host user\n' >&2; exit 1; }
  [[ "$(podman info --format '{{.Host.Security.Rootless}}')" == true ]] || {
    printf 'oci: Podman is not running rootless\n' >&2
    exit 1
  }
fi

# The loaded image must be native Linux/amd64, and a concrete image ID must
# exist. Never pull, build, or fall back to a registry tag in this suite.
"$engine" image inspect "$image" >/dev/null
os="$("$engine" image inspect "$image" --format '{{.Os}}')"
arch="$("$engine" image inspect "$image" --format '{{.Architecture}}')"
user="$("$engine" image inspect "$image" --format '{{.Config.User}}')"
entry="$("$engine" image inspect "$image" --format '{{json .Config.Entrypoint}}')"
image_id="$("$engine" image inspect "$image" --format '{{.Id}}')"
[[ "$os" == linux && "$arch" == amd64 && "$user" == 65532:65532 ]] || {
  printf 'oci: unexpected OS/architecture/user: %s/%s/%s\n' "$os" "$arch" "$user" >&2
  exit 1
}
[[ "$entry" == '["/usr/local/bin/certbotbot.bash"]' ]] || {
  printf 'oci: unexpected image entrypoint: %s\n' "$entry" >&2
  exit 1
}
[[ -n "$image_id" ]] || exit 1

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

# Disallow runtime network traffic even for negative paths. The only writable
# filesystem is an explicitly scoped, UID-owned tmpfs. Do not mount host state.
run=("$engine" run --rm --pull=never --network=none --read-only
  --cap-drop=ALL --security-opt=no-new-privileges
  --tmpfs /run/certbotbot:rw,nosuid,nodev,uid=65532,gid=65532,mode=0700
  "$image")

run_capture() {
  local label=$1
  shift
  local status=0
  "${run[@]}" "$@" >"$work/$label.out" 2>"$work/$label.err" || status=$?
  printf '%s\n' "$status" >"$work/$label.status"
}
host_capture() {
  local label=$1
  shift
  local status=0
  "$producer" "$@" >"$work/$label.host.out" 2>"$work/$label.host.err" || status=$?
  printf '%s\n' "$status" >"$work/$label.host.status"
}

# Runtime tests supply no credentials, secrets, or application state. Report
# only engine diagnostics from these known-safe synthetic invocations so a
# container startup failure cannot masquerade as a public CLI regression.
oci_report_runtime_failure() {
  local label=$1
  printf 'oci: %s host exit=%s container exit=%s\n' \
    "$label" "$(cat "$work/$label.host.status")" \
    "$(cat "$work/$label.status")" >&2
  if [[ -s "$work/$label.err" ]]; then
    printf 'oci: %s container stderr follows:\n' "$label" >&2
    cat "$work/$label.err" >&2
  fi
}

for pair in help version; do
  host_capture "$pair" "--$pair"
  run_capture "$pair" "--$pair"
  cmp -s "$work/$pair.host.status" "$work/$pair.status" || {
    printf 'oci: %s exit status differs from ordinary producer\n' "$pair" >&2
    oci_report_runtime_failure "$pair"
    exit 1
  }
  cmp -s "$work/$pair.host.out" "$work/$pair.out" || {
    printf 'oci: %s stdout differs from ordinary producer\n' "$pair" >&2
    exit 1
  }
  [[ ! -s "$work/$pair.err" ]] || {
    printf 'oci: %s emitted unexpected stderr\n' "$pair" >&2
    exit 1
  }
done

# The image deliberately supplies CMD ["--help"], so *zero Docker argv*
# is a successful help invocation. The bare host producer differs because it
# has no image CMD; test that image-specific default independently.
run_capture default
cmp -s "$work/help.status" "$work/default.status" || {
  printf 'oci: default image command did not exit like --help\n' >&2
  exit 1
}
cmp -s "$work/help.out" "$work/default.out" || {
  printf 'oci: default image command did not print --help output\n' >&2
  exit 1
}
[[ ! -s "$work/default.err" ]] || {
  printf 'oci: default image command emitted unexpected stderr\n' >&2
  exit 1
}

# Explicitly pass an incomplete invocation so CMD is replaced and the real
# required-argument failure path is exercised without contacting cloud APIs.
for scenario in missing-domain invalid; do
  case "$scenario" in
    missing-domain)
      host_capture "$scenario" --s3-bucket fixture-bucket
      run_capture "$scenario" --s3-bucket fixture-bucket
      ;;
    invalid)
      host_capture "$scenario" --oci-unknown-option
      run_capture "$scenario" --oci-unknown-option
      ;;
  esac
  [[ "$(cat "$work/$scenario.status")" != 0 ]] || {
    printf 'oci: invalid input unexpectedly succeeded: %s\n' "$scenario" >&2
    exit 1
  }
  cmp -s "$work/$scenario.host.status" "$work/$scenario.status" || {
    printf 'oci: %s failure exit status differs\n' "$scenario" >&2
    oci_report_runtime_failure "$scenario"
    exit 1
  }
done

# Override ENTRYPOINT solely for a read-only runtime inspection; application
# invocation above always uses the real exec-form ENTRYPOINT.
"$engine" run --rm --pull=never --network=none --read-only \
  --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /run/certbotbot:rw,nosuid,nodev,uid=65532,gid=65532,mode=0700 \
  --entrypoint /bin/bash "$image" -c '
    set -euo pipefail
    [[ "$(id -u)" == 65532 && "$(id -g)" == 65532 ]]
    [[ "$HOME" == /run/certbotbot && "$TMPDIR" == /run/certbotbot ]]
    [[ "$(stat -c %a /run/certbotbot)" == 700 ]]
    [[ -w "$TMPDIR" ]]
    test -z "$(find "$TMPDIR" -mindepth 1 -print -quit)"
    probe="$(mktemp)"
    printf "runtime-fixture\n" > "$probe"
    rm -f -- "$probe"
    for tool in bash aws certbot gpg openssl tar gzip find awk sed grep sha256sum; do
      command -v "$tool" >/dev/null
    done
    aws --version 2>&1 | grep -Eq "^aws-cli/2\\."
    certbot --config-dir "$TMPDIR/config" --work-dir "$TMPDIR/work" --logs-dir "$TMPDIR/logs" plugins --text 2>&1 | grep -Fq dns-route53
    test -s /usr/local/share/certbotbot/packages.lock
    test ! -e /var/run/docker.sock
  ' >"$work/inspect.out" 2>"$work/inspect.err" || {
    printf 'oci: read-only unprivileged runtime inspection failed\n' >&2
    cat "$work/inspect.err" >&2
    exit 1
  }

printf 'oci: %s accepted verified %s image %s (linux/amd64, no runtime network)\n' "$engine" "$image" "$image_id"
