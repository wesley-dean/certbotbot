# shellcheck shell=bash
## @file lib/plugins/dns/route53.bash
## @brief Supplies fixed DNS-01 Route53 options and a read-only Certbot probe.
## @details
## The module is included in every generated artifact through deterministic
## build-time discovery.  Route53 will become the first issuing backend in
## Phase 3, after renewal behavior and portable Certbot state are verified.
## The only executable operation implemented here asks Certbot for its version;
## arbitrary Certbot arguments are not exposed through the provider registry.
## Normal certificate issuance remains explicitly unsupported.

declare -a CERTBOTBOT_DNS_CHALLENGE_ARGS=()

## @fn certbotbot_dns_route53_challenge_args()
## @brief Prepares fixed DNS-01 authenticator option-vector elements.
## @retval 0 Route53 options were populated.
## @par Standard Output
## Nothing is written to STDOUT.
certbotbot_dns_route53_challenge_args() {
  # The array is consumed by other modules after standalone assembly.
  # shellcheck disable=SC2034
  CERTBOTBOT_DNS_CHALLENGE_ARGS=(--dns-route53 --preferred-challenges dns)
}

## @fn certbotbot_dns_route53_run()
## @brief Probes Certbot availability or fails closed for issuance operations.
## @param operation The supported read-only operation probe.
## @retval 0 Certbot --version completed successfully.
## @retval 64 Invalid probe invocation.
## @retval 69 Issuance operation has not been implemented.
## @note Other statuses propagate from the read-only Certbot subprocess.
## @par Standard Output
## Nothing is written to STDOUT.
certbotbot_dns_route53_run() {
  local operation=${1:-}
  case "${operation}" in
    probe)
      if (( $# != 1 )); then
        return 64
      fi
      certbotbot_command_certbot --version >/dev/null
      ;;
    *)
      return 69
      ;;
  esac
}

certbotbot_provider_register dns route53 certbotbot_dns_route53_run
