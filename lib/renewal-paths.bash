# shellcheck shell=bash
## @file lib/renewal-paths.bash
## @brief Prepares a private, validated renewal-path preview for another node.
## @details
## This module runs only after the read-only account/environment identity
## check from ADR-031 succeeds.  It requires all five persisted Certbot path
## fields to identify the same lineage and the same former absolute root.
## It emits a new, owner-private copy targeting the current workspace;
## original restored archive contents are not changed.
##
## The preview is NOT installed or passed to Certbot.  Certbot explicitly
## cautions that renewal file edits can break renewal.  Real Certbot tests
## on separate producer workspaces remain a mandatory release gate.
## @see doc/adr/ADR-032-validated-renewal-path-preview.md

CERTBOTBOT_RENEWAL_PREVIEW=''

## @fn certbotbot_renewal_preview_discard()
## @brief Deletes only this process's known private renewal-path preview.
## @retval 0 No preview existed or the recorded file was removed.
## @retval 73 Unsafe recorded pathname or filesystem removal failure.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_renewal_preview_discard() {
  local path=${CERTBOTBOT_RENEWAL_PREVIEW:-}
  if [[ -z $path ]]; then
    return 0
  fi
  if [[ -z ${CERTBOTBOT_WORKSPACE_ROOT:-} ||
    $path != "$CERTBOTBOT_WORKSPACE_ROOT"/renewal.???????? ||
    ! -f $path || -L $path || ! -O $path ]]; then
    return 73
  fi
  rm -f -- "$path" || return 73
  CERTBOTBOT_RENEWAL_PREVIEW=''
}

## @fn certbotbot_renewal_path_preview()
## @brief Rebase the five validated lineage paths into a private copy.
## @param name Canonical lineage identity.
## @param environment production or staging, matching the current invocation.
## @retval 0 The private preview path is in CERTBOTBOT_RENEWAL_PREVIEW.
## @retval 64 Invalid or inconsistent renewal metadata or unsafe workspace.
## @retval 65 Restored account identity mismatch.
## @retval 73 Filesystem error while preparing the private preview.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @note The preview does not become Certbot configuration until a future
## integration proves it works against supported real Certbot releases.
certbotbot_renewal_path_preview() {
  local LC_ALL=C
  local name=${1:-} environment=${2:-} source='' target='' output=''
  local line='' item='' section='' key='' value='' old_root='' mode=''
  local count=0
  local -a keys=(archive_dir cert chain fullchain privkey)
  local -A old=() seen=()
  if (( $# != 2 )) || [[ -n ${CERTBOTBOT_RENEWAL_PREVIEW:-} ]] ||
    ! certbotbot_validate_hostname "$name" ||
    [[ $name == \*.* || $name != "${name,,}" ||
      -z ${CERTBOTBOT_WORKSPACE_ROOT:-} ||
      -z ${CERTBOTBOT_WORKSPACE_CONFIG:-} ]]; then
    return 64
  fi
  certbotbot_state_verify_identity "$CERTBOTBOT_COMMON_STAGE" \
    "$CERTBOTBOT_RESTORE_ROOT" "$name" "$environment" || return $?
  target=$CERTBOTBOT_WORKSPACE_CONFIG
  if [[ $target != /* || ! -d $target || -L $target || ! -O $target ]]; then
    return 64
  fi
  mode="$(stat -c '%a' -- "$target")" || return 73
  if [[ $mode != 700 ]]; then
    return 64
  fi
  source="$CERTBOTBOT_RESTORE_ROOT/renewal/$name.conf"
  while IFS= read -r line || [[ -n $line ]]; do
    (( count += 1 ))
    if (( count > 4096 )) || [[ $line == *$'\r'* ]]; then
      return 64
    fi
    item=${line#"${line%%[![:space:]]*}"}
    if [[ -z $item ]]; then
      continue
    fi
    if [[ $item =~ ^\[([a-z_]+)\][[:space:]]*$ ]]; then
      section=${BASH_REMATCH[1]}
      continue
    fi
    # ADR-031 has already rejected malformed lines and hooks.  This
    # additional pass authorizes ONLY the five path-bearing top-level keys.
    if [[ $item =~ ^([a-z_][a-z_0-9]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key=${BASH_REMATCH[1]}
      value=${BASH_REMATCH[2]}
      value=${value%"${value##*[![:space:]]}"}
      if [[ -z $section ]]; then
        case "$key" in
          archive_dir | cert | chain | fullchain | privkey)
            if [[ -n ${seen[$key]+_} ]]; then
              return 64
            fi
            seen["$key"]=1
            old["$key"]=$value
            ;;
          version | renew_before_expiry) ;;
          *) return 64 ;;
        esac
      else
        case "$key" in
          archive_dir | cert | chain | fullchain | privkey | config_dir | work_dir | logs_dir)
            return 64
            ;;
        esac
      fi
    fi
  done <"$source"
  for key in "${keys[@]}"; do
    if [[ -z ${old[$key]+_} ]]; then
      return 64
    fi
  done
  value=${old[archive_dir]}
  old_root=${value%"/archive/$name"}
  if [[ $old_root == "$value" || $old_root != /* || $old_root == / ||
    $old_root == *'//'* || $old_root == *'/./'* ||
    $old_root == *'/../'* || $old_root == *'/.' ||
    $old_root == *'/..' || $old_root == */ ]]; then
    return 64
  fi
  if [[ ${old[archive_dir]} != "$old_root/archive/$name" ||
    ${old[cert]} != "$old_root/live/$name/cert.pem" ||
    ${old[chain]} != "$old_root/live/$name/chain.pem" ||
    ${old[fullchain]} != "$old_root/live/$name/fullchain.pem" ||
    ${old[privkey]} != "$old_root/live/$name/privkey.pem" ]]; then
    return 64
  fi
  output="$(mktemp -- "$CERTBOTBOT_WORKSPACE_ROOT/renewal.XXXXXXXX")" ||
    return 73
  chmod 0600 -- "$output" || { rm -f -- "$output"; return 73; }
  section=''
  while IFS= read -r line || [[ -n $line ]]; do
    item=${line#"${line%%[![:space:]]*}"}
    if [[ $item =~ ^\[([a-z_]+)\][[:space:]]*$ ]]; then
      section=${BASH_REMATCH[1]}
    fi
    if [[ -z $section ]] &&
      [[ $item =~ ^([a-z_][a-z_0-9]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key=${BASH_REMATCH[1]}
      case "$key" in
        archive_dir) line="archive_dir = $target/archive/$name" ;;
        cert | chain | fullchain | privkey)
          line="$key = $target/live/$name/$key.pem"
          ;;
      esac
    fi
    if ! printf '%s\n' "$line" >>"$output"; then
      rm -f -- "$output"
      return 73
    fi
  done <"$source"
  CERTBOTBOT_RENEWAL_PREVIEW=$output
  return 0
}
