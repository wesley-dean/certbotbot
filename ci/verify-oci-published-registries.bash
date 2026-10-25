#!/usr/bin/env bash
# shellcheck shell=bash
## @file ci/verify-oci-published-registries.bash
## @brief Verify both published OCI images from their actual registries.
## @details
## This post-push check runs only after the signed, attested release and
## unprivileged OCI gate have passed, inside the protected publisher job.
## Verify the immutable image digest, all required mutable tag mappings,
## supported platform, source revision and embedded ordinary producer.
## Registry responses are external evidence: action outputs alone cannot
## establish dual-registry success.  Fail closed on any mismatch.
##
## Registries can propagate new manifests asynchronously.  Retry only
## unavailable manifest/pull reads a bounded number of times.  Never
## retry a manifest that reports the wrong digest or image identity.
## Untrusted registry error text is not logged, so credentials cannot
## accidentally appear through upstream diagnostic formatting.

set -euo pipefail

## @fn registry_fail()
## @brief Report a nonsecret publisher-verification failure.
## @param message Diagnostic describing the violated contract.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## The supplied failure message.
## @retval 1 The verification failed.
registry_fail() {
  printf 'OCI registry verification: %s\n' "$1" >&2
  exit 1
}

## @fn registry_read_manifest()
## @brief Read a registry manifest with bounded propagation retries.
## @details
## A successful response with an unexpected digest is a hard failure.
## Failed reads are retried five times at five-second intervals.
## The caller owns credentials; this helper never authenticates or logs
## raw registry error output.
## @param reference Full registry image reference by tag or digest.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nonsecret retry progress and terminal failure diagnostics.
## @retval 0 A verified response contains the expected digest.
## @retval 1 The digest mismatches or the manifest remains unavailable.
registry_read_manifest() {
  local reference="$1" result='' actual='' attempt=1 rc=0 reason=''
  for ((attempt = 1; attempt <= 5; attempt++)); do
    if result="$(docker buildx imagetools inspect "$reference" 2>&1)"; then
      actual="$(awk '$1 == "Digest:" {print $2; exit}' <<< "$result")"
      [[ "$actual" == "$DIGEST" ]] ||
        registry_fail "digest mismatch for $reference (expected $DIGEST; found \${actual:-none})"
      return 0
    else
      rc=$?
      reason=registry_or_client_error
      case "$result" in
        *unauthorized* | *Unauthorized* | *denied* | *forbidden* | *"401"* | *"403"*)
          reason=authentication_or_authorization
          ;;
        *"not found"* | *"404"* | *"manifest unknown"*)
          reason=manifest_not_yet_visible
          ;;
        *"429"* | *"rate limit"* | *"Too Many Requests"*)
          reason=rate_limited
          ;;
      esac
      printf 'OCI registry verification: manifest read %s attempt %d/5 failed (exit=%d, category=%s)\n' \
        "$reference" "$attempt" "$rc" "$reason" >&2
      if [[ "$reason" == authentication_or_authorization ]]; then
        registry_fail "registry denied $reference; check package visibility and pull permissions"
      fi
      if ((attempt < 5)); then
        sleep 5
      fi
    fi
  done
  registry_fail "manifest unavailable after five attempts: $reference"
}

## @fn registry_pull_image()
## @brief Pull the exact digest with bounded registry-read retries.
## @param reference Full immutable registry reference.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nonsecret retry messages.
## @retval 0 Docker fetched the image by digest.
## @retval 1 The image was not pullable after five attempts.
registry_pull_image() {
  local reference="$1" attempt=1 rc=0
  for ((attempt = 1; attempt <= 5; attempt++)); do
    if docker pull "$reference" >/dev/null 2>&1; then
      return 0
    else
      rc=$?
      printf 'OCI registry verification: pull %s attempt %d/5 failed (exit=%d)\n' \
        "$reference" "$attempt" "$rc" >&2
      if ((attempt < 5)); then
        sleep 5
      fi
    fi
  done
  registry_fail "image could not be pulled by immutable digest: $reference"
}

for required in DIGEST GHCR_REF DOCKERHUB_REF IMAGE_TAGS SOURCE_SHA \
  RELEASE_VERSION PRODUCER_SHA REPORTED_SOURCE REPORTED_REF; do
  [[ -n "\${!required:-}" ]] ||
    registry_fail "missing nonsecret publisher identity: $required"
done

[[ "$DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]] ||
  registry_fail 'invalid action image digest format'
[[ "$SOURCE_SHA" =~ ^[a-f0-9]{40}$ ]] ||
  registry_fail 'invalid source SHA format'
[[ "$PRODUCER_SHA" =~ ^[a-f0-9]{64}$ ]] ||
  registry_fail 'invalid producer SHA-256 format'
[[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  registry_fail 'invalid stable release version format'
[[ "$REPORTED_SOURCE" == "$SOURCE_SHA" ]] ||
  registry_fail 'reusable action reported a different source commit'
[[ "$REPORTED_REF" == "refs/tags/v$RELEASE_VERSION" ]] ||
  registry_fail 'reusable action reported a different release ref'
[[ "$GHCR_REF" == "ghcr.io/wesley-dean/certbotbot@$DIGEST" ]] ||
  registry_fail 'unexpected GHCR digest reference'
[[ "$DOCKERHUB_REF" == "docker.io/wesleydean/certbotbot@$DIGEST" ]] ||
  registry_fail 'unexpected Docker Hub digest reference'

for repository in ghcr.io/wesley-dean/certbotbot \
  docker.io/wesleydean/certbotbot; do
  for tag in "$RELEASE_VERSION" latest "sha-$SOURCE_SHA"; do
    reference="$repository:$tag"
    grep -Fxq -- "$reference" <<< "$IMAGE_TAGS" ||
      registry_fail "required published tag absent from action output: $reference"
    registry_read_manifest "$reference"
  done

  expected="$repository@$DIGEST"
  registry_read_manifest "$expected"
  registry_pull_image "$expected"

  platform="$(docker image inspect "$expected" \
    --format '{{.Os}}/{{.Architecture}}')" ||
    registry_fail "cannot inspect pulled image architecture: $expected"
  [[ "$platform" == linux/amd64 ]] ||
    registry_fail "unexpected pulled image architecture: $expected"

  actual_source="$(docker image inspect "$expected" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" ||
    registry_fail "cannot inspect source revision label: $expected"
  [[ "$actual_source" == "$SOURCE_SHA" ]] ||
    registry_fail "source revision label mismatch: $expected"

  actual_producer="$(docker image inspect "$expected" \
    --format '{{index .Config.Labels "io.certbotbot.producer.sha256"}}')" ||
    registry_fail "cannot inspect producer SHA label: $expected"
  [[ "$actual_producer" == "$PRODUCER_SHA" ]] ||
    registry_fail "producer digest label mismatch: $expected"
  printf 'OCI registry verification: accepted %s\n' "$expected"
done
