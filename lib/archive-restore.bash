# shellcheck shell=bash
## @file lib/archive-restore.bash
## @brief Restores one domain archive to private staging, never active state.
## @details
## This module requires an existing certbotbot private workspace.  It copies
## the archive into that workspace, validates the private copy under ADR-026,
## and extracts only into a newly created empty, 0700 staging directory.
## All extracted objects are checked again before the staging path is returned.
## No state is installed into config/, no Certbot command is run, and nothing
## is uploaded.  Only a future reviewed producer may consume the result.
## @see doc/adr/ADR-027-isolated-domain-archive-restoration.md

CERTBOTBOT_RESTORE_ROOT=''

## @fn certbotbot_restore_inspect_tree()
## @brief Validates every extracted member after isolated extraction.
## @param root Fresh, private extraction root.
## @param name Canonical lineage identity.
## @retval 0 The extracted tree matches the narrow lineage structure.
## @retval 64 Unexpected types, names, links, modes, or missing files.
## @retval 73 Local filesystem inspection failed.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_restore_inspect_tree() {
  local root=$1 name=$2 item type path kind mode count=0 manifest
  local -A required=()
  if (( $# != 2 )) || ! certbotbot_validate_hostname "$name" ||
    [[ $name == \*.* || $name != "${name,,}" ||
      $root != /* || ! -d $root || -L $root || ! -O $root ]]; then
    return 64
  fi
  mode="$(stat -c '%a' -- "$root")" || return 73
  if [[ $mode != 700 ]]; then
    return 64
  fi
  manifest="$(mktemp -- "${CERTBOTBOT_WORKSPACE_ROOT}/.inspect.XXXXXXXX")" ||
    return 73
  # GNU find emits NUL-delimited relative-name/type pairs without following
  # symlinks.  Materializing the enumeration preserves find's exit status.
  if ! find -P "$root" -mindepth 1 -printf '%P\0%y\0' >"$manifest"; then
    rm -f -- "$manifest"
    return 73
  fi
  while IFS= read -r -d '' item && IFS= read -r -d '' type; do
    (( count += 1 ))
    if (( count > 4096 )) || [[ ! $item =~ ^[a-z0-9./_-]+$ ||
      $item == /* || $item == ./* || $item == *../* ||
      $item == *'/./'* ]]; then
      rm -f -- "$manifest"
      return 64
    fi
    path="$root/$item"
    if [[ ! -O $path ]]; then
      rm -f -- "$manifest"
      return 64
    fi
    case "$type" in
      d)
        case "$item" in
          archive | "archive/$name" | live | "live/$name" |
          renewal | combined) ;;
          *) rm -f -- "$manifest"; return 64 ;;
        esac
        if [[ -L $path ]]; then
          rm -f -- "$manifest"
          return 64
        fi
        ;;
      f)
        if [[ -L $path || ! -s $path ]]; then
          rm -f -- "$manifest"
          return 64
        fi
        if [[ $item == "archive/$name/"* ]]; then
          local leaf=${item#"archive/$name/"}
          if [[ ! $leaf =~ ^(cert|chain|fullchain|privkey)[1-9][0-9]*[.]pem$ ]]; then
            rm -f -- "$manifest"
            return 64
          fi
          kind=${BASH_REMATCH[1]}
        elif [[ $item == "renewal/$name.conf" ]]; then
          kind=renewal
          required[renewal]=1
        elif [[ $item == "live/$name/combined.pem" ]]; then
          kind=combined
          required[live_combined]=1
        elif [[ $item == "combined/$name.pem" ]]; then
          kind=combined
          required[combined]=1
        else
          rm -f -- "$manifest"
          return 64
        fi
        if [[ $kind == privkey || $kind == combined ]]; then
          mode="$(stat -c '%a' -- "$path")" || {
            rm -f -- "$manifest"
            return 73
          }
          if [[ ! $mode =~ ^[0-7]{3,4}$ ]] ||
            (( (8#$mode & 8#77) != 0 )); then
            rm -f -- "$manifest"
            return 64
          fi
        fi
        ;;
      l)
        if [[ $item != "live/$name/"* ]]; then
          rm -f -- "$manifest"
          return 64
        fi
        kind=${item#"live/$name/"}
        if [[ ! $kind =~ ^(cert|chain|fullchain|privkey)[.]pem$ ]]; then
          rm -f -- "$manifest"
          return 64
        fi
        ;;
      *)
        rm -f -- "$manifest"
        return 64
        ;;
    esac
  done <"$manifest"
  rm -f -- "$manifest"

  for kind in cert chain fullchain privkey; do
    certbotbot_pem_check_link "$root" "$name" "$kind" || return 64
  done
  if [[ -z ${required[renewal]+_} || -z ${required[live_combined]+_} ||
    -z ${required[combined]+_} ]]; then
    return 64
  fi
  for path in archive "archive/$name" live "live/$name" renewal combined; do
    if [[ ! -d $root/$path || -L $root/$path ]]; then
      return 64
    fi
  done
}

## @fn certbotbot_restore_discard()
## @brief Discards only the recorded owner-private restore staging tree.
## @retval 0 No staging exists or the recorded tree was removed.
## @retval 73 The recorded target is unsafe or cleanup failed.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @note Normal deletion does not guarantee secure key erasure.
certbotbot_restore_discard() {
  local target=$CERTBOTBOT_RESTORE_ROOT mode
  if [[ -z $target ]]; then
    return 0
  fi
  if [[ -z $CERTBOTBOT_WORKSPACE_ROOT ||
    $target != "$CERTBOTBOT_WORKSPACE_ROOT"/restore.* ||
    ! ${target##*/} =~ ^restore[.][a-zA-Z0-9]{8}$ ||
    ! -d $target || -L $target || ! -O $target ]]; then
    return 73
  fi
  mode="$(stat -c '%a' -- "$target")" || return 73
  if [[ $mode != 700 ]]; then
    return 73
  fi
  rm -rf -- "$target" || return 73
  CERTBOTBOT_RESTORE_ROOT=''
}

## @fn certbotbot_restore_domain()
## @brief Validates and extracts a domain archive into new private staging.
## @param archive Absolute owned, readable archive pathname.
## @param name Canonical certificate lineage identity.
## @retval 0 New staging location is in CERTBOTBOT_RESTORE_ROOT.
## @retval 64 Invalid request, archive manifest, or extracted filesystem.
## @retval 73 Failed copy, staging operation, or extraction.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @note Does not change active Certbot config or call external services.
certbotbot_restore_domain() {
  local archive=$1 name=$2 stage='' copy='' mode result=0
  if (( $# != 2 )) || [[ -n $CERTBOTBOT_RESTORE_ROOT ||
    -z $CERTBOTBOT_WORKSPACE_ROOT ||
    ! -d $CERTBOTBOT_WORKSPACE_ROOT || -L $CERTBOTBOT_WORKSPACE_ROOT ||
    ! -O $CERTBOTBOT_WORKSPACE_ROOT ||
    $archive != /* || ! -f $archive || -L $archive ||
    ! -O $archive || ! -r $archive ]] ||
    ! certbotbot_validate_hostname "$name" ||
    [[ $name == \*.* || $name != "${name,,}" ]]; then
    return 64
  fi
  mode="$(stat -c '%a' -- "$CERTBOTBOT_WORKSPACE_ROOT")" || return 73
  if [[ $mode != 700 ]]; then
    return 64
  fi

  # Freeze input bytes in the private workspace before validation/extraction.
  copy="$(mktemp -- "$CERTBOTBOT_WORKSPACE_ROOT/.archive.XXXXXXXX")" ||
    return 73
  if ! (umask 077; cp -- "$archive" "$copy" && chmod 0600 -- "$copy"); then
    rm -f -- "$copy"
    return 73
  fi
  if ! certbotbot_archive_validate_domain "$copy" "$name"; then
    rm -f -- "$copy"
    return 64
  fi
  stage="$(mktemp -d -- "$CERTBOTBOT_WORKSPACE_ROOT/restore.XXXXXXXX")" || {
    rm -f -- "$copy"
    return 73
  }
  # An empty destination and a strict manifest keep permitted live symlinks
  # at leaf positions.  Do not restore archived ownership or permissive modes.
  if ! (umask 077; tar --extract --gzip --file "$copy" \
    --directory "$stage" --no-same-owner --no-same-permissions \
    --no-overwrite-dir --delay-directory-restore); then
    result=73
  elif ! certbotbot_restore_inspect_tree "$stage" "$name"; then
    result=64
  fi
  rm -f -- "$copy"
  if (( result != 0 )); then
    rm -rf -- "$stage"
    return "$result"
  fi
  CERTBOTBOT_RESTORE_ROOT=$stage
  return 0
}
