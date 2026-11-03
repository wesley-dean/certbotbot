#!/usr/bin/env bash
# shellcheck shell=bash
## @file tests/e2e-local/first-issue-host.bash
## @brief Builds and runs credential-free positive and negative local E2E tests.
## @details
## The explicit 'build' phase is the only phase allowed to fetch runner
## dependencies. 'run' requires the already cached runner image, a running
## validated private Compose project and the private gateway's public root.
## Positive run stages use separate unprivileged, read-only containers,
## each with its own disposable tmpfs and no Docker socket or default route.
## The distinct run-faults action requires a successful positive S3 seed and
## verifies each expected refusal against independent SeaweedFS readback.
## The file never accepts user-provided cloud credentials, bucket, CA or URLs.
## @par Usage
## @code{.sh}
## make build
## bash tests/e2e-local/first-issue-host.bash build
## bash tests/e2e-local/run.bash fetch
## bash tests/e2e-local/run.bash up
## bash tests/e2e-local/first-issue-host.bash probe
## bash tests/e2e-local/first-issue-host.bash run
## bash tests/e2e-local/first-issue-host.bash run-faults
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
  local flavor sum name
  for name in certbotbot.dev.bash certbotbot.bash certbotbot.min.bash; do
    [[ -f "$REPO/dist/$name" && -f "$REPO/dist/$name.sha256" &&
      ! -L "$REPO/dist/$name" && ! -L "$REPO/dist/$name.sha256" ]] ||
      { problem 'build all three exact public producers and checksums'; return 65; }
    (cd "$REPO/dist" && sha256sum -c "$name.sha256") >/dev/null 2>&1 ||
      { problem 'public producer flavor checksum verification failed'; return 65; }
  done
  # Key the local runner image to all three artifact flavors AND its test
  # source, not merely the ordinary producer. Reusing a stale local image
  # after a changed test runner must never yield false pass evidence.
  sum="$(sha256sum \
    "$REPO/dist/certbotbot.dev.bash" "$REPO/dist/certbotbot.bash" \
    "$REPO/dist/certbotbot.min.bash" \
    "$E2E/runner.Dockerfile" "$E2E/first-issue.bash" \
    "$E2E/provider-env.bash" "$E2E/certbot-force-renewal.bash" \
    "$E2E/negative-scenarios.bash" "$E2E/aws-put-reject.bash" | \
    sha256sum | awk '{print $1}')" || return 74
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
  case "$phase" in
    noop)
      case "${1-}" in development|ordinary|minified) ;;
        *) problem 'invalid no-op container flavor'; return 64 ;;
      esac
      name="${name}-${1}"
      ;;
    fault)
      case "${1-}" in
        ca-production|s3-unavailable|route53-unavailable|acme-unavailable|acme-order-rejected|s3-put-reject|corrupt-archive) ;;
        *) problem 'invalid negative scenario container name'; return 64 ;;
      esac
      name="${name}-${1}"
      ;;
  esac
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

## @fn pebble_order_count()
## @brief Reads only the last nonsecret order count emitted by pinned Pebble.
## @details
## The upstream pinned Pebble WFE emits "There are now N orders in the db"
## whenever a new order is successfully added. No raw logs, account IDs,
## or request contents are exported. A missing count means no proof, not zero.
## @retval 0 Count was established from pinned Pebble's container logs.
## @retval 65 Count not observable; no-op must not be reported as verified.
pebble_order_count() {
  local cid count
  cid="$(docker compose --env-file /dev/null -f "$E2E/compose.yml" \
    -p certbotbot-local-e2e ps -q pebble)" ||
    { problem 'Pebble container unavailable for order observation'; return 65; }
  [[ -n "$cid" ]] ||
    { problem 'Pebble container missing for order observation'; return 65; }
  count="$(docker logs "$cid" 2>&1 |
    sed -nE 's/.*There are now ([0-9]+) orders in the db.*/\1/p' | tail -n 1)" ||
    { problem 'Pebble order log inspection failed'; return 65; }
  [[ "$count" =~ ^[0-9]+$ && "$count" != 0 ]] ||
    { problem 'Pebble order counter not evidenced'; return 65; }
  printf '%s\n' "$count"
}

## @fn run_lifecycle()
## @brief Issues once, verifies, then proves three isolated non-due no-ops.
## @param image Already built and locally cached checked runner tag.
run_lifecycle() (
  local image="$1" tmp='' cert_ca='' cid='' log='' digest='' result=''
  local flavor count_before count_after renewed_digest='' renewed_cert='' old_cert=''
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
  docker exec "$cid" cat /data/caddy/pki/authorities/local/root.crt >"$cert_ca" 2>/dev/null ||
    { problem 'ephemeral public gateway CA unavailable'; return 74; }
  chmod 0644 "$cert_ca"
  openssl x509 -in "$cert_ca" -noout >/dev/null 2>&1 ||
    { problem 'gateway CA fixture invalid'; return 65; }
  log="$tmp/bootstrap.log"
  # Destroy the runner, account keys, client caches and logs even if a step
  # fails. No logs are printed from inside the untrusted provider process.
  if ! run_phase "$image" "$cert_ca" bootstrap >"$log" 2>&1; then
    # Only script-owned literal failure messages may escape this private log.
    # Raw Certbot, AWS, ACME and container output remains discarded.
    local reason='unclassified' line
    while IFS= read -r line; do
      case "$line" in
        'local-first-issue: local SeaweedFS bucket creation failed') reason=s3-bucket-create ;;
        'local-first-issue: new synthetic bucket unavailable') reason=s3-bucket-head ;;
        'local-first-issue: existing current archive forbids a first-issuance test') reason=unexpected-existing-object ;;
        'local-first-issue: current S3 object state is ambiguous') reason=s3-missing-object-ambiguous ;;
        'local-first-issue: ordinary issuance accepted missing account archive') reason=missing-account-accepted ;;
        'local-first-issue: failed ordinary issuance unexpectedly published an object') reason=failed-issue-published ;;
        'local-first-issue: current S3 object state became ambiguous after failed issuance') reason=s3-state-changed ;;
        'local-first-issue: real Pebble account registration or conditional S3 publish failed') reason=registration-or-publish ;;
        'local-first-issue: registration_stage=acme-registration') reason=register-acme ;;
        'local-first-issue: registration_stage=s3-conditional-publish') reason=register-s3-publish ;;
        'local-first-issue: registration_stage=account-packaging') reason=register-account-packaging ;;
        'local-first-issue: registration_stage=account-final-preflight') reason=register-account-final-preflight ;;
        'local-first-issue: registration_stage=account-initial-preflight') reason=register-account-initial-preflight ;;
        'local-first-issue: registration_stage=s3-object-preflight') reason=register-s3-preflight ;;
        'local-first-issue: registration_stage=certbot-unavailable') reason=register-certbot-unavailable ;;
        'local-first-issue: registration_stage=unclassified') reason=register-unclassified ;;
        'local-first-issue: registration did not confirm publication') reason=registration-receipt ;;
        'local-first-issue: account archive is unreadable') reason=account-archive-unreadable ;;
        'local-first-issue: native staging account data missing') reason=account-native-state-missing ;;
        'local-first-issue: registration unexpectedly created a certificate lineage') reason=registration-created-lineage ;;
        'local-first-issue: real Pebble certificate issuance or S3 publication failed') reason=issuance-or-publish ;;
        'local-first-issue: issuance_stage=s3-archive-missing') reason=issue-s3-archive-missing ;;
        'local-first-issue: issuance_stage=s3-object-preflight') reason=issue-s3-object-preflight ;;
        'local-first-issue: issuance_stage=s3-fetch') reason=issue-s3-fetch ;;
        'local-first-issue: issuance_stage=archive-restore') reason=issue-archive-restore ;;
        'local-first-issue: issuance_stage=restored-state') reason=issue-restored-state ;;
        'local-first-issue: issuance_stage=shared-state') reason=issue-shared-state ;;
        'local-first-issue: issuance_stage=account-unavailable') reason=issue-account-unavailable ;;
        'local-first-issue: issuance_stage=issuance-preflight') reason=issue-issuance-preflight ;;
        'local-first-issue: issuance_stage=issuance-account-identity') reason=issue-account-identity ;;
        'local-first-issue: issuance_stage=authenticator-probe') reason=issue-authenticator-probe ;;
        'local-first-issue: issuance_stage=route53-plugin') reason=issue-route53-plugin ;;
        'local-first-issue: issuance_stage=account-probe') reason=issue-account-probe ;;
        'local-first-issue: issuance_stage=certonly') reason=issue-certonly ;;
        'local-first-issue: issuance_stage=lineage-incomplete') reason=issue-lineage-incomplete ;;
        'local-first-issue: issuance_stage=post-issue-state') reason=issue-post-issue-state ;;
        'local-first-issue: issuance_stage=certificate-verification') reason=issue-certificate-verification ;;
        'local-first-issue: issuance_stage=certificate-key') reason=issue-certificate-key ;;
        'local-first-issue: issuance_stage=publish-preflight') reason=issue-publish-preflight ;;
        'local-first-issue: issuance_stage=s3-publish') reason=issue-s3-publish ;;
        'local-first-issue: issuance_stage=unclassified') reason=issue-unclassified ;;
        'local-first-issue: first issuance did not report issuance and publication') reason=issuance-receipt ;;
        'local-first-issue: independent S3 object download failed') reason=s3-object-read ;;
        'local-first-issue: downloaded S3 object is empty') reason=s3-object-empty ;;
        'local-first-issue: certificate archive unreadable') reason=certificate-archive-unreadable ;;
        'local-first-issue: selected renewal lineage missing') reason=certificate-lineage-missing ;;
        'local-first-issue: selected certificate bytes absent') reason=certificate-missing ;;
        'local-first-issue: certificate extraction failed') reason=certificate-extraction ;;
        'local-first-issue: leaf SAN does not match requested identity') reason=certificate-san ;;
        'local-first-issue: invalid issued PEM certificate') reason=certificate-pem ;;
        'local-first-issue: private key and certificate mismatch') reason=certificate-key-mismatch ;;
      esac
    done <"$log"
    # Only fixed, self-authored stage receipts are exported from the bridge.
    # Python/server logs stay private, even if a protocol request is malformed.
    local bridge_id='' bridge_log='' route_stage=no-request route_refusal=none
    bridge_id="$(docker compose --env-file /dev/null -f "$E2E/compose.yml" \
      -p certbotbot-local-e2e ps -q route53-bridge 2>/dev/null)" || bridge_id=''
    if [[ -n "$bridge_id" ]]; then
      bridge_log="$(docker logs "$bridge_id" 2>/dev/null)" || bridge_log=''
      if grep -Fqx 'local-route53-stub: hosted-zones=accepted' <<<"$bridge_log"; then
        route_stage=hosted-zones
      fi
      if grep -Fqx 'local-route53-stub: rrset-change=accepted' <<<"$bridge_log"; then
        route_stage=rrset-change
      fi
      if grep -Fqx 'local-route53-stub: change-poll=accepted' <<<"$bridge_log"; then
        route_stage=change-poll
      fi
      local fixed_code
      for fixed_code in AccessDenied InvalidInput InvalidAction InvalidChangeBatch NoSuchChange; do
        if grep -Fqx "local-route53-stub: refused=$fixed_code" <<<"$bridge_log"; then
          route_refusal="$fixed_code"
          break
        fi
      done
    fi
    problem "route53-checkpoint=$route_stage"
    problem "route53-refusal=$route_refusal"
    problem "bootstrap-failure=$reason"
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
  old_cert="$(sed -nE 's/^local-first-issue: independently_verified_cert_der_sha256=([0-9a-f]{64})$/\1/p' "$result")"
  [[ "$old_cert" =~ ^[0-9a-f]{64}$ ]] ||
    { problem 'initial independently verified DER fingerprint missing'; return 65; }
  printf '%s\n' 'local-first-issue-host: real local ACME and SeaweedFS first issuance verified (DNS-01 validation bypassed)'
  printf '%s\n' "local-first-issue-host: archive_sha256=$digest"
  sed -n '/^local-first-issue: independently_verified_cert_der_sha256=/p' "$result"

  # The pinned Pebble server records a nonsecret counter for every new order.
  # A no-op succeeds only when this count remains unchanged for each exact
  # producer flavor, proving no new order was added to Pebble's DB.
  count_before="$(pebble_order_count)" || return $?
  for flavor in development ordinary minified; do
    if ! run_phase "$image" "$cert_ca" noop "$flavor" "$digest" \
      >"$tmp/noop-$flavor.log" 2>&1; then
      problem 'fresh-runner selected renewal/no-op failed'
      return 74
    fi
    grep -Fqx "local-first-issue: fresh_runner_noop=$flavor; archive_sha256=$digest" \
      "$tmp/noop-$flavor.log" ||
      { problem 'fresh-runner no-op attestation missing'; return 65; }
    count_after="$(pebble_order_count)" || return $?
    [[ "$count_after" == "$count_before" ]] ||
      { problem 'new Pebble ACME order appeared during supposed no-op'; return 65; }
    printf 'local-first-issue-host: restored_noop=%s; no_new_order=true; no_republish=true\n' "$flavor"
  done

  # The first runner is long gone; this separate runner restores the current
  # S3 state, requests exactly one selected renewal using a one-shot private
  # force marker, and publishes through the unchanged public producer.
  count_before="$(pebble_order_count)" || return $?
  if ! run_phase "$image" "$cert_ca" renew "$digest" \
    >"$tmp/renew.log" 2>&1; then
    problem 'isolated second real Certbot renewal or S3 republication failed'
    return 74
  fi
  grep -Fqx 'local-first-issue: real_certbot_force_trigger_consumed=true' \
    "$tmp/renew.log" ||
    { problem 'real Certbot single-use renewal trigger not evidenced'; return 65; }
  renewed_digest="$(sed -nE 's/^local-first-issue: renewed_archive_sha256=([0-9a-f]{64})$/\1/p' "$tmp/renew.log")"
  renewed_cert="$(sed -nE 's/^local-first-issue: renewed_cert_der_sha256=([0-9a-f]{64})$/\1/p' "$tmp/renew.log")"
  [[ "$renewed_digest" =~ ^[0-9a-f]{64}$ && "$renewed_digest" != "$digest" &&
    "$renewed_cert" =~ ^[0-9a-f]{64}$ && "$renewed_cert" != "$old_cert" ]] ||
    { problem 'renewal did not produce a different archive and certificate'; return 65; }
  count_after="$(pebble_order_count)" || return $?
  [[ "$count_before" =~ ^[0-9]+$ && "$count_after" =~ ^[0-9]+$ &&
    "$count_after" -eq $((count_before + 1)) ]] ||
    { problem 'a second, and only one second, Pebble ACME order was not evidenced'; return 65; }

  # A third-party real S3 download from an entirely new container must
  # independently establish remote archive and certificate identity.
  if ! run_phase "$image" "$cert_ca" verify "$renewed_digest" \
    >"$tmp/renew-verify.log" 2>&1; then
    problem 'fresh independent validator rejected renewed S3 archive'
    return 74
  fi
  grep -Fqx "local-first-issue: independently_verified_cert_der_sha256=$renewed_cert" \
    "$tmp/renew-verify.log" ||
    { problem 'independent DER identity did not match renewed certificate'; return 65; }
  printf 'local-first-issue-host: second_real_pebble_order=true; renewed_archive_sha256=%s; renewed_cert_der_sha256=%s\n' "$renewed_digest" "$renewed_cert"

  # Nothing in the renewed archive may silently force later public renewals.
  # The same normal, unchanged no-op behavior must hold in another fresh
  # runner even after the deliberate one-shot renewal completed.
  if ! run_phase "$image" "$cert_ca" noop ordinary "$renewed_digest" \
    >"$tmp/noop-after-renew.log" 2>&1; then
    problem 'normal post-renewal check failed or unexpectedly republished'
    return 74
  fi
  grep -Fqx "local-first-issue: fresh_runner_noop=ordinary; archive_sha256=$renewed_digest" \
    "$tmp/noop-after-renew.log" ||
    { problem 'ordinary no-op did not survive real renewal'; return 65; }
  [[ "$(pebble_order_count)" == "$count_after" ]] ||
    { problem 'ordinary no-op after renewal created another ACME order'; return 65; }
  printf '%s\n' 'local-first-issue-host: renewed_object_independently_verified=true; subsequent_normal_noop=true'
)

## @fn run_faults()
## @brief Exercises each expected local provider failure after positive seeding.
## @details
## Requires pre-existing genuine SeaweedFS certificate state from a successful
## positive run. Each fault uses its own fresh runner. Independently fetches the
## original object after each refusal, and checks the exact hash and certificate.
## An ACME availability check pauses ONLY this project's Pebble container and
## resumes it under an EXIT trap; a stalled gateway aborts before issuer entry.
## No raw Certbot/AWS/ACME logs or private state are reported.
## @param image Already cached runner from the verified public producer.
run_faults() (
  local image="$1" tmp='' cert_ca='' cid='' pebble_id='' scenario=''
  local digest='' observed='' stdout_file=''
  docker image inspect "$image" >/dev/null 2>&1 ||
    { problem 'negative runner image missing; build before entering isolation'; return 69; }
  bash "$HARNESS" status >/dev/null ||
    { problem 'local services must be healthy before failure injection'; return 65; }
  tmp="$(mktemp -d)" ||
    { problem 'private negative test scratch unavailable'; return 74; }
  trap 'if [[ -n "$pebble_id" ]]; then docker unpause "$pebble_id" >/dev/null 2>&1 || true; fi; rm -rf -- "$tmp"' EXIT
  cert_ca="$tmp/gateway-root.crt"
  cid="$(docker compose --env-file /dev/null -f "$E2E/compose.yml" \
    -p certbotbot-local-e2e ps -q acme-gateway)" || return 74
  [[ -n "$cid" ]] ||
    { problem 'local canonical staging gateway absent'; return 65; }
  docker exec "$cid" cat /data/caddy/pki/authorities/local/root.crt >"$cert_ca" 2>/dev/null ||
    { problem 'temporary gateway public root unavailable'; return 74; }
  chmod 0644 "$cert_ca"
  openssl x509 -in "$cert_ca" -noout >/dev/null 2>&1 ||
    { problem 'gateway public root invalid'; return 65; }

  if ! run_phase "$image" "$cert_ca" baseline >"$tmp/baseline.log" 2>&1; then
    problem 'negative suite requires independently readable real certificate state'
    return 65
  fi
  digest="$(sed -nE 's/^local-first-issue: baseline_archive_sha256=([0-9a-f]{64})$/\1/p' "$tmp/baseline.log")"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] ||
    { problem 'baseline did not establish exact remote object digest'; return 65; }

  for scenario in ca-production s3-unavailable corrupt-archive acme-order-rejected route53-unavailable s3-put-reject; do
    stdout_file="$tmp/fault-$scenario.log"
    if ! run_phase "$image" "$cert_ca" fault "$scenario" "$digest" \
      >"$stdout_file" 2>&1; then
      problem 'expected failure scenario did not establish its preservation proof'
      return 74
    fi
    grep -Fqx \
      "local-first-issue: negative_scenario=$scenario; remote_unchanged=true; provider_success=false" \
      "$stdout_file" ||
      { problem 'required negative scenario receipt missing'; return 65; }
    if ! run_phase "$image" "$cert_ca" baseline >"$tmp/check-$scenario.log" 2>&1; then
      problem 'independent object verification failed after negative scenario'
      return 74
    fi
    observed="$(sed -nE 's/^local-first-issue: baseline_archive_sha256=([0-9a-f]{64})$/\1/p' "$tmp/check-$scenario.log")"
    [[ "$observed" == "$digest" ]] ||
      { problem 'authoritative object changed after negative scenario'; return 65; }
    printf 'local-first-issue-host: negative=%s; remote_unchanged=true\n' "$scenario"
  done

  # ACME availability is a local service outage, not an ACME order refusal.
  # Do not interfere with the pinned synthetic S3 object or the gateway PKI.
  pebble_id="$(docker compose --env-file /dev/null -f "$E2E/compose.yml" \
    -p certbotbot-local-e2e ps -q pebble)" || return 74
  [[ -n "$pebble_id" ]] ||
    { problem 'local Pebble container unavailable for outage test'; return 65; }
  docker pause "$pebble_id" >/dev/null ||
    { problem 'could not pause dedicated Pebble test CA'; return 74; }
  if ! run_phase "$image" "$cert_ca" fault acme-unavailable "$digest" \
    >"$tmp/fault-acme.log" 2>&1; then
    problem 'ACME outage did not fail closed before publication'
    return 74
  fi
  grep -Fqx \
    'local-first-issue: negative_scenario=acme-unavailable; remote_unchanged=true; provider_success=false' \
    "$tmp/fault-acme.log" ||
    { problem 'ACME outage negative receipt missing'; return 65; }
  docker unpause "$pebble_id" >/dev/null ||
    { problem 'Pebble did not resume after fault'; return 74; }
  pebble_id=''
  if ! run_phase "$image" "$cert_ca" baseline >"$tmp/check-acme.log" 2>&1; then
    problem 'ACME recovery verification failed'
    return 74
  fi
  observed="$(sed -nE 's/^local-first-issue: baseline_archive_sha256=([0-9a-f]{64})$/\1/p' "$tmp/check-acme.log")"
  [[ "$observed" == "$digest" ]] ||
    { problem 'remote object changed during ACME outage'; return 65; }
  printf '%s\n' 'local-first-issue-host: negative=acme-unavailable; remote_unchanged=true'
  printf '%s\n' 'local-first-issue-host: all-negative-scenarios=passed; dns-validation=bypassed'
)

## @fn run_isolation_probe()
## @brief Exercises the same nonroot, no-egress runner flags used by lifecycle.
## @details
## The only host-to-container data is a disposable public-only gateway root,
## extracted from this project's own running Caddy container. The dedicated
## probe phase verifies actual private HTTPS and attempts TCP connections
## only to documentation-reserved IPs, never real public provider services.
## Its temporary logs and root copy are removed on all normal exit paths.
## @param image Locally cached, source-bound runner image name.
## @retval 0 A nonsecret explicit private-route attestation was observed.
## @retval 65 Isolation, gateway or run receipt does not match contract.
run_isolation_probe() (
  local image="$1" tmp='' cid='' ca_file=''
  docker image inspect "$image" >/dev/null 2>&1 ||
    { problem 'checked isolation runner image missing'; return 69; }
  bash "$HARNESS" status >/dev/null ||
    { problem 'isolated Compose project is not in a verified running state'; return 65; }
  tmp="$(mktemp -d)" ||
    { problem 'private probe scratch unavailable'; return 74; }
  trap 'rm -rf -- "$tmp"' EXIT
  ca_file="$tmp/gateway-root.crt"
  cid="$(docker compose --env-file /dev/null -f "$E2E/compose.yml" \
    -p certbotbot-local-e2e ps -q acme-gateway)" || return 74
  [[ -n "$cid" ]] ||
    { problem 'isolation gateway container missing'; return 65; }
  docker exec "$cid" cat /data/caddy/pki/authorities/local/root.crt >"$ca_file" 2>/dev/null ||
    { problem 'public-only gateway root unavailable for isolation probe'; return 74; }
  chmod 0644 "$ca_file"
  openssl x509 -in "$ca_file" -noout >/dev/null 2>&1 ||
    { problem 'isolation gateway public root invalid'; return 65; }
  # Preserve only an exit code and exact script-owned diagnostics. Nothing
  # from Docker stderr or the private container log is copied to CI.
  local phase_status=0 reason='unclassified' line
  run_phase "$image" "$ca_file" isolation >"$tmp/isolation.log" 2>&1 ||
    phase_status=$?
  if (( phase_status != 0 )); then
    while IFS= read -r line; do
      case "$line" in
        'local-provider: default network route forbidden') reason=provider-default-route ;;
        'local-provider: ephemeral test trust root unavailable') reason=missing-test-root ;;
        'local-provider: endpoint verifier unavailable') reason=missing-verifier ;;
        'local-provider: canonical staging name resolution failed') reason=staging-dns-failed ;;
        'local-provider: staging name is not bound to test gateway') reason=staging-dns-mismatch ;;
        'local-provider: production CA name must not resolve') reason=production-dns-resolved ;;
        'local-provider: authenticated staging directory unavailable') reason=staging-tls-or-http-failed ;;
        'local-provider: foreign or malformed ACME directory') reason=staging-directory-mismatch ;;
        'local-first-issue: private staging TLS and route admission check failed') reason=provider-admission-failed ;;
        'local-first-issue: isolated runner has a default network route') reason=runner-default-route ;;
        'local-first-issue: isolation route table missing') reason=missing-route-table ;;
        'local-first-issue: outside-documentation-network connection unexpectedly succeeded') reason=external-tcp-succeeded ;;
        'local-first-issue: private runner resolved forbidden external DNS name') reason=forbidden-dns-resolved ;;
      esac
    done <"$tmp/isolation.log"
    if [[ "$reason" == unclassified ]] &&
      grep -Fqx 'local-first-issue: isolation_passed=true; challenge_validation=bypassed' \
        "$tmp/isolation.log"; then
      if grep -Fqx 'local-first-issue: isolation workspace cleanup failed' \
        "$tmp/isolation.log"; then
        reason=runner-cleanup-failed
      elif grep -Fqx 'local-first-issue: isolation_cleanup_verified=true' \
        "$tmp/isolation.log"; then
        reason=runner-cleanup-succeeded-but-exited
      else
        reason=runner-cleanup-unverified
      fi
    fi
    if [[ "$reason" == unclassified ]]; then
      case "$phase_status" in
        124|137) reason=runner-timeout ;;
        125) reason=docker-startup-rejected ;;
        126|127) reason=runner-executable-unavailable ;;
        64|65|69|74) reason=runner-inner-exit ;;
        *) reason=runner-exit-other ;;
      esac
      # Stage markers are fixed text issued by this test-only executable.
      # The last marker is useful if a shell or third-party binary exits
      # without an explicit error classification.
      if [[ "$reason" == runner-inner-exit || "$reason" == runner-exit-other ]]; then
        if grep -Fqx 'local-first-issue: isolation_stage=reserved-dns' "$tmp/isolation.log"; then
          reason=runner-stage-reserved-dns
        elif grep -Fqx 'local-first-issue: isolation_stage=reserved-tcp' "$tmp/isolation.log"; then
          reason=runner-stage-reserved-tcp
        elif grep -Fqx 'local-first-issue: isolation_stage=route' "$tmp/isolation.log"; then
          reason=runner-stage-route
        elif grep -Fqx 'local-first-issue: isolation_stage=provider' "$tmp/isolation.log"; then
          reason=runner-stage-provider
        else
          reason=runner-before-isolation-entrypoint
        fi
      fi
    fi
    problem "sealed runner isolation probe failed: $reason; exit_status=$phase_status"
    return 65
  fi
  grep -Fqx 'local-first-issue: isolation_passed=true; challenge_validation=bypassed' \
    "$tmp/isolation.log" ||
    { problem 'bounded isolation test receipt missing'; return 65; }
  printf '%s\n' 'local-first-issue-host: active_no_egress_probe=true; challenge_validation=bypassed'
)

## @fn main()
## @brief Dispatches explicit dependency-fetch and sealed-test phases only.
main() {
  local action="${1-}" image=''
  (( $# == 1 )) ||
    { problem 'usage: first-issue-host.bash build|run'; return 64; }
  case "$action" in
    build|probe|run|run-faults) ;;
    *) problem 'usage: first-issue-host.bash build|probe|run|run-faults'; return 64 ;;
  esac
  reject_cloud_env || return $?
  require_engine || return $?
  image="$(verified_artifact)" || return $?
  if [[ "$action" == build ]]; then
    build_runner "$image"
    return $?
  fi
  # No remote image pull, package installation, or source compilation here.
  # Cleanup is deliberately scoped to this project's known ephemeral runner names.
  trap 'docker rm -f certbotbot-local-e2e-bootstrap certbotbot-local-e2e-verify certbotbot-local-e2e-noop-development certbotbot-local-e2e-noop-ordinary certbotbot-local-e2e-noop-minified certbotbot-local-e2e-renew certbotbot-local-e2e-baseline certbotbot-local-e2e-fault-ca-production certbotbot-local-e2e-fault-s3-unavailable certbotbot-local-e2e-fault-corrupt-archive certbotbot-local-e2e-fault-acme-order-rejected certbotbot-local-e2e-fault-route53-unavailable certbotbot-local-e2e-fault-s3-put-reject certbotbot-local-e2e-fault-acme-unavailable certbotbot-local-e2e-isolation >/dev/null 2>&1 || true' EXIT
  case "$action" in
    probe) run_isolation_probe "$image" ;;
    run) run_lifecycle "$image" ;;
    run-faults) run_faults "$image" ;;
  esac
}

main "$@"
