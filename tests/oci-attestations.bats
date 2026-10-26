#!/usr/bin/env bats

setup() {
  ROOT="$(mktemp -d)"
  mkdir -p "$ROOT/bin"
  export PATH="$ROOT/bin:$PATH"
  export DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export SUBJECT=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  export ATTEST=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  export SOURCE_SHA=0123456789abcdef0123456789abcdef01234567
  export VERSION=0.25.1
  export BAD_PLATFORM=false
  export BAD_BINDING=false
  export NO_SBOM=false
  export NO_PROVENANCE=false
  export NO_ATTESTATION=false
  export VERIFY="$BATS_TEST_DIRNAME/../ci/verify-oci-attestations.bash"
  cat > "$ROOT/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == buildx && "$2" == imagetools &&
  "$3" == inspect && "$4" == --raw ]] || exit 69
reference=$5
if [[ "$reference" == *"@$ATTEST" ]]; then
  jq -n --argjson no_sbom "$NO_SBOM" \
    --argjson no_provenance "$NO_PROVENANCE" '
    {
      schemaVersion: 2,
      mediaType: "application/vnd.oci.image.manifest.v1+json",
      layers: (
        (if $no_sbom then [] else [{
          mediaType: "application/vnd.in-toto+json",
          annotations: {"in-toto.io/predicate-type": "https://spdx.dev/Document"}
        }] end) +
        (if $no_provenance then [] else [{
          mediaType: "application/vnd.in-toto+json",
          annotations: {"in-toto.io/predicate-type": "https://slsa.dev/provenance/v0.2"}
        }] end)
      )
    }'
else
  jq -n --arg subject "$SUBJECT" --arg attest "$ATTEST" \
    --argjson bad_platform "$BAD_PLATFORM" \
    --argjson bad_binding "$BAD_BINDING" \
    --argjson no_attestation "$NO_ATTESTATION" '
    {
      schemaVersion: 2,
      mediaType: "application/vnd.oci.image.index.v1+json",
      manifests:
        ([{
          digest: $subject,
          platform: {
            os: "linux",
            architecture: (if $bad_platform then "arm64" else "amd64" end)
          }
        }] +
        (if $no_attestation then [] else [{
          digest: $attest,
          platform: {os: "unknown", architecture: "unknown"},
          annotations: {
            "vnd.docker.reference.type": "attestation-manifest",
            "vnd.docker.reference.digest":
              (if $bad_binding then "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
               else $subject end)
          }
        }] end))
    }'
fi
DOCKER
  chmod +x "$ROOT/bin/docker"
}

teardown() {
  rm -rf -- "$ROOT"
}

@test "both registries expose one amd64 manifest and bound SBOM/provenance" {
  run bash "$VERIFY" "$DIGEST" "$SOURCE_SHA" "$VERSION" "$ROOT/evidence"
  [ "$status" -eq 0 ]
  [[ "$output" == *"accepted ghcr.io/"* ]]
  [[ "$output" == *"accepted docker.io/"* ]]
  [ -s "$ROOT/evidence/ghcr.json" ]
  [ -s "$ROOT/evidence/dockerhub.json" ]
  jq -e --arg digest "$DIGEST" \
    '.index_digest == $digest and .provenance_predicate_present == true' \
    "$ROOT/evidence/dockerhub.json"
}

@test "reject unsupported runnable platform" {
  export BAD_PLATFORM=true
  run bash "$VERIFY" "$DIGEST" "$SOURCE_SHA" "$VERSION" "$ROOT/evidence"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected runnable platform"* ]]
}

@test "reject unattached or wrongly bound attestation manifest" {
  export BAD_BINDING=true
  run bash "$VERIFY" "$DIGEST" "$SOURCE_SHA" "$VERSION" "$ROOT/evidence"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing image-bound attestation"* ]]
}

@test "reject no attestation descriptor" {
  export NO_ATTESTATION=true
  run bash "$VERIFY" "$DIGEST" "$SOURCE_SHA" "$VERSION" "$ROOT/evidence"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing image-bound attestation"* ]]
}

@test "reject missing SBOM attestation" {
  export NO_SBOM=true
  run bash "$VERIFY" "$DIGEST" "$SOURCE_SHA" "$VERSION" "$ROOT/evidence"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing SPDX SBOM"* ]]
}

@test "reject missing provenance attestation" {
  export NO_PROVENANCE=true
  run bash "$VERIFY" "$DIGEST" "$SOURCE_SHA" "$VERSION" "$ROOT/evidence"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing SLSA provenance"* ]]
}

@test "reject invalid source and digest before consulting registries" {
  run bash "$VERIFY" invalid "$SOURCE_SHA" "$VERSION" "$ROOT/evidence"
  [ "$status" -ne 0 ]
  [ ! -e "$ROOT/evidence" ]
}

@test "publication and pulled verification jobs remain independent" {
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/publish-image.yml"
  grep -Fq 'verify_pulled:' "$workflow"
  grep -Fq 'needs: [verify, publish]' "$workflow"
  grep -Fq 'bash ci/verify-oci-attestations.bash' "$workflow"
  grep -Fq 'bash tests/oci-runtime.bash podman' "$workflow"
  grep -Fq 'bash tests/oci-runtime.bash docker' "$workflow"
  grep -Fq 'retention-days: 1' "$workflow"
}
