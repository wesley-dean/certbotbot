# shellcheck shell=bash
## @file lib/state-identity.bash
## @brief Checks that restored account and lineage metadata select the same CA.
## @details
## This is a read-only gate between isolated account/domain archive staging
## and any future Certbot invocation.  It reads the selected lineage's
## renewal/<name>.conf as data, requires unique server/account/authenticator
## values inside [renewalparams], and confirms that the referenced account
## directory exists under the selected Let's Encrypt authority.  The
## production/staging identity is supplied explicitly and must agree with
## ACME_ENVIRONMENT when that runtime value is set.
##
## This function does NOT parse account JSON, select an account in Certbot,
## normalize historical absolute paths, approve arbitrary renewal options,
## or enable issuance or publication.  Other renewal configuration fields
## are outside this helper's identity-verification guarantee.  Active Certbot
## use still requires the separate portability and restored-hook review.
## @see doc/adr/ADR-025-certbot-state-portability-and-issuance-boundary.md
## @see doc/adr/ADR-031-restored-acme-account-and-lineage-identity.md

## @fn certbotbot_state_verify_identity()
## @brief Checks that a staged lineage references the selected restored CA.
## @param account_root Private, already validated common-account staging root.
## @param lineage_root Private, already validated domain staging root.
## @param name Canonical lineage identity without a leading wildcard.
## @param environment production or staging, matching the selected run.
## @retval 0 Exact account identity, environment, and DNS authenticator match.
## @retval 64 Invalid arguments, unsafe stage paths, or unsupported input.
## @retval 65 Mismatched, missing, ambiguous, or incomplete account identity.
## @retval 73 Error reading necessary filesystem metadata.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @note Validity of JSON registration and portability of archive_dir, live,
## and renewal file paths are NOT established by this check.
certbotbot_state_verify_identity() {
  local LC_ALL=C
  local account_root=${1:-} lineage_root=${2:-}
  local name=${3:-} environment=${4:-}
  local config='' line='' section='' key='' value='' server=''
  local account='' authenticator='' expected='' host='' dir=''
  local mode='' bytes='' stripped='' lines=0
  local trimmed_line='' comment_marker=''
  printf -v comment_marker '%b' '\043'
  local -A seen=()
  local -a files=(meta.json regr.json private_key.json)

  if (( $# != 4 )) ||
    ! certbotbot_validate_hostname "$name" ||
    [[ $name == \*.* || $name != "${name,,}" ]] ||
    ! certbotbot_acme_validate_environment "$environment" ||
    [[ $environment != "${ACME_ENVIRONMENT:-production}" ||
      -z $CERTBOTBOT_COMMON_STAGE || -z $CERTBOTBOT_RESTORE_ROOT ||
      $account_root != "$CERTBOTBOT_COMMON_STAGE" ||
      $lineage_root != "$CERTBOTBOT_RESTORE_ROOT" ]]; then
    return 64
  fi
  if ! certbotbot_pem_check_directory "$account_root" ||
    ! certbotbot_pem_check_directory "$lineage_root"; then
    return 64
  fi
  for dir in "$account_root" "$lineage_root"; do
    mode="$(stat -c '%a' -- "$dir")" || return 73
    if [[ ! $mode =~ ^[0-7]{3,4}$ ]] ||
      (( (8#$mode & 8#77) != 0 )); then
      return 64
    fi
  done
  config="$lineage_root/renewal/$name.conf"
  if [[ ! -f $config || -L $config || ! -O $config || ! -r $config ||
    ! -s $config ]] ||
    ! certbotbot_pem_check_directory "$lineage_root/renewal"; then
    return 64
  fi
  bytes="$(stat -c '%s' -- "$config")" || return 73
  if [[ ! $bytes =~ ^[0-9]{1,6}$ ]] || (( bytes > 131072 )); then
    return 64
  fi
  # Bash read skips NUL bytes, which could make two consumers interpret the
  # same renewal file differently.  Refuse such files before INI inspection.
  stripped="$(LC_ALL=C tr -d '\000' < "$config" | wc -c)" || return 73
  if (( stripped != bytes )); then
    return 64
  fi

  expected="$(certbotbot_acme_directory "$environment")" || return 64
  while IFS= read -r line || [[ -n $line ]]; do
    (( lines += 1 ))
    if (( lines > 4096 )) || [[ $line == *$'\r'* ]]; then
      return 64
    fi
    if [[ $line =~ ^[[:space:]]*$ ]]; then
      continue
    fi
    trimmed_line=${line#"${line%%[![:space:]]*}"}
    if [[ ${trimmed_line:0:1} == "$comment_marker" ]]; then
      continue
    fi
    if [[ $line =~ ^[[:space:]]*\[([a-z_]+)\][[:space:]]*$ ]]; then
      section=${BASH_REMATCH[1]}
      case "$section" in
        renewalparams | acme_renewal_info) ;;
        *) return 64 ;;
      esac
      if [[ $section == renewalparams ]]; then
        if [[ -n ${seen[section]+_} ]]; then
          return 65
        fi
        seen[section]=1
      fi
      continue
    fi
    if [[ ! $line =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z_0-9]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      return 64
    fi
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    value=${value%"${value##*[![:space:]]}"}
    if [[ $key == *hook* || $key == installer ]]; then
      return 64
    fi
    if [[ $section != renewalparams ]]; then
      if [[ $key == server || $key == account || $key == authenticator ]]; then
        return 65
      fi
      continue
    fi
    case "$key" in
      server | account | authenticator)
        if [[ -n ${seen[$key]+_} ]]; then
          return 65
        fi
        seen["$key"]=1
        case "$key" in
          server) server=$value ;;
          account) account=$value ;;
          authenticator) authenticator=$value ;;
        esac
        ;;
      *) ;;
    esac
  done <"$config"

  if [[ -z ${seen[section]+_} || -z ${seen[server]+_} ||
    -z ${seen[account]+_} || -z ${seen[authenticator]+_} ||
    $server != "$expected" || $authenticator != dns-route53 ||
    ! $account =~ ^[a-f0-9]{32,64}$ ]]; then
    return 65
  fi

  case "$environment" in
    production) host='acme-v02.api.letsencrypt.org' ;;
    staging) host='acme-staging-v02.api.letsencrypt.org' ;;
  esac
  dir="$account_root/accounts/$host/directory/$account"
  if ! certbotbot_pem_check_directory "$dir"; then
    return 65
  fi
  mode="$(stat -c '%a' -- "$dir")" || return 73
  if [[ ! $mode =~ ^[0-7]{3,4}$ ]] ||
    (( (8#$mode & 8#77) != 0 )); then
    return 65
  fi
  local file
  for file in "${files[@]}"; do
    local path="$dir/$file"
    if [[ ! -f $path || -L $path || ! -O $path || ! -r $path ||
      ! -s $path ]]; then
      return 65
    fi
    mode="$(stat -c '%a' -- "$path")" || return 73
    if [[ ! $mode =~ ^[0-7]{3,4}$ ]] ||
      (( (8#$mode & 8#77) != 0 )); then
      return 65
    fi
  done
  return 0
}
