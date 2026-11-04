#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "$BATS_TEST_DIRNAME/.." && pwd -P)"
  PARSER="$REPO_ROOT/tests/e2e-local/negative-timing.bash"
  HOST="$REPO_ROOT/tests/e2e-local/first-issue-host.bash"
  CI="$REPO_ROOT/tests/e2e-local/ci-local-e2e.bash"
  TEST_SCRATCH="$(mktemp -d)" || return 1
  TIMING_LOG="$TEST_SCRATCH/negative.log"
}

teardown() {
  rm -rf -- "$TEST_SCRATCH"
}

report_timing() {
  run bash -c '
    source "$1"
    negative_timing_report "$2" "$3"
  ' _ "$PARSER" "$TIMING_LOG" "$1"
}

@test "bounded serial timing parser works under Bash without Docker" {
  run bash -n "$PARSER"
  [ "$status" -eq 0 ]
  printf '%s\n' \
    'local-first-issue-host: negative_timing=ca-production; elapsed_seconds=09; status=pass' \
    >"$TIMING_LOG"
  report_timing ca-production
  [ "$status" -eq 0 ]
  [ "$output" = 'local-e2e-ci: timing_negative=ca-production; elapsed_seconds=9; status=pass' ]
}

@test "all seven approved names produce only their bounded nonsecret timing" {
  local scenario
  for scenario in \
    ca-production s3-unavailable corrupt-archive acme-order-rejected \
    route53-unavailable s3-put-reject acme-unavailable; do
    printf 'local-first-issue-host: negative_timing=%s; elapsed_seconds=2100; status=pass\n' \
      "$scenario" >"$TIMING_LOG"
    report_timing "$scenario"
    [ "$status" -eq 0 ]
    [ "$output" = "local-e2e-ci: timing_negative=$scenario; elapsed_seconds=2100; status=pass" ]
  done
}

@test "missing and duplicate negative timing evidence fails closed" {
  : >"$TIMING_LOG"
  report_timing ca-production
  [ "$status" -eq 65 ]
  [[ "$output" != *"$TIMING_LOG"* ]]

  printf '%s\n' \
    'local-first-issue-host: negative_timing=ca-production; elapsed_seconds=12; status=pass' \
    'local-first-issue-host: negative_timing=ca-production; elapsed_seconds=13; status=pass' \
    >"$TIMING_LOG"
  report_timing ca-production
  [ "$status" -eq 65 ]
  [[ "$output" != *elapsed_seconds* ]]
}

@test "malformed, failed, oversized, and secret-bearing timing lines are refused" {
  local line
  for line in \
    'local-first-issue-host: negative_timing=ca-production; elapsed_seconds=2101; status=pass' \
    'local-first-issue-host: negative_timing=ca-production; elapsed_seconds=10000; status=pass' \
    'local-first-issue-host: negative_timing=ca-production; elapsed_seconds=-1; status=pass' \
    'local-first-issue-host: negative_timing=ca-production; elapsed_seconds=4; status=fail' \
    'local-first-issue-host: negative_timing=ca-production; elapsed_seconds=4; status=pass; secret=SHOULD_NOT_APPEAR' \
    'local-first-issue-host: negative_timing=ca-production; elapsed_seconds=xyz; status=pass'; do
    printf '%s\n' "$line" >"$TIMING_LOG"
    report_timing ca-production
    [ "$status" -eq 65 ]
    [[ "$output" != *SHOULD_NOT_APPEAR* ]]
  done
}

@test "unlisted names and partial evidence cannot satisfy full timing receipt" {
  printf '%s\n' \
    'local-first-issue-host: negative_timing=ca-production; elapsed_seconds=7; status=pass' \
    >"$TIMING_LOG"
  report_timing acme-unavailable
  [ "$status" -eq 65 ]
  report_timing unauthorized-case
  [ "$status" -eq 64 ]
  [[ "$output" != *"$TIMING_LOG"* ]]
}

@test "timing parser refuses symlink and missing private logs" {
  local other="$TEST_SCRATCH/real.log"
  printf '%s\n' \
    'local-first-issue-host: negative_timing=ca-production; elapsed_seconds=7; status=pass' \
    >"$other"
  ln -s -- "$other" "$TIMING_LOG"
  report_timing ca-production
  [ "$status" -eq 65 ]
  rm -- "$TIMING_LOG"
  report_timing ca-production
  [ "$status" -eq 65 ]
}

@test "default gate keeps serial acceptance and requires each timing receipt" {
  grep -Fq 'bash "$HOST" run-faults' "$CI"
  grep -Fq 'negative_timing_report "$logfile" "$scenario"' "$CI"
  grep -Fq 'all-negative-scenarios=passed; dns-validation=bypassed' "$CI"
  grep -Fq 'local-e2e-ci: negative_seven=passed' "$CI"
  grep -Fq 'full_protocol_gate=passed' "$CI"
  grep -Fq 'docker pause "$pebble_id"' "$HOST"
  grep -Fq 'docker unpause "$pebble_id"' "$HOST"
  grep -Fq 'local-first-issue-host: negative_timing=%s;' "$HOST"
  grep -Fq 'local-first-issue-host: negative_timing=acme-unavailable;' "$HOST"
}
