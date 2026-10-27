#!/usr/bin/env bats

setup() {
  TEST_ROOT="$(mktemp -d)"
  mkdir -p "$TEST_ROOT/dist" "$TEST_ROOT/tests" "$TEST_ROOT/bin"
  cp "$BATS_TEST_DIRNAME/../Makefile" "$TEST_ROOT/Makefile"
  printf '@test "fixture" { true; }\n' > "$TEST_ROOT/tests/fixture.bats"
  # This copied Makefile is tested in an intentionally minimal repository.
  # Keep the required milestone 4 inventory visible to its new guard without
  # copying private lifecycle fixtures or invoking the actual public issuer.
  printf '@test "mock public E2E" { true; }\n' \
    > "$TEST_ROOT/tests/milestone-4-public-e2e.bats"
  cat > "$TEST_ROOT/bin/bats" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
# The Make prerequisite queries the Bats inventory independently of the
# selected-flavor execution. Do not record this check as an artifact test.
if [[ "${1-}" == --count ]]; then
  printf '%s\n' "${MOCK_BATS_COUNT:-1}"
  exit 0
fi
printf '%s|%s\n' "$BASH_STARTER_ARTIFACT" "$*" >> "$MOCK_BATS_LOG"
if [[ "${1-}" == --formatter ]]; then
  printf '<testsuite name="mock" tests="1" failures="0"/>\n'
fi
exit "${MOCK_BATS_EXIT:-0}"
MOCK
  chmod 0755 "$TEST_ROOT/bin/bats"
  local name
  for name in certbotbot.dev.bash certbotbot.bash certbotbot.min.bash; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/dist/$name"
    chmod 0755 "$TEST_ROOT/dist/$name"
    if command -v sha256sum >/dev/null 2>&1; then
      (cd "$TEST_ROOT/dist" && sha256sum "$name" > "$name.sha256")
    else
      (cd "$TEST_ROOT/dist" && shasum -a 256 "$name" > "$name.sha256")
    fi
  done
}

teardown() {
  rm -rf -- "$TEST_ROOT"
}

@test "test-one selects exactly one verified producer flavor without rebuilding" {
  local row flavor artifact
  for row in 'development:certbotbot.dev.bash' 'ordinary:certbotbot.bash' 'minified:certbotbot.min.bash'; do
    flavor="${row%%:*}"
    artifact="${row#*:}"
    : > "$TEST_ROOT/log"
    run env PATH="$TEST_ROOT/bin:$PATH" MOCK_BATS_LOG="$TEST_ROOT/log" \
      make -s -C "$TEST_ROOT" test-one "TEST_FLAVOR=$flavor"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$TEST_ROOT/log")" -eq 1 ]
    grep -Fqx "$TEST_ROOT/dist/$artifact|tests/fixture.bats tests/milestone-4-public-e2e.bats" "$TEST_ROOT/log"
    [ ! -e "$TEST_ROOT/vendor" ]
    [ ! -e "$TEST_ROOT/test-results" ]
  done
}

@test "test-report-one selects the same complete suite and unique JUnit destinations" {
  local row flavor artifact
  for row in 'development:certbotbot.dev.bash' 'ordinary:certbotbot.bash' 'minified:certbotbot.min.bash'; do
    flavor="${row%%:*}"
    artifact="${row#*:}"
    : > "$TEST_ROOT/log"
    run env PATH="$TEST_ROOT/bin:$PATH" MOCK_BATS_LOG="$TEST_ROOT/log" \
      make -s -C "$TEST_ROOT" test-report-one "TEST_FLAVOR=$flavor"
    [ "$status" -eq 0 ]
    grep -Fqx "$TEST_ROOT/dist/$artifact|--formatter junit tests/fixture.bats tests/milestone-4-public-e2e.bats" "$TEST_ROOT/log"
    grep -Fq '<testsuite name="mock"' "$TEST_ROOT/test-results/bats-$flavor.xml"
  done
  [ "$(find "$TEST_ROOT/test-results" -name '*.xml' -type f | wc -l)" -eq 3 ]
}

@test "missing or malformed TEST_FLAVOR is rejected without invoking Bats" {
  local flavor
  for flavor in '' invalid client 'DEVELOPMENT' 'development;touch marker' '../../certbotbot.bash'; do
    : > "$TEST_ROOT/log"
    run env PATH="$TEST_ROOT/bin:$PATH" MOCK_BATS_LOG="$TEST_ROOT/log" \
      make -s -C "$TEST_ROOT" test-one "TEST_FLAVOR=$flavor"
    [ "$status" -ne 0 ]
    [ ! -s "$TEST_ROOT/log" ]
  done
  [ ! -e "$TEST_ROOT/marker" ]
}

@test "selected missing, nonexecutable or symlinked artifacts fail before Bats" {
  local artifact="$TEST_ROOT/dist/certbotbot.dev.bash"
  rm -- "$artifact"
  run env PATH="$TEST_ROOT/bin:$PATH" MOCK_BATS_LOG="$TEST_ROOT/log" \
    make -s -C "$TEST_ROOT" test-one TEST_FLAVOR=development
  [ "$status" -ne 0 ]
  printf '#!/usr/bin/env bash\nexit 0\n' > "$artifact"
  run env PATH="$TEST_ROOT/bin:$PATH" MOCK_BATS_LOG="$TEST_ROOT/log" \
    make -s -C "$TEST_ROOT" test-one TEST_FLAVOR=development
  [ "$status" -ne 0 ]
  rm -- "$artifact"
  ln -s certbotbot.bash "$artifact"
  run env PATH="$TEST_ROOT/bin:$PATH" MOCK_BATS_LOG="$TEST_ROOT/log" \
    make -s -C "$TEST_ROOT" test-one TEST_FLAVOR=development
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_ROOT/log" ]
}

@test "tampered bytes or altered checksum companions are rejected" {
  local artifact="$TEST_ROOT/dist/certbotbot.dev.bash"
  printf 'echo tampered\n' >> "$artifact"
  run env PATH="$TEST_ROOT/bin:$PATH" MOCK_BATS_LOG="$TEST_ROOT/log" \
    make -s -C "$TEST_ROOT" test-one TEST_FLAVOR=development
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_ROOT/log" ]
}

@test "wrong checksum filename and legacy companions fail closed" {
  local artifact="$TEST_ROOT/dist/certbotbot.dev.bash"
  sed 's/certbotbot.dev.bash$/certbotbot.bash/' "$artifact.sha256" > "$artifact.sha256.tmp"
  mv "$artifact.sha256.tmp" "$artifact.sha256"
  run env PATH="$TEST_ROOT/bin:$PATH" MOCK_BATS_LOG="$TEST_ROOT/log" \
    make -s -C "$TEST_ROOT" test-one TEST_FLAVOR=development
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_ROOT/log" ]
}

@test "stale .256 sidecars are rejected even when current checksum is valid" {
  : > "$TEST_ROOT/dist/certbotbot.dev.bash.256"
  run env PATH="$TEST_ROOT/bin:$PATH" MOCK_BATS_LOG="$TEST_ROOT/log" \
    make -s -C "$TEST_ROOT" test-one TEST_FLAVOR=development
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_ROOT/log" ]
}

@test "a Bats failure propagates for test-one" {
  run env PATH="$TEST_ROOT/bin:$PATH" MOCK_BATS_LOG="$TEST_ROOT/log" MOCK_BATS_EXIT=7 \
    make -s -C "$TEST_ROOT" test-one TEST_FLAVOR=development
  [ "$status" -ne 0 ]
  [ "$(wc -l < "$TEST_ROOT/log")" -eq 1 ]
}

@test "a Bats failure propagates for test-report-one while retaining failure output" {
  run env PATH="$TEST_ROOT/bin:$PATH" MOCK_BATS_LOG="$TEST_ROOT/log" MOCK_BATS_EXIT=7 \
    make -s -C "$TEST_ROOT" test-report-one TEST_FLAVOR=ordinary
  [ "$status" -ne 0 ]
  [ "$(wc -l < "$TEST_ROOT/log")" -eq 1 ]
  [ -s "$TEST_ROOT/test-results/bats-ordinary.xml" ]
  [ ! -e "$TEST_ROOT/test-results/bats-development.xml" ]
}

@test "missing or symlinked required public E2E suite fails before Bats" {
  local suite="$TEST_ROOT/tests/milestone-4-public-e2e.bats"
  rm -- "$suite"
  run env PATH="$TEST_ROOT/bin:$PATH" MOCK_BATS_LOG="$TEST_ROOT/log" \
    make -s -C "$TEST_ROOT" test-one TEST_FLAVOR=development
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_ROOT/log" ]

  ln -s fixture.bats "$suite"
  run env PATH="$TEST_ROOT/bin:$PATH" MOCK_BATS_LOG="$TEST_ROOT/log" \
    make -s -C "$TEST_ROOT" test-one TEST_FLAVOR=development
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_ROOT/log" ]
}

@test "empty public E2E case inventory fails before running any artifact" {
  run env PATH="$TEST_ROOT/bin:$PATH" MOCK_BATS_LOG="$TEST_ROOT/log" \
    MOCK_BATS_COUNT=0 make -s -C "$TEST_ROOT" test-report-one TEST_FLAVOR=ordinary
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_ROOT/log" ]
  [ ! -e "$TEST_ROOT/test-results/bats-ordinary.xml" ]
}

@test "empty Bats test inventory fails without invoking Bats" {
  rm -- "$TEST_ROOT/tests/fixture.bats"
  rm -- "$TEST_ROOT/tests/milestone-4-public-e2e.bats"
  run env PATH="$TEST_ROOT/bin:$PATH" MOCK_BATS_LOG="$TEST_ROOT/log" \
    make -s -C "$TEST_ROOT" test-one TEST_FLAVOR=development
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_ROOT/log" ]
}
