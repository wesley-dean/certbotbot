#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/archive.bash
## @brief Verifies bounded tar/gzip structure without extracting certificate data.
## @details
## This pre-extraction format gate follows ADR-022. It reads raw 512-byte
## tar headers using GNU od and Bash 4.3, with no interpreted tar commands.
## The algorithm rejects unsupported extensions, unsafe paths and links,
## incomplete gzip streams, and inconsistent archive metadata. Successful
## format validation never authorizes account use or Certbot execution.

## @var CERTBOTBOT_TAR_HEADER
## @brief Numeric byte values for the currently inspected 512-byte block.
declare -a CERTBOTBOT_TAR_HEADER=()

## @fn certbotbot_tar_block()
## @brief Loads exactly one 512-byte block from the decoded tar stream.
## @param source Path to the private decoded tar file.
## @param offset Zero-based byte offset, divisible by 512.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @returns Nothing is written to STDOUT.
## @retval 0 Block loaded into CERTBOTBOT_TAR_HEADER.
## @retval 1 Read failed or block was incomplete.
certbotbot_tar_block() {
  local contents
  contents="$(LC_ALL=C od -An -v -tu1 -w512 -N512 -j "$2" -- "$1" 2>/dev/null)" || return 1
  IFS=' ' read -r -a CERTBOTBOT_TAR_HEADER <<< "$contents"
  (( ${#CERTBOTBOT_TAR_HEADER[@]} == 512 ))
}

## @fn certbotbot_tar_octal()
## @brief Parses one fixed-width header field as bounded ASCII octal.
## @param start Zero-based offset within the header.
## @param width Length of the field in bytes.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @returns Nothing is written to STDOUT.
## @retval 0 Value stored in REPLY.
## @retval 1 Non-octal or malformed field.
certbotbot_tar_octal() {
  local start="$1" width="$2" i x ended=false
  REPLY=0
  for (( i=start; i<start+width; i++ )); do
    x="${CERTBOTBOT_TAR_HEADER[i]}"
    if (( x == 0 || x == 32 )); then
      ended=true
      continue
    fi
    [[ "$ended" == false ]] || return 1
    (( x >= 48 && x <= 55 )) || return 1
    REPLY=$(( REPLY * 8 + x - 48 ))
  done
}

## @fn certbotbot_tar_text()
## @brief Reads a NUL-terminated printable ASCII header field.
## @param start Zero-based offset.
## @param width Field length.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @returns Nothing is written to STDOUT.
## @retval 0 Field stored in REPLY.
## @retval 1 Invalid control byte or non-NUL content after terminator.
certbotbot_tar_text() {
  local start="$1" width="$2" i x char octal ended=false
  REPLY=''
  for (( i=start; i<start+width; i++ )); do
    x="${CERTBOTBOT_TAR_HEADER[i]}"
    if (( x == 0 )); then
      ended=true
      continue
    fi
    [[ "$ended" == false ]] || return 1
    (( x >= 32 && x <= 126 )) || return 1
    printf -v octal '%03o' "$x"
    printf -v char '%b' "\\0$octal"
    REPLY+="$char"
  done
}

## @fn certbotbot_tar_path()
## @brief Enforces the canonical relative Certbot member-name subset.
## @param path Raw tar name, optionally beginning ./.
## @param type Tar type as a numeric ASCII byte.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @returns Nothing is written to STDOUT.
## @retval 0 Normalized name stored in REPLY.
## @retval 1 Invalid or unsupported path.
certbotbot_tar_path() {
  local path="$1" type="$2" component
  local -a parts=()
  if [[ "$path" == './' && "$type" == 53 ]]; then REPLY='.'; return 0; fi
  if [[ "$path" == ./* ]]; then path="${path#./}"; fi
  if [[ "$type" == 53 && "$path" == */ ]]; then path="${path%/}"; fi
  [[ "$path" != '' && "$path" != /* && "$path" != *//* ]] || return 1
  [[ "$path" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  IFS=/ read -r -a parts <<< "$path"
  (( ${#parts[@]} > 0 )) || return 1
  for component in "${parts[@]}"; do
    [[ "$component" != '' && "$component" != '.' &&
      "$component" != '..' ]] || return 1
  done
  case "${parts[0]}" in
    accounts|archive|live|renewal|csr|keys|renewal-hooks) ;;
    README|cli.ini) (( ${#parts[@]} == 1 )) || return 1 ;;
    *) return 1 ;;
  esac
  if [[ "${parts[0]}" == renewal-hooks && "$type" != 53 ]]; then
    return 1
  fi
  REPLY="$path"
}

## @fn certbotbot_tar_link()
## @brief Checks the canonical live-to-archive Certbot PEM link relationship.
## @param path Canonical live certificate link path.
## @param target Symbolic link target stored in the header.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @returns Nothing is written to STDOUT.
## @retval 0 Corresponding regular archive PEM path stored in REPLY.
## @retval 1 Unexpected symlink form or mismatched certificate lineage.
certbotbot_tar_link() {
  local path="$1" target="$2" lineage piece link_lineage link_piece version
  if [[ "$path" =~ ^live/([^/]+)/(cert|chain|fullchain|privkey)\.pem$ ]]; then
    lineage="${BASH_REMATCH[1]}"
    piece="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  if [[ "$target" =~ ^\.\./\.\./archive/([^/]+)/(cert|chain|fullchain|privkey)([1-9][0-9]*)\.pem$ ]]; then
    link_lineage="${BASH_REMATCH[1]}"
    link_piece="${BASH_REMATCH[2]}"
    version="${BASH_REMATCH[3]}"
  else
    return 1
  fi
  [[ "$lineage" == "$link_lineage" && "$piece" == "$link_piece" ]] || return 1
  REPLY="archive/$lineage/$piece$version.pem"
}

## @fn certbotbot_archive_validate()
## @brief Checks bounded gzip/tar structure without extracting any data.
## @details
## A fresh private temporary directory stores the decoded data (maximum
## 32 MiB), which is inspected at precise tar header offsets. File bodies
## are skipped according to their validated byte lengths. Unsafe metadata,
## extensions, duplicates, symlink targets and permissions fail closed.
## No host Certbot paths, AWS calls, or credential files are accessed here.
## Temporary decoded data is removed on success and on ordinary failures.
## @param archive Readable, non-symlink local .tar.gz file.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed safe diagnostics only.
## @returns Nothing is written to STDOUT.
## @retval 0 Format preflight passed; account and renewal safety not verified.
## @retval 64 Invalid archive argument.
## @retval 65 Archive malformed, oversized or unsupported.
certbotbot_archive_validate() {
  local archive temp decoded length offset=0 zero_count=0 count=0
  local i sum empty size mode kind name prefix link parent target
  local -A types=() targets=()
  local -a components=()
  if (( $# != 1 )); then
    printf '%s\n' 'certbotbot: invalid archive input' >&2
    return 64
  fi
  archive="$1"
  if [[ ! -f "$archive" || ! -r "$archive" || -L "$archive" ]]; then
    printf '%s\n' 'certbotbot: unreadable archive input' >&2
    return 64
  fi
  temp="$(umask 077; mktemp -d)" || return 65
  decoded="$temp/data.tar"
  if ! (set -o pipefail; gzip -cd -- "$archive" 2>/dev/null |
    head -c 33554433 >"$decoded"); then
    rm -rf -- "$temp"
    printf '%s\n' 'certbotbot: invalid or oversized archive' >&2
    return 65
  fi
  length="$(wc -c <"$decoded")" || { rm -rf -- "$temp"; return 65; }
  if (( length < 1024 || length > 33554432 || length % 512 != 0 )); then
    rm -rf -- "$temp"
    printf '%s\n' 'certbotbot: invalid archive boundaries' >&2
    return 65
  fi

  local valid=true
  while (( offset < length )); do
    if ! certbotbot_tar_block "$decoded" "$offset"; then valid=false; break; fi
    empty=true
    for (( i=0; i<512; i++ )); do
      if (( CERTBOTBOT_TAR_HEADER[i] != 0 )); then empty=false; break; fi
    done
    if [[ "$empty" == true ]]; then
      zero_count=$((zero_count + 1))
      if (( zero_count > 40 )); then valid=false; break; fi
      offset=$((offset + 512))
      continue
    fi
    if (( zero_count > 0 )); then valid=false; break; fi
    count=$((count + 1))
    if (( count > 2048 )); then valid=false; break; fi
    if (( CERTBOTBOT_TAR_HEADER[257] != 117 ||
      CERTBOTBOT_TAR_HEADER[258] != 115 ||
      CERTBOTBOT_TAR_HEADER[259] != 116 ||
      CERTBOTBOT_TAR_HEADER[260] != 97 ||
      CERTBOTBOT_TAR_HEADER[261] != 114 )); then valid=false; break; fi
    if ! { (( CERTBOTBOT_TAR_HEADER[262] == 0 &&
      CERTBOTBOT_TAR_HEADER[263] == 48 &&
      CERTBOTBOT_TAR_HEADER[264] == 48 )) ||
      (( CERTBOTBOT_TAR_HEADER[262] == 32 &&
      CERTBOTBOT_TAR_HEADER[263] == 32 )); }; then
      valid=false; break
    fi
    sum=0
    for (( i=0; i<512; i++ )); do
      if (( i >= 148 && i <= 155 )); then
        sum=$((sum + 32))
      else
        sum=$((sum + CERTBOTBOT_TAR_HEADER[i]))
      fi
    done
    if ! certbotbot_tar_octal 148 8 || (( REPLY != sum )); then valid=false; break; fi
    if ! certbotbot_tar_octal 124 12; then valid=false; break; fi
    size="$REPLY"
    if ! certbotbot_tar_octal 100 8; then valid=false; break; fi
    mode="$REPLY"
    if ! certbotbot_tar_octal 108 8 || (( REPLY > 65535 )); then valid=false; break; fi
    if ! certbotbot_tar_octal 116 8 || (( REPLY > 65535 )); then valid=false; break; fi
    kind="${CERTBOTBOT_TAR_HEADER[156]}"
    if (( size > 33554432 || mode >= 512 )); then valid=false; break; fi
    if (( kind != 0 && kind != 48 && kind != 53 && kind != 50 )); then
      valid=false; break
    fi
    if (( kind != 50 && (mode / 16 % 2 != 0 || mode / 2 % 2 != 0) )); then
      valid=false; break
    fi
    if ! certbotbot_tar_text 0 100; then valid=false; break; fi
    name="$REPLY"
    if ! certbotbot_tar_text 345 155; then valid=false; break; fi
    prefix="$REPLY"
    if [[ -n "$prefix" ]]; then
      if (( CERTBOTBOT_TAR_HEADER[262] != 0 )); then valid=false; break; fi
      name="$prefix/$name"
    fi
    if ! certbotbot_tar_path "$name" "$kind"; then valid=false; break; fi
    name="$REPLY"
    if [[ -n "${types[$name]+x}" ]]; then valid=false; break; fi
    types["$name"]="$kind"
    if ! certbotbot_tar_text 157 100; then valid=false; break; fi
    link="$REPLY"
    if (( kind == 53 )); then
      if (( size != 0 )) || [[ -n "$link" ]]; then valid=false; break; fi
    elif (( kind == 50 )); then
      if (( size != 0 )) || ! certbotbot_tar_link "$name" "$link"; then
        valid=false; break
      fi
      targets["$name"]="$REPLY"
    elif [[ -n "$link" ]]; then
      valid=false; break
    fi
    offset=$((offset + 512 + ((size + 511) / 512) * 512))
    if (( offset > length )); then valid=false; break; fi
  done

  if (( zero_count < 2 || count == 0 )); then valid=false; fi
  if [[ "$valid" == true ]]; then
    for name in "${!types[@]}"; do
      IFS=/ read -r -a components <<< "$name"
      parent=''
      for (( i=0; i<${#components[@]}-1; i++ )); do
        if [[ -n "$parent" ]]; then parent+='/'; fi
        parent+="${components[i]}"
        if [[ -n "${types[$parent]+x}" && "${types[$parent]}" != 53 ]]; then
          valid=false; break
        fi
      done
      [[ "$valid" == true ]] || break
    done
  fi
  if [[ "$valid" == true ]]; then
    for name in "${!targets[@]}"; do
      target="${targets[$name]}"
      if [[ -z "${types[$target]+x}" ||
        ( "${types[$target]}" != 0 && "${types[$target]}" != 48 ) ]]; then
        valid=false; break
      fi
    done
  fi
  rm -rf -- "$temp"
  if [[ "$valid" != true ]]; then
    printf '%s\n' 'certbotbot: unsafe or unsupported archive contents' >&2
    return 65
  fi
  return 0
}
