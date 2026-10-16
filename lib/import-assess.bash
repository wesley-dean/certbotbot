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
  certbotbot_renewal_path_preview "$name" "$environment" || return $?

  # The preflight is deliberately non-activating. Never leave a path preview
  # behind to be accidentally used by another part of this process.
  if ! certbotbot_renewal_preview_discard; then
    result=73
  fi
  return "$result"
}
