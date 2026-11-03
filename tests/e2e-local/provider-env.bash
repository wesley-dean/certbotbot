#!/usr/bin/env bash
# shellcheck shell=bash
## @file tests/e2e-local/provider-env.bash
## @brief Confines an unchanged public producer to the private staging gateway.
## @details
## Test-only code outside shipped source. Requires an internal container runner
## provisioned in a later task with ephemeral public gateway CA trust at
## /run/certbotbot-e2e/gateway-root.crt. Route53 deliberately fails closed
## until the separately approved task #243 supplies a verified local adapter.
## @par Usage
## @code{.sh}
## provider-env.bash --check
## provider-env.bash -- /abs/dist/certbotbot.bash --acme-environment staging ...
## @endcode

set -euo pipefail
readonly STAGING='acme-staging-v02.api.letsencrypt.org'
readonly GATEWAY_IP='172.31.248.5'
readonly S3_IP='172.31.248.4'
readonly TRUST_FILE='/run/certbotbot-e2e/gateway-root.crt'

## @fn provider_error()
## @brief Reports a bounded, nonsecret failure without overriding status.
provider_error() {
  printf 'local-provider: %s\n' "$1" >&2
}

## @fn provider_validate_args()
## @brief Requires one explicit staging selection and refuses arbitrary URLs.
provider_validate_args() {
  local -a argv=("$@")
  local i count=0
  for ((i = 1; i < ${#argv[@]}; i++)); do
    case "${argv[i]}" in
      --acme-environment=staging) count=$((count + 1)) ;;
      --acme-environment)
        ((i + 1 < ${#argv[@]})) ||
          { provider_error 'missing staging value'; return 64; }
        i=$((i + 1))
        [[ "${argv[i]}" == staging ]] ||
          { provider_error 'only explicit staging is supported'; return 64; }
        count=$((count + 1))
        ;;
      --acme-environment=*|--server|--server=*|--staging)
        provider_error 'unsupported CA or direct endpoint'
        return 64
        ;;
    esac
  done
  ((count == 1)) ||
    { provider_error 'exactly one staging selection is required'; return 64; }
}

## @fn provider_verify_isolation()
## @brief Checks network isolation, exact staging DNS, and authenticated TLS.
## @retval 0 Private canonical directory validated.
## @retval 65 Unsafe or uncertain provider boundary.
provider_verify_isolation() {
  local addresses directory
  [[ -r /proc/net/route ]] ||
    { provider_error 'route table unavailable'; return 65; }
  if awk 'NR > 1 && $2 == "00000000" { found = 1 } END { exit !found }' /proc/net/route; then
    provider_error 'default network route forbidden'
    return 65
  fi
  [[ -f "$TRUST_FILE" && ! -L "$TRUST_FILE" && -s "$TRUST_FILE" ]] ||
    { provider_error 'ephemeral test trust root unavailable'; return 65; }
  for executable in getent curl jq; do
    command -v "$executable" >/dev/null 2>&1 ||
      { provider_error 'endpoint verifier unavailable'; return 69; }
  done
  addresses="$(getent ahostsv4 "$STAGING" | awk '{print $1}' | sort -u)" ||
    { provider_error 'canonical staging name resolution failed'; return 65; }
  [[ "$addresses" == "$GATEWAY_IP" ]] ||
    { provider_error 'staging name is not bound to test gateway'; return 65; }
  if getent ahostsv4 acme-v02.api.letsencrypt.org >/dev/null 2>&1; then
    provider_error 'production CA name must not resolve'
    return 65
  fi
  directory="$(curl --noproxy '*' --fail --silent --show-error \
    --connect-timeout 2 --max-time 5 --cacert "$TRUST_FILE" \
    "https://$STAGING/directory" 2>/dev/null)" ||
    { provider_error 'authenticated staging directory unavailable'; return 65; }
  jq -e --arg prefix "https://$STAGING/" '
    (.newNonce | type == "string" and startswith($prefix))
    and (.newAccount | type == "string" and startswith($prefix))
    and (.newOrder | type == "string" and startswith($prefix))
  ' <<<"$directory" >/dev/null ||
    { provider_error 'foreign or malformed ACME directory'; return 65; }
}

## @fn main()
## @brief Runs a checksum-verified public producer with synthetic environment.
main() {
  local file sum
  [[ $# -ge 1 ]] ||
    { provider_error 'usage: --check | -- ABSOLUTE_ARTIFACT ARGS'; return 64; }
  case "$1" in
    --check)
      (($# == 1)) || { provider_error 'unexpected arguments'; return 64; }
      provider_verify_isolation
      ;;
    --)
      shift
      (($# >= 2)) ||
        { provider_error 'public artifact and CLI required'; return 64; }
      file="$1"
      [[ "$file" == /* && -x "$file" && -f "$file" && ! -L "$file" ]] ||
        { provider_error 'invalid public artifact'; return 65; }
      provider_validate_args "$@" || return $?
      command -v sha256sum >/dev/null 2>&1 ||
        { provider_error 'checksum tool unavailable'; return 69; }
      [[ -f "$file.sha256" && ! -L "$file.sha256" ]] ||
        { provider_error 'checksum companion missing'; return 65; }
      sum="$(sha256sum "$file" | awk '{print $1}')" ||
        { provider_error 'cannot hash public artifact'; return 65; }
      [[ "$(cat "$file.sha256")" == "$sum  ${file##*/}" ]] ||
        { provider_error 'public artifact checksum mismatch'; return 65; }
      provider_verify_isolation || return $?
      # No inherited profile/IMDS/proxy/user CA or Certbot configuration.
      # Local Route53 intentionally points at a closed loopback port until
      # the separately reviewed real DNS bridge (#243) is installed.
      env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/tmp TMPDIR=/tmp \
        AWS_ACCESS_KEY_ID=CBOTBOT_LOCAL_TEST_ACCESS_ONLY \
        AWS_SECRET_ACCESS_KEY=CBOTBOT_LOCAL_TEST_SECRET_NOT_A_CLOUD_KEY \
        AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1 \
        AWS_EC2_METADATA_DISABLED=true AWS_CONFIG_FILE=/dev/null \
        AWS_SHARED_CREDENTIALS_FILE=/dev/null \
        AWS_ENDPOINT_URL_S3="http://$S3_IP:8333" \
        AWS_ENDPOINT_URL_ROUTE53=http://127.0.0.1:9 \
        REQUESTS_CA_BUNDLE="$TRUST_FILE" SSL_CERT_FILE="$TRUST_FILE" \
        CURL_CA_BUNDLE="$TRUST_FILE" \
        "$@"
      ;;
    *)
      provider_error 'usage: --check | -- ABSOLUTE_ARTIFACT ARGS'
      return 64
      ;;
  esac
}
main "$@"
