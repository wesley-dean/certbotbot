#!/usr/bin/env bats

setup() {
  ROOT="$(mktemp -d)"
  mkdir -p "$ROOT/bin"
  export PATH="$ROOT/bin:$PATH"
  VERIFY="$BATS_TEST_DIRNAME/../ci/verify-oci-published-registries.bash"
  export DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export SOURCE_SHA=0123456789abcdef0123456789abcdef01234567
  export PRODUCER_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  export RELEASE_VERSION=0.25.0
  export REPORTED_SOURCE="$SOURCE_SHA"
  export REPORTED_REF=refs/tags/v0.25.0
  export GHCR_REF="ghcr.io/wesley-dean/certbotbot@$DIGEST"
  export DOCKERHUB_REF="docker.io/wesleydean/certbotbot@$DIGEST"
  export IMAGE_TAGS="$(printf '%s\n' \
    "ghcr.io/wesley-dean/certbotbot:$RELEASE_VERSION" \
    "ghcr.io/wesley-dean/certbotbot:latest" \
    "ghcr.io/wesley-dean/certbotbot:sha-$SOURCE_SHA" \
    "docker.io/wesleydean/certbotbot:$RELEASE_VERSION" \
    "docker.io/wesleydean/certbotbot:latest" \
    "docker.io/wesleydean/certbotbot:sha-$SOURCE_SHA")"
  export MOCK_MANIFEST_STATE="$ROOT/manifest-calls"
  export MOCK_PULL_STATE="$ROOT/pull-calls"
  export MOCK_OUTAGE=none
  export MOCK_PULL_OUTAGE=none
  export MOCK_WRONG_DIGEST=false
  export MOCK_WRONG_LABEL=false
  printf '0\n' > "$MOCK_MANIFEST_STATE"
  printf '0\n' > "$MOCK_PULL_STATE"

  cat > "$ROOT/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == buildx && "$2" == imagetools && "$3" == inspect ]]; then
  n="$(cat "$MOCK_MANIFEST_STATE")"
  printf '%s\n' "$((n + 1))" > "$MOCK_MANIFEST_STATE"
  if [[ "$MOCK_OUTAGE" == always ]] ||
    { [[ "$MOCK_OUTAGE" == twice ]] && ((n < 2)); }; then
    printf 'registry manifest not yet visible\n' >&2
    exit 255
  fi
  if [[ "$MOCK_WRONG_DIGEST" == true ]]; then
    printf 'Name: %s\nDigest: sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\n' "$4"
  else
    printf 'Name: %s\nDigest: %s\n' "$4" "$DIGEST"
  fi
elif [[ "$1" == pull ]]; then
  n="$(cat "$MOCK_PULL_STATE")"
  printf '%s\n' "$((n + 1))" > "$MOCK_PULL_STATE"
  if [[ "$MOCK_PULL_OUTAGE" == always ]] ||
    { [[ "$MOCK_PULL_OUTAGE" == twice ]] && ((n < 2)); }; then
    exit 255
  fi
elif [[ "$1" == image && "$2" == inspect ]]; then
  case "$5" in
    '{{.Os}}/{{.Architecture}}') printf '%s\n' linux/amd64 ;;
    '{{index .Config.Labels "org.opencontainers.image.revision"}}')
      if [[ "$MOCK_WRONG_LABEL" == true ]]; then printf '%s\n' "wrong"; else printf '%s\n' "$SOURCE_SHA"; fi ;;
    '{{index .Config.Labels "io.certbotbot.producer.sha256"}}')
      printf '%s\n' "$PRODUCER_SHA" ;;
    *) exit 65 ;;
  esac
else
  exit 65
fi
DOCKER
  cat > "$ROOT/bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
exit 0
SLEEP
  chmod +x "$ROOT/bin/docker" "$ROOT/bin/sleep"
}

teardown() {
  rm -rf -- "$ROOT"
}

@test "identical digests and image labels pass for both registries" {
  run bash "$VERIFY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"accepted ghcr.io/"* ]]
  [[ "$output" == *"accepted docker.io/"* ]]
  [ "$(cat "$MOCK_MANIFEST_STATE")" -eq 8 ]
  [ "$(cat "$MOCK_PULL_STATE")" -eq 2 ]
}

@test "not-yet-visible manifests recover with bounded retries" {
  export MOCK_OUTAGE=twice
  run bash "$VERIFY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"attempt 1/5 failed"* ]]
  [ "$(cat "$MOCK_MANIFEST_STATE")" -eq 10 ]
}

@test "persistent registry manifest outage fails after five attempts" {
  export MOCK_OUTAGE=always
  run bash "$VERIFY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest unavailable after five attempts"* ]]
  [ "$(cat "$MOCK_MANIFEST_STATE")" -eq 5 ]
}

@test "persistent registry pull outage fails after five attempts" {
  export MOCK_PULL_OUTAGE=always
  run bash "$VERIFY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not be pulled by immutable digest"* ]]
  [ "$(cat "$MOCK_PULL_STATE")" -eq 5 ]
}

@test "actual manifest digest mismatch fails closed without retries" {
  export MOCK_WRONG_DIGEST=true
  run bash "$VERIFY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"digest mismatch"* ]]
  [ "$(cat "$MOCK_MANIFEST_STATE")" -eq 1 ]
}

@test "unexpected pulled image labels remain a failure" {
  export MOCK_WRONG_LABEL=true
  run bash "$VERIFY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"source revision label mismatch"* ]]
}

@test "missing required tag fails closed" {
  IMAGE_TAGS="$(printf '%s\n' "$IMAGE_TAGS" | grep -v 'docker.io/wesleydean/certbotbot:latest')"
  export IMAGE_TAGS
  run bash "$VERIFY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"required published tag absent"* ]]
}

@test "untrusted source identity does not access registries" {
  export REPORTED_SOURCE=ffffffffffffffffffffffffffffffffffffffff
  run bash "$VERIFY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"different source commit"* ]]
  [ "$(cat "$MOCK_MANIFEST_STATE")" -eq 0 ]
}

@test "workflow invokes bounded verifier with both required registries" {
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/publish-image.yml"
  grep -Fq 'bash ci/verify-oci-published-registries.bash' "$workflow"
  grep -Fq 'required_registries: dockerhub,ghcr' "$workflow"
  ! grep -Fq 'CERTBOTBOT_IMAGE_PUBLISH_ENABLED' "$workflow"
}
