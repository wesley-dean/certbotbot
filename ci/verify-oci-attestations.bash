#!/usr/bin/env bash
# shellcheck shell=bash
## @file ci/verify-oci-attestations.bash
## @brief Verify public OCI manifest platforms and SBOM/provenance binding.
## @details
## This credential-free check inspects the manifests that both registries
## actually serve at one already verified immutable digest.  It requires
## exactly one supported linux/amd64 runnable manifest and a BuildKit
## attestation manifest referring to that manifest's digest.  Attestation
## layers must identify both SPDX SBOM and SLSA provenance predicates.
##
## This is structural publication evidence, not a cryptographic signature,
## independent trust assertion, or full validation of in-toto payloads.
## Signed release and ordinary producer attestation checks remain upstream.
## Never claim image signing merely from BuildKit's OCI attestations.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## A nonsecret result for each registry.
## @par STDERR
## Nonsecret diagnostic identifying a violated publication requirement.
## @retval 0 Both registry copies meet the indexed attestation contract.
## @retval 1 Required identity, platform, or attestation evidence is missing.
## @retval 64 The caller supplied invalid inputs.
## @retval 69 Required inspection tooling is unavailable.

set -euo pipefail

## @fn oci_attestation_fail()
## @brief Fail closed with a nonsecret manifest verification diagnostic.
## @param message Description of the failed contract.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## The failed assertion.
## @retval 1 The verification has failed.
oci_attestation_fail() {
  printf 'OCI attestation verification: %s\n' "$1" >&2
  exit 1
}

if (( $# != 4 )); then
  printf 'usage: %s IMAGE_DIGEST SOURCE_SHA VERSION REPORT_DIR\n' "$0" >&2
  exit 64
fi
digest=$1
source_sha=$2
version=$3
report_dir=$4

[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ &&
  "$source_sha" =~ ^[0-9a-f]{40}$ &&
  "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 64
[[ -n "$report_dir" && ! -e "$report_dir" && ! -L "$report_dir" ]] || exit 64
for command in docker jq mkdir; do
  command -v "$command" >/dev/null || exit 69
done
mkdir -m 0700 -- "$report_dir" || exit 1

for registry in ghcr.io/wesley-dean/certbotbot \
  docker.io/wesleydean/certbotbot; do
  reference="$registry@$digest"
  index="$(docker buildx imagetools inspect --raw "$reference" 2>/dev/null)" ||
    oci_attestation_fail "image index unavailable: $reference"

  # Only the tested linux/amd64 image may be runnable.  BuildKit's
  # unknown/unknown attestation descriptors are not runnable platforms.
  jq -e '
    .schemaVersion == 2 and
    .mediaType == "application/vnd.oci.image.index.v1+json" and
    ([.manifests[] | select(.platform.os=="linux" and
      .platform.architecture=="amd64")] | length) == 1 and
    ([.manifests[] | select(
      (.platform.os=="linux" and .platform.architecture=="amd64") or
      (.platform.os=="unknown" and .platform.architecture=="unknown")
    )] | length) == (.manifests | length)
  ' <<< "$index" >/dev/null ||
    oci_attestation_fail "unexpected runnable platform set: $reference"

  image_digest="$(jq -r '.manifests[] |
    select(.platform.os=="linux" and .platform.architecture=="amd64") |
    .digest' <<< "$index")"
  [[ "$image_digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    oci_attestation_fail "missing runnable manifest digest: $reference"

  attestation_digest="$(jq -r --arg subject "$image_digest" '
    .manifests[] |
    select(.annotations["vnd.docker.reference.type"]=="attestation-manifest"
      and .annotations["vnd.docker.reference.digest"]==$subject
      and .platform.os=="unknown"
      and .platform.architecture=="unknown") |
    .digest
  ' <<< "$index")"
  [[ "$attestation_digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    oci_attestation_fail "missing image-bound attestation descriptor: $reference"

  attestation="$(docker buildx imagetools inspect --raw \
    "$registry@$attestation_digest" 2>/dev/null)" ||
    oci_attestation_fail "image-bound attestation manifest unavailable: $reference"
  jq -e '
    .schemaVersion == 2 and
    .mediaType == "application/vnd.oci.image.manifest.v1+json" and
    any(.layers[]; .mediaType=="application/vnd.in-toto+json" and
      .annotations["in-toto.io/predicate-type"]=="https://spdx.dev/Document")
  ' <<< "$attestation" >/dev/null ||
    oci_attestation_fail "missing SPDX SBOM attestation: $reference"
  jq -e '
    any(.layers[]; .mediaType=="application/vnd.in-toto+json" and
      (.annotations["in-toto.io/predicate-type"] |
        startswith("https://slsa.dev/provenance/v")))
  ' <<< "$attestation" >/dev/null ||
    oci_attestation_fail "missing SLSA provenance attestation: $reference"

  report="$report_dir/$(case "$registry" in ghcr.io/*) printf ghcr;; *) printf dockerhub;; esac).json"
  jq -n --arg registry "$registry" --arg digest "$digest" \
    --arg source_sha "$source_sha" --arg version "$version" \
    --arg image_manifest "$image_digest" \
    --arg attestation_manifest "$attestation_digest" \
    '{
      registry: $registry,
      index_digest: $digest,
      source_sha: $source_sha,
      version: $version,
      runtime_platform: "linux/amd64",
      image_manifest: $image_manifest,
      attestation_manifest: $attestation_manifest,
      sbom_predicate: "https://spdx.dev/Document",
      provenance_predicate_present: true,
      evidence: "OCI descriptor and predicate annotations; not a signature"
    }' > "$report"
  printf 'OCI attestation verification: accepted %s\n' "$reference"
done
