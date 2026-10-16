# shellcheck shell=bash
## @file lib/plugins/storage/s3.bash
## @brief Registers the built-in S3 object-storage implementation placeholder.
## @details
## This reviewed source module is concatenated into the release at build time.
## A future implementation will distinguish missing objects from failed reads,
## and use S3_ENDPOINT_URL for operator-trusted S3-compatible endpoints.
## No object access or modification is performed in the current phase.

## @fn certbotbot_storage_s3_run()
## @brief Rejects object operations until the S3 adapter is implemented.
## @retval 69 The provider's storage operation is not implemented.
## @par Standard Output
## Nothing is written to STDOUT.
certbotbot_storage_s3_run() {
  return 69
}

certbotbot_provider_register storage s3 certbotbot_storage_s3_run
