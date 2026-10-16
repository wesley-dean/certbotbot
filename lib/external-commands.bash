# shellcheck shell=bash
## @file lib/external-commands.bash
## @brief Preserves subprocess argument vectors at audited external boundaries.
## @details
## Provider implementations supply validated separate argv elements to these
## entry points.  This module does not build shell command strings, evaluate
## environment data, enable tracing, or print arguments.  PATH-based fake
## executables can exercise the wrappers in Bats without cloud credentials.
## The process inherits the producer's standard AWS credential chain.
##
## These functions are internal implementation seams, not a consumer plugin
## interface.  The public issuance path remains disabled until downstream
## certificate and archive processing has been implemented and validated.

## @fn certbotbot_command_certbot()
## @brief Invokes the installed Certbot executable with literal argv elements.
## @param args Arguments previously validated by the DNS provider.
## @returns Standard output, if any, is owned by Certbot.
## @retval 127 The Certbot executable could not be found.
## @note Other statuses are propagated unchanged from Certbot.
certbotbot_command_certbot() {
  command certbot "$@"
}

## @fn certbotbot_command_aws()
## @brief Invokes the installed AWS CLI with literal argv elements.
## @param args Arguments previously validated by the storage provider.
## @returns Standard output, if any, is owned by the AWS CLI.
## @retval 127 The AWS CLI executable could not be found.
## @note Other statuses are propagated unchanged from the AWS CLI.
certbotbot_command_aws() {
  command aws "$@"
}
