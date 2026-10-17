# shellcheck shell=bash
## @file lib/remote-candidate.bash
## @brief Compose remote split archives into a verified inactive Certbot tree.
## @details
## ADR-054 connects typed, optionally encrypted S3 collection retrieval
## to complete multi-lineage assembly and certificate validation. No action
## here invokes Certbot, changes active config, modifies S3, or registers an
## account. Failed candidates cannot persist as apparent valid state.
## @see doc/adr/ADR-054-remote-verified-inactive-candidate.md

## @var CERTBOTBOT_REMOTE_CANDIDATE_NAMES
## @brief Canonical selected lineages in the completely prepared batch.
declare -a CERTBOTBOT_REMOTE_CANDIDATE_NAMES=()

## @var CERTBOTBOT_REMOTE_CANDIDATE_VERIFIED
## @brief True only after every selected certificate passes all checks.
CERTBOTBOT_REMOTE_CANDIDATE_VERIFIED=''

## @fn certbotbot_remote_candidate_discard()
## @brief Safely discard the private candidate and clear any verified state.
## @retval 0 Recorded candidate and verification state discarded.
## @retval 73 Candidate could not be removed safely.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @note This does not guarantee secure erasure from physical media.
certbotbot_remote_candidate_discard() {
  local result=0
  CERTBOTBOT_REMOTE_CANDIDATE_VERIFIED=''
  CERTBOTBOT_REMOTE_CANDIDATE_NAMES=()
  certbotbot_import_candidate_discard || result=$?
  return "$result"
}

## @fn certbotbot_remote_candidate_prepare()
## @brief Prepare a complete, existing S3 archive collection without activation.
## @details
## The ADR-039 stage downloads selected objects once and checks optional
## encryption mode. ADR-045 freezes those exact plaintext bytes before
## the downloaded stage is destroyed. All selected lineages must be
## present: missing lineages are not implicit authorization to issue.
## @param bucket Validated S3 bucket.
## @param names Canonical distinct existing lineage names.
## @retval 0 Owner-private inactive candidate exists, pending crypto checks.
## @retval 10 Entire collection confirmed absent; no candidate produced.
## @retval 64 Invalid request or ambient state.
## @retval 65 Missing lineage, archive corruption, or identity conflict.
## @retval 69 Denied, unknown, or interrupted S3 operation.
## @retval 73 Local stage or cleanup failed.
## @note Other existing validator statuses may propagate unchanged.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_remote_candidate_prepare() {
  local bucket=${1:-} environment=${ACME_ENVIRONMENT:-production}
  local i=0 result=0 stage_status=0
  local -a names=() pairs=()
  (( $# >= 2 && $# <= 33 )) || return 64
  [[ $- != *x* && -z ${CERTBOTBOT_REMOTE_CANDIDATE_VERIFIED:-} &&
    ${#CERTBOTBOT_REMOTE_CANDIDATE_NAMES[@]} == 0 &&
    -z ${CERTBOTBOT_IMPORT_CANDIDATE_ROOT:-} &&
    -z ${CERTBOTBOT_IMPORT_CANDIDATE_CONFIG:-} &&
    -z ${CERTBOTBOT_S3_STAGE_ROOT:-} &&
    -z ${CERTBOTBOT_COMMON_STAGE:-} &&
    -z ${CERTBOTBOT_RESTORE_ROOT:-} &&
    -z ${CERTBOTBOT_RENEWAL_PREVIEW:-} ]] || return 64
  names=("${@:2}")
  # Typed staging checks all names, bucket, namespace, and encryption mode
  # before contacting the S3 API or interpreting missing-state results.
  if certbotbot_s3_stage_collection "$bucket" "${names[@]}"; then
    :
  else
    return $?
  fi
  if (( ${#CERTBOTBOT_S3_STAGE_PRESENT[@]} != ${#names[@]} + 1 )) ||
    [[ ${CERTBOTBOT_S3_STAGE_PRESENT[0]} != 1 ]]; then
    result=65
  fi
  if (( result == 0 )); then
    for (( i=0; i<${#names[@]}; i++ )); do
      if [[ ${CERTBOTBOT_S3_STAGE_PRESENT[i+1]} != 1 ||
        -z ${CERTBOTBOT_S3_STAGE_PATHS[i+1]} ]]; then
        result=65
        break
      fi
      pairs+=("${names[i]}" "${CERTBOTBOT_S3_STAGE_PATHS[i+1]}")
    done
  fi
  if (( result == 0 )); then
    if certbotbot_import_candidate_prepare \
      "${CERTBOTBOT_S3_STAGE_PATHS[0]}" "$environment" "${pairs[@]}"; then
      :
    else
      result=$?
    fi
  fi
  certbotbot_s3_stage_discard || stage_status=73
  if (( result != 0 || stage_status != 0 )); then
    certbotbot_remote_candidate_discard || return 73
    (( stage_status == 0 )) || return 73
    return "$result"
  fi
  # shellcheck disable=SC2034
  CERTBOTBOT_REMOTE_CANDIDATE_NAMES=("${names[@]}")
  return 0
}

## @fn certbotbot_remote_candidate_verify()
## @brief Check all candidate chains, matching keys, and exact SAN sets.
## @details
## The bundle comes from the operator, never retrieved archive contents.
## For staging it must be explicit; production may use the system store.
## A rejected or incomplete batch discards all private candidate state.
## Each SAN string is space-separated, canonical, and includes apex/wildcard.
## @param ca_bundle Operator-selected staging roots or production trust selector.
## @param pairs One canonical name and exact SAN string per prepared lineage.
## @retval 0 All certificate chains, keys, and exact SANs validated.
## @retval 64 Invalid request, missing staging trust, or wrong name list.
## @retval 65 Expired/untrusted/mismatched certificate or SAN identity.
## @retval 69 Required cryptographic executable unavailable.
## @retval 73 Failed candidate cleanup.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_remote_candidate_verify() {
  local bundle=${1:-} config=${CERTBOTBOT_IMPORT_CANDIDATE_CONFIG:-}
  local name='' group='' result=0 i=0
  local -a request=() sans=()
  if (( $# < 3 || ($# - 1) % 2 != 0 ||
    ($# - 1) / 2 != ${#CERTBOTBOT_REMOTE_CANDIDATE_NAMES[@]} )) ||
    [[ $- == *x* || -n ${CERTBOTBOT_REMOTE_CANDIDATE_VERIFIED:-} ||
      -z ${CERTBOTBOT_IMPORT_CANDIDATE_ROOT:-} ||
      -z $config ||
      $config != "$CERTBOTBOT_IMPORT_CANDIDATE_ROOT/config" ||
      $config == "${CERTBOTBOT_WORKSPACE_CONFIG:-}" ]]; then
    # An already prepared candidate must not remain usable after an invalid
    # verification request; this is the same full-batch failure boundary.
    if [[ -n ${CERTBOTBOT_IMPORT_CANDIDATE_ROOT:-} &&
      ${CERTBOTBOT_IMPORT_CANDIDATE_CONFIG:-} ==
        "$CERTBOTBOT_IMPORT_CANDIDATE_ROOT/config" ]]; then
      certbotbot_remote_candidate_discard || return 73
    fi
    return 64
  fi
  if [[ ${ACME_ENVIRONMENT:-production} == staging && -z $bundle ]]; then
    certbotbot_remote_candidate_discard || return 73
    return 64
  fi
  request=("${@:2}")
  for (( i=0; i<${#CERTBOTBOT_REMOTE_CANDIDATE_NAMES[@]}; i++ )); do
    name=${request[i*2]}
    group=${request[i*2+1]}
    if [[ $name != "${CERTBOTBOT_REMOTE_CANDIDATE_NAMES[i]}" ||
      -z $group || $group == *[[:cntrl:]]* ||
      $group == ' '* || $group == *' ' || $group == *'  '* ]]; then
      result=64
      break
    fi
    read -r -a sans <<< "$group"
    if (( ${#sans[@]} < 2 )); then
      result=64
      break
    fi
    certbotbot_crypto_verify_lineage "$config" "$name" "$bundle" ||
      { result=$?; break; }
    certbotbot_crypto_verify_sans "$config" "$name" "${sans[@]}" ||
      { result=$?; break; }
  done
  if (( result != 0 )); then
    certbotbot_remote_candidate_discard || return 73
    return "$result"
  fi
  # Successful validation does not grant an activation capability.
  CERTBOTBOT_REMOTE_CANDIDATE_VERIFIED=true
  return 0
}
