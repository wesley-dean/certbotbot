#!/usr/bin/env bash
# shellcheck shell=bash
## @file ci/verify-oci-public-release.bash
## @brief Bind a completed Versioning run to attested release assets.
## @details
## Validates the exact tag/commit, signed-commit API verification, public
## release inventory and attestations before recreating an immutable handoff.
## Does not publish, build, or use cloud credentials. A mismatched release
## or unverified asset must never become container build input.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## One nonsecret release identity line upon success.
## @par STDERR
## Static diagnostic on failure.
## @retval 0 Public release and source identities verified.
## @retval 64 Invalid arguments.
## @retval 65 Missing, unsafe or mismatched release identity.
## @retval 69 Required verification tooling unavailable.
## @retval 74 Download or staging failure.
set -euo pipefail
fail() { printf 'oci public release: %s\n' "$1" >&2; exit "${2:-65}"; }
(( $# == 4 )) || fail 'usage: SOURCE_SHA RUN_ID ATTEMPT OUTPUT_DIR' 64
source_sha=$1
run_id=$2
attempt=$3
output=$4
[[ "$source_sha" =~ ^[0-9a-f]{40}$ && "$run_id" =~ ^[1-9][0-9]*$ &&
  "$attempt" =~ ^[1-9][0-9]*$ ]] || fail 'invalid source identity' 64
[[ "${GH_REPO-}" == wesley-dean/certbotbot ]] || fail 'unexpected repository'
for tool in gh git jq sha256sum bash mktemp chmod; do
  command -v "$tool" >/dev/null 2>&1 || fail 'required verifier unavailable' 69
done
[[ -n "${GH_TOKEN-}" ]] || fail 'missing API read authorization' 69
[[ "$(git rev-parse --verify HEAD)" == "$source_sha" ]] ||
  fail 'checkout differs from completed run'
[[ ! -e "$output" && ! -L "$output" ]] || fail 'output must not exist' 64

# Full clone includes tags, but one tag alone is insufficient evidence.
# Reject ambiguity; do not guess a release version or trust latest.
mapfile -t tags < <(git tag --points-at "$source_sha" --list 'v[0-9]*')
(( ${#tags[@]} == 1 )) || fail 'expected exactly one release tag on source commit'
tag=${tags[0]}
[[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] ||
  fail 'unexpected release tag syntax'
version=${BASH_REMATCH[1]}
[[ "$(git rev-list -n 1 "refs/tags/$tag")" == "$source_sha" ]] ||
  fail 'tag does not point to verified source'

release="$(gh api "repos/$GH_REPO/releases/tags/$tag")" ||
  fail 'GitHub release unavailable'
jq -e --arg tag "$tag" '
  .tag_name == $tag and .draft == false and .prerelease == false and
  (.published_at != null)
' <<<"$release" >/dev/null || fail 'release not published and stable'

# Require GitHub's signature verification for source revision. This is
# independent of a tag naming a commit and of asset checksum sidecars.
gh api "repos/$GH_REPO/commits/$source_sha" |
  jq -e '.commit.verification.verified == true' >/dev/null ||
  fail 'release commit signature is not verified'
names=(certbotbot.dev.bash certbotbot.bash certbotbot.min.bash certbotbot-client.bash)
expected=()
for item in "${names[@]}"; do
  expected+=("$item" "$item.sha256")
done
mapfile -t actual < <(jq -r '.assets[].name' <<<"$release" | LC_ALL=C sort)
mapfile -t permitted < <(printf '%s\n' "${expected[@]}" | LC_ALL=C sort)
[[ "${actual[*]}" == "${permitted[*]}" ]] ||
  fail 'missing, unexpected or duplicated release assets'
mkdir -m 0700 -- "$output" || fail 'cannot create private output' 74
for item in "${expected[@]}"; do
  gh release download "$tag" --repo "$GH_REPO" --pattern "$item" \
    --dir "$output" --clobber >/dev/null ||
    fail 'release asset download failed' 74
  [[ -f "$output/$item" && ! -L "$output/$item" ]] ||
    fail 'downloaded asset is not a regular file'
  # Verify the GitHub-attested subject, not merely the adjacent checksum
  # supplied by the same release publisher.
  gh attestation verify "$output/$item" --repo "$GH_REPO" >/dev/null ||
    fail 'release asset attestation verification failed'
done
for item in "${names[@]}"; do
  chmod 0755 "$output/$item"
done
digest="$(bash ci/producer-handoff.bash create "$output" \
  "$source_sha" "$run_id" "$attempt" "$version")" ||
  fail 'verified release assets failed source/run provenance'
bash ci/producer-handoff.bash verify "$output" \
  "$source_sha" "$run_id" "$attempt" "$version" "$digest" ||
  fail 'release handoff cannot be reverified'
printf 'oci release: %s source=%s handoff=%s\n' "$tag" "$source_sha" "$digest"
