#!/usr/bin/env bash
# shellcheck shell=bash
## @file tests/e2e-local/negative-timing.bash
## @brief Validates and prints bounded negative-case timing receipts.
## @details
## This test-only helper consumes private output from the existing serial
## Pebble/SeaweedFS fault runner. Each requested scenario must have exactly one
## complete pass receipt with a bounded integer elapsed time. Arbitrary host or
## provider output is never copied to CI, and absent, duplicate, malformed or
## implausible receipts fail closed. Timings are performance observations, not
## additional evidence of remote object integrity or permission to skip faults.
## This file is sourced by the host-side CI runner and never enters the producer,
## private Docker test image, or published OCI artifacts. See ADR-057.

## @fn negative_timing_report()
## @brief Prints one verified, nonsecret negative-scenario timing observation.
## @details
## The scenario is checked against the exact seven-case acceptance allowlist.
## The private host log must contain exactly one matching receipt. The 2100s cap
## is the existing global deadline for the full negative stage, not a new SLA.
## Rejects partial, reordered, duplicate, overlong or malformed receipts. This
## method does not establish that the scenario passed: callers must additionally
## verify the existing independent remote-object and whole-suite receipts.
## @param logfile Path to the existing private host negative-suite log.
## @param scenario One of the seven fixed local negative scenario names.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## One bounded, nonsecret elapsed-seconds receipt on success.
## @par STDERR
## A static diagnostic with no provider output or private paths on error.
## @retval 0 Exactly one bounded timing receipt was verified.
## @retval 64 A caller supplied a name outside the fixed allowlist.
## @retval 65 The private log or timing evidence is missing or invalid.
negative_timing_report() {
  local logfile="$1" scenario="$2" prefix='' line='' elapsed=''
  local -i found=0
  case "$scenario" in
    ca-production|s3-unavailable|corrupt-archive|acme-order-rejected|route53-unavailable|s3-put-reject|acme-unavailable) ;;
    *)
      printf '%s\n' 'local-e2e-ci: unapproved negative timing selector' >&2
      return 64
      ;;
  esac
  [[ -f "$logfile" && -r "$logfile" && ! -L "$logfile" ]] || {
    printf '%s\n' 'local-e2e-ci: private negative timing log unavailable' >&2
    return 65
  }
  prefix="local-first-issue-host: negative_timing=$scenario;"
  while IFS= read -r line; do
    [[ "$line" == "$prefix"* ]] || continue
    (( found+=1 ))
    if [[ "$line" =~ ^local-first-issue-host:\ negative_timing=[a-z0-9-]+\;\ elapsed_seconds=([0-9]{1,4})\;\ status=pass$ ]]; then
      elapsed="${BASH_REMATCH[1]}"
      (( 10#$elapsed <= 2100 )) || {
        printf '%s\n' 'local-e2e-ci: negative timing exceeds stage bound' >&2
        return 65
      }
    else
      printf '%s\n' 'local-e2e-ci: malformed negative timing receipt' >&2
      return 65
    fi
  done <"$logfile"
  if (( found != 1 )); then
    printf '%s\n' 'local-e2e-ci: negative timing proof missing or duplicated' >&2
    return 65
  fi
  printf 'local-e2e-ci: timing_negative=%s; elapsed_seconds=%d; status=pass\n' \
    "$scenario" "$((10#$elapsed))"
}
