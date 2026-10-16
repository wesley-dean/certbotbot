# shellcheck shell=bash
## @file lib/locking.bash
## @brief Serializes cooperating producer processes on a single host.
## @details
## A stable lock name is derived from the storage bucket and endpoint, not
## from secret credentials.  flock holds an advisory lock on a private file
## descriptor until explicitly released or until the process exits.  The
## selected lock directory must belong to the caller and exclude group/other
## permissions.  This is not a distributed lock or a security boundary against
## another process already running with the same user identity.
##
## A caller must acquire the lock after input validation and before reading
## remote archive state.  Until the actual producer workflow is implemented,
## the public certbotbot entrypoint deliberately does not acquire this lock.

CERTBOTBOT_LOCK_FD=''

## @fn certbotbot_lock_acquire()
## @brief Acquires an exclusive, nonblocking lock for one storage collection.
## @param bucket Stable object-storage bucket identifier.
## @param endpoint Optional S3-compatible endpoint URL; empty for AWS defaults.
## @retval 0 This process holds the exclusive local lock.
## @retval 64 Arguments were invalid or this process already holds a lock.
## @retval 69 Required locking or hashing tooling is unavailable.
## @retval 73 The lock directory or lock file is unsafe/unusable.
## @retval 75 Another cooperating local producer holds the lock.
## @par Standard Output
## Nothing is written to STDOUT.
## @par Standard Error
## A nonsecret diagnostic on failure.
## @note Lock contention never falls back to proceeding without a lock.
certbotbot_lock_acquire() {
  local bucket=${1:-} endpoint=${2:-}
  local root digest mode fd path old_umask
  local -a digest_args=()

  if (( $# != 2 )) || [[ -z ${bucket} || -n ${CERTBOTBOT_LOCK_FD} ]]; then
    printf '%s\n' 'invalid or repeated local lock request' >&2
    return 64
  fi
  if ! command -v flock >/dev/null 2>&1; then
    printf '%s\n' 'flock is required for local producer serialization' >&2
    return 69
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    digest_args=(sha256sum)
  elif command -v shasum >/dev/null 2>&1; then
    digest_args=(shasum -a 256)
  else
    printf '%s\n' 'a SHA-256 tool is required for local producer serialization' >&2
    return 69
  fi

  if ! digest="$(printf '%s\0%s\0' "${bucket}" "${endpoint}" |
    "${digest_args[@]}")"; then
    printf '%s\n' 'cannot identify the local storage collection' >&2
    return 73
  fi
  digest=${digest%% *}

  root=${CERTBOTBOT_LOCK_DIR:-}
  if [[ -z ${root} && -n ${XDG_RUNTIME_DIR:-} ]]; then
    root="${XDG_RUNTIME_DIR}/certbotbot/locks"
  elif [[ -z ${root} && -n ${HOME:-} ]]; then
    root="${HOME}/.cache/certbotbot/locks"
  fi
  if [[ -z ${root} || ${root} != /* || -L ${root} ]]; then
    printf '%s\n' 'local lock directory must be an absolute non-symlink path' >&2
    return 73
  fi

  # Private umask applies to new parent directories and the lockfile only.
  old_umask="$(umask)"
  umask 077
  if ! mkdir -p -- "${root}"; then
    umask "${old_umask}"
    printf '%s\n' 'cannot create local lock directory' >&2
    return 73
  fi
  umask "${old_umask}"

  if [[ ! -d ${root} || -L ${root} || ! -O ${root} ]]; then
    printf '%s\n' 'local lock directory is not owned by the caller' >&2
    return 73
  fi
  if ! mode="$(stat -c '%a' -- "${root}")" ||
    [[ ! "${mode}" =~ ^[0-7]{3,4}$ ]] ||
    (( (8#${mode} & 8#77) != 0 )); then
    printf '%s\n' 'local lock directory allows group/other access' >&2
    return 73
  fi

  path="${root}/${digest}.lock"
  if [[ -e "${path}" || -L "${path}" ]]; then
    if [[ ! -f "${path}" || -L "${path}" || ! -O "${path}" ]]; then
      printf '%s\n' 'local lock file is not an owned regular file' >&2
      return 73
    fi
  fi

  old_umask="$(umask)"
  umask 077
  if ! exec {fd}>>"${path}"; then
    umask "${old_umask}"
    printf '%s\n' 'cannot open local lock file' >&2
    return 73
  fi
  umask "${old_umask}"

  if ! flock -n "${fd}"; then
    exec {fd}>&-
    printf '%s\n' 'another local producer holds the storage lock' >&2
    return 75
  fi

  CERTBOTBOT_LOCK_FD=${fd}
  return 0
}

## @fn certbotbot_lock_release()
## @brief Releases the local advisory lock held by this Bash process.
## @retval 0 No lock was held, or the held lock was released.
## @retval 73 The advisory unlock failed; the descriptor remains held.
## @par Standard Output
## Nothing is written to STDOUT.
## @note The caller owns normal-exit and signal cleanup; process termination
## closes file descriptors even when an explicit cleanup trap cannot run.
certbotbot_lock_release() {
  local fd=${CERTBOTBOT_LOCK_FD}
  if [[ -z ${fd} ]]; then
    return 0
  fi
  if ! flock -u "${fd}"; then
    return 73
  fi
  exec {fd}>&-
  CERTBOTBOT_LOCK_FD=''
}
