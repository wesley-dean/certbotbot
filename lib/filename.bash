#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/filename.bash
## @brief Resolves safe archive key templates using released mktext.
## @details
## Implements ADR-032 without interpreting user templates as shell code.
## S3_KEY remains strictly literal. Only an explicitly chosen current template,
## an explicitly provided backup template, or a future enabled dated backup
## requires a UTC clock lookup. One validated date is frozen for the call.
## The renderer receives a caller-owned associative array of nonsecret values.
## This module never reads, writes, enumerates, or deletes remote objects.

## @var CERTBOTBOT_BACKUP_KEY
## @brief The validated dated key, empty while backup naming is not requested.
CERTBOTBOT_BACKUP_KEY=''

## @fn certbotbot_filename_error()
## @brief Reports an untrusted-input failure without echoing its raw value.
## @param message Fixed nonsecret diagnostic text.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## A fixed diagnostic.
## @returns Nothing is written to STDOUT.
## @retval 64 Invalid filename, date, or rendering configuration.
certbotbot_filename_error() {
  printf 'certbotbot: %s\n' "$1" >&2
  return 64
}

## @fn certbotbot_filename_date()
## @brief Obtains one fully validated UTC date and its padded components.
## @details
## Calls date once, not once per token. The numeric calendar checks guard
## malformed or replaced date implementations, including invalid leap days.
## The values are shell-local, never exported or derived from archive data.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## A static diagnostic on failure.
## @returns Date through CERTBOTBOT_FILENAME_DATE/YEAR/MONTH/DOM variables.
## @retval 0 A consistent UTC snapshot was captured.
## @retval 64 Clock unavailable or date invalid.
certbotbot_filename_date() {
  local snapshot year month day maxday
  if ! snapshot="$(LC_ALL=C date -u +%Y%m%d 2>/dev/null)" ||
    [[ ! "$snapshot" =~ ^[0-9]{8}$ ]]; then
    certbotbot_filename_error 'cannot obtain valid UTC date'
    return 64
  fi
  CERTBOTBOT_FILENAME_YEAR="${snapshot:0:4}"
  CERTBOTBOT_FILENAME_MONTH="${snapshot:4:2}"
  CERTBOTBOT_FILENAME_DOM="${snapshot:6:2}"
  year=$((10#$CERTBOTBOT_FILENAME_YEAR))
  month=$((10#$CERTBOTBOT_FILENAME_MONTH))
  day=$((10#$CERTBOTBOT_FILENAME_DOM))
  if (( year < 1 || month < 1 || month > 12 || day < 1 )); then
    certbotbot_filename_error 'invalid UTC calendar date'
    return 64
  fi
  case "$month" in
    4|6|9|11) maxday=30 ;;
    2)
      maxday=28
      if (( year % 400 == 0 || (year % 4 == 0 && year % 100 != 0) )); then
        maxday=29
      fi
      ;;
    *) maxday=31 ;;
  esac
  if (( day > maxday )); then
    certbotbot_filename_error 'invalid UTC calendar date'
    return 64
  fi
  CERTBOTBOT_FILENAME_DATE="$snapshot"
}

## @fn certbotbot_filename_render()
## @brief Lexically renders and validates one single-component tar.gz key.
## @details
## The template grammar is deliberately narrower than generic mktext:
## only uppercase exact {YEAR}, {MONTH}, and {DOM} are supported. Replacing
## accepted macros with safe placeholders before validating the remaining
## characters rejects unknown macros, brace nesting, paths, whitespace,
## shell-looking syntax, traversal, and leading punctuation. The final name
## has separate constraints: 255 ASCII bytes maximum and exact .tar.gz suffix.
## mktext's single substitution pass never recursively renders values.
## @param template Untrusted operator-specified template.
## @par STDIN
## The caller supplies no STDIN; the helper pipes its template to mktext.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed diagnostics only.
## @returns Validated, rendered key in REPLY.
## @retval 0 One safe gzip-tar basename produced.
## @retval 64 Unsafe template or unavailable/failed renderer.
certbotbot_filename_render() {
  local template="${1-}" safe rendered
  local -A certbotbot_filename_context=(
    [YEAR]="$CERTBOTBOT_FILENAME_YEAR"
    [MONTH]="$CERTBOTBOT_FILENAME_MONTH"
    [DOM]="$CERTBOTBOT_FILENAME_DOM"
  )
  safe="${template//\{YEAR\}/Y}"
  safe="${safe//\{MONTH\}/M}"
  safe="${safe//\{DOM\}/D}"
  if [[ ! "$safe" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ||
    "$safe" == *..* || "$safe" == *. ]]; then
    certbotbot_filename_error 'invalid filename template'
    return 64
  fi
  if ! declare -F mktext >/dev/null 2>&1; then
    certbotbot_filename_error 'embedded mktext renderer unavailable'
    return 64
  fi
  if ! rendered="$(printf '%s' "$template" |
    mktext render certbotbot_filename_context 2>/dev/null)"; then
    certbotbot_filename_error 'filename rendering failed'
    return 64
  fi
  if (( ${#rendered} > 255 )) ||
    [[ ! "$rendered" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ||
      "$rendered" == *..* || "$rendered" == *. ||
      "$rendered" != *.tar.gz ]]; then
    certbotbot_filename_error 'unsafe rendered archive name'
    return 64
  fi
  REPLY="$rendered"
}

## @fn certbotbot_filename_resolve()
## @brief Freezes the effective current and optionally requested backup key.
## @details
## Ordinary MVP literal keys bypass mktext and clock reads. When needed,
## the UTC snapshot is computed just once and reused by both templates.
## The current selected key is replaced before the S3 fetch; the
## same variable is passed to the publisher later in the invocation.
## Backup resolution alone never authorizes an extra PutObject.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed error on unsafe or colliding names.
## @returns Frozen CERTBOTBOT_S3_KEY and optional CERTBOTBOT_BACKUP_KEY.
## @retval 0 Filename resolution succeeded.
## @retval 64 Date/template/key collision failure before S3.
certbotbot_filename_resolve() {
  local current="$CERTBOTBOT_S3_KEY" need_backup=false
  CERTBOTBOT_BACKUP_KEY=''
  if [[ "${CERTBOTBOT_BACKUP_KEY_TEMPLATE_EXPLICIT:-false}" == true ||
    "${CERTBOTBOT_DATED_BACKUP_ENABLED:-false}" == true ]]; then
    need_backup=true
  fi
  if [[ "${CERTBOTBOT_S3_KEY_IS_TEMPLATE:-false}" != true &&
    "$need_backup" != true ]]; then
    return 0
  fi
  certbotbot_filename_date || return 64
  if [[ "${CERTBOTBOT_S3_KEY_IS_TEMPLATE:-false}" == true ]]; then
    certbotbot_filename_render "$current" || return 64
    current="$REPLY"
  fi
  if [[ "$need_backup" == true ]]; then
    certbotbot_filename_render "$CERTBOTBOT_BACKUP_KEY_TEMPLATE" || return 64
    if [[ "$REPLY" == "$current" ]]; then
      certbotbot_filename_error 'current and backup archive keys collide'
      return 64
    fi
    CERTBOTBOT_BACKUP_KEY="$REPLY"
  fi
  CERTBOTBOT_S3_KEY="$current"
}
