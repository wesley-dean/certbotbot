#!/usr/bin/env bats

setup() {
  HANDOFF_ROOT="$(mktemp -d)"
  mkdir -p "$HANDOFF_ROOT/dist"
  HANDOFF_SCRIPT="${BATS_TEST_DIRNAME}/../ci/producer-handoff.bash"
  SOURCE_SHA="$(git rev-parse HEAD)"
  BUILD_COMMIT="$(git rev-parse --short=12 HEAD)"
  BUILD_DATE="$(git show -s --format=%cI HEAD)"
  local name
  for name in certbotbot.dev.bash certbotbot.bash certbotbot.min.bash certbotbot-client.bash; do
    printf '#!/usr/bin/env bash\n# Version: 0.0.0-dev\n# Build commit: %s\n# Build date: %s\nexit 0\n' \
      "$BUILD_COMMIT" "$BUILD_DATE" > "$HANDOFF_ROOT/dist/$name"
    if [[ "$name" == certbotbot-client.bash ]]; then
      {
        printf 'BASH_STARTER_PROJECT_NAME=certbotbot-client\n'
        printf 'BASH_STARTER_VERSION=0.0.0-dev\n'
        printf 'BASH_STARTER_BUILD_COMMIT=%s\n' "$BUILD_COMMIT"
        printf 'BASH_STARTER_BUILD_DATE=%s\n' "$BUILD_DATE"
      } >> "$HANDOFF_ROOT/dist/$name"
    fi
    chmod 0755 "$HANDOFF_ROOT/dist/$name"
    (cd "$HANDOFF_ROOT/dist" && sha256sum "$name" > "$name.sha256")
  done
}

teardown() {
  rm -rf -- "$HANDOFF_ROOT"
}

create_handoff() {
  MANIFEST_SHA="$(bash "$HANDOFF_SCRIPT" create "$HANDOFF_ROOT/dist" "$SOURCE_SHA" 101 1 0.0.0-dev)"
}

@test "handoff create and verify bind exact source, version, run and attempt" {
  create_handoff
  run bash "$HANDOFF_SCRIPT" verify "$HANDOFF_ROOT/dist" "$SOURCE_SHA" 101 1 0.0.0-dev "$MANIFEST_SHA"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -Fqx "source_sha=$SOURCE_SHA" "$HANDOFF_ROOT/dist/producer-handoff.manifest"
  grep -Fqx 'file_count=8' "$HANDOFF_ROOT/dist/producer-handoff.manifest"
}

@test "handoff rejects different run and attempt even with a valid manifest SHA" {
  create_handoff
  run bash "$HANDOFF_SCRIPT" verify "$HANDOFF_ROOT/dist" "$SOURCE_SHA" 102 1 0.0.0-dev "$MANIFEST_SHA"
  [ "$status" -ne 0 ]
  run bash "$HANDOFF_SCRIPT" verify "$HANDOFF_ROOT/dist" "$SOURCE_SHA" 101 2 0.0.0-dev "$MANIFEST_SHA"
  [ "$status" -ne 0 ]
}

@test "handoff rejects a wrong expected manifest digest or modified manifest" {
  create_handoff
  run bash "$HANDOFF_SCRIPT" verify "$HANDOFF_ROOT/dist" "$SOURCE_SHA" 101 1 0.0.0-dev "$(printf '%064d' 0)"
  [ "$status" -ne 0 ]
  printf 'injected-field=bad\n' >> "$HANDOFF_ROOT/dist/producer-handoff.manifest"
  run bash "$HANDOFF_SCRIPT" verify "$HANDOFF_ROOT/dist" "$SOURCE_SHA" 101 1 0.0.0-dev "$MANIFEST_SHA"
  [ "$status" -ne 0 ]
}

@test "handoff rejects any altered executable or checksum companion" {
  create_handoff
  printf 'echo modified\n' >> "$HANDOFF_ROOT/dist/certbotbot.min.bash"
  run bash "$HANDOFF_SCRIPT" verify "$HANDOFF_ROOT/dist" "$SOURCE_SHA" 101 1 0.0.0-dev "$MANIFEST_SHA"
  [ "$status" -ne 0 ]
  (cd "$HANDOFF_ROOT/dist" && sha256sum certbotbot.min.bash > certbotbot.min.bash.sha256)
  run bash "$HANDOFF_SCRIPT" verify "$HANDOFF_ROOT/dist" "$SOURCE_SHA" 101 1 0.0.0-dev "$MANIFEST_SHA"
  [ "$status" -ne 0 ]
}

@test "handoff rejects extra and hidden files, including unsupported fourth variants" {
  create_handoff
  : > "$HANDOFF_ROOT/dist/.hidden"
  run bash "$HANDOFF_SCRIPT" verify "$HANDOFF_ROOT/dist" "$SOURCE_SHA" 101 1 0.0.0-dev "$MANIFEST_SHA"
  [ "$status" -ne 0 ]
  rm -f "$HANDOFF_ROOT/dist/.hidden"
   : > "$HANDOFF_ROOT/dist/certbotbot-client.dev.bash"
  run bash "$HANDOFF_SCRIPT" verify "$HANDOFF_ROOT/dist" "$SOURCE_SHA" 101 1 0.0.0-dev "$MANIFEST_SHA"
  [ "$status" -ne 0 ]
}

@test "handoff rejects absent, symlinked or nonexecutable product entries" {
  create_handoff
  rm "$HANDOFF_ROOT/dist/certbotbot.bash.sha256"
  run bash "$HANDOFF_SCRIPT" verify "$HANDOFF_ROOT/dist" "$SOURCE_SHA" 101 1 0.0.0-dev "$MANIFEST_SHA"
  [ "$status" -ne 0 ]
  (cd "$HANDOFF_ROOT/dist" && sha256sum certbotbot.bash > certbotbot.bash.sha256)
  chmod 0644 "$HANDOFF_ROOT/dist/certbotbot.bash"
  run bash "$HANDOFF_SCRIPT" verify "$HANDOFF_ROOT/dist" "$SOURCE_SHA" 101 1 0.0.0-dev "$MANIFEST_SHA"
  [ "$status" -ne 0 ]
  chmod 0755 "$HANDOFF_ROOT/dist/certbotbot.bash"
  rm "$HANDOFF_ROOT/dist/certbotbot.bash"
  ln -s certbotbot.dev.bash "$HANDOFF_ROOT/dist/certbotbot.bash"
  run bash "$HANDOFF_SCRIPT" verify "$HANDOFF_ROOT/dist" "$SOURCE_SHA" 101 1 0.0.0-dev "$MANIFEST_SHA"
  [ "$status" -ne 0 ]
}

@test "handoff creation fails on stale companions or forged build provenance" {
  : > "$HANDOFF_ROOT/dist/certbotbot.dev.bash.256"
  run bash "$HANDOFF_SCRIPT" create "$HANDOFF_ROOT/dist" "$SOURCE_SHA" 101 1 0.0.0-dev
  [ "$status" -ne 0 ]
  rm "$HANDOFF_ROOT/dist/certbotbot.dev.bash.256"
  sed -i 's/# Version: 0.0.0-dev/# Version: 999.0.0/' "$HANDOFF_ROOT/dist/certbotbot.dev.bash"
  (cd "$HANDOFF_ROOT/dist" && sha256sum certbotbot.dev.bash > certbotbot.dev.bash.sha256)
  run bash "$HANDOFF_SCRIPT" create "$HANDOFF_ROOT/dist" "$SOURCE_SHA" 101 1 0.0.0-dev
  [ "$status" -ne 0 ]
}

@test "handoff binds client executable bytes and identity independently of sidecar" {
  create_handoff
  printf 'echo tampered\n' >>"$HANDOFF_ROOT/dist/certbotbot-client.bash"
  (cd "$HANDOFF_ROOT/dist" && sha256sum certbotbot-client.bash >certbotbot-client.bash.sha256)
  run bash "$HANDOFF_SCRIPT" verify "$HANDOFF_ROOT/dist" "$SOURCE_SHA" 101 1 0.0.0-dev "$MANIFEST_SHA"
  [ "$status" -ne 0 ]
}

@test "handoff refuses a missing client or an incompatible client version" {
  rm "$HANDOFF_ROOT/dist/certbotbot-client.bash.sha256"
  run bash "$HANDOFF_SCRIPT" create "$HANDOFF_ROOT/dist" "$SOURCE_SHA" 101 1 0.0.0-dev
  [ "$status" -ne 0 ]
  (cd "$HANDOFF_ROOT/dist" && sha256sum certbotbot-client.bash >certbotbot-client.bash.sha256)
  sed -i 's/BASH_STARTER_VERSION=0.0.0-dev/BASH_STARTER_VERSION=9.9.9/' "$HANDOFF_ROOT/dist/certbotbot-client.bash"
  (cd "$HANDOFF_ROOT/dist" && sha256sum certbotbot-client.bash >certbotbot-client.bash.sha256)
  run bash "$HANDOFF_SCRIPT" create "$HANDOFF_ROOT/dist" "$SOURCE_SHA" 101 1 0.0.0-dev
  [ "$status" -ne 0 ]
}
