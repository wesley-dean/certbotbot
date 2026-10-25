#!/usr/bin/env bats

setup() {
  WORKFLOW="${BATS_TEST_DIRNAME}/../.github/workflows/test.yml"
  TEST_ROOT="$(mktemp -d)"
}

teardown() {
  rm -rf -- "$TEST_ROOT"
}

# Extract the actual aggregate-shell guard from the maintained Actions YAML.
# This permits failure injection without publishing test-only workflow inputs.
extract_suite_gate() {
  local step="$1"
  awk -v step="$step" '
    $0 == "      - name: " step { found = 1; next }
    found && $0 == "        run: |" { in_script = 1; next }
    in_script && substr($0, 1, 10) == "          " {
      print substr($0, 11)
      next
    }
    in_script { exit }
  ' "$WORKFLOW" > "$TEST_ROOT/gate.bash"
  [ -s "$TEST_ROOT/gate.bash" ]
  bash -n "$TEST_ROOT/gate.bash"
}

@test "Bats and both compatibility suites each schedule three producer variants" {
  [ "$(grep -Fc 'flavor: [development, ordinary, minified]' "$WORKFLOW")" -eq 3 ]
  [ "$(grep -Fc 'fail-fast: false' "$WORKFLOW")" -eq 3 ]
  grep -Fq '  bats:' "$WORKFLOW"
  grep -Fq '  bash43-flavor:' "$WORKFLOW"
  grep -Fq '  encryption-flavor:' "$WORKFLOW"
}

@test "legacy required-check names remain strict aggregate jobs" {
  [ "$(grep -Fc '    name: Check, build, and test' "$WORKFLOW")" -eq 1 ]
  [ "$(grep -Fc '    name: Bash 4.3 compatibility' "$WORKFLOW")" -eq 1 ]
  [ "$(grep -Fc '    name: Authenticated archive interoperability' "$WORKFLOW")" -eq 1 ]
  grep -Fq '    needs: [prepare, bats, bash43, encryption]' "$WORKFLOW"
  grep -Fq '    needs: [prepare, bash43-flavor]' "$WORKFLOW"
  grep -Fq '    needs: [prepare, encryption-flavor]' "$WORKFLOW"
}

@test "Bash 4.3 and encryption suites use the approved same-run verified handoff" {
  [ "$(grep -Fc 'name: producer-${{ github.run_id }}-${{ github.run_attempt }}' "$WORKFLOW")" -eq 4 ]
  [ "$(grep -Fc 'bash ci/producer-handoff.bash verify dist' "$WORKFLOW")" -eq 3 ]
  [ "$(grep -Fc '0.0.0-dev "$EXPECTED_MANIFEST_SHA"' "$WORKFLOW")" -eq 3 ]
  grep -Fq 'retention-days: 1' "$WORKFLOW"
}

@test "Bash 4.3 matrix selects exactly one executable and runs the existing acceptance" {
  sed -n '/^  bash43-flavor:/,/^  bash43:/p' "$WORKFLOW" > "$TEST_ROOT/selection"
  grep -Fq 'bash tests/compat-bash43.bash' "$TEST_ROOT/selection"
  grep -Fq 'bash:4.3' "$TEST_ROOT/selection"
  grep -Fq 'development) artifact=dist/certbotbot.dev.bash' "$TEST_ROOT/selection"
  grep -Fq 'ordinary) artifact=dist/certbotbot.bash' "$TEST_ROOT/selection"
  grep -Fq 'minified) artifact=dist/certbotbot.min.bash' "$TEST_ROOT/selection"
  ! grep -Eq 'make (all|build|deps)' "$TEST_ROOT/selection"
}

@test "encryption matrix preserves GnuPG version and non-skipped positive coverage" {
  sed -n '/^  encryption-flavor:/,/^  encryption:/p' "$WORKFLOW" > "$TEST_ROOT/crypto"
  grep -Fq 'runs-on: ubuntu-26.04' "$TEST_ROOT/crypto"
  grep -Fq 'dpkg --compare-versions "$gpg_version" ge 2.4.7' "$TEST_ROOT/crypto"
  grep -Fq -- '--formatter tap' "$TEST_ROOT/crypto"
  grep -Fq -- "--filter 'encryption|encrypted|ciphertext|migrat|decryption|GnuPG'" "$TEST_ROOT/crypto"
  grep -Fq 'tests/public-lifecycle.bats' "$TEST_ROOT/crypto"
  grep -Fq "grep -Eq '^ok [0-9]+ .*# skip'" "$TEST_ROOT/crypto"
  grep -Fq 'if (( count < 20 )); then' "$TEST_ROOT/crypto"
  ! grep -Eq 'make (all|build|deps)' "$TEST_ROOT/crypto"
}

@test "Bash 4.3 suite gate rejects failed skipped cancelled or missing flavors" {
  extract_suite_gate "Require all Bash 4.3 flavor checks"
  run env PREPARE_RESULT=success FLAVORS_RESULT=success bash "$TEST_ROOT/gate.bash"
  [ "$status" -eq 0 ]
  local failed
  for failed in failure skipped cancelled ''; do
    run env PREPARE_RESULT=success FLAVORS_RESULT="$failed" bash "$TEST_ROOT/gate.bash"
    [ "$status" -ne 0 ]
  done
  run env PREPARE_RESULT=skipped FLAVORS_RESULT=success bash "$TEST_ROOT/gate.bash"
  [ "$status" -ne 0 ]
}

@test "encryption suite gate rejects failed skipped cancelled or missing flavors" {
  extract_suite_gate "Require all authenticated encryption flavor checks"
  run env PREPARE_RESULT=success FLAVORS_RESULT=success bash "$TEST_ROOT/gate.bash"
  [ "$status" -eq 0 ]
  local failed
  for failed in failure skipped cancelled ''; do
    run env PREPARE_RESULT=success FLAVORS_RESULT="$failed" bash "$TEST_ROOT/gate.bash"
    [ "$status" -ne 0 ]
  done
  run env PREPARE_RESULT=failure FLAVORS_RESULT=success bash "$TEST_ROOT/gate.bash"
  [ "$status" -ne 0 ]
}
