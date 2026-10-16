# shellcheck shell=bash
## @file lib/input.bash
## @brief Parses independent certificate requests without shell evaluation.
## @details
## One nonblank physical input line defines one Certbot lineage.  The first
## token supplies both the lineage identity and its implicit apex/wildcard SANs.
## Additional SANs are used literally, with stable first-occurrence ordering.
## Parsed names and whitespace-delimited normalized SAN records remain in
## parallel arrays.  SAN text is safe to split later because every validated
## token contains only ASCII DNS-label characters, dots, and a leading wildcard.
##
## This parser does not access AWS, Certbot, S3, files outside an explicitly
## selected input file, or any account/certificate state.

declare -a CERTBOTBOT_REQUEST_NAMES=()
declare -a CERTBOTBOT_REQUEST_SANS=()

## @fn certbotbot_validate_hostname()
## @brief Validates an ASCII FQDN, allowing an optional leading wildcard.
## @details
## A wildcard is accepted only as one leading "*." and the underlying name
## requires at least two labels.  This conservative grammar rejects Unicode
## (IDNs must be supplied as punycode), underscores, trailing dots, IP literals
## with colons, option-looking names, and path or shell metacharacters.
## @param hostname Candidate DNS hostname.
## @retval 0 Candidate satisfies the accepted hostname grammar.
## @retval 1 Candidate is invalid.
## @par Standard Output
## Nothing is written to STDOUT.
certbotbot_validate_hostname() {
  local hostname=${1:-} label
  local -a labels=()

  if [[ "${hostname}" == \*.* ]]; then
    hostname=${hostname#\*.}
  fi

  if (( ${#hostname} == 0 || ${#hostname} > 253 )) ||
    [[ "${hostname}" == .* || "${hostname}" == *. || "${hostname}" == *'*'* ]]; then
    return 1
  fi

  local IFS='.'
  read -r -a labels <<< "${hostname}"
  if (( ${#labels[@]} < 2 )); then
    return 1
  fi
  for label in "${labels[@]}"; do
    if (( ${#label} == 0 || ${#label} > 63 )) ||
      [[ ! "${label}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
      return 1
    fi
  done
}

## @fn certbotbot_input_add_line()
## @brief Parses one physical certificate line into normalized request arrays.
## @details
## Empty or whitespace-only lines are ignored in batch mode.  Domain values
## are canonicalized to ASCII lowercase before validation and deduplication.
## Duplicate lineage identities fail rather than silently overriding earlier
## SAN sets.  No partial request from a failing line is appended to the arrays.
## @param line Physical input line without its newline terminator.
## @retval 0 A new lineage was appended or a blank line was ignored.
## @retval 64 The line contains invalid/duplicate certificate data.
## @par Standard Output
## Nothing is written to STDOUT.
certbotbot_input_add_line() {
  local line=${1:-} raw name primary san existing
  local -a tokens=() sans=()
  local -A seen=()
  local IFS=$' \t\n'

  # Permit CRLF files while rejecting embedded CR via hostname validation.
  line=${line%$'\r'}
  if [[ "${line}" == *$'\n'* ]]; then
    printf '%s\n' 'embedded newline in certificate group' >&2
    return 64
  fi
  read -r -a tokens <<< "${line}"
  if (( ${#tokens[@]} == 0 )); then
    return 0
  fi

  primary=${tokens[0],,}
  name=${primary#\*.}
  if ! certbotbot_validate_hostname "${primary}"; then
    printf '%s\n' 'invalid primary certificate hostname' >&2
    return 64
  fi

  for existing in "${CERTBOTBOT_REQUEST_NAMES[@]}"; do
    if [[ "${existing}" == "${name}" ]]; then
      printf 'duplicate certificate lineage: %s\n' "${name}" >&2
      return 64
    fi
  done

  sans=("${name}" "*.${name}")
  seen["${name}"]=1
  seen["*.${name}"]=1

  for raw in "${tokens[@]:1}"; do
    san=${raw,,}
    if ! certbotbot_validate_hostname "${san}"; then
      printf '%s\n' 'invalid additional certificate hostname' >&2
      return 64
    fi
    if [[ -z ${seen[${san}]+_} ]]; then
      sans+=("${san}")
      seen["${san}"]=1
    fi
  done

  CERTBOTBOT_REQUEST_NAMES+=("${name}")
  CERTBOTBOT_REQUEST_SANS+=("${sans[*]}")
}

## @fn certbotbot_input_parse()
## @brief Parses either one positional group or a multi-line configuration.
## @details
## The caller selects exactly one source: positional arguments, a
## certificates-file, or the CERTIFICATES environment value.  Files are read
## line by line without evaluating their contents.  Empty whole inputs fail,
## so the caller can never accidentally request "renew everything".
## @param mode Either args, file, or env.
## @param payload File path when mode=file; otherwise positional SAN tokens.
## @retval 0 At least one unique certificate group was parsed.
## @retval 64 Invalid/ambiguous input or unreadable file.
## @par Standard Output
## Nothing is written to STDOUT.
certbotbot_input_parse() {
  local mode=${1:-} line path
  local IFS=' '
  shift || return 64
  CERTBOTBOT_REQUEST_NAMES=()
  CERTBOTBOT_REQUEST_SANS=()

  case "${mode}" in
    args)
      for line in "$@"; do
        if [[ "${line}" == *$'\n'* || "${line}" == *$'\r'* ]]; then
          printf '%s\n' 'positional arguments cannot contain line breaks' >&2
          return 64
        fi
      done
      certbotbot_input_add_line "$*" || return $?
      ;;
    env)
      while IFS= read -r line || [[ -n "${line}" ]]; do
        certbotbot_input_add_line "${line}" || return $?
      done <<< "${CERTIFICATES:-}"
      ;;
    file)
      path=${1:-}
      if (( $# != 1 )) || [[ ! -f "${path}" || ! -r "${path}" ]]; then
        printf '%s\n' 'certificate input file is unavailable' >&2
        return 64
      fi
      while IFS= read -r line || [[ -n "${line}" ]]; do
        certbotbot_input_add_line "${line}" || return $?
      done < "${path}"
      ;;
    *)
      printf '%s\n' 'unknown certificate input mode' >&2
      return 64
      ;;
  esac

  if (( ${#CERTBOTBOT_REQUEST_NAMES[@]} == 0 )); then
    printf '%s\n' 'at least one certificate group is required' >&2
    return 64
  fi
}
