#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/publish.bash
## @brief Publishes a verified Certbot candidate to one existing S3 object.
## @details
## Implements ADR-028 and the single-key no-op policy of ADR-020. This module
## is a post-success execution adapter. It requires an already successful
## selected Certbot operation and its independently verified durable-change
## result from the caller. It never calls Certbot, restores cloud resources,
## selects an ACME account, or infers a fallback S3 object.
##
## Before PutObject it requires private canonical state and invokes the
## existing candidate archive builder itself. No arbitrary provided file
## may bypass validation. Certificate renewal and durable-state changes are
## distinct: changed=true requires publication even if Certbot issued no new
## leaf. When changed=false, a successful unchanged no-op publishes only if
## the explicit override is true.
## The normative product truth table is in
## doc/mvp-upload-no-renewal-policy.md. AWS CLI v2 is inherited from the operator's
## environment; command output is suppressed. Failed PutObject leaves remote
## state unknown, not necessarily unchanged. The caller owns cleanup and
## externally serialized S3 writers. Mocked before/after remote digest and
## lost-response tests are specified in doc/mvp-failure-preservation.md.

## @fn certbotbot_s3_publish()
## @brief Applies the no-op policy and uploads one locally verified candidate.
## @details
## WORKSPACE/config must contain a complete, already processed selected
## lineage, a single registered production account, and canonical renewal
## metadata for every stored lineage. The full candidate includes every
## unrelated lineage, not a selected-only subset. The caller must have verified the Certbot result and certificate
## material, and must pass the exact bucket/key used for the earlier S3 read.
##
## When CHANGED and OVERRIDE are both false, no candidate or AWS call is
## performed; CERTBOTBOT_S3_PUBLISHED=false indicates a successful skip.
## Otherwise the function creates WORKSPACE/candidate.tar.gz through
## certbotbot_archive_package, which enforces strict tar/gzip validation.
## When ADR-031 encryption is enabled, only a validated authenticated OCB\n## envelope is eligible for the single same-key PutObject call. Migration\n## forces one verified publication even for otherwise unchanged Certbot state.\n## It sends the chosen file using one AWS CLI v2 s3api put-object call with
## explicit SHA256 checksum algorithm and application/gzip content type.
## On success CERTBOTBOT_S3_PUBLISHED=true. On failure it is cleared.
##
## The status says whether this local invocation requested and received
## success from AWS, not whether a later independent read will succeed.
## S3 concurrent writes and partial/interrupted publication are outside
## this module's guarantees. The private candidate remains for the
## workspace owner to remove.
## @param workspace Canonical private, owned mode-0700 invocation workspace.
## @param selected Validated selected non-wildcard certificate lineage name.
## @param bucket The same configured existing S3 bucket used for retrieval.
## @param key The same configured object key used for retrieval.
## @param changed Literal true/false verified durable-state change result.
## @param override Literal true/false UPLOAD_NO_RENEWAL configuration value.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Static non-sensitive errors, no AWS credentials or service output.
## @returns Nothing is written to STDOUT.
## @retval 0 Upload was accepted, or a verified unchanged no-op was skipped.
## @retval 64 Invalid arguments, bucket/key or private workspace.
## @retval 65 Restored selected account/lineage or metadata is unsuitable.
## @retval 69 AWS CLI unavailable.
## @retval 74 Candidate generation or remote PutObject failed.
## @note Candidate builder may also propagate its defined 64 or 65 statuses.
## @par Examples
## @code
## certbotbot_s3_publish "$workspace" "$CERTBOTBOT_CERT_NAME" \
##   "$CERTBOTBOT_S3_BUCKET" "$CERTBOTBOT_S3_KEY" \
##   "$CERTBOTBOT_DURABLE_CHANGED" "$CERTBOTBOT_UPLOAD_NO_RENEWAL" ||
##   exit $?
## @endcode
certbotbot_s3_publish() {
  local workspace selected bucket key changed override config physical candidate
  CERTBOTBOT_S3_PUBLISHED=''
  if (( $# != 6 )); then
    printf '%s\n' 'certbotbot: invalid S3 publication arguments' >&2
    return 64
  fi
  workspace="$1"
  selected="$2"
  bucket="$3"
  key="$4"
  changed="$5"
  override="$6"
  if [[ "$workspace" != /* || "$workspace" == / ||
    "$workspace" == */ || ! "$workspace" =~ ^/[A-Za-z0-9._/-]+$ ||
    ! -d "$workspace" || -L "$workspace" || ! -O "$workspace" ||
    "$selected" == *'*'* ]] ||
    ! certbotbot_dns_valid "$selected" ||
    [[ -z "$bucket" || "$bucket" == *[[:space:]]* ||
      -z "$key" || "$key" == -* || "$key" == */* ||
      "$key" == *[[:space:]]* ]]; then
    printf '%s\n' 'certbotbot: invalid S3 publication input' >&2
    return 64
  fi
  case "$changed:$override" in
    true:true|true:false|false:true|false:false) ;;
    *)
      printf '%s\n' 'certbotbot: invalid S3 publication boolean' >&2
      return 64
      ;;
  esac
  physical="$(cd -P -- "$workspace" && pwd -P)" || return 64
  if [[ "$physical" != "$workspace" ||
    "$(stat -c %a -- "$workspace" 2>/dev/null)" != 700 ]]; then
    printf '%s\n' 'certbotbot: unsafe S3 publication workspace' >&2
    return 64
  fi
  candidate="$workspace/candidate.tar.gz"
  if [[ -e "$candidate" || -L "$candidate" ]]; then
    printf '%s\n' 'certbotbot: occupied S3 publication candidate path' >&2
    return 64
  fi
  config="$workspace/config"
  if ! certbotbot_state_preflight "$config" "$selected" >/dev/null 2>&1 ||
    [[ "$CERTBOTBOT_LINEAGE_STATE" != present ]] ||
    ! certbotbot_renewal_map "$config" "$selected" verify >/dev/null 2>&1 ||
    ! certbotbot_state_canonical_all "$config" "$selected" >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: selected publication state is unsuitable' >&2
    return 65
  fi

  if [[ "$changed" == false && "$override" == false &&
    "${CERTBOTBOT_MIGRATING:-false}" != true ]]; then
    # Caller-visible publication outcome (successful no-op, no remote write).
    # shellcheck disable=SC2034
    CERTBOTBOT_S3_PUBLISHED=false
    return 0
  fi
  if ! command -v aws >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: AWS CLI v2 is required for publication' >&2
    return 69
  fi
  certbotbot_archive_package "$workspace" "$selected" || return $?
  local content_type=application/gzip
  if [[ "$CERTBOTBOT_ARCHIVE_ENCRYPTION" == gpg-ocb ]]; then
    certbotbot_crypto_wrap "$workspace" || return $?
    candidate="$workspace/candidate.tar.gz.enc"
    content_type=application/octet-stream
  fi

  if ! aws --no-cli-pager s3api put-object \
    --bucket "$bucket" --key "$key" --body "$candidate" \
    --checksum-algorithm SHA256 --content-type "$content_type" \
    --output json >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: S3 archive upload failed; remote state is uncertain' >&2
    return 74
  fi
  # Caller-visible publication outcome after AWS has returned success.
  # shellcheck disable=SC2034
  CERTBOTBOT_S3_PUBLISHED=true
  return 0
}
