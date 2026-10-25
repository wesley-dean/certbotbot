#!/usr/bin/env bash
# shellcheck shell=bash
## @file ci/verify-client-crypto.bash
## @brief Enforces non-skipped, real-GnuPG shipped-client acceptance.
## @details
## The caller verifies the immutable eight-file handoff before invoking this
## read-only gate. The suite creates local secrets; do not log raw Bats output.
## @par STDIN
## Nothing is read from STDIN.
## @returns Fixed acceptance status and test names on STDOUT.
## @retval 0 Complete actual-GnuPG suite succeeded without skips.
## @retval 1 Missing prerequisites, reduced suite, failures or skips.
set -euo pipefail

: "${BASH_STARTER_CLIENT_ARTIFACT:?verified client executable required}"
: "${BASH_STARTER_ARTIFACT:?verified producer executable required}"

for artifact in "$BASH_STARTER_CLIENT_ARTIFACT" "$BASH_STARTER_ARTIFACT"; do
  [[ -f "$artifact" && ! -L "$artifact" && -x "$artifact" &&
    -f "$artifact.sha256" && ! -L "$artifact.sha256" ]] || {
    printf '%s\n' 'Verified executable or checksum missing' >&2
    exit 1
  }
  (cd "$(dirname "$artifact")" &&
    sha256sum -c "$(basename "$artifact").sha256" >/dev/null) || {
    printf '%s\n' 'Verified executable checksum mismatch' >&2
    exit 1
  }
done

for tool in gpg bats awk grep sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'Encrypted-client test prerequisite unavailable: %s\n' "$tool" >&2
    exit 1
  }
done

version="$(gpg --version 2>/dev/null | head -n 1)" || version=''
if [[ "$version" =~ gpg\ \(GnuPG\)\ ([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"
else
  printf '%s\n' 'Cannot identify GnuPG version' >&2
  exit 1
fi
if (( major < 2 || (major == 2 &&
  (minor < 4 || (minor == 4 && patch < 7))) )); then
  printf '%s\n' 'Encrypted-client tests require GnuPG 2.4.7+' >&2
  exit 1
fi

suite=tests/client-authenticated-shipped.bats
[[ -f "$suite" && ! -L "$suite" ]] || {
  printf '%s\n' 'Required shipped-client acceptance suite missing' >&2
  exit 1
}
expected="$(grep -c '^@test "' "$suite" || :)"
if [[ ! "$expected" =~ ^[0-9]+$ ]] || (( expected < 19 )); then
  printf '%s\n' 'Encrypted-client test inventory incomplete' >&2
  exit 1
fi
for essential in \
  'real producer OCB account-only archive restores privately' \
  'real encrypted multi-lineage archive is identical to plaintext restoration' \
  'wrong secret cannot authenticate a real OCB payload' \
  'changed authenticated ciphertext or tag never activates state' \
  'legacy CFB/MDC and incorrect authenticated S2K format are rejected' \
  'encrypted mode cannot downgrade to valid plaintext archive'; do
  grep -Fq "@test \"$essential\"" "$suite" || {
    printf '%s\n' 'Required encrypted-client acceptance test missing' >&2
    exit 1
  }
done

# A failed suite may contain tool diagnostic or fixture data. Show only TAP
# plan and names, and never publish this full report as a workflow artifact.
report="$(umask 077; mktemp "${RUNNER_TEMP:-/tmp}/client-crypto.XXXXXXXX.tap")" || exit 1
trap 'rm -f -- "$report"' EXIT
result=0
bats --formatter tap "$suite" >"$report" 2>&1 || result=$?
grep -E '^(1\.\.[0-9]+|ok [0-9]+ |not ok [0-9]+ )' "$report" || :
if (( result != 0 )); then
  printf '%s\n' 'Real-GnuPG shipped-client acceptance failed' >&2
  exit 1
fi
if grep -Eiq '^ok [0-9]+ .*# skip|^not ok [0-9]+' "$report"; then
  printf '%s\n' 'Encrypted-client acceptance skips and failures are prohibited' >&2
  exit 1
fi
plan="$(grep -E '^1\.\.[0-9]+$' "$report" | tail -n 1 || :)"
[[ "$plan" == "1..$expected" ]] || {
  printf '%s\n' 'Encrypted-client test-plan mismatch' >&2
  exit 1
}
passed="$(grep -Ec '^ok [0-9]+ ' "$report" || :)"
[[ "$passed" == "$expected" ]] || {
  printf '%s\n' 'Encrypted-client acceptance results incomplete' >&2
  exit 1
}
printf 'Verified %s real-GnuPG shipped-client tests without skips\n' "$passed"
