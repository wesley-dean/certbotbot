# shellcheck shell=bash
## @file lib/account-archive.bash
## @brief Stages narrowly scoped ACME account archives without installing them.
## @details
## Only Let's Encrypt ACME v2 production/staging account directories and
## meta.json, regr.json, private_key.json are permitted.  No symlinks, hooks,
## unrelated config, or certificate lineages may occur in a common archive.
## Archives are copied to a private workspace before validation/extraction,
## and every actual extracted entry is inspected again.  This is not account
## selection, JSON verification, or activation of certificate issuance.
## @see doc/adr/ADR-028-isolated-common-acme-account-state.md

CERTBOTBOT_COMMON_STAGE=''

## @fn certbotbot_common_member()
## @brief Checks a relative common-state path and GNU find/tar entry type.
## @param path Relative account path.
## @param type d for directory or f for ordinary file.
## @retval 0 Entry fits the first-release account-only allowlist.
## @retval 64 Entry type or pathname is unsupported.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_common_member() {
  local path=${1:-} type=${2:-}
  local server='(acme-v02[.]api[.]letsencrypt[.]org|acme-staging-v02[.]api[.]letsencrypt[.]org)'
  local ident='[a-f0-9]{32,64}'
  if (( $# != 2 )) || [[ ! $path =~ ^[a-z0-9./_-]+$ ||
    $path == /* || $path == ./* || $path == *../* ||
    $path == *'/./'* ]]; then
    return 64
  fi
  if [[ $type == d ]]; then
    [[ $path == accounts/ ||
      $path =~ ^accounts/$server/$ ||
      $path =~ ^accounts/$server/directory/$ ||
      $path =~ ^accounts/$server/directory/$ident/$ ]]
  elif [[ $type == f ]]; then
    [[ $path =~ ^accounts/$server/directory/$ident/(meta|regr|private_key)[.]json$ ]]
  else
    return 64
  fi
}

## @fn certbotbot_common_complete()
## @brief Requires a complete account triplet for each referenced account.
## @param inventory Inventory file with one accepted account filename per line.
## @retval 0 At least one and at most 16 complete accounts were found.
## @retval 64 Account records were incomplete or too numerous.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_common_complete() {
  local inventory=${1:-} path id file
  local -A accounts=() files=()
  while IFS= read -r path || [[ -n $path ]]; do
    [[ -n $path ]] || continue
    id=${path%/*}
    file=${path##*/}
    accounts["$id"]=1
    files["$id/$file"]=1
  done <"$inventory"
  if (( ${#accounts[@]} < 1 || ${#accounts[@]} > 16 )); then
    return 64
  fi
  for id in "${!accounts[@]}"; do
    for file in meta.json regr.json private_key.json; do
      [[ -n ${files["$id/$file"]+_} ]] || return 64
    done
  done
}

## @fn certbotbot_common_validate()
## @brief Inspects compressed common-state tar metadata without extraction.
## @param archive Absolute owned compressed tar file.
## @retval 0 Only complete, private ACME v2 accounts were declared.
## @retval 64 Invalid metadata, paths, accounts, limits, or modes.
## @retval 69 GNU tar listing failed.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_common_validate() {
  local LC_ALL=C
  local archive=${1:-} listing compressed line mode size_text size path type
  local count=0 total=0 inventory status
  local -A seen=()
  if (( $# != 1 )) || [[ $archive != /* || ! -f $archive ||
    -L $archive || ! -O $archive || ! -r $archive ]]; then
    return 64
  fi
  if ! compressed="$(stat -c '%s' -- "$archive")" ||
    [[ ! $compressed =~ ^[0-9]{1,8}$ ]] ||
    (( compressed > 16777216 )); then
    return 64
  fi
  if ! listing="$(set -o pipefail; tar --list --gzip --verbose \
    --file "$archive" --full-time --numeric-owner \
    --quoting-style=escape | head -c 524288)"; then
    return 69
  fi
  [[ -n $listing ]] || return 64
  inventory="$(mktemp)" || return 73
  status=0
  while IFS= read -r line || [[ -n $line ]]; do
    (( count += 1 ))
    if (( count > 256 )) ||
      [[ ! $line =~ ^([d-][rwxstST-]{9})[[:space:]]+[0-9]+/[0-9]+[[:space:]]+([0-9]+)[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]]+(.+)$ ]]; then
      status=64
      break
    fi
    mode=${BASH_REMATCH[1]}
    size_text=${BASH_REMATCH[2]}
    path=${BASH_REMATCH[3]}
    type=${mode:0:1}
    if [[ $type == - ]]; then
      type=f
    fi
    if [[ ! $size_text =~ ^[0-9]{1,7}$ ]] ||
      ! certbotbot_common_member "$path" "$type" ||
      [[ -n ${seen[$path]+_} || ${mode:4:6} != ------ ]]; then
      status=64
      break
    fi
    seen["$path"]=1
    size=$((10#$size_text))
    total=$((total + size))
    if (( size > 1048576 || total > 8388608 )) ||
      { [[ $type == d ]] && (( size != 0 )); } ||
      { [[ $type == - ]] && (( size == 0 )); }; then
      status=64
      break
    fi
    if [[ $type == f ]]; then
      printf '%s\n' "$path" >>"$inventory"
    fi
  done <<< "$listing"
  if (( status == 0 )); then
    certbotbot_common_complete "$inventory" || status=64
  fi
  rm -f -- "$inventory"
  return "$status"
}

## @fn certbotbot_common_inspect()
## @brief Independently checks files restored into the private staging tree.
## @param root Private fresh extraction directory.
## @retval 0 Observed regular files and directories form complete accounts.
## @retval 64 Unsafe entries, modes, or missing files.
## @retval 73 Filesystem enumeration failed.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_common_inspect() {
  local root=${1:-} manifest inventory item type mode path count=0 status=0
  if (( $# != 1 )) || [[ $root != /* || ! -d $root ||
    -L $root || ! -O $root ]]; then
    return 64
  fi
  mode="$(stat -c '%a' -- "$root")" || return 73
  [[ $mode == 700 ]] || return 64
  manifest="$(mktemp -- "$CERTBOTBOT_WORKSPACE_ROOT/.common-list.XXXXXXXX")" ||
    return 73
  inventory="$(mktemp -- "$CERTBOTBOT_WORKSPACE_ROOT/.common-files.XXXXXXXX")" ||
    { rm -f -- "$manifest"; return 73; }
  if ! find -P "$root" -mindepth 1 -printf '%P\0%y\0' >"$manifest"; then
    rm -f -- "$manifest" "$inventory"
    return 73
  fi
  while IFS= read -r -d '' item && IFS= read -r -d '' type; do
    (( count += 1 ))
    # find omits the directory's trailing slash; tar listings retain it.
    # Preserve one canonical directory representation at the policy boundary.
    local member="$item"
    if [[ $type == d ]]; then
      member="${item}/"
    fi
    if (( count > 256 )) ||
      ! certbotbot_common_member "$member" "$type"; then
      status=64
      break
    fi
    path="$root/$item"
    if [[ ! -O $path || -L $path ]]; then
      status=64
      break
    fi
    mode="$(stat -c '%a' -- "$path")" || { status=73; break; }
    if [[ ! $mode =~ ^[0-7]{3,4}$ ]] ||
      (( (8#$mode & 8#77) != 0 )); then
      status=64
      break
    fi
    if [[ $type == f ]]; then
      if [[ ! -s $path ]]; then
        status=64
        break
      fi
      printf '%s\n' "$item" >>"$inventory"
    fi
  done <"$manifest"
  if (( status == 0 )); then
    certbotbot_common_complete "$inventory" || status=64
  fi
  rm -f -- "$manifest" "$inventory"
  return "$status"
}

## @fn certbotbot_common_discard()
## @brief Disposes only the recorded private account staging directory.
## @retval 0 No account stage exists or its removal succeeded.
## @retval 73 Recorded staging target is unsafe or could not be removed.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_common_discard() {
  local target=$CERTBOTBOT_COMMON_STAGE mode
  if [[ -z $target ]]; then
    return 0
  fi
  if [[ -z $CERTBOTBOT_WORKSPACE_ROOT ||
    $target != "$CERTBOTBOT_WORKSPACE_ROOT"/account.* ||
    ! ${target##*/} =~ ^account[.][a-zA-Z0-9]{8}$ ||
    ! -d $target || -L $target || ! -O $target ]]; then
    return 73
  fi
  mode="$(stat -c '%a' -- "$target")" || return 73
  [[ $mode == 700 ]] || return 73
  rm -rf -- "$target" || return 73
  CERTBOTBOT_COMMON_STAGE=''
}

## @fn certbotbot_common_restore()
## @brief Copies, validates, and isolates one common ACME account archive.
## @param archive Absolute owned readable compressed common tar file.
## @retval 0 An accepted private tree is in CERTBOTBOT_COMMON_STAGE.
## @retval 64 Invalid input, archive layout, or extracted account state.
## @retval 73 Local staging or extraction failed.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @note This never selects an account or modifies active Certbot config.
certbotbot_common_restore() {
  local archive=${1:-} copy='' stage='' mode result=0
  if (( $# != 1 )) || [[ -n $CERTBOTBOT_COMMON_STAGE ||
    -z $CERTBOTBOT_WORKSPACE_ROOT ||
    ! -d $CERTBOTBOT_WORKSPACE_ROOT || -L $CERTBOTBOT_WORKSPACE_ROOT ||
    ! -O $CERTBOTBOT_WORKSPACE_ROOT ||
    $archive != /* || ! -f $archive || -L $archive ||
    ! -O $archive || ! -r $archive ]]; then
    return 64
  fi
  mode="$(stat -c '%a' -- "$CERTBOTBOT_WORKSPACE_ROOT")" || return 73
  [[ $mode == 700 ]] || return 64
  copy="$(mktemp -- "$CERTBOTBOT_WORKSPACE_ROOT/.common.XXXXXXXX")" ||
    return 73
  if ! (umask 077; cp -- "$archive" "$copy" && chmod 0600 -- "$copy"); then
    rm -f -- "$copy"
    return 73
  fi
  if ! certbotbot_common_validate "$copy"; then
    rm -f -- "$copy"
    return 64
  fi
  stage="$(mktemp -d -- "$CERTBOTBOT_WORKSPACE_ROOT/account.XXXXXXXX")" ||
    { rm -f -- "$copy"; return 73; }
  if ! (umask 077; tar --extract --gzip --file "$copy" \
    --directory "$stage" --no-same-owner --no-same-permissions \
    --no-overwrite-dir --delay-directory-restore); then
    result=73
  elif ! certbotbot_common_inspect "$stage"; then
    result=64
  fi
  rm -f -- "$copy"
  if (( result != 0 )); then
    rm -rf -- "$stage"
    return "$result"
  fi
  CERTBOTBOT_COMMON_STAGE=$stage
  return 0
}
