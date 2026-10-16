# shellcheck shell=bash
## @file lib/workspace.bash
## @brief Creates and removes isolated, private Certbot producer workspaces.
## @details
## Certbot account and key material must never be staged in a shared working
## directory.  Each invocation owns one mktemp-created directory and three
## private child directories (config, work, logs).  Only this process's exact
## recorded directory may be removed.  Lifecycle callbacks and traps belong
## to the future producer orchestrator, not to an imported runtime library.
##
## The temporary parent is selected from CERTBOTBOT_TMPDIR, TMPDIR, or /tmp.
## It must exist, be absolute, and not itself be a symlink.  This protection
## does not make a compromised producer user account or insecure parent safe.
## @see doc/adr/ADR-022-execution-serialization-and-publishing.md
## @see doc/adr/ADR-025-certbot-state-portability-and-issuance-boundary.md

CERTBOTBOT_WORKSPACE_ROOT=''
CERTBOTBOT_WORKSPACE_CONFIG=''
CERTBOTBOT_WORKSPACE_WORK=''
CERTBOTBOT_WORKSPACE_LOGS=''

## @fn certbotbot_workspace_create()
## @brief Creates a fresh private workspace with dedicated Certbot directories.
## @retval 0 Workspace directory paths were exported as Bash variables.
## @retval 64 A workspace already exists or the temp parent is invalid.
## @retval 73 Temporary directory creation or privacy verification failed.
## @par Standard Output
## Nothing is written to STDOUT.
## @note The caller must call certbotbot_workspace_destroy on normal exit
## and arrange cleanup traps for signals after successful creation.
certbotbot_workspace_create() {
  local parent=${CERTBOTBOT_TMPDIR:-${TMPDIR:-/tmp}} root mode
  if [[ -n ${CERTBOTBOT_WORKSPACE_ROOT} ]] ||
    [[ ${parent} != /* || ! -d ${parent} || -L ${parent} ]]; then
    return 64
  fi

  if ! root="$(mktemp -d -- "${parent%/}/certbotbot.XXXXXXXX")"; then
    return 73
  fi

  if [[ ! -d ${root} || -L ${root} || ! -O ${root} ]] ||
    ! mode="$(stat -c '%a' -- "${root}")" ||
    [[ ${mode} != 700 ]]; then
    # Remove only the directory just created with our fixed basename.
    rm -rf -- "${root}"
    return 73
  fi

  if ! mkdir -m 0700 -- "${root}/config" "${root}/work" "${root}/logs"; then
    rm -rf -- "${root}"
    return 73
  fi

  CERTBOTBOT_WORKSPACE_ROOT=${root}
  CERTBOTBOT_WORKSPACE_CONFIG="${root}/config"
  CERTBOTBOT_WORKSPACE_WORK="${root}/work"
  CERTBOTBOT_WORKSPACE_LOGS="${root}/logs"
}

## @fn certbotbot_workspace_destroy()
## @brief Removes only the currently recorded private workspace.
## @retval 0 No workspace existed, or its exact directory was removed.
## @retval 73 Recorded workspace is not a safe owned private directory,
## or removal failed.
## @par Standard Output
## Nothing is written to STDOUT.
## @note This is ordinary filesystem cleanup, not secure erasure of secrets
## from swap, backups, storage snapshots, or forensic copies.
certbotbot_workspace_destroy() {
  local root=${CERTBOTBOT_WORKSPACE_ROOT} mode
  if [[ -z ${root} ]]; then
    return 0
  fi
  if [[ ${root} != /* || ! "${root##*/}" =~ ^certbotbot[.][a-zA-Z0-9]{8}$ ]] ||
    [[ ! -d ${root} || -L ${root} || ! -O ${root} ]] ||
    ! mode="$(stat -c '%a' -- "${root}")" ||
    [[ ${mode} != 700 ]]; then
    return 73
  fi
  if ! rm -rf -- "${root}"; then
    return 73
  fi
  CERTBOTBOT_WORKSPACE_ROOT=''
  # These caller-facing paths are consumed after standalone artifact assembly.
  # shellcheck disable=SC2034
  CERTBOTBOT_WORKSPACE_CONFIG=''
  # shellcheck disable=SC2034
  CERTBOTBOT_WORKSPACE_WORK=''
  # shellcheck disable=SC2034
  CERTBOTBOT_WORKSPACE_LOGS=''
}
