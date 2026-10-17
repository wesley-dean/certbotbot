# shellcheck shell=bash
## @file lib/gpg-archives.bash
## @brief Prepares and opens private AES-256 encrypted archive files.
## @details
## The GPG passphrase is conveyed only through standard input to GPG's
## --passphrase-fd 0 option. It never appears in an argv element or a
## diagnostic. The child GPG environment does not retain GPG_PASSPHRASE.
## Every invocation uses a disposable private GNUPG home so it never
## modifies a runner's long-lived keyrings or agent state.
##
## The helper is strictly local: it does not fetch, upload, validate tar
## members, or enable issuance. ADR-021 governs collection-wide modes and
## the prohibition on automatic plaintext fallback.
## @see doc/adr/ADR-021-optional-symmetric-encryption-and-migration.md

## @fn certbotbot_gpg_transform()
## @brief Encrypt or decrypt one private archive file in the current workspace.
## @details
## The output must be a newly created, empty, owner-only ordinary file;
## the source must also be a private, owned regular file. Both files
## must reside under the current producer workspace, with canonical
## existing parent directories. The caller owns the output after success
## and must discard it after use.
## @param action Either encrypt or decrypt.
## @param input Absolute private input pathname inside the workspace.
## @param output Absolute private, initially empty output pathname.
## @retval 0 GPG completed and produced a nonempty mode-0600 file.
## @retval 64 Invalid input, workspace, passphrase, or enabled xtrace.
## @retval 65 GPG failed to encrypt/decrypt or produced invalid empty output.
## @retval 69 GPG executable is unavailable.
## @retval 73 Private temporary homedir or output cleanup failed.
## @par STDIN
## Nothing is read from the caller's STDIN; the passphrase reaches GPG
## via a dedicated pipeline created by this function.
## @returns Nothing is written to STDOUT.
## @note GPG diagnostics and secret-bearing args are never logged.
## @note Cleanup is not cryptographic erasure of secret material.
certbotbot_gpg_transform() {
  local action=${1:-} input=${2:-} output=${3:-}
  local root=${CERTBOTBOT_WORKSPACE_ROOT:-} pass='' home=''
  local input_parent='' output_parent='' mode='' result=0
  local -a operation=()

  # Never read a passphrase while shell tracing is enabled; xtrace would
  # otherwise reveal expansions of secret shell variables.
  if [[ $- == *x* ]] || (( $# != 3 )) || [[ -z $root ]]; then
    return 64
  fi
  pass=${GPG_PASSPHRASE:-}
  if [[ -z $pass || $pass == *$'\n'* || $pass == *$'\r'* ]] ||
    [[ $root != /* || ! -d $root || -L $root || ! -O $root ||
      $input != "$root"/* || $output != "$root"/* ||
      $input == *'/../'* || $output == *'/../'* ||
      $input == *'/./'* || $output == *'/./'* ||
      $input == *'//'* || $output == *'//'* ||
      $input == "$output" || $input == */.. || $output == */.. ||
      $input == */. || $output == */. ||
      ! -f $input || -L $input || ! -O $input || ! -s $input ||
      ! -f $output || -L $output || ! -O $output || -s $output ||
      $input -ef $output ]]; then
    return 64
  fi
  case "$action" in
    encrypt) operation=(--symmetric --cipher-algo AES256) ;;
    decrypt) operation=(--decrypt) ;;
    *) return 64 ;;
  esac

  mode="$(stat -c '%a' -- "$root")" || return 73
  [[ $mode == 700 ]] || return 64
  for input_parent in "$input" "$output"; do
    mode="$(stat -c '%a' -- "$input_parent")" || return 73
    [[ $mode == 600 ]] || return 64
  done
  input_parent="$(realpath -e -- "$(dirname -- "$input")")" || return 73
  output_parent="$(realpath -e -- "$(dirname -- "$output")")" || return 73
  if [[ $input_parent != "$root" && $input_parent != "$root"/* ]] ||
    [[ $output_parent != "$root" && $output_parent != "$root"/* ]]; then
    return 64
  fi
  if ! command -v gpg >/dev/null 2>&1; then
    return 69
  fi

  home="$(mktemp -d -- "$root/.gpg.XXXXXXXX")" || return 73
  # No global agent/keyring state and no GPG stdout, stderr, or shell tracing.
  # env -u strips the passphrase from GPG's inherited environment.
  # GPG is the final pipeline process and its exit status is the
  # authoritative transform result. Avoid a subshell-wrapped pipeline:
  # the pinned Bash-Minifier does not preserve that syntax reliably.
  if printf '%s\n' "$pass" |
    env -u GPG_PASSPHRASE gpg --homedir "$home" --no-options \
      --batch --yes --quiet --no-tty --pinentry-mode loopback \
      --passphrase-fd 0 --no-symkey-cache "${operation[@]}" \
      --output "$output" -- "$input" >/dev/null 2>&1; then
    if [[ ! -s $output || -L $output || ! -f $output ]]; then
      result=65
    fi
  else
    result=65
  fi
  rm -rf -- "$home" || return 73
  if (( result != 0 )); then
    : >"$output" || return 73
  fi
  return "$result"
}

## @fn certbotbot_gpg_encrypt_archive()
## @brief Symmetrically encrypt one prepared private archive with AES-256.
## @param input Existing private plaintext archive.
## @param output Empty private ciphertext output file.
## @retval 0 AES-256 ciphertext was prepared for later publication.
## @note Other statuses propagate from certbotbot_gpg_transform().
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_gpg_encrypt_archive() {
  (( $# == 2 )) || return 64
  certbotbot_gpg_transform encrypt "$1" "$2"
}

## @fn certbotbot_gpg_decrypt_archive()
## @brief Decrypt one private downloaded ciphertext into a private archive.
## @param input Existing encrypted archive bytes in the private workspace.
## @param output Empty private plaintext output file.
## @retval 0 A private plaintext archive was prepared for validation.
## @note Other statuses propagate from certbotbot_gpg_transform().
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_gpg_decrypt_archive() {
  (( $# == 2 )) || return 64
  certbotbot_gpg_transform decrypt "$1" "$2"
}
