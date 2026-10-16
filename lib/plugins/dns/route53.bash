# shellcheck shell=bash
## @file lib/plugins/dns/route53.bash
## @brief Registers the built-in Route53 DNS-01 implementation placeholder.
## @details
## This reviewed source module is concatenated into the release at build time.
## The actual Certbot DNS Route53 adapter will be implemented in Phase 3.
## Until then, its operation fails without creating external side effects.

## @fn certbotbot_dns_route53_run()
## @brief Rejects DNS issuance until the Certbot adapter is implemented.
## @retval 69 The provider's issuing operation is not implemented.
## @par Standard Output
## Nothing is written to STDOUT.
certbotbot_dns_route53_run() {
  return 69
}

certbotbot_provider_register dns route53 certbotbot_dns_route53_run
