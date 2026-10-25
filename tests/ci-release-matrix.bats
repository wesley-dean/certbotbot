#!/usr/bin/env bats

setup() {
  RELEASE_WORKFLOW="$BATS_TEST_DIRNAME/../.github/workflows/semver.yml"
  TEST_ROOT="$(mktemp -d)"
}

teardown() {
  rm -rf -- "$TEST_ROOT"
}

# Exercise the actual GitHub Actions gate body with injected workflow outcomes.
# This is a local shell test and never invokes the GitHub release API.
extract_release_gate() {
  local step=$1
  awk -v step="$step" '
    $0 == "      - name: " step { found = 1; next }
    found && $0 == "        run: |" { in_script = 1; next }
    in_script && substr($0, 1, 10) == "          " {
      print substr($0, 11)
      next
    }
    in_script { exit }
  ' "$RELEASE_WORKFLOW" > "$TEST_ROOT/gate.bash"
  [ -s "$TEST_ROOT/gate.bash" ]
  bash -n "$TEST_ROOT/gate.bash"
}

@test "release workflow schedules complete Bats and Bash 4.3 suites per producer flavor" {
  [ "$(grep -Fc 'flavor: [development, ordinary, minified]' "$RELEASE_WORKFLOW")" -eq 2 ]
  [ "$(grep -Fc 'fail-fast: false' "$RELEASE_WORKFLOW")" -eq 2 ]
  [ "$(grep -Fc 'make test-one "TEST_FLAVOR=$TEST_FLAVOR"' "$RELEASE_WORKFLOW")" -eq 1 ]
  grep -Fq 'bash tests/compat-bash43.bash' "$RELEASE_WORKFLOW"
  grep -Fq 'bash:4.3' "$RELEASE_WORKFLOW"
  [ "$(grep -Fc 'bash ci/producer-handoff.bash verify dist' "$RELEASE_WORKFLOW")" -eq 3 ]
  ! grep -Fq 'make test VERSION=' "$RELEASE_WORKFLOW"
}

@test "release candidate is calculated once without tagging and built once" {
  grep -Fq 'bitshifted/git-auto-semver@c4e8f005e839f822325356f141939cf6c76b5701' "$RELEASE_WORKFLOW"
  [ "$(grep -Fc 'create_tag: false' "$RELEASE_WORKFLOW")" -eq 1 ]
  [ "$(grep -Fc 'make build "VERSION=$RELEASE_VERSION"' "$RELEASE_WORKFLOW")" -eq 1 ]
  [ "$(grep -Fc 'bash ci/producer-handoff.bash create dist' "$RELEASE_WORKFLOW")" -eq 1 ]
  grep -Fq 'manifest_sha: ${{ steps.handoff.outputs.manifest_sha }}' "$RELEASE_WORKFLOW"
}

@test "all consumers use same-run one-day handoff and externally bound manifest digest" {
  [ "$(grep -Fc 'name: release-producer-${{ github.run_id }}-${{ github.run_attempt }}' "$RELEASE_WORKFLOW")" -eq 4 ]
  [ "$(grep -Fc 'EXPECTED_MANIFEST_SHA: ${{ needs.prepare.outputs.manifest_sha }}' "$RELEASE_WORKFLOW")" -eq 3 ]
  [ "$(grep -Fc '"$RELEASE_VERSION" "$EXPECTED_MANIFEST_SHA"' "$RELEASE_WORKFLOW")" -eq 3 ]
  [ "$(grep -Fc 'retention-days: 1' "$RELEASE_WORKFLOW")" -eq 1 ]
  ! grep -Eq 'make (all|deps|build) "TEST_FLAVOR=' "$RELEASE_WORKFLOW"
}

@test "release test and publisher jobs do not rebuild different executable bytes" {
  sed -n '/^  release-bats:/,/^  gate:/p' "$RELEASE_WORKFLOW" > "$TEST_ROOT/matrices"
  ! grep -Eq 'make (all|deps|build)( |$)' "$TEST_ROOT/matrices"
  grep -Fq 'make test-one' "$TEST_ROOT/matrices"
  sed -n '/^  publish:/,/^  versioning:/p' "$RELEASE_WORKFLOW" > "$TEST_ROOT/publisher"
  ! grep -Eq 'make (all|deps|build)( |$)' "$TEST_ROOT/publisher"
  grep -Fq "if: github.ref == 'refs/heads/main' && needs.gate.result == 'success'" "$TEST_ROOT/publisher"
  grep -Fq 'subject-path: |' "$TEST_ROOT/publisher"
  grep -Fq 'dist/*.bash.sha256' "$TEST_ROOT/publisher"
  grep -Fq 'target_commitish: "${{ github.sha }}"' "$TEST_ROOT/publisher"
}

@test "only the final publisher has release write, OIDC and attestation authority" {
  [ "$(grep -Fc 'contents: write' "$RELEASE_WORKFLOW")" -eq 1 ]
  [ "$(grep -Fc 'id-token: write' "$RELEASE_WORKFLOW")" -eq 1 ]
  [ "$(grep -Fc 'attestations: write' "$RELEASE_WORKFLOW")" -eq 1 ]
  [ "$(grep -Fc 'artifact-metadata: write' "$RELEASE_WORKFLOW")" -eq 1 ]
  grep -Fq 'name: versioning' "$RELEASE_WORKFLOW"
  grep -Fq 'needs: [version, prepare, release-bats, release-bash43, gate, publish]' "$RELEASE_WORKFLOW"
}

@test "prepublication gate refuses any failed skipped cancelled or absent matrix result" {
  extract_release_gate "Reject any incomplete release gate"
  run env VERSION_RESULT=success PREPARE_RESULT=success BATS_RESULT=success BASH43_RESULT=success bash "$TEST_ROOT/gate.bash"
  [ "$status" -eq 0 ]
  local variable outcome
  for variable in VERSION_RESULT PREPARE_RESULT BATS_RESULT BASH43_RESULT; do
    for outcome in failure skipped cancelled ''; do
      run env VERSION_RESULT=success PREPARE_RESULT=success BATS_RESULT=success BASH43_RESULT=success "$variable=$outcome" bash "$TEST_ROOT/gate.bash"
      [ "$status" -ne 0 ]
    done
  done
}

@test "final versioning check refuses unverified or incomplete publication" {
  extract_release_gate "Require fully published and verified release"
  run env VERSION_RESULT=success PREPARE_RESULT=success BATS_RESULT=success BASH43_RESULT=success GATE_RESULT=success PUBLISH_RESULT=success bash "$TEST_ROOT/gate.bash"
  [ "$status" -eq 0 ]
  local variable outcome
  for variable in VERSION_RESULT PREPARE_RESULT BATS_RESULT BASH43_RESULT GATE_RESULT PUBLISH_RESULT; do
    for outcome in failure skipped cancelled ''; do
      run env VERSION_RESULT=success PREPARE_RESULT=success BATS_RESULT=success BASH43_RESULT=success GATE_RESULT=success PUBLISH_RESULT=success "$variable=$outcome" bash "$TEST_ROOT/gate.bash"
      [ "$status" -ne 0 ]
    done
  done
}

@test "release inventory remains three producer variants and excludes unimplemented client" {
  grep -Fq 'test ! -e dist/certbotbot-client.bash' "$RELEASE_WORKFLOW"
  grep -Fq 'dist/certbotbot.dev.bash dist/certbotbot.bash dist/certbotbot.min.bash' "$RELEASE_WORKFLOW"
  grep -Fq 'dist/*.bash.sha256' "$RELEASE_WORKFLOW"
  grep -Fq 'bash ci/producer-handoff.bash create dist' "$RELEASE_WORKFLOW"
}
