# shellcheck shell=bash
## @file lib/import-assess.bash
## @brief Performs a non-activating assessment of staged Certbot state.
## @details
## ADR-037 permits checking isolated common-account and one domain stage
## against the selected ACME environment and a portable renewal-path preview.
## This module never installs restored bytes into active config, never invokes
## Certbot, and never changes object storage. It rejects a populated config.
## @see doc/adr/ADR-037-gated-active-certbot-import.md

## @fn certbotbot_import_assess()
## @brief Validate one staged account/lineage pair without activating it.
## @param name Canonical requested lineage.
## @param environment production or staging.
## @retval 0 The staged inputs and private path preview passed preflight.
## @retval 64 Bad arguments, staged state, or unsafe active workspace.
## @retval 65 Restored ACME account or environment mismatch.
## @retval 73 Local filesystem or preview-cleanup failure.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @note This is not proof of account registration, safe renewal options,
## or certificate validity and cannot authorize active import or issuance.
certbotbot_import_assess() {
  local name=${1:-} environment=${2:-} mode='' result=0 item=''
  if (( $# != 2 )) || [[ -n ${CERTBOTBOT_RENEWAL_PREVIEW:-} ||
    -z ${CERTBOTBOT_COMMON_STAGE:-} ||
    -z ${CERTBOTBOT_RESTORE_ROOT:-} ||
    -z ${CERTBOTBOT_WORKSPACE_CONFIG:-} ]] ||
    ! certbotbot_validate_hostname "$name" ||
    [[ $name == \*.* || $name != "${name,,}" ]] ||
    ! certbotbot_acme_validate_environment "$environment"; then
    return 64
  fi

  if [[ ! -d $CERTBOTBOT_WORKSPACE_CONFIG ||
    -L $CERTBOTBOT_WORKSPACE_CONFIG ||
    ! -O $CERTBOTBOT_WORKSPACE_CONFIG ]]; then
    return 64
  fi
  mode="$(stat -c '%a' -- "$CERTBOTBOT_WORKSPACE_CONFIG")" || return 73
  [[ $mode == 700 ]] || return 64

  # Nothing may already have been installed into the active configuration.
  # Do not rely on pathname globbing (hidden files are significant).
  item="$(find -P "$CERTBOTBOT_WORKSPACE_CONFIG" -mindepth 1 -print -quit)" ||
    return 73
  [[ -z $item ]] || return 64

  certbotbot_common_inspect "$CERTBOTBOT_COMMON_STAGE" || return $?
  certbotbot_restore_inspect_tree "$CERTBOTBOT_RESTORE_ROOT" "$name" ||
    return $?
  # Refuse unreviewed Certbot options before producing any path preview.
  certbotbot_renewal_policy_check "$name" "$environment" || return $?
  certbotbot_renewal_path_preview "$name" "$environment" || return $?

  # The preflight is deliberately non-activating. Never leave a path preview
  # behind to be accidentally used by another part of this process.
  if ! certbotbot_renewal_preview_discard; then
    result=73
  fi
  return "$result"
}

## @fn certbotbot_import_assess_archives()
## @brief Restores and assesses one account/domain pair without activation.
## @details
## Both archives are frozen and independently checked by their existing
## private staging helpers before the ADR-037 assessment. The helper owns
## only the staging trees that it creates; callers must start with no
## existing common, domain, or renewal-preview state. Regardless of success
## or validation failure, it discards those trees before returning. The
## caller continues to own the private producer workspace itself.
##
## No restored data are merged into config/, used by Certbot, or published.
## This is one-lineage preparation only: a later orchestrator must validate
## every selected lineage before making any active-state decision.
##
## @param common_archive Absolute pathname to a local common tar.gz archive.
## @param domain_archive Absolute pathname to one local lineage tar.gz archive.
## @param name Canonical requested certificate lineage.
## @param environment Selected production or staging ACME environment.
##
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Validation or extraction tools may emit diagnostics. Never log keys.
##
## @returns Nothing is written to STDOUT.
## @retval 0 Both archives passed non-activating assessment and were discarded.
## @retval 64 Invalid inputs or unsafe archive, stage, or workspace state.
## @retval 65 Restored account or ACME environment does not match the lineage.
## @retval 73 Local storage, extraction, inspection, or cleanup failed.
## @note Archive validation and renewal inspection may propagate further
## nonzero statuses. Cleanup errors take precedence over earlier failures.
## @see doc/adr/ADR-027-isolated-domain-archive-restoration.md
## @see doc/adr/ADR-028-isolated-common-acme-account-state.md
## @see doc/adr/ADR-037-gated-active-certbot-import.md
certbotbot_import_assess_archives() {
  local common_archive=${1:-} domain_archive=${2:-}
  local name=${3:-} environment=${4:-}
  local result=0 cleanup_failed=false

  # Do not discard stages that belong to another caller. This operation
  # claims both staging slots only when neither has been used.
  if (( $# != 4 )) ||
    [[ -n ${CERTBOTBOT_COMMON_STAGE:-} ||
      -n ${CERTBOTBOT_RESTORE_ROOT:-} ||
      -n ${CERTBOTBOT_RENEWAL_PREVIEW:-} ]] ||
    ! certbotbot_validate_hostname "$name" ||
    [[ $name == \*.* || $name != "${name,,}" ]] ||
    ! certbotbot_acme_validate_environment "$environment"; then
    return 64
  fi

  if certbotbot_common_restore "$common_archive"; then
    if certbotbot_restore_domain "$domain_archive" "$name"; then
      certbotbot_import_assess "$name" "$environment" || result=$?
    else
      result=$?
    fi
  else
    result=$?
  fi

  # Attempt all owned cleanups, even if an earlier operation failed. No
  # staged account, renewal preview, or domain may become ambient state for
  # a later request. Keep the original validation status when cleanup works.
  if [[ -n ${CERTBOTBOT_RENEWAL_PREVIEW:-} ]]; then
    certbotbot_renewal_preview_discard || cleanup_failed=true
  fi
  if [[ -n ${CERTBOTBOT_RESTORE_ROOT:-} ]]; then
    certbotbot_restore_discard || cleanup_failed=true
  fi
  if [[ -n ${CERTBOTBOT_COMMON_STAGE:-} ]]; then
    certbotbot_common_discard || cleanup_failed=true
  fi
  if [[ $cleanup_failed == true ]]; then
    return 73
  fi
  return "$result"
}

## @fn certbotbot_import_assess_batch()
## @brief Assess multiple requested lineages against one common archive.
## @details
## The complete requested lineage/archive list is validated before archive
## restoration begins. Duplicate lineage identities or repeated archive paths
## are rejected. One private copy of the common archive is reused across the
## sequential per-lineage assessments so a changed input path cannot silently
## select different shared account bytes midway through the batch.
##
## Each domain archive is independently copied, validated, assessed, and
## discarded by certbotbot_import_assess_archives(). The shared private copy
## is discarded before return. Success means every requested lineage passed
## non-activating assessment; it does not create an installable candidate,
## retain stage paths, or authorize Certbot or S3 access.
##
## @param common_archive Absolute pathname of the common account archive.
## @param environment production or staging ACME environment.
## @param ... One or more (canonical lineage, domain archive) argument pairs.
##
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Underlying validation and filesystem commands may issue diagnostics.
##
## @returns Nothing is written to STDOUT.
## @retval 0 Every requested lineage passed the non-activating assessment.
## @retval 64 Invalid request, unsafe files, or nonempty active configuration.
## @retval 73 Local snapshot creation, copying, or cleanup failed.
## @note Per-lineage validation may propagate further failure codes,
## including 65 for a mismatched account or ACME environment. No stages
## are left behind if the delegated per-lineage cleanup succeeds.
## @see doc/adr/ADR-019-composable-state-archives-and-consumer-boundary.md
## @see doc/adr/ADR-037-gated-active-certbot-import.md
certbotbot_import_assess_batch() {
  local common_archive=${1:-} environment=${2:-}
  local mode='' item='' snapshot='' result=0 index=0 name='' archive=''
  local -a requests=()
  local -A names=() archives=()

  # The list is a flat sequence of paired arguments, never parsed as shell
  # words. A complete syntax and identity preflight precedes any tar read.
  if (( $# < 4 || ($# - 2) % 2 != 0 )) ||
    [[ -n ${CERTBOTBOT_COMMON_STAGE:-} ||
      -n ${CERTBOTBOT_RESTORE_ROOT:-} ||
      -n ${CERTBOTBOT_RENEWAL_PREVIEW:-} ]] ||
    ! certbotbot_acme_validate_environment "$environment" ||
    [[ $environment != "${ACME_ENVIRONMENT:-production}" ||
      $common_archive != /* || ! -f $common_archive ||
      -L $common_archive || ! -O $common_archive ||
      ! -r $common_archive ||
      -z ${CERTBOTBOT_WORKSPACE_ROOT:-} ||
      -z ${CERTBOTBOT_WORKSPACE_CONFIG:-} ]]; then
    return 64
  fi

  if [[ ! -d $CERTBOTBOT_WORKSPACE_ROOT ||
    -L $CERTBOTBOT_WORKSPACE_ROOT ||
    ! -O $CERTBOTBOT_WORKSPACE_ROOT ||
    ! -d $CERTBOTBOT_WORKSPACE_CONFIG ||
    -L $CERTBOTBOT_WORKSPACE_CONFIG ||
    ! -O $CERTBOTBOT_WORKSPACE_CONFIG ]] ||
    ! mode="$(stat -c '%a' -- "$CERTBOTBOT_WORKSPACE_ROOT")" ||
    [[ $mode != 700 ]] ||
    ! mode="$(stat -c '%a' -- "$CERTBOTBOT_WORKSPACE_CONFIG")" ||
    [[ $mode != 700 ]]; then
    return 64
  fi

  # A hidden file is as important as a visible one. The active directory
  # must not already contain state belonging to another invocation.
  item="$(find -P "$CERTBOTBOT_WORKSPACE_CONFIG" \
    -mindepth 1 -print -quit)" || return 73
  [[ -z $item ]] || return 64

  shift 2
  requests=("$@")
  for (( index=0; index<${#requests[@]}; index+=2 )); do
    name=${requests[index]}
    archive=${requests[index+1]}
    if ! certbotbot_validate_hostname "$name" ||
      [[ $name == \*.* || $name != "${name,,}" ||
        $archive != /* || ! -f $archive || -L $archive ||
        ! -O $archive || ! -r $archive ||
        $archive == "$common_archive" ]] ||
      [[ -n ${names[$name]+_} || -n ${archives[$archive]+_} ]]; then
      return 64
    fi
    names["$name"]=1
    archives["$archive"]=1
  done

  # The local common snapshot is identical for every assessment in the
  # batch. No remote storage or Certbot command runs through this helper.
  snapshot="$(mktemp -- \
    "$CERTBOTBOT_WORKSPACE_ROOT/.batch-common.XXXXXXXX")" || return 73
  if ! (umask 077; cp -- "$common_archive" "$snapshot" &&
    chmod 0600 -- "$snapshot"); then
    rm -f -- "$snapshot" || return 73
    return 73
  fi

  for (( index=0; index<${#requests[@]}; index+=2 )); do
    name=${requests[index]}
    archive=${requests[index+1]}
    if certbotbot_import_assess_archives \
      "$snapshot" "$archive" "$name" "$environment"; then
      :
    else
      result=$?
      break
    fi
  done
  rm -f -- "$snapshot" || return 73
  return "$result"
}
