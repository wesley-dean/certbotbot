#!/usr/bin/env bash
# shellcheck shell=bash
## @file tests/e2e-local/run.bash
## @brief Provisions and tears down disposable, pinned local ACME/S3 services.
## @details
## ADR-046 / task #242.  The only network-enabled operation is explicit
## "fetch" for upstream immutable images.  "up" uses cached images only.
## The internal Docker bridge has no published ports or external route.
## This runner does not simulate Route53 or invoke certbotbot: those are
## separate approved tasks.  Readiness is not interoperability evidence.
## @par Usage
## @code{.sh}
## bash tests/e2e-local/run.bash fetch
## bash tests/e2e-local/run.bash up
## bash tests/e2e-local/run.bash status
## bash tests/e2e-local/run.bash down
## @endcode

set -euo pipefail

readonly E2E_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly COMPOSE_FILE="$E2E_DIR/compose.yml"
readonly PROJECT='certbotbot-local-e2e'
readonly NETWORK="${PROJECT}_isolated"
readonly PEBBLE_IP='172.31.248.2'
readonly ROUTE53_IP='172.31.248.6'
readonly SEAWEED_IP='172.31.248.4'
readonly GATEWAY_IP='172.31.248.5'
readonly STAGING_HOST='acme-staging-v02.api.letsencrypt.org'

## @fn report_error()
## @brief Emits a bounded nonsecret error without selecting the exit status.
## @param message Fixed error string without credentials.
report_error() {
  printf 'local-e2e: %s\n' "$1" >&2
}

## @fn fail()
## @brief Reports a failure and returns status one to the caller.
## @param message Fixed error string without credentials.
fail() {
  report_error "$1"
  return 1
}

## @fn compose()
## @brief Restricts all Docker Compose commands to this one project and file.
compose() {
  docker compose --env-file /dev/null -f "$COMPOSE_FILE" -p "$PROJECT" "$@"
}

## @fn require_tools()
## @brief Enforces initial Linux/native Docker Compose support boundary.
## @retval 0 Local tooling and Docker engine are available.
## @retval 1 The runtime is missing, remote, or unsupported.
require_tools() {
  [[ "$(uname -s)" == Linux ]] || fail 'Linux Docker host required' || return 1
  command -v docker >/dev/null 2>&1 || fail 'Docker unavailable' || return 1
  command -v jq >/dev/null 2>&1 || fail 'jq unavailable' || return 1
  command -v curl >/dev/null 2>&1 || fail 'curl unavailable' || return 1
  [[ -z "${DOCKER_HOST-}" && -z "${DOCKER_CONTEXT-}" ]] ||
    { fail 'remote/overridden Docker context is disallowed'; return 1; }
  [[ "$(docker context show 2>/dev/null)" == default ]] ||
    { fail 'non-default Docker context is unsupported'; return 1; }
  [[ "$(docker info --format '{{.OSType}}' 2>/dev/null)" == linux ]] ||
    { fail 'Linux Docker engine unavailable'; return 1; }
  docker compose version >/dev/null 2>&1 ||
    { fail 'Docker Compose v2 unavailable'; return 1; }
}

## @fn reject_ambient_cloud_credentials()
## @brief Refuses any inherited AWS settings before container provisioning.
## @details
## No host credentials are referenced in compose.yml; the guard adds a
## defense against accidental invocation in a cloud-authorized shell.
reject_ambient_cloud_credentials() {
  local key
  while IFS= read -r key; do
    case "$key" in
      AWS_*|GPG_SYMMETRIC_KEY)
        fail 'remove cloud credentials/settings from host environment first'
        return 1
        ;;
    esac
  done < <(compgen -e)
}

## @fn validate_topology()
## @brief Verifies resolved Compose configuration before any container starts.
## @details
## The manifest is fixed data; no operator-controlled image, endpoint,
## external network, bind-mounted secret, or host-port setting is allowed.
validate_topology() {
  local definition
  definition="$(compose config --format json)" ||
    { fail 'Compose configuration is invalid'; return 1; }
  # A short-lived Pebble profile makes a newly issued certificate appear
  # immediately due. The local contract needs exactly one 90-day profile.
  jq -e '
    (.pebble.profiles | keys == ["default"])
    and (.pebble.profiles.default.validityPeriod == 7776000)
    and (.pebble.domainBlocklist == ["blocked-domain.example","blocked.e2e.test"])
    and (.pebble.listenAddress == "0.0.0.0:14000")
    and (.pebble.managementListenAddress == "0.0.0.0:15000")
    and (.pebble.externalAccountBindingRequired == false)
  ' "$E2E_DIR/pebble-config.json" >/dev/null ||
    { fail 'unexpected local Pebble certificate profile'; return 1; }
  jq -e '
    (.networks.isolated.internal == true)
    and (.networks.isolated.driver == "bridge")
    and ([.services | keys[]] | sort == ["acme-gateway","pebble","route53-bridge","seaweedfs"])
    and ([.services[] | .platform] | all(. == "linux/amd64"))
    and (.services.pebble.environment.PEBBLE_VA_ALWAYS_VALID == "1")
    and (.services.pebble.command == ["-config","/opt/local-e2e-pebble.json","-strict"])
    and (.services["acme-gateway"].command == ["caddy","run","--config","/etc/caddy/Caddyfile","--adapter","caddyfile"])
    and (.services["route53-bridge"].networks.isolated.ipv4_address == "172.31.248.6")
    and ([.services[] | .image] |
       all(test("^[a-z0-9./:-]+@sha256:[0-9a-f]{64}$")))
    and ([.services[] | has("ports")] | all(. == false))
    and ([.services[] | (.network_mode // "")] |
       all(. != "host" and . != "none"))
    and ([.services[] | (.privileged // false)] | all(. == false))
    and (.services["acme-gateway"].cap_add == ["NET_BIND_SERVICE"])
    and (.services["acme-gateway"].cap_drop == ["ALL"])
    and (.services["acme-gateway"].read_only == true)
    and ([.services | to_entries[] | select(.key != "acme-gateway") | (.value.cap_add // [])] | all(length == 0))
    and ([.services[] | (.devices // [])] | all(length == 0))
    and ([.services[] | (.network_mode // "")] | all(. == ""))
    and ([.services[] | .networks | keys[]] | all(. == "isolated"))
  ' <<<"$definition" >/dev/null ||
    { fail 'unsafe or non-pinned Docker Compose topology'; return 1; }
}

## @fn validate_cached_images()
## @brief Requires all four immutable image references to be locally cached.
## @details
## No implicit pull is permitted when starting the offline test network.
validate_cached_images() {
  local image
  while IFS= read -r image; do
    [[ -n "$image" ]] || continue
    docker image inspect "$image" >/dev/null 2>&1 ||
      { fail 'missing pinned image; run fetch before up'; return 1; }
  done < <(compose config --images)
}

## @fn check_running_isolation()
## @brief Inspects actual Docker network/port/privilege state after startup.
check_running_isolation() {
  local service cid ports
  [[ "$(docker network inspect "$NETWORK" --format '{{.Internal}}' 2>/dev/null)" == true ]] ||
    { fail 'actual network is not internal'; return 1; }
  [[ "$(docker network inspect "$NETWORK" --format '{{.Driver}}' 2>/dev/null)" == bridge ]] ||
    { fail 'actual network is not a private bridge'; return 1; }
  for service in pebble seaweedfs acme-gateway route53-bridge; do
    cid="$(compose ps -q "$service")"
    [[ -n "$cid" && "$(docker inspect "$cid" --format '{{.State.Running}}')" == true ]] ||
      { fail 'required service is not running'; return 1; }
    ports="$(docker inspect "$cid" --format '{{json .NetworkSettings.Ports}}')"
    jq -e 'all(to_entries[]; .value == null)' <<<"$ports" >/dev/null ||
      { fail 'unexpected published host port'; return 1; }
    [[ "$(docker inspect "$cid" --format '{{.HostConfig.Privileged}}')" == false ]] ||
      { fail 'privileged container is forbidden'; return 1; }
  done
}

## @fn probe_services()
## @brief Checks real HTTP readiness on the Docker-private bridge with timeouts.
## @details
## The Pebble-only -k check is a diagnostic of its *self-signed local test
## server*, not an instruction to disable TLS validation in certbotbot.
## Real ACME trust, credentials, and S3 conditional semantics are not
## established by these probes.  Docker rootless parity is not claimed.
probe_services() {
  local attempt code response cid ca_file directory
  for ((attempt = 1; attempt <= 45; attempt++)); do
    if curl --noproxy '*' -4 -skf --connect-timeout 1 --max-time 2 \
      "https://$PEBBLE_IP:14000/dir" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  (( attempt <= 45 )) || { fail 'Pebble ACME directory readiness timed out'; return 1; }

  # The Route53 stub is not DNS infrastructure. Its synthetic zone listing
  # proves the local API is reachable; no TXT validation is claimed.
  for ((attempt = 1; attempt <= 45; attempt++)); do
    if response="$(curl --noproxy '*' -4 -fsS --connect-timeout 1 \
      --max-time 2 -H 'Authorization: AWS4-HMAC-SHA256 Credential=CBOTBOT_LOCAL_TEST_ACCESS_ONLY/20261102/us-east-1/route53/aws4_request, SignedHeaders=host, Signature=synthetic' \
      "http://$ROUTE53_IP:8056/2013-04-01/hostedzone" 2>/dev/null)" &&
      [[ "$response" == *'ListHostedZonesResponse'* ]]; then
      break
    fi
    sleep 1
  done
  (( attempt <= 45 )) ||
    { fail 'local Route53 API stub readiness timed out'; return 1; }

  for ((attempt = 1; attempt <= 45; attempt++)); do
    code="$(curl --noproxy '*' -4 -s -o /dev/null -w '%{http_code}' \
      --connect-timeout 1 --max-time 2 "http://$SEAWEED_IP:8333/" || true)"
    case "$code" in
      200|400|401|403|404) break ;;
    esac
    sleep 1
  done
  (( attempt <= 45 )) || { fail 'SeaweedFS S3 HTTP readiness timed out'; return 1; }

  # Read only the gateway's ephemeral public root cert, never its private key.
  cid="$(compose ps -q acme-gateway)"
  ca_file="$(umask 077; mktemp)" ||
    { fail 'temporary test-only CA trust unavailable'; return 1; }
  for ((attempt = 1; attempt <= 45; attempt++)); do
    if docker exec "$cid" cat /data/caddy/pki/authorities/local/root.crt >"$ca_file" 2>/dev/null &&
      directory="$(curl --noproxy '*' -4 -fsS --cacert "$ca_file"         --connect-timeout 1 --max-time 3         --resolve "$STAGING_HOST:443:$GATEWAY_IP"         "https://$STAGING_HOST/directory" 2>/dev/null)" &&
      jq -e --arg prefix "https://$STAGING_HOST/" '
        (.newNonce | type == "string" and startswith($prefix))
        and (.newAccount | type == "string" and startswith($prefix))
        and (.newOrder | type == "string" and startswith($prefix))
      ' <<<"$directory" >/dev/null 2>&1; then
      rm -f -- "$ca_file"
      return 0
    fi
    sleep 1
  done
  # This is still pre-registration: no ACME account, certificate archive,
  # provider session, or real cloud credentials exist. Report a final bounded
  # TLS/HTTP error so a gateway failure cannot be mistaken for an ACME failure.
  if [[ -s "$ca_file" ]]; then
    report_error 'canonical staging TLS/HTTP probe diagnostic follows'
    curl --noproxy '*' -4 -fsS --cacert "$ca_file" \
      --connect-timeout 1 --max-time 3 \
      --resolve "$STAGING_HOST:443:$GATEWAY_IP" \
      "https://$STAGING_HOST/directory" \
      --output /dev/null >/dev/null || true
  else
    report_error 'canonical gateway public root did not materialize'
    # Public root only, before ACME account registration.  Show the actual
    # Exact public-only read error and file metadata, never key material.
    report_error 'retrying public-only root read with stderr visible'
    docker exec "$cid" cat /data/caddy/pki/authorities/local/root.crt >"$ca_file" \
      2>/dev/null || true
    report_error 'listing public-root file location inside isolated Caddy'
    docker exec "$cid" sh -c \
      'ls -ld /data /data/caddy /data/caddy/pki /data/caddy/pki/authorities/local; ls -l /data/caddy/pki/authorities/local/root.crt' \
      2>&1 || true
  fi
  rm -f -- "$ca_file"
  fail 'verified canonical staging gateway readiness timed out'
  return 1
}

## @fn teardown()
## @brief Deletes only containers, network, and anonymous volumes in this project.
teardown() {
  compose down --volumes --remove-orphans --timeout 10
}

## @fn main()
## @brief Selects explicit provisioning, startup, inspection, and cleanup modes.
main() {
  local action="${1-}"
  (( $# == 1 )) || { report_error 'usage: run.bash fetch|up|status|down'; return 64; }
  case "$action" in
    fetch|up|status|down) ;;
    *) report_error 'usage: run.bash fetch|up|status|down'; return 64 ;;
  esac
  require_tools || return 69
  if [[ "$action" == down ]]; then
    teardown
    return
  fi
  validate_topology || return 65
  if [[ "$action" == status ]]; then
    check_running_isolation
    return
  fi
  reject_ambient_cloud_credentials || return 65
  if [[ "$action" == fetch ]]; then
    # The only network-allowed operation; the upstream images are never built.
    compose pull
    validate_cached_images
    return
  fi

  validate_cached_images || return 69
  # Preserve project-scoped cleanup even when startup is interrupted.
  trap 'teardown >/dev/null 2>&1 || true; exit 129' HUP
  trap 'teardown >/dev/null 2>&1 || true; exit 130' INT
  trap 'teardown >/dev/null 2>&1 || true; exit 143' TERM
  if ! compose up --no-build --pull never --detach; then
    teardown >/dev/null 2>&1 || true
    report_error 'container startup failed; private resources removed'
    return 74
  fi
  if ! check_running_isolation || ! probe_services; then
    # Only owned service startup logs, bounded to pre-ACME-registration time.
    # Do not use this diagnostic in positive or negative credentialed phases.
    local service service_id
    for service in acme-gateway pebble; do
      service_id="$(compose ps -a -q "$service" 2>/dev/null || true)"
      [[ -n "$service_id" ]] || continue
      report_error "pre-registration $service startup diagnostic"
      docker logs --tail 14 "$service_id" 2>&1 || true
    done
    teardown >/dev/null 2>&1 || true
    report_error 'readiness/isolation failed; private resources removed'
    return 74
  fi
  trap - HUP INT TERM
  printf '%s\n' 'local-e2e: isolated services responding; no ACME/S3 lifecycle proven'
}

main "$@"
