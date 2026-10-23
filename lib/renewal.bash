#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/renewal.bash
## @brief Maps selected Certbot renewal paths between canonical and private roots.
## @details
## Implements the approved reversible path policy under ADR-022. Only the
## exact five documented path-bearing keys are changed, and unsupported
## Certbot metadata fails closed without partially rewriting the file.

## @fn certbotbot_renewal_map()
## @brief Maps a complete selected lineage's renewal paths atomically.
## @details
## Requires a restored private configuration passing the local ACME state
## preflight, and a regular private renewal file for the selected name.
## prepare converts canonical /etc/letsencrypt paths into the private root;
## finalize performs exactly the inverse. verify checks canonical source
## paths and the supported metadata schema without modifying any file.
## The entire input is parsed before
## writing a same-directory temporary output, so validation failures preserve
## the original bytes. Only a bounded conservative Route53 configuration
## dialect is supported. No account, host, PEM, or S3 data is mutated.
## @param config Absolute canonical owned mode-0700 config directory.
## @param name Validated single non-wildcard certificate lineage name.
## @param direction prepare, finalize, or read-only verify.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed diagnostics; configuration data is never printed.
## @returns Nothing is written to STDOUT.
## @retval 0 Paths mapped or canonical metadata verified, as requested.
## @retval 64 Invalid caller arguments or unsafe config root.
## @retval 65 Unexpected, incomplete, or unsafe renewal metadata.
## @retval 74 Failure writing a private replacement file.
## @note Actual Certbot compatibility and remote ACME account suitability
## are separate gates, and this function does not authorize issuance.
certbotbot_renewal_map() {
  local config name direction file physical source_root dest_root
  local account_dir account_id='' entry
  local input_bytes count_bytes=0 line value key prefix separator suffix raw
  local relative replacement section='' output='' temporary='' field
  local seen_renewal=false seen_acme=false valid=true
  local -A seen=() found=()
  local LC_ALL=C

  if (( $# != 3 )); then
    printf '%s\n' 'certbotbot: invalid renewal mapping arguments' >&2
    return 64
  fi
  config="$1"
  name="$2"
  direction="$3"
  if [[ "$config" != /* || "$config" == / || "$config" == */ ||
    ! "$config" =~ ^/[A-Za-z0-9._/-]+$ ||
    ! -d "$config" || -L "$config" || ! -O "$config" ||
    "$name" == *'*'* ]] || ! certbotbot_dns_valid "$name"; then
    printf '%s\n' 'certbotbot: invalid renewal mapping input' >&2
    return 64
  fi
  case "$direction" in
    prepare) source_root=/etc/letsencrypt; dest_root="$config" ;;
    verify) source_root=/etc/letsencrypt; dest_root=/etc/letsencrypt ;;
    finalize) source_root="$config"; dest_root=/etc/letsencrypt ;;
    *)
      printf '%s\n' 'certbotbot: invalid renewal mapping direction' >&2
      return 64
      ;;
  esac
  physical="$(cd -P -- "$config" && pwd -P)" || return 64
  if [[ "$physical" != "$config" ||
    "$(stat -c %a -- "$config" 2>/dev/null)" != 700 ]]; then
    printf '%s\n' 'certbotbot: unsafe renewal mapping root' >&2
    return 64
  fi

  if ! certbotbot_state_preflight "$config" "$name" >/dev/null 2>&1 ||
    [[ "$CERTBOTBOT_LINEAGE_STATE" != present ]]; then
    printf '%s\n' 'certbotbot: selected lineage unavailable for mapping' >&2
    return 65
  fi
  file="$config/renewal/$name.conf"
  if [[ ! -f "$file" || -L "$file" || ! -r "$file" || ! -O "$file" ||
    -n "$(find "$file" -perm /077 -print -quit 2>/dev/null)" ]]; then
    printf '%s\n' 'certbotbot: unsafe renewal metadata file' >&2
    return 65
  fi
  input_bytes="$(wc -c <"$file")" || return 65
  if (( input_bytes == 0 || input_bytes > 65536 )); then
    printf '%s\n' 'certbotbot: unsupported renewal metadata size' >&2
    return 65
  fi
  account_dir="$config/accounts/acme-v02.api.letsencrypt.org/directory"
  for entry in "$account_dir/"*; do
    [[ -d "$entry" && ! -L "$entry" ]] || continue
    account_id="${entry##*/}"
    break
  done
  [[ -n "$account_id" ]] || return 65

  while IFS= read -r line || [[ -n "$line" ]]; do
    count_bytes=$((count_bytes + ${#line} + 1))
    if (( ${#line} > 8192 )) ||
      [[ "$line" == *$'\r'* || ! "$line" =~ ^[[:print:][:blank:]]*$ ||
        "${line,,}" == *hook* ]]; then
      valid=false
      break
    fi
    if [[ "$line" =~ ^[[:blank:]]*\[([^][]+)\][[:blank:]]*$ ]]; then
      case "${BASH_REMATCH[1]}" in
        renewalparams)
          if [[ "$seen_renewal" == true || "$seen_acme" == true ]]; then
            valid=false; break
          fi
          seen_renewal=true
          section=renewalparams
          ;;
        acme_renewal_info)
          if [[ "$seen_renewal" != true || "$seen_acme" == true ]]; then
            valid=false; break
          fi
          seen_acme=true
          section=acme_renewal_info
          ;;
        *) valid=false; break ;;
      esac
      output+="$line"$'\n'
      continue
    fi
    if [[ -z "$line" || "$line" =~ ^[[:blank:]]*# ]]; then
      if [[ "$line" == *'/etc/letsencrypt'* ||
        "$line" == *"$config/"* ]]; then valid=false; break; fi
      output+="$line"$'\n'
      continue
    fi
    if [[ ! "$line" =~ ^([[:blank:]]*)([a-z_][a-z0-9_]*)([[:blank:]]*=[[:blank:]]*)(.*)$ ]]; then
      valid=false
      break
    fi
    prefix="${BASH_REMATCH[1]}"
    key="${BASH_REMATCH[2]}"
    separator="${BASH_REMATCH[3]}"
    raw="${BASH_REMATCH[4]}"
    value="$raw"
    while [[ "$value" == *[[:blank:]] ]]; do value="${value%?}"; done
    suffix="${raw:${#value}}"
    if [[ -n "${seen["$section:$key"]+x}" ]]; then valid=false; break; fi
    seen["$section:$key"]=1

    if [[ -z "$section" ]]; then
      case "$key" in
        archive_dir|cert|privkey|chain|fullchain)
          found["$key"]=1
          if [[ "$key" == archive_dir ]]; then
            relative="/archive/$name"
          else
            relative="/live/$name/$key.pem"
          fi
          if [[ "$value" != "$source_root$relative" ]]; then
            valid=false; break
          fi
          replacement="$dest_root$relative"
          output+="$prefix$key$separator$replacement$suffix"$'\n'
          continue
          ;;
        version)
          [[ "$value" =~ ^[0-9]+([.][0-9]+)+$ ]] || { valid=false; break; }
          ;;
        renew_before_expiry)
          [[ "$value" =~ ^[0-9]+[[:blank:]]+(days?|hours?)$ ]] ||
            { valid=false; break; }
          ;;
        *) valid=false; break ;;
      esac
    elif [[ "$section" == renewalparams ]]; then
      case "$key" in
        account) [[ "$value" == "$account_id" ]] || { valid=false; break; } ;;
        authenticator)
          [[ "$value" == dns-route53 ]] || { valid=false; break; }
          ;;
        server)
          [[ "$value" == https://acme-v02.api.letsencrypt.org/directory ]] ||
            { valid=false; break; }
          ;;
        key_type)
          [[ "$value" == ecdsa || "$value" == rsa ]] ||
            { valid=false; break; }
          ;;
        dns_route53_propagation_seconds|rsa_key_size)
          [[ "$value" =~ ^[0-9]+$ ]] || { valid=false; break; }
          ;;
        elliptic_curve)
          [[ "$value" =~ ^[A-Za-z0-9_-]+$ ]] || { valid=false; break; }
          ;;
        reuse_key)
          case "$value" in True|False|true|false) ;; *) valid=false; break ;; esac
          ;;
        pref_challs|preferred_challenges)
          [[ "$value" == dns-01 ]] || { valid=false; break; }
          ;;
        *) valid=false; break ;;
      esac
    elif [[ "$section" == acme_renewal_info ]]; then
      case "$key" in
        ari_retry_after)
          [[ "$value" =~ ^[0-9TZ:+.-]+$ ]] || { valid=false; break; }
          ;;
        *) valid=false; break ;;
      esac
    else
      valid=false
      break
    fi
    output+="$line"$'\n'
  done <"$file"

  for field in archive_dir cert privkey chain fullchain; do
    [[ -n "${found[$field]+x}" ]] || valid=false
  done
  if [[ "$seen_renewal" != true ||
    -z "${seen['renewalparams:account']+x}" ||
    -z "${seen['renewalparams:authenticator']+x}" ||
    -z "${seen['renewalparams:server']+x}" ]] ||
    (( count_bytes != input_bytes )); then
    valid=false
  fi
  if [[ "$valid" != true ]]; then
    printf '%s\n' 'certbotbot: unsupported renewal configuration' >&2
    return 65
  fi
  if [[ "$direction" == verify ]]; then
    return 0
  fi
  temporary="$(umask 077; mktemp "$config/renewal/.mapping.XXXXXXXX")" || {
    printf '%s\n' 'certbotbot: renewal mapping staging unavailable' >&2
    return 74
  }
  if ! printf '%s' "$output" >"$temporary" ||
    ! chmod 600 -- "$temporary" || ! mv -fT -- "$temporary" "$file"; then
    rm -f -- "$temporary"
    printf '%s\n' 'certbotbot: renewal mapping update failed' >&2
    return 74
  fi
  return 0
}
