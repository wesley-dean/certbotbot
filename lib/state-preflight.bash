# shellcheck shell=bash
## @file lib/state-preflight.bash
## @brief Assesses retrieved object-store state without activating Certbot.
## @details
## The producer must distinguish an empty remote collection from a partially
## existing collection and distinguish valid restored archives from merely
## successful downloads. ADR-039 owns typed retrieval and private downloaded
## bytes. ADR-037, ADR-038, and the existing archive validators own the
## semantic assessment. This module composes them into one fail-closed step.
##
## Every present object must be validated before this operation succeeds.
## Missing selected lineages are reported as data only. No function here
## creates, installs, renews, or publishes Certbot state.
## @see doc/adr/ADR-040-remote-state-assessment-boundary.md

## @var CERTBOTBOT_STATE_MISSING_NAMES
## @brief Ordered canonical lineages confirmed absent in an existing collection.
## @details
## Populated only after complete assessment returns zero. Cleared on error.
## Its presence does not authorize first issuance or new account registration.
declare -a CERTBOTBOT_STATE_MISSING_NAMES=()

## @fn certbotbot_state_assess_remote()
## @brief Retrieve and validate one remote common account and requested lineages.
## @details
## The entire requested collection is downloaded before archive inspection.
## A common archive is validated even if every requested domain is absent.
## Existing domain archives are passed as one complete batch to the
## established non-activating assessment, which checks structural isolation,
## account identity, allowed renewal options, and safe path relocation.
## All downloaded bytes and temporary staging are discarded on both outcomes.
## This is not the activating issuer, nor a certificate cryptographic check.
##
## @param bucket Configured S3 bucket.
## @param names One or more distinct canonical requested lineage names.
##
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Underlying archive commands may emit non-secret validation diagnostics.
##
## @returns Nothing is written to STDOUT.
## @retval 0 All present archives passed assessment; missing names recorded.
## @retval 10 Entire collection confirmed absent, without registration.
## @retval 64 Invalid input, active state, or unsafe restored archive.
## @retval 65 Account/authority conflict or orphaned domain state.
## @retval 69 Unknown remote service, authentication, or transport failure.
## @retval 73 Local staging, validation I/O, or cleanup failure.
## @note Other nonzero statuses may be propagated by archive validators.
## @note Successful assessment does not prove ACME account registration,
## certificate validity, SAN identity, or publishability.
certbotbot_state_assess_remote() {
  local bucket=${1:-} environment=${ACME_ENVIRONMENT:-production}
  local result=0 index=0 name='' common=''
  local -a names=() present_pairs=() missing=()

  # Never preserve a prior successful missing-lineage report on failure.
  CERTBOTBOT_STATE_MISSING_NAMES=()

  # Refuse caller-owned staging so an error cannot destroy unrelated state.
  if (( $# < 2 )) ||
    [[ -n ${CERTBOTBOT_S3_STAGE_ROOT:-} ||
      -n ${CERTBOTBOT_COMMON_STAGE:-} ||
      -n ${CERTBOTBOT_RESTORE_ROOT:-} ||
      -n ${CERTBOTBOT_RENEWAL_PREVIEW:-} ]]; then
    return 64
  fi
  names=("${@:2}")

  # The retrieval helper validates every name and key before accessing S3.
  # A fully empty collection is distinct from a corrupt stored account.
  if certbotbot_s3_stage_collection "$bucket" "${names[@]}"; then
    :
  else
    return $?
  fi

  common=${CERTBOTBOT_S3_STAGE_PATHS[0]}
  if [[ -z $common || ${CERTBOTBOT_S3_STAGE_PRESENT[0]} != 1 ]]; then
    result=65
  fi

  if (( result == 0 )); then
    # The common archive is always authoritative, even when every selected
    # domain is confirmed absent. The delegated validator does not install it.
    if certbotbot_common_restore "$common"; then
      certbotbot_common_discard || result=73
    else
      result=$?
    fi
  fi

  if (( result == 0 )); then
    for (( index=0; index<${#names[@]}; index+=1 )); do
      name=${names[index]}
      if [[ ${CERTBOTBOT_S3_STAGE_PRESENT[index+1]} == 1 ]]; then
        present_pairs+=("$name" "${CERTBOTBOT_S3_STAGE_PATHS[index+1]}")
      else
        missing+=("$name")
      fi
    done
    # Batch assessment requires at least one existing selected lineage.
    # A common-only collection has already passed its independent check.
    if (( ${#present_pairs[@]} > 0 )); then
      certbotbot_import_assess_batch "$common" "$environment" \
        "${present_pairs[@]}" || result=$?
    fi
  fi

  # Cleanup failures supersede earlier validation errors; callers must
  # never treat a retained downloaded account key as successful disposal.
  certbotbot_s3_stage_discard || return 73
  if (( result != 0 )); then
    CERTBOTBOT_STATE_MISSING_NAMES=()
    return "$result"
  fi
  # Caller-facing result is consumed after standalone assembly.
  # shellcheck disable=SC2034
  CERTBOTBOT_STATE_MISSING_NAMES=("${missing[@]}")
  return 0
}
