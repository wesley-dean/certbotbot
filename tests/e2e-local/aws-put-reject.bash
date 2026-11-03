#!/usr/bin/env bash
# shellcheck shell=bash
## @file tests/e2e-local/aws-put-reject.bash
## @brief Rejects one S3 PutObject only in the isolated negative E2E profile.
## @details
## This test-only PATH adapter is NOT a replacement for real AWS CLI behavior.
## Every call delegates to the installed /usr/bin/aws unchanged, except an
## explicit bounded "s3-put-reject" fault, which returns a nonzero status
## without accepting a write. A private receipt proves the producer reached
## the publication boundary. No fake successful storage response is permitted.

set -euo pipefail
umask 077

readonly AWS_REAL=/usr/bin/aws
readonly RECEIPT=/tmp/.certbotbot-e2e-put-rejected

## @fn main()
## @brief Forwards real AWS calls unless one approved negative PUT is selected.
## @param ... AWS CLI argv (original order preserved).
main() {
  [[ -x "$AWS_REAL" ]] || return 69
  local mode="${LOCAL_E2E_FAULT_MODE-}"
  local -a argv=("$@")
  case "$mode" in
    ''|s3-unavailable|route53-unavailable|acme-unavailable|corrupt-archive|ca-production)
      exec "$AWS_REAL" "$@"
      ;;
    s3-put-reject)
      if [[ "${argv[0]-}" == --no-cli-pager ]]; then
        argv=("${argv[@]:1}")
      fi
      if [[ "${argv[0]-}" == s3api && "${argv[1]-}" == put-object ]]; then
        # Only the synthetic owned bucket and current object are eligible.
        local bucket='' key='' i
        for ((i = 2; i < ${#argv[@]}; i++)); do
          case "${argv[i]}" in
            --bucket)
              (( i + 1 < ${#argv[@]} )) || return 65
              bucket="${argv[++i]}"
              ;;
            --key)
              (( i + 1 < ${#argv[@]} )) || return 65
              key="${argv[++i]}"
              ;;
          esac
        done
        [[ "$bucket" == certbotbot-local-e2e && "$key" == latest.tar.gz ]] ||
          return 65
        printf '%s\n' 'synthetic-s3-put-rejected' >"$RECEIPT" || return 74
        chmod 600 -- "$RECEIPT" || return 74
        printf '%s\n' 'local-s3-fault: intentional PutObject rejection' >&2
        return 75
      fi
      exec "$AWS_REAL" "$@"
      ;;
    *)
      printf '%s\n' 'local-s3-fault: invalid fault profile' >&2
      return 64
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
