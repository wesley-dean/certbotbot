# shellcheck shell=bash
## @file lib/plugins/dns/route53.bash
## @brief Defines the bundled Route53 DNS-01 Certbot command contract.
## @details
## This provider is discoverable at build time only.  For every issuing request,
## the caller supplies an already validated lineage name, private Certbot
## directories, an account email, and the complete normalized DNS SAN list.
## The provider verifies the apex/wildcard pair and uses one quoted -d argument
## per SAN.  The invocation explicitly selects certonly and DNS challenges,
## keeping HTTP/TLS-ALPN challenge mechanisms outside the supported behavior.
##
## This command interface is testable using an injected fake certbot binary.
## The current public certbotbot entrypoint deliberately does not call it:
## restoring Certbot's path-bearing renewal state and securely republishing
## domain archives are prerequisites to exposing live issuance to consumers.
## @see doc/adr/ADR-018-certificate-identity-and-dns-issuance.md
## @see doc/adr/ADR-025-certbot-state-portability-and-issuance-boundary.md

declare -a CERTBOTBOT_DNS_CHALLENGE_ARGS=()

## @fn certbotbot_dns_route53_challenge_args()
## @brief Prepares the DNS-01-specific Certbot option vector.
## @retval 0 Route53 options were populated.
## @par Standard Output
## Nothing is written to STDOUT.
certbotbot_dns_route53_challenge_args() {
  # The array is consumed by other modules after standalone assembly.
  # shellcheck disable=SC2034
  CERTBOTBOT_DNS_CHALLENGE_ARGS=(--dns-route53 --preferred-challenges dns)
}

## @fn certbotbot_dns_route53_validate_directory()
## @brief Ensures an input Certbot directory is private and owned by the caller.
## @param path Absolute existing directory path.
## @retval 0 An existing non-symlink private directory was verified.
## @retval 64 The path or its ownership/permissions are unsuitable.
## @par Standard Output
## Nothing is written to STDOUT.
certbotbot_dns_route53_validate_directory() {
  local directory=${1:-} mode
  if (( $# != 1 )) || [[ ${directory} != /* || ! -d ${directory} ||
    -L ${directory} || ! -O ${directory} ]]; then
    return 64
  fi
  if ! mode="$(stat -c '%a' -- "${directory}")" ||
    [[ ! "${mode}" =~ ^[0-7]{3,4}$ ]] ||
    (( (8#${mode} & 8#77) != 0 )); then
    return 64
  fi
}

## @fn certbotbot_dns_route53_issue()
## @brief Requests a Certbot DNS-01 lineage without installing it on a webserver.
## @details
## The caller owns the private temporary workspace and passes its already
## created config, work, and log directories separately, then the exact SANs.
## Certbot's own renewal eligibility determines whether an unchanged lineage
## is renewed.  --renew-with-new-domains permits deliberate SAN replacement.
## The first domain identity MUST appear along with its wildcard; any other
## SANs are included verbatim without deriving additional wildcard names.
##
## This internal method does not create or publish archives, perform credential
## acquisition, or translate renewal-config absolute paths.  The production
## orchestrator must handle those responsibilities before calling this method.
## @param name Canonical certificate lineage identity, without wildcard prefix.
## @param config_dir Existing private Certbot configuration directory.
## @param work_dir Existing private Certbot working directory.
## @param logs_dir Existing private Certbot logging directory.
## @param email ACME account email for non-interactive registration/selection.
## @param sans Two or more validated DNS identities for this certificate.
## @retval 64 Invalid or unsafe issuance inputs; Certbot was not invoked.
## @retval 69 Registration/terms configuration unsupported by this stage.
## @note Other status values propagate unchanged from the Certbot process.
## @par Standard Output
## Certbot owns any standard output from its invoked process.
## @par Examples
## @code
## certbotbot_dns_route53_issue example.com "$config" "$work" "$logs" \
##   admin@example.com example.com '*.example.com' www.example.com
## @endcode
certbotbot_dns_route53_issue() {
  local LC_ALL=C
  local name=${1:-} config_dir=${2:-} work_dir=${3:-}
  local logs_dir=${4:-} email=${5:-} san
  local seen_apex=false seen_wildcard=false acme_server=''
  local -a certbot_args=()
  local -A seen_domains=()

  if (( $# < 7 )) ||
    [[ ${name} == \*.* ]] ||
    ! certbotbot_validate_hostname "${name}" ||
    [[ ${name} != "${name,,}" ]] ||
    [[ ! ${email} =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+$ ]] ||
    [[ ${AGREE_TOS:-true} != true ]]; then
    return 64
  fi
  if [[ ${REGISTER_ACCOUNT:-true} != true ]]; then
    # Prevent accidental implicit account registration until account selection
    # and restored-account verification are implemented in the producer.
    return 69
  fi

  certbotbot_dns_route53_validate_directory "${config_dir}" || return 64
  certbotbot_dns_route53_validate_directory "${work_dir}" || return 64
  certbotbot_dns_route53_validate_directory "${logs_dir}" || return 64

  shift 5
  for san in "$@"; do
    if ! certbotbot_validate_hostname "${san}" ||
      [[ ${san} != "${san,,}" ||
        -n ${seen_domains[${san}]+_} ]]; then
      return 64
    fi
    seen_domains["${san}"]=1
    if [[ ${san} == "${name}" ]]; then
      seen_apex=true
    elif [[ ${san} == "*.${name}" ]]; then
      seen_wildcard=true
    fi
  done
  if [[ ${seen_apex} != true || ${seen_wildcard} != true ]]; then
    return 64
  fi

  if ! acme_server="$(certbotbot_acme_directory "${ACME_ENVIRONMENT:-production}")"; then
    return 64
  fi
  certbotbot_dns_route53_challenge_args
  # Keep each Bash array assignment on one physical line: Bash-Minifier's
  # pinned release does not preserve multiline compound array initializers.
  certbot_args=(certonly --non-interactive)
  certbot_args+=("${CERTBOTBOT_DNS_CHALLENGE_ARGS[@]}")
  certbot_args+=(--server "${acme_server}")
  certbot_args+=(--cert-name "${name}" --config-dir "${config_dir}")
  certbot_args+=(--work-dir "${work_dir}" --logs-dir "${logs_dir}")
  certbot_args+=(--keep-until-expiring --renew-with-new-domains --agree-tos)
  certbot_args+=(--email "${email}")
  for san in "$@"; do
    certbot_args+=(-d "${san}")
  done
  certbotbot_command_certbot "${certbot_args[@]}"
}

## @fn certbotbot_dns_route53_run()
## @brief Dispatches the limited built-in Route53 operations.
## @param operation probe, issue, or an unsupported operation.
## @param args Operation-specific arguments.
## @retval 64 Invalid probe arguments.
## @retval 69 Unsupported operation.
## @note Other statuses propagate from Certbot or issue validation.
## @par Standard Output
## Certbot owns standard output from the issue operation; probe is silent.
certbotbot_dns_route53_run() {
  local operation=${1:-}
  shift || return 64
  case "${operation}" in
    probe)
      if (( $# != 0 )); then
        return 64
      fi
      certbotbot_command_certbot --version >/dev/null
      ;;
    issue) certbotbot_dns_route53_issue "$@" ;;
    *) return 69 ;;
  esac
}

certbotbot_provider_register dns route53 certbotbot_dns_route53_run
