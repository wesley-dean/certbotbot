#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/restore.bash
## @brief Creates private workspaces and stages validated Certbot archives.
## @details
## This adapter implements the inactive restoration boundary in ADR-022.
## It never extracts into the host's /etc/letsencrypt directory, evaluates
## restored content, calls Certbot, or accesses S3. A preflighted archive is
## copied into a new private staging directory before GNU tar sees its bytes.
## The orchestrator owns removal of the workspace after the full operation.

## @fn certbotbot_workspace_create()
## @brief Creates a new owned 0700 workspace on the local filesystem.
## @details
## A fresh directory is allocated using mktemp, with a private umask.
## Ownership and final lifecycle cleanup belong to the invoking process.
## This helper does not delete any previously created workspace.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## One absolute workspace pathname followed by a newline on success.
## @par STDERR
## A fixed diagnostic on failure.
## @returns An absolute pathname to one new private workspace.
## @retval 0 The private workspace was created.
## @retval 74 A private workspace could not be allocated.
## @par Examples
## @code
## workspace="$(certbotbot_workspace_create)" || exit $?
## # The caller must delete only its owned workspace when finished.
## @endcode
certbotbot_workspace_create() {
  local workspace
  workspace="$(umask 077; mktemp -d)" || {
    printf '%s\n' 'certbotbot: private workspace unavailable' >&2
    return 74
  }
  if [[ "$workspace" != /* || ! -O "$workspace" ||
    "$(stat -c %a -- "$workspace" 2>/dev/null)" != 700 ]]; then
    rm -rf -- "$workspace"
    printf '%s\n' 'certbotbot: private workspace unavailable' >&2
    return 74
  fi
  printf '%s\n' "$workspace"
}

## @fn certbotbot_archive_restore()
## @brief Restores supported archive bytes into an inactive config directory.
## @details
## Accepts an owned, canonical, empty-target workspace with mode 0700.
## Copies the archive into a fresh 0700 child, validates that precise copy
## before extraction, and extracts it under an inactive staging root using
## GNU tar without stored owners or unmasked permissions. On success, a
## rename installs the staging directory at WORKSPACE/config; on any error
## only adapter-owned staging is removed. The workspace and unrelated files
## are preserved. No secret data or untrusted tar error text is printed.
##
## The format validator accepts only constrained member types and links.
## The extractor confirms the resulting filesystem contains only regular
## files, directories, and resolvable symlinks, and no group/world-writable
## data. Caller must still verify registered ACME account and renewal
## configuration (including execution hooks and path remapping).
## @param archive Readable non-symlink archive path.
## @param workspace Canonical new absolute directory, owned and mode 0700.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed safe diagnostics; tar output is suppressed.
## @returns Nothing is written to STDOUT.
## @retval 0 An isolated WORKSPACE/config directory was prepared.
## @retval 64 Invalid workspace, arguments, or existing target.
## @retval 65 Archive failed format or post-extraction checks.
## @retval 74 Local extraction or staging failed.
## @par Examples
## @code
## certbotbot_archive_restore "$workspace/downloaded.tar.gz" "$workspace" ||
##   exit $?
## # Verify account, hooks, and canonical renewal path mapping next.
## @endcode
certbotbot_archive_restore() {
  local archive workspace physical temp staged root bad
  if (( $# != 2 )); then
    printf '%s\n' 'certbotbot: invalid archive restoration arguments' >&2
    return 64
  fi
  archive="$1"
  workspace="$2"
  if [[ "$workspace" != /* || "$workspace" == / || ! -d "$workspace" ||
    -L "$workspace" || ! -O "$workspace" || ! -f "$archive" ||
    -L "$archive" || ! -r "$archive" ]]; then
    printf '%s\n' 'certbotbot: invalid private workspace or archive' >&2
    return 64
  fi
  physical="$(cd -P -- "$workspace" && pwd -P)" || {
    printf '%s\n' 'certbotbot: invalid private workspace' >&2
    return 64
  }
  if [[ "$physical" != "$workspace" ||
    "$(stat -c %a -- "$workspace" 2>/dev/null)" != 700 ||
    -e "$workspace/config" || -L "$workspace/config" ]]; then
    printf '%s\n' 'certbotbot: unsafe or occupied private workspace' >&2
    return 64
  fi
  if ! command -v tar >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: GNU tar unavailable' >&2
    return 74
  fi

  temp="$(umask 077; mktemp -d "$workspace/restore.XXXXXXXX")" || {
    printf '%s\n' 'certbotbot: private restoration staging failed' >&2
    return 74
  }
  staged="$temp/seeded.tar.gz"
  root="$temp/staging"
  if ! (umask 077; cp -- "$archive" "$staged" &&
    chmod 600 -- "$staged" && mkdir -m 700 -- "$root"); then
    rm -rf -- "$temp"
    printf '%s\n' 'certbotbot: private restoration staging failed' >&2
    return 74
  fi

  if ! certbotbot_archive_validate "$staged" >/dev/null 2>&1; then
    rm -rf -- "$temp"
    printf '%s\n' 'certbotbot: archive rejected before extraction' >&2
    return 65
  fi
  if ! (umask 077; tar --extract --gzip --file "$staged" \
    --directory "$root" --no-same-owner --no-same-permissions \
    --no-overwrite-dir >/dev/null 2>&1); then
    rm -rf -- "$temp"
    printf '%s\n' 'certbotbot: isolated archive extraction failed' >&2
    return 74
  fi

  if ! chmod 700 -- "$root"; then
    rm -rf -- "$temp"
    printf '%s\n' 'certbotbot: restored directory is unusable' >&2
    return 74
  fi
  bad="$(find "$root" -mindepth 1 ! -type d ! -type f ! -type l \
    -print -quit 2>/dev/null)" || bad='invalid'
  if [[ -z "$bad" ]]; then
    bad="$(find "$root" -type f -perm /022 -print -quit 2>/dev/null)" ||
      bad='invalid'
  fi
  if [[ -z "$bad" ]]; then
    bad="$(find "$root" -type d -perm /022 -print -quit 2>/dev/null)" ||
      bad='invalid'
  fi
  if [[ -z "$bad" ]]; then
    bad="$(find "$root" -type l ! -exec test -e {} \; -print -quit \
      2>/dev/null)" || bad='invalid'
  fi
  if [[ -n "$bad" ]]; then
    rm -rf -- "$temp"
    printf '%s\n' 'certbotbot: unsafe restored filesystem state' >&2
    return 65
  fi

  if [[ -e "$workspace/config" || -L "$workspace/config" ]] ||
    ! mv -T -- "$root" "$workspace/config"; then
    rm -rf -- "$temp"
    printf '%s\n' 'certbotbot: cannot install isolated configuration' >&2
    return 74
  fi
  rm -rf -- "$temp"
  return 0
}
