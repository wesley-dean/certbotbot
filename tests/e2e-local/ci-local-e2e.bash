#!/usr/bin/env bash
# shellcheck shell=bash
## @file tests/e2e-local/ci-local-e2e.bash
## @brief Runs mandatory isolated ACME/S3 positive, negative, and egress tests.
## @details
## CI obtains source dependencies, verifies the real published producer artifact
## flavors and pulls immutable pinned service images BEFORE the internal Docker
## network starts. After that, all real protocol tests use unprivileged,
## no-egress, fresh runners with synthetic AWS credentials, Pebble ACME and
## SeaweedFS. Raw provider logs remain in disposable mode-0700 scratch and are
## never uploaded. A passing gate is NOT live AWS, Route53, DNS-01 validation or
## Let's Encrypt acceptance. See ADRs 046, 047, 048 and 049.
## @par Usage
## @code{.sh}
## bash tests/e2e-local/ci-local-e2e.bash
## @endcode

set -euo pipefail
umask 077
readonly REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly E2E="$REPO/tests/e2e-local"
readonly STACK="$E2E/run.bash"
readonly HOST="$E2E/first-issue-host.bash"
readonly COMPOSE_FILE="$E2E/compose.yml"
readonly PROJECT=certbotbot-local-e2e
readonly NETWORK=certbotbot-local-e2e_isolated
WORK=''
PROJECT_STARTED=false

## @fn error()
## @brief Prints a fixed nonsecret failure classification.
## @param message Nonsecret diagnostic string.
error() {
  printf 'local-e2e-ci: %s\n' "$1" >&2
}

## @fn reject_credentials()
## @brief Refuses inherited cloud authentication and remote Docker contexts.
## @retval 0 No unsafe exported credentials or Docker connection were found.
## @retval 65 Potential real cloud authority was detected.
reject_credentials() {
  local key
  [[ -z "${DOCKER_HOST-}" && -z "${DOCKER_CONTEXT-}" ]] ||
    { error 'remote Docker context forbidden'; return 65; }
  while IFS= read -r key; do
    case "$key" in
      AWS_*|GPG_SYMMETRIC_KEY|AZURE_CLIENT_ID|AZURE_CLIENT_SECRET|AZURE_TENANT_ID|AZURE_FEDERATED_TOKEN_FILE|GOOGLE_APPLICATION_CREDENTIALS)
        error 'ambient cloud credentials/settings forbidden'
        return 65
        ;;
    esac
  done < <(compgen -e)
}

## @fn require_host()
## @brief Validates a nonroot native Linux Docker and Compose v2 host.
## @retval 69 Required tools or local Docker engine are unavailable.
require_host() {
  local tool
  [[ "$(uname -s)" == Linux && "$(id -u)" -ne 0 ]] ||
    { error 'native unprivileged Linux host required'; return 69; }
  for tool in docker make bash curl jq openssl sha256sum timeout grep awk sed mktemp; do
    command -v "$tool" >/dev/null 2>&1 ||
      { error 'local verification tool missing'; return 69; }
  done
  [[ "$(docker context show 2>/dev/null)" == default &&
    "$(docker info --format '{{.OSType}}' 2>/dev/null)" == linux ]] ||
    { error 'local Linux Docker engine unavailable'; return 69; }
  docker compose version >/dev/null 2>&1 ||
    { error 'Docker Compose v2 unavailable'; return 69; }
}

## @fn require_receipt()
## @brief Requires an exact nonsecret phase receipt in a private log.
## @param file Previously captured private phase output.
## @param line Exact expected bounded proof line.
## @retval 65 Required proof not observed.
require_receipt() {
  [[ -f "$1" && ! -L "$1" ]] && grep -Fqx -- "$2" "$1" ||
    { error 'required bounded protocol proof missing'; return 65; }
}

## @fn prepare()
## @brief Acquires and verifies all dependencies before private-network startup.
## @details
## No mutable released producer, secret or default public CA is used. All
## artifacts derive from this checked source and have valid checksum companions.
## @retval 74 Dependency, build, checksum, or pinned image verification failed.
prepare() {
  local name
  if ! (cd "$REPO" && make deps && make deps-check) >"$WORK/deps.log" 2>&1; then
    error 'dependency preparation or offline verification failed'
    return 74
  fi
  if ! (cd "$REPO" && make build VERSION=0.0.0-dev) >"$WORK/build.log" 2>&1; then
    error 'public artifact build failed'
    return 74
  fi
  for name in certbotbot.dev.bash certbotbot.bash certbotbot.min.bash; do
    [[ -f "$REPO/dist/$name" && -f "$REPO/dist/$name.sha256" &&
      ! -L "$REPO/dist/$name" && ! -L "$REPO/dist/$name.sha256" ]] ||
      { error 'public artifact or checksum missing'; return 65; }
    (cd "$REPO/dist" && sha256sum -c "$name.sha256") >/dev/null 2>&1 ||
      { error 'public artifact checksum mismatch'; return 65; }
  done
  if ! bash "$HOST" build >"$WORK/runner-build.log" 2>&1; then
    error 'real Certbot runner image build failed'
    # This stage runs BEFORE any cloud/provider credential or ACME account
    # material exists. Only its public package/image build diagnostics are
    # safe to expose; later provider/runtime logs must remain private.
    tail -n 45 "$WORK/runner-build.log" >&2 || true
    return 74
  fi
  if ! bash "$STACK" fetch >"$WORK/service-fetch.log" 2>&1; then
    error 'pinned upstream image fetch/digest gate failed'
    return 74
  fi
  printf '%s\n' 'local-e2e-ci: dependencies_and_images=prefetched_and_verified'
}

## @fn start_private_project()
## @brief Starts pinned preloaded services with actual private network checks.
## @retval 65/74 Container/network isolation or service readiness failed.
start_private_project() {
  PROJECT_STARTED=true
  if ! bash "$STACK" up >"$WORK/startup.log" 2>&1; then
    error 'isolated ACME/SeaweedFS services unavailable'
    # Startup occurs before ACME account registration or S3 certificate
    # publication. The topology/readiness errors contain only owned service
    # names and public gateway diagnostics, not provider credentials.
    # Never expose the later real Certbot/AWS execution logs.
    tail -n 45 "$WORK/startup.log" >&2 || true
    return 74
  fi
  [[ "$(docker network inspect "$NETWORK" --format '{{.Internal}}' 2>/dev/null)" == true &&
    "$(docker network inspect "$NETWORK" --format '{{.Driver}}' 2>/dev/null)" == bridge ]] ||
    { error 'actual network is not an internal bridge'; return 65; }
  printf '%s\n' 'local-e2e-ci: private_network=inspected'
}

## @fn probe_no_egress()
## @brief Tests actual private runner routing, DNS and staging TLS before/after.
## @param phase before or after the real protocol scenarios.
## @retval 65 The real container isolation probe could not be proven.
probe_no_egress() {
  local phase="$1" logfile="$WORK/isolation-$1.log"
  if ! timeout --signal=TERM --kill-after=15s 240s \
    bash "$HOST" probe >"$logfile" 2>&1; then
    # The host emits an allowlisted classification from the sealed runner.
    # Match only exact owned receipts; never echo the underlying Docker
    # or provider output from private logs into the Actions console.
    local reason='unclassified' classification
    for classification in \
      provider-default-route missing-test-root missing-verifier \
      staging-dns-failed staging-dns-mismatch production-dns-resolved \
      staging-tls-or-http-failed staging-directory-mismatch \
      runner-default-route missing-route-table external-tcp-succeeded \
      forbidden-dns-resolved; do
      if grep -Fqx -- \
        "local-first-issue-host: sealed runner isolation probe failed: $classification" \
        "$logfile"; then
        reason="$classification"
        break
      fi
    done
    error "active no-egress and staging TLS probe failed: $reason"
    return 65
  fi
  require_receipt "$logfile" \
    'local-first-issue-host: active_no_egress_probe=true; challenge_validation=bypassed' ||
    return $?
  printf 'local-e2e-ci: no_egress_probe=%s; challenge_validation=bypassed\n' "$phase"
}

## @fn run_positive()
## @brief Proves first issue, three fresh no-ops, second order and republish.
## @retval 74 Real ACME and SeaweedFS acceptance could not be demonstrated.
run_positive() {
  local logfile="$WORK/positive.log" flavor
  if ! timeout --signal=TERM --kill-after=15s 2100s \
    bash "$HOST" run >"$logfile" 2>&1; then
    error 'real Pebble certificate lifecycle or S3 publication failed'
    return 74
  fi
  for flavor in development ordinary minified; do
    require_receipt "$logfile" \
      "local-first-issue-host: restored_noop=$flavor; no_new_order=true; no_republish=true" ||
      return $?
  done
  grep -Eq \
    '^local-first-issue-host: second_real_pebble_order=true; renewed_archive_sha256=[a-f0-9]{64}; renewed_cert_der_sha256=[a-f0-9]{64}$' \
    "$logfile" ||
    { error 'second real Pebble order and certificate replacement unproven'; return 65; }
  require_receipt "$logfile" \
    'local-first-issue-host: renewed_object_independently_verified=true; subsequent_normal_noop=true' ||
    return $?
  printf '%s\n' 'local-e2e-ci: positive=passed; second_real_pebble_order=true; independent_s3_readback=true'
}

## @fn run_negative()
## @brief Proves all seven external-provider faults preserve remote state.
## @retval 74 A required failure or independent S3 readback was not proven.
run_negative() {
  local logfile="$WORK/negative.log" scenario
  if ! timeout --signal=TERM --kill-after=15s 2100s \
    bash "$HOST" run-faults >"$logfile" 2>&1; then
    error 'isolated ACME, Route53 stub, S3 or archive failure gate failed'
    return 74
  fi
  for scenario in \
    ca-production s3-unavailable corrupt-archive acme-order-rejected \
    route53-unavailable s3-put-reject acme-unavailable; do
    require_receipt "$logfile" \
      "local-first-issue-host: negative=$scenario; remote_unchanged=true" ||
      return $?
  done
  require_receipt "$logfile" \
    'local-first-issue-host: all-negative-scenarios=passed; dns-validation=bypassed' ||
    return $?
  printf '%s\n' 'local-e2e-ci: negative_seven=passed; original_seaweedfs_archive=unchanged'
}

## @fn cleanup()
## @brief Unpauses project-owned Pebble and deletes only this Compose project.
## @details
## An unfinished failure test can leave Pebble paused; unpause before teardown.
## If cleanup fails after a green scenario, turn the CI result red. No private
## logs or certificates are ever uploaded to the workflow.
## @param original Original exit code, preserved if nonzero.
cleanup() {
  local original="$1" cleanup_failure=0 pebble=''
  trap - EXIT HUP INT TERM
  if [[ "$PROJECT_STARTED" == true ]]; then
    pebble="$(docker compose --env-file /dev/null -f "$COMPOSE_FILE" \
      -p "$PROJECT" ps -q pebble 2>/dev/null || true)"
    if [[ -n "$pebble" ]] &&
      [[ "$(docker inspect "$pebble" --format '{{.State.Paused}}' 2>/dev/null)" == true ]]; then
      docker unpause "$pebble" >/dev/null 2>&1 || cleanup_failure=1
    fi
    bash "$STACK" down >/dev/null 2>&1 || cleanup_failure=1
    if docker network inspect "$NETWORK" >/dev/null 2>&1; then
      cleanup_failure=1
    fi
  fi
  if [[ -n "$WORK" && -d "$WORK" ]]; then
    rm -rf -- "$WORK" || cleanup_failure=1
  fi
  if (( cleanup_failure != 0 )); then
    error 'private Docker project cleanup could not be verified'
    (( original != 0 )) && exit "$original"
    exit 75
  fi
  exit "$original"
}

## @fn main()
## @brief Runs mandatory prefetch, no-egress, positive, negative and cleanup.
## @retval 0 Every genuine protocol acceptance stage and security probe passed.
## @retval 64 Unexpected command-line input.
## @retval 65 One security boundary or required proof is missing.
## @retval 69 Required native Linux Docker prerequisites are absent.
## @retval 74 Real protocol or fixture operations could not be verified.
main() {
  (($# == 0)) ||
    { error 'usage: ci-local-e2e.bash (no arguments)'; return 64; }
  reject_credentials || return $?
  require_host || return $?
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/certbotbot-local-ci.XXXXXXXX")" ||
    { error 'private CI temporary workspace unavailable'; return 74; }
  trap 'cleanup "$?"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  prepare || return $?
  start_private_project || return $?
  probe_no_egress before || return $?
  run_positive || return $?
  run_negative || return $?
  probe_no_egress after || return $?
  printf '%s\n' 'local-e2e-ci: full_protocol_gate=passed; mode=challenge-validation-bypassed; aws_route53_dns01_live_ca=not_tested'
}

main "$@"
