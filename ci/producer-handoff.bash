#!/usr/bin/env bash
# shellcheck shell=bash
## @file ci/producer-handoff.bash
## @brief Prepare or verify a same-run producer artifact handoff.
## @details
## This build-side utility validates the three producer scripts, the separate client, and their
## checksum companions. It does not download dependencies, rebuild executables,
## access a network, or authorize cross-run artifact reuse. The caller supplies
## the expected GitHub workflow run identity and, for verify, the digest of the
## manifest published as a trusted preparation-job output (ADR-036).
##
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## In create mode, the SHA-256 digest of the generated manifest is printed.
## In verify mode, nothing is written to STDOUT.
## @par STDERR
## Static, nonsecret diagnostics on failure.
## @retval 0 The handoff was generated or verified.
## @retval 64 Invalid command or invocation identity.
## @retval 65 Missing, unexpected, or corrupted handoff files.
## @retval 69 Required local verification tool unavailable.
set -euo pipefail

handoff_error() {
  printf 'producer handoff: %s\n' "$1" >&2
  exit "${2:-65}"
}

if (( $# != 6 && $# != 7 )); then
  handoff_error 'expected create/verify directory source-sha run-id run-attempt version [manifest-sha]' 64
fi
mode=$1
root=$2
source_sha=$3
run_id=$4
run_attempt=$5
version=$6
expected_manifest_sha=${7-}
[[ "$mode" == create && $# == 6 || "$mode" == verify && $# == 7 ]] || handoff_error 'invalid mode or argument count' 64
[[ "$source_sha" =~ ^[a-f0-9]{40}$ && "$run_id" =~ ^[1-9][0-9]*$ && "$run_attempt" =~ ^[1-9][0-9]*$ ]] || handoff_error 'invalid workflow identity' 64
[[ "$version" =~ ^[a-zA-Z0-9][a-zA-Z0-9.+_-]*$ ]] || handoff_error 'invalid build version' 64
if [[ "$mode" == verify && ! "$expected_manifest_sha" =~ ^[a-f0-9]{64}$ ]]; then
  handoff_error 'invalid expected manifest digest' 64
fi
command -v sha256sum >/dev/null 2>&1 || handoff_error 'sha256sum unavailable' 69
command -v git >/dev/null 2>&1 || handoff_error 'git unavailable' 69
command -v bash >/dev/null 2>&1 || handoff_error 'bash unavailable' 69
[[ -d "$root" && ! -L "$root" ]] || handoff_error 'invalid handoff directory'
[[ "$(git rev-parse --verify HEAD 2>/dev/null)" == "$source_sha" ]] || handoff_error 'checkout does not match workflow source commit'
build_commit=$(git rev-parse --short=12 HEAD)
build_date=$(git show -s --format=%cI HEAD)
[[ -n "$build_date" && "$build_date" != *$'\n'* ]] || handoff_error 'invalid build date'

names=(certbotbot.dev.bash certbotbot.bash certbotbot.min.bash certbotbot-client.bash)
[[ -f "$root/certbotbot.dev.bash" && ! -L "$root/certbotbot.dev.bash" ]] || handoff_error 'missing development artifact'
grep -Fqx -- "# Version: $version" "$root/certbotbot.dev.bash" || handoff_error 'artifact version does not match expected build'
grep -Fqx -- "# Build commit: $build_commit" "$root/certbotbot.dev.bash" || handoff_error 'artifact source commit does not match checkout'
grep -Fqx -- "# Build date: $build_date" "$root/certbotbot.dev.bash" || handoff_error 'artifact build date does not match checkout'
grep -Fqx -- "BASH_STARTER_PROJECT_NAME=certbotbot-client" "$root/certbotbot-client.bash" || handoff_error 'client identity mismatch'
grep -Fqx -- "BASH_STARTER_VERSION=$version" "$root/certbotbot-client.bash" || handoff_error 'client version mismatch'
grep -Fqx -- "BASH_STARTER_BUILD_COMMIT=$build_commit" "$root/certbotbot-client.bash" || handoff_error 'client source commit mismatch'
grep -Fqx -- "BASH_STARTER_BUILD_DATE=$build_date" "$root/certbotbot-client.bash" || handoff_error 'client build date mismatch'
expected_count=8
[[ "$mode" == verify ]] && expected_count=9
actual_count=0
shopt -s dotglob nullglob
for f in "$root"/*; do
  [[ -e "$f" || -L "$f" ]] || continue
  (( actual_count += 1 ))
  filename=${f##*/}
  case "$filename" in
    certbotbot.dev.bash|certbotbot.dev.bash.sha256|certbotbot.bash|certbotbot.bash.sha256|certbotbot.min.bash|certbotbot.min.bash.sha256|certbotbot-client.bash|certbotbot-client.bash.sha256) ;;
    producer-handoff.manifest) [[ "$mode" == verify ]] || handoff_error 'unexpected handoff manifest' ;;
    *) handoff_error 'unexpected handoff file' ;;
  esac
  [[ -f "$f" && ! -L "$f" ]] || handoff_error 'unsafe handoff entry'
done
[[ "$actual_count" -eq "$expected_count" ]] || handoff_error 'incomplete handoff inventory'

manifest=$(printf 'format=certbotbot-producer-client-handoff-v2\nsource_sha=%s\nrun_id=%s\nrun_attempt=%s\nversion=%s\nbuild_commit=%s\nbuild_date=%s\nfile_count=8\n' \
  "$source_sha" "$run_id" "$run_attempt" "$version" "$build_commit" "$build_date")
for name in "${names[@]}"; do
  script="$root/$name"
  sidecar="$script.sha256"
  [[ -f "$script" && ! -L "$script" && -x "$script" && -f "$sidecar" && ! -L "$sidecar" ]] || handoff_error 'missing or unsafe executable or checksum'
  [[ ! -e "$script.256" && ! -L "$script.256" ]] || handoff_error 'stale checksum companion'
  bash -n "$script" >/dev/null 2>&1 || handoff_error 'invalid executable Bash syntax'
  hash=$(sha256sum -- "$script" | awk '{print $1}')
  printf '%s  %s\n' "$hash" "$name" | cmp -s - "$sidecar" || handoff_error 'checksum mismatch'
  manifest+=$'\n'"$name=$hash"
done
manifest+=$'\n'
manifest_path="$root/producer-handoff.manifest"
if [[ "$mode" == create ]]; then
  [[ ! -e "$manifest_path" && ! -L "$manifest_path" ]] || handoff_error 'manifest already exists'
  ( umask 077; printf '%s' "$manifest" > "$manifest_path" )
  sha256sum -- "$manifest_path" | awk '{print $1}'
else
  [[ -f "$manifest_path" && ! -L "$manifest_path" ]] || handoff_error 'manifest missing or unsafe'
  actual_sha=$(sha256sum -- "$manifest_path" | awk '{print $1}')
  [[ "$actual_sha" == "$expected_manifest_sha" ]] || handoff_error 'manifest digest mismatch'
  printf '%s' "$manifest" | cmp -s - "$manifest_path" || handoff_error 'manifest content mismatch'
fi
