#!/usr/bin/env bash
# shellcheck shell=bash
## @file ci/prepare-oci-context.bash
## @brief Build an allowlisted OCI context from the exact eight verified Bash files.
## @details
## This never downloads artifacts, changes release files, builds an image,
## reads runtime secrets, or grants publication authority. Release mode needs
## the trusted same-run/attempt manifest digest; local mode creates and
## verifies a temporary manifest from the complete current development build.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Only nonsecret build arguments are printed on success.
## @par STDERR
## Static diagnostics on failure.
## @retval 0 Complete private build context was prepared and verified.
## @retval 64 Invalid input or workflow identity.
## @retval 65 Corrupt/incomplete handoff or unsafe context inputs.
## @retval 69 Local validation tool unavailable.
## @retval 74 Failed staging or local I/O.
set -euo pipefail

oci_error() {
  printf 'oci context: %s\n' "$1" >&2
  exit "${2:-65}"
}

if (( $# != 7 && $# != 8 )); then
  oci_error 'usage: MODE HANDOFF_DIR OUTPUT_DIR SOURCE_SHA RUN_ID ATTEMPT VERSION [MANIFEST_SHA]' 64
fi
mode=$1
root=$2
output=$3
source_sha=$4
run_id=$5
run_attempt=$6
version=$7
expected_manifest_sha=${8-}

case "$mode" in
  local) (( $# == 7 )) || oci_error 'local mode does not accept a release digest' 64 ;;
  release)
    (( $# == 8 )) || oci_error 'release mode requires the trusted manifest digest' 64
    [[ "$expected_manifest_sha" =~ ^[a-f0-9]{64}$ ]] ||
      oci_error 'invalid manifest digest' 64
    ;;
  *) oci_error 'mode must be local or release' 64 ;;
esac
[[ "$source_sha" =~ ^[a-f0-9]{40}$ &&
  "$run_id" =~ ^[1-9][0-9]*$ &&
  "$run_attempt" =~ ^[1-9][0-9]*$ &&
  "$version" =~ ^[a-zA-Z0-9][a-zA-Z0-9.+_-]*$ ]] ||
  oci_error 'invalid build identity' 64
for tool in git bash sha256sum install cmp dirname basename realpath mktemp; do
  command -v "$tool" >/dev/null 2>&1 ||
    oci_error 'required local verification tool unavailable' 69
done
[[ "$(git rev-parse --verify HEAD 2>/dev/null)" == "$source_sha" ]] ||
  oci_error 'checkout does not match source commit'
[[ -d "$root" && ! -L "$root" ]] || oci_error 'handoff directory unavailable'
[[ -f Dockerfile && ! -L Dockerfile &&
  -f .dockerignore && ! -L .dockerignore &&
  -f oci/debian.sources && ! -L oci/debian.sources &&
  -f ci/producer-handoff.bash && ! -L ci/producer-handoff.bash ]] ||
  oci_error 'reviewed OCI sources unavailable'

# The target must be newly created under an existing canonical directory.
# Never recursively clean up an operator-supplied preexisting directory.
output_name="$(basename -- "$output")"
[[ "$output_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ &&
  "$output_name" != '.' && "$output_name" != '..' ]] ||
  oci_error 'invalid output directory name' 64
parent="$(realpath -e -- "$(dirname -- "$output")")" ||
  oci_error 'output parent unavailable' 74
[[ -d "$parent" && ! -L "$parent" ]] ||
  oci_error 'unsafe output parent'
output="$parent/$output_name"
[[ ! -e "$output" && ! -L "$output" ]] ||
  oci_error 'output must not exist'

# Only paths newly created by this invocation may be removed.
temp=''
output_created=false
completed=false
oci_cleanup() {
  if [[ "$output_created" == true && "$completed" != true ]]; then
    rm -rf -- "$output"
  fi
  if [[ -n "$temp" ]]; then
    rm -rf -- "$temp"
  fi
}
trap oci_cleanup EXIT

# Release candidates have an independently trusted manifest and full strict
# inventory. A local build can acquire an equivalent *development-only*
# manifest in a separate temporary copy, never publishing it as a release.
names=(certbotbot.dev.bash certbotbot.bash certbotbot.min.bash certbotbot-client.bash)
if [[ "$mode" == release ]]; then
  bash ci/producer-handoff.bash verify "$root" "$source_sha" "$run_id" \
    "$run_attempt" "$version" "$expected_manifest_sha" ||
    oci_error 'release handoff verification failed'
else
  [[ ! -e "$root/producer-handoff.manifest" &&
    ! -L "$root/producer-handoff.manifest" ]] ||
    oci_error 'local mode must use an unmanifested development build'
  shopt -s nullglob dotglob
  entries=("$root"/*)
  (( ${#entries[@]} == 8 )) || oci_error 'local handoff inventory is not eight files'
  for item in "${entries[@]}"; do
    case "${item##*/}" in
      certbotbot.dev.bash|certbotbot.dev.bash.sha256|certbotbot.bash|certbotbot.bash.sha256|certbotbot.min.bash|certbotbot.min.bash.sha256|certbotbot-client.bash|certbotbot-client.bash.sha256) ;;
      *) oci_error 'unexpected local artifact' ;;
    esac
    [[ -f "$item" && ! -L "$item" ]] ||
      oci_error 'unsafe local artifact'
  done
  umask 077
  temp="$(mktemp -d)" || oci_error 'cannot create verifier workspace' 74
  for name in "${names[@]}"; do
    [[ -f "$root/$name" && -f "$root/$name.sha256" &&
      ! -L "$root/$name" && ! -L "$root/$name.sha256" ]] ||
      oci_error 'missing or unsafe local artifact'
    install -m 0755 "$root/$name" "$temp/$name"
    install -m 0644 "$root/$name.sha256" "$temp/$name.sha256"
  done
  expected_manifest_sha="$(bash ci/producer-handoff.bash create "$temp" \
    "$source_sha" "$run_id" "$run_attempt" "$version")" ||
    oci_error 'cannot verify development artifact handoff'
  bash ci/producer-handoff.bash verify "$temp" "$source_sha" "$run_id" \
    "$run_attempt" "$version" "$expected_manifest_sha" ||
    oci_error 'development handoff verification failed'
fi

# The SHA passed to the Dockerfile comes from the independently verified
# handoff, not from an arbitrary unrelated build argument.
digest="$(sha256sum -- "$root/certbotbot.bash" | awk '{print $1}')" ||
  oci_error 'cannot compute verified producer digest'
[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || oci_error 'invalid producer digest'

# A successful verification has no authority to overwrite an existing path.
# The output is owned exclusively by this invocation after mkdir succeeds.
umask 077
mkdir -m 0700 -- "$output" || oci_error 'cannot create output context' 74
output_created=true
mkdir -m 0700 "$output/oci" "$output/oci/producer" ||
  oci_error 'cannot create allowlisted context' 74
install -m 0644 Dockerfile "$output/Dockerfile" ||
  oci_error 'cannot stage Dockerfile' 74
install -m 0644 .dockerignore "$output/.dockerignore" ||
  oci_error 'cannot stage Docker ignore rules' 74
install -m 0644 oci/debian.sources "$output/oci/debian.sources" ||
  oci_error 'cannot stage pinned Debian sources' 74
install -m 0644 "$root/certbotbot.bash" "$output/oci/producer/certbotbot.bash" ||
  oci_error 'cannot stage verified executable' 74
install -m 0644 "$root/certbotbot.bash.sha256" \
  "$output/oci/producer/certbotbot.bash.sha256" ||
  oci_error 'cannot stage verified checksum' 74
printf 'source_sha=%s\nversion=%s\nproducer_sha256=%s\nhandoff_manifest_sha256=%s\nbuild_kind=%s\n' \
  "$source_sha" "$version" "$digest" "$expected_manifest_sha" "$mode" \
  >"$output/oci/producer/provenance.txt" ||
  oci_error 'cannot stage provenance' 74
( cd "$output/oci/producer" && sha256sum -c certbotbot.bash.sha256 >/dev/null ) ||
  oci_error 'staged producer checksum invalid'

completed=true
printf 'SOURCE_COMMIT=%s\nRELEASE_VERSION=%s\nPRODUCER_SHA256=%s\n' \
  "$source_sha" "$version" "$digest"
printf 'HANDOFF_MANIFEST_SHA256=%s\nBUILD_KIND=%s\n' "$expected_manifest_sha" "$mode"
