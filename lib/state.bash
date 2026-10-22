#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/state.bash
## @brief Verifies local ACME account presence and selected-lineage coherence.
## @details
## This module enforces the read-only preflight contract in ADR-023.
## Archive format verification and safe extraction must already have completed.
## No restored scripts or configuration are executed or sourced. The checks
## deliberately do not claim that the account is registered remotely or that
## canonical renewal metadata has been mapped into a private Certbot runtime.

## @fn certbotbot_state_account()
## @brief Requires one unambiguous production ACME account with private files.
## @details
## The account must occupy Certbot's production endpoint directory and contain
## nonempty, regular registration, key and metadata files. No other account
## endpoints or competing IDs are allowed in the single-account MVP. The key
## must have no group/other permissions. Content is never printed or parsed.
## @param config Canonical private restored Certbot configuration root.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @returns Nothing is written to STDOUT.
## @retval 0 One local account has the required expected structure.
## @retval 1 Account selection or on-disk structure is unsuitable.
certbotbot_state_account() {
  local config="$1" host directory account entry file count=0
  host="$config/accounts/acme-v02.api.letsencrypt.org"
  directory="$host/directory"
  [[ -d "$directory" && ! -L "$directory" && -O "$directory" ]] ||
    return 1
  for entry in "$config/accounts/"*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    [[ "$entry" == "$host" && -d "$entry" && ! -L "$entry" ]] ||
      return 1
  done
  for entry in "$host/"*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    [[ "$entry" == "$directory" && -d "$entry" && ! -L "$entry" ]] ||
      return 1
  done
  for entry in "$directory/"*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    [[ -d "$entry" && ! -L "$entry" && -O "$entry" ]] || return 1
    count=$((count + 1))
    (( count == 1 )) || return 1
    account="$entry"
  done
  (( count == 1 )) || return 1
  for file in private_key.json regr.json meta.json; do
    entry="$account/$file"
    [[ -f "$entry" && ! -L "$entry" && -s "$entry" &&
      -r "$entry" && -O "$entry" ]] || return 1
    if [[ "$file" == private_key.json ]]; then
      [[ -z "$(find "$entry" -perm /077 -print -quit 2>/dev/null)" ]] ||
        return 1
    else
      [[ -z "$(find "$entry" -perm /022 -print -quit 2>/dev/null)" ]] ||
        return 1
    fi
  done
  for entry in "$account/"*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    case "${entry##*/}" in
      private_key.json|regr.json|meta.json) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

## @fn certbotbot_state_hooks()
## @brief Rejects archived hook configuration and executable hook directories.
## @details
## Archived hook command execution is excluded from the MVP. A cli.ini file
## can inject arbitrary Certbot options and is therefore refused. Empty
## renewal-hooks directories may exist, but no non-directory members are
## allowed. A later version may add reviewed compatibility for specific
## inert options; this version fails closed.
## @param config Canonical private restored configuration root.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @returns Nothing is written to STDOUT.
## @retval 0 No disallowed global hook options or scripts were found.
## @retval 1 Unexpected hook content or unsafe configuration was found.
certbotbot_state_hooks() {
  local config="$1" bad
  [[ ! -e "$config/cli.ini" && ! -L "$config/cli.ini" ]] || return 1
  if [[ -e "$config/renewal-hooks" || -L "$config/renewal-hooks" ]]; then
    [[ -d "$config/renewal-hooks" &&
      ! -L "$config/renewal-hooks" ]] || return 1
    bad="$(find "$config/renewal-hooks" -mindepth 1 ! -type d \
      -print -quit 2>/dev/null)" || return 1
    [[ -z "$bad" ]] || return 1
  fi
}

## @fn certbotbot_state_lineage()
## @brief Classifies absent versus complete selected certificate lineage.
## @details
## An account-only archive may omit or contain empty live/archive/renewal
## directories. Any lineage material must correspond to exactly the selected
## name in all three trees. Relative live PEM links are checked against
## their actual regular archive targets using the canonical link contract.
## Renewal command hooks are rejected. No renewal config is evaluated and
## its absolute paths are deliberately left unchanged for a later adapter.
## @param config Canonical restored configuration root.
## @param selected Validated, explicit or derived certificate name.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @returns Nothing is written to STDOUT.
## @retval 0 REPLY is absent or present for exactly the selected lineage.
## @retval 1 Ambiguous, partial, conflicting, or executable state.
certbotbot_state_lineage() {
  local config="$1" selected="$2" root path member part target
  local present=false
  for root in live archive renewal; do
    if [[ -e "$config/$root" || -L "$config/$root" ]]; then
      [[ -d "$config/$root" && ! -L "$config/$root" ]] || return 1
      for member in "$config/$root/"*; do
        [[ -e "$member" || -L "$member" ]] || continue
        if [[ "${member##*/}" == README ]]; then
          [[ -f "$member" && ! -L "$member" ]] || return 1
          continue
        fi
        if [[ "$root" == renewal ]]; then
          [[ "$member" == "$config/renewal/$selected.conf" &&
            -f "$member" && ! -L "$member" && -s "$member" ]] ||
            return 1
        else
          [[ "$member" == "$config/$root/$selected" &&
            -d "$member" && ! -L "$member" ]] || return 1
        fi
        present=true
      done
    fi
  done
  if [[ "$present" == false ]]; then
    REPLY=absent
    return 0
  fi
  [[ -d "$config/live/$selected" && ! -L "$config/live/$selected" &&
    -d "$config/archive/$selected" && ! -L "$config/archive/$selected" &&
    -f "$config/renewal/$selected.conf" &&
    ! -L "$config/renewal/$selected.conf" &&
    -s "$config/renewal/$selected.conf" ]] || return 1
  if LC_ALL=C grep -qi 'hook' "$config/renewal/$selected.conf"; then
    return 1
  fi
  for part in cert chain fullchain privkey; do
    path="$config/live/$selected/$part.pem"
    [[ -L "$path" ]] || return 1
    target="$(readlink -- "$path")" || return 1
    certbotbot_tar_link "live/$selected/$part.pem" "$target" || return 1
    [[ -f "$config/$REPLY" && ! -L "$config/$REPLY" ]] || return 1
  done
  for member in "$config/live/$selected/"*; do
    [[ -e "$member" || -L "$member" ]] || continue
    case "${member##*/}" in
      README) [[ -f "$member" && ! -L "$member" ]] || return 1 ;;
      cert.pem|chain.pem|fullchain.pem|privkey.pem) [[ -L "$member" ]] || return 1 ;;
      *) return 1 ;;
    esac
  done
  for member in "$config/archive/$selected/"*; do
    [[ -e "$member" || -L "$member" ]] || continue
    if [[ "${member##*/}" != README ]]; then
      [[ "${member##*/}" =~ ^(cert|chain|fullchain|privkey)[1-9][0-9]*\.pem$ ]] ||
        return 1
    fi
    [[ -f "$member" && ! -L "$member" && -O "$member" ]] || return 1
  done
  REPLY=present
}

## @fn certbotbot_state_preflight()
## @brief Verifies restored account and selected lineage without side effects.
## @details
## This function is valid only after a private archive restoration. It
## checks canonical ownership/privacy, a single recognized ACME account,
## absence of archived hook execution, and one coherent selected lineage.
## Result is set in CERTBOTBOT_LINEAGE_STATE and cleared on all failures.
## It never invokes Certbot/AWS, reads the host account, or writes to S3.
## @param config Absolute canonical path of the private restored config root.
## @param selected Validated non-wildcard certificate name.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## One fixed safe diagnostic on failure.
## @returns Nothing is written to STDOUT.
## @retval 0 Local account structure and selected lineage are unambiguous.
## @retval 64 Invalid caller path or certificate name.
## @retval 65 Local restored state is missing, ambiguous, or unsafe.
## @par Examples
## @code
## certbotbot_state_preflight "$workspace/config" "$CERTBOTBOT_CERT_NAME" ||
##   exit $?
## # Certbot must still verify the account and canonical path mapping.
## @endcode
certbotbot_state_preflight() {
  local config selected physical
  CERTBOTBOT_LINEAGE_STATE=''
  if (( $# != 2 )); then
    printf '%s\n' 'certbotbot: invalid restored state arguments' >&2
    return 64
  fi
  config="$1"
  selected="$2"
  if [[ "$config" != /* || ! -d "$config" || -L "$config" ||
    ! -O "$config" || "$selected" == *'*'* ]] ||
    ! certbotbot_dns_valid "$selected"; then
    printf '%s\n' 'certbotbot: invalid restored state input' >&2
    return 64
  fi
  physical="$(cd -P -- "$config" && pwd -P)" || return 64
  if [[ "$physical" != "$config" ||
    "$(stat -c %a -- "$config" 2>/dev/null)" != 700 ]]; then
    printf '%s\n' 'certbotbot: unsafe restored configuration root' >&2
    return 64
  fi
  if ! certbotbot_state_account "$config" ||
    ! certbotbot_state_hooks "$config" ||
    ! certbotbot_state_lineage "$config" "$selected"; then
    printf '%s\n' 'certbotbot: restored account or lineage is unsuitable' >&2
    return 65
  fi
  CERTBOTBOT_LINEAGE_STATE="$REPLY"
  return 0
}
