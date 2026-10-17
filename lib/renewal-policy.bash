# shellcheck shell=bash
## @file lib/renewal-policy.bash
## @brief Rejects unsupported or unsafe persisted Certbot renewal options.
## @details
## Account identity and private archive restoration are necessary but do not
## make arbitrary persisted renewal configuration safe to pass to Certbot.
## Certbot renewal files can select hooks, plugins, and external paths. This
## module accepts only the minimal supported Certbot 5.8.0 Route53 profile,
## treats every unknown field as a compatibility failure, and never evaluates
## or installs untrusted renewal content. It intentionally uses Bash 4.3 and
## does not add a JSON, INI, Python, or other runtime parser dependency.
##
## The separate ADR-031 identity validator rejects NULs and ambiguous ACME
## references. ADR-032 validates the historical paths; this policy must
## succeed before the non-activating path preview is prepared. None of these
## gates proves that the archived ACME account is genuine.
## @see doc/adr/ADR-038-restored-renewal-option-policy.md

## @fn certbotbot_renewal_policy_check()
## @brief Apply the bounded Certbot 5.8.0 Route53 renewal-option policy.
## @details
## Requires the previously restored account/domain staging roots recorded
## by this process, and checks their ACME identity before parsing options.
## A key may occur once per section; only the exact keys, types, and values
## enumerated in ADR-038 are accepted. Unrecognized fields fail closed.
##
## @param name Canonical lineage name without a leading wildcard.
## @param environment production or staging, matching this run.
##
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## No diagnostics or confidential contents are emitted by this function.
##
## @returns Nothing is written to STDOUT.
## @retval 0 The persisted renewal options match the accepted narrow profile.
## @retval 64 Unsupported content, duplicates, or malformed configuration.
## @retval 65 The account/lineage identity does not match the ACME authority.
## @retval 73 Required file metadata or content could not be read.
## @note The ADR-031 identity checker may propagate its own nonzero statuses.
## @note Success does not authorize Certbot execution or active state import.
certbotbot_renewal_policy_check() {
  local LC_ALL=C
  local name=${1:-} environment=${2:-}
  local file='' line='' trimmed='' key='' value='' section=top
  local count=0 saw_section=false
  local -A sections=() seen=()
  local -a required_top=(version archive_dir cert chain fullchain privkey)
  local -a required_params=(server account authenticator key_type)
  local required=''

  if (( $# != 2 )) || ! certbotbot_validate_hostname "$name" ||
    [[ $name == \*.* || $name != "${name,,}" ]] ||
    ! certbotbot_acme_validate_environment "$environment"; then
    return 64
  fi
  certbotbot_state_verify_identity "$CERTBOTBOT_COMMON_STAGE" \
    "$CERTBOTBOT_RESTORE_ROOT" "$name" "$environment" || return $?

  file="$CERTBOTBOT_RESTORE_ROOT/renewal/$name.conf"
  if [[ ! -f $file || -L $file || ! -O $file || ! -r $file ||
    ! -s $file ]]; then
    return 64
  fi

  while IFS= read -r line || [[ -n $line ]]; do
    (( count += 1 ))
    if (( count > 4096 )) || [[ $line == *$'\r'* ]]; then
      return 64
    fi
    trimmed=${line#"${line%%[![:space:]]*}"}
    if [[ -z $trimmed || ${trimmed:0:1} == '#' ]]; then
      continue
    fi

    if [[ $trimmed =~ ^\[([a-z_]+)\][[:space:]]*$ ]]; then
      section=${BASH_REMATCH[1]}
      case "$section" in
        renewalparams | acme_renewal_info) ;;
        *) return 64 ;;
      esac
      if [[ -n ${sections[$section]+_} ]]; then
        return 64
      fi
      sections["$section"]=1
      saw_section=true
      continue
    fi

    if [[ ! $trimmed =~ ^([a-z_][a-z_0-9]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      return 64
    fi
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    value=${value%"${value##*[![:space:]]}"}
    if [[ -z $value || -n ${seen["$section:$key"]+_} ]]; then
      return 64
    fi
    seen["$section:$key"]=1

    case "$section:$key" in
      top:version)
        [[ $value =~ ^[0-9]+[.][0-9]+([.][0-9]+)?$ ]] || return 64
        ;;
      top:archive_dir | top:cert | top:chain | top:fullchain | top:privkey)
        # ADR-032 checks canonical historical paths and shared lineage root.
        [[ $value == /* ]] || return 64
        ;;
      renewalparams:server)
        [[ $value == "$(certbotbot_acme_directory "$environment")" ]] ||
          return 65
        ;;
      renewalparams:account)
        [[ $value =~ ^[a-f0-9]{32,64}$ ]] || return 65
        ;;
      renewalparams:authenticator)
        [[ $value == dns-route53 ]] || return 64
        ;;
      renewalparams:key_type)
        case "$value" in
          ecdsa | rsa) ;;
          *) return 64 ;;
        esac
        ;;
      renewalparams:dns_route53_propagation_seconds)
        if [[ ! $value =~ ^[0-9]{1,4}$ ]] ||
          (( 10#$value > 3600 )); then
          return 64
        fi
        ;;
      renewalparams:pref_challs)
        [[ $value == dns-01 ]] || return 64
        ;;
      acme_renewal_info:ari_retry_after)
        [[ $value =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] ||
          return 64
        ;;
      *)
        # No freeform Certbot flags, credential paths, install hooks, or
        # plugin options may cross this future execution boundary.
        return 64
        ;;
    esac
  done <"$file"

  [[ $saw_section == true && -n ${sections[renewalparams]+_} ]] ||
    return 64
  for required in "${required_top[@]}"; do
    [[ -n ${seen["top:$required"]+_} ]] || return 64
  done
  for required in "${required_params[@]}"; do
    [[ -n ${seen["renewalparams:$required"]+_} ]] || return 64
  done
  if [[ -n ${sections[acme_renewal_info]+_} &&
    -z ${seen["acme_renewal_info:ari_retry_after"]+_} ]]; then
    return 64
  fi
  return 0
}
