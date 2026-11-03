#!/usr/bin/env bash
# shellcheck shell=bash
## @file tests/e2e-local/first-issue-host.bash
## @brief Builds and runs the first genuine local ACME/S3 lifecycle test.
## @details
## The explicit 'build' phase is the only phase allowed to fetch runner
## dependencies. 'run' requires the already cached runner image, a running
## validated private Compose project and the private gateway's public root.
## The two phases of 'run' use separate unprivileged, read-only containers,
## each with its own disposable tmpfs and no Docker socket or default route.
## The file never accepts user-provided cloud credentials, bucket, CA or URLs.
## @par Usage
## @code{.sh}
## make build
## bash tests/e2e-local/first-issue-host.bash build
## bash tests/e2e-local/run.bash fetch
## bash tests/e2e-local/run.bash up
## bash tests/e2e-local/first-issue-host.bash run
## bash tests/e2e-local/run.bash down
## @endcode

set -euo pipefail
umask 077

readonly REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly E2E="$REPO/tests/e2e-local"
readonly HARNESS="$E2E/run.bash"
readonly NETWORK=certbotbot-local-e2e_isolated
readonly STAGING=acme-staging-v02.api.letsencrypt.org
readonly IMAGE_PREFIX=certbotbot-local-runner

## @fn problem()
## @brief Writes a fixed diagnostic that contains no credentials or account data.
## @param message Fixed diagnostic.
problem() {
  printf 'local-first-issue-host: %s\n' "$1" >&2
}

## @fn reject_cloud_env()
## @brief Refuses an AWS-authorized shell before any Docker or build operation.
reject_cloud_env() {
  local name
  while IFS= read -r name; do
    case "$name" in
      AWS_*|GPG_SYMMETRIC_KEY)
        problem 'remove exported cloud or encryption settings first'
        return 65
        ;;
    esac
  done < <(compgen -e)
}

## @fn require_engine()
## @brief Requires a native Linux Docker Engine and Compose v2.
require_engine() {
  [[ "$(uname -s)" == Linux ]] ||
    { problem 'native Linux host required'; return 69; }
  command -v docker >/dev/null 2>&1 &&
    command -v timeout >/dev/null 2>&1 &&
    command -v sha256sum >/dev/null 2>&1 ||
    { problem 'Docker, timeout or checksum utility unavailable'; return 69; }
  [[ -z "${DOCKER_HOST-}" && -z "${DOCKER_CONTEXT-}" ]] ||
    { problem 'remote or overridden Docker context forbidden'; return 65; }
  [[ "$(docker context show 2>/dev/null)" == default &&
    "$(docker info --format '{{.OSType}}' 2>/dev/null)" == linux ]] ||
    { problem 'default local Linux Docker engine required'; return 69; }
  docker compose version >/dev/null 2>&1 ||
    { problem 'Docker Compose v2 unavailable'; return 69; }
}

## @fn verified_artifact()
## @brief Calculates the exact checked public producer's immutable image tag.
## @returns Docker image name with twelve-character artifact SHA suffix.
verified_artifact() {
  local sum
  [[ -f "$REPO/dist/certbotbot.bash" &&
    -f "$REPO/dist/certbotbot.bash.sha256" &&
    ! -L "$REPO/dist/certbotbot.bash" ]] ||
    { problem 'first build exact public producer and checksum'; return 65; }
  (cd "$REPO/dist" && sha256sum -c certbotbot.bash.sha256) >/dev/null 2>&1 ||
    { problem 'public producer checksum verification failed'; return 65; }
  sum="$(sha256sum "$REPO/dist/certbotbot.bash" | awk '{print $1}')" || return 74
  [[ "$sum" =~ ^[a-f0-9]{64}$ ]] || return 65
  printf '%s:sha-%s\n' "$IMAGE_PREFIX" "${sum:0:12}"
}

## @fn build_runner()
## @brief Builds verified test runner while dependency network access is allowed.
build_runner() {
  local image="$1"
  docker build --file "$E2E/runner.Dockerfile" --tag "$image" "$REPO" ||
    { problem 'test runner build failed'; return 74; }
  docker image inspect "$image" >/dev/null 2>&1 ||
    { problem 'built test image unavailable'; return 69; }
  printf '%s\n' 'local-first-issue-host: private runner image prepared'
}

## @fn run_phase()
## @brief Executes a bounded phase with no public DNS/default route or host state.
## @param image Verified prebuilt runner tag.
## @param ca_file Ephemeral public-only local CA root path.
## @param phase bootstrap or verify.
## @param ... Optional nonsecret digest argument.
run_phase() {
  local image="$1" ca_file="$2" phase="$3"
  shift 3
  local name="certbotbot-local-e2e-${phase}"
  # No --privileged, published ports, host network, root credentials, Docker
  # socket or shared file state. Private hosts binding plus loopback-only DNS
  # enforce the canonical staging host with no public resolver fallback.
  timeout --signal=TERM --kill-after=15s 420s \
    docker run --rm --name "$name" \
      --network "$NETWORK" --dns 127.0.0.1 \
      --add-host "$STAGING:172.31.248.5" \
      --read-only \
      --tmpfs /tmp:rw,nosuid,nodev,size=536870912,mode=1777 \
      --cap-drop ALL --security-opt no-new-privileges:true \
      --pids-limit 256 --memory 1g --cpus 2 \
      --mount "type=bind,source=$ca_file,target=/run/certbotbot-e2e/gateway-root.crt,readonly" \
      "$image" "$phase" "$@"
}

## @fn run_lifecycle()
## @brief Starts two isolated runners and independently verifies S3 bytes.
## @param image Already built and locally cached checked runner tag.
run_lifecycle() (
  local image="$1" tmp='' cert_ca='' cid='' log='' digest='' result=''
  docker image inspect "$image" >/dev/null 2>&1 ||
    { problem 'runner image missing; use build before starting sealed services'; return 69; }
  bash "$HARNESS" status >/dev/null ||
    { problem 'local services are not in verified running state'; return 65; }
  tmp="$(mktemp -d)" ||
    { problem 'temporary public-root staging unavailable'; return 74; }
  trap 'rm -rf -- "$tmp"' EXIT
  # Only temporary public CA root bytes are exposed on the host.
  cert_ca="$tmp/gateway-root.crt"
  cid="$(docker compose --env-file /dev/null -f "$E2E/compose.yml" \
    -p certbotbot-local-e2e ps -q acme-gateway)" || return 74
  [[ -n "$cid" ]] ||
    { problem 'canonical gateway container missing'; return 65; }
  docker cp "$cid:/data/caddy/pki/authorities/local/root.crt" "$cert_ca" >/dev/null 2>&1 ||
    { problem 'ephemeral public gateway CA unavailable'; return 74; }
  chmod 0644 "$cert_ca"
  openssl x509 -in "$cert_ca" -noout >/dev/null 2>&1 ||
    { problem 'gateway CA fixture invalid'; return 65; }
  log="$tmp/bootstrap.log"
  # Destroy the runner, account keys, client caches and logs even if a step
  # fails. No logs are printed from inside the untrusted provider process.
  if ! run_phase "$image" "$cert_ca" bootstrap >"$log" 2>&1; then
    problem 'real registration/initial issuance failed; see private runner evidence'
    return 74
  fi
  digest="$(sed -n 's/^local-first-issue: issued_archive_sha256=\([a-f0-9]\{64\}\)$/\1/p' "$log")"
  [[ "$digest" =~ ^[a-f0-9]{64}$ ]] ||
    { problem 'bootstrap did not supply a valid object identity'; return 65; }

  result="$tmp/verify.log"
  if ! run_phase "$image" "$cert_ca" verify "$digest" >"$result" 2>&1; then
    problem 'independent fresh runner could not verify stored certificate'
    return 74
  fi
  grep -Eq '^local-first-issue: independently_verified_cert_der_sha256=[a-f0-9]{64}$' "$result" ||
    { problem 'independent certificate proof missing'; return 65; }
  printf '%s\n' 'local-first-issue-host: real local ACME and SeaweedFS first issuance verified (DNS-01 validation bypassed)'
  printf '%s\n' "local-first-issue-host: archive_sha256=$digest"
  sed -n '/^local-first-issue: independently_verified_cert_der_sha256=/p' "$result"
)

## @fn main()
## @brief Dispatches explicit dependency-fetch and sealed-test phases only.
main() {
  local action="${1-}" image=''
  (( $# == 1 )) ||
    { problem 'usage: first-issue-host.bash build|run'; return 64; }
  case "$action" in
    build|run) ;;
    *) problem 'usage: first-issue-host.bash build|run'; return 64 ;;
  esac
  reject_cloud_env || return $?
  require_engine || return $?
  image="$(verified_artifact)" || return $?
  if [[ "$action" == build ]]; then
    build_runner "$image"
    return $?
  fi
  # No remote image pull, package installation, or source compilation here.
  # Cleanup is deliberately scoped to this run's two fixed container names.
  trap 'docker rm -f certbotbot-local-e2e-bootstrap certbotbot-local-e2e-verify >/dev/null 2>&1 || true' EXIT
  run_lifecycle "$image"
}

main "$@"
