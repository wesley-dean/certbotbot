# shellcheck shell=bash
## @file lib/plugins/storage/s3.bash
## @brief Implements bounded S3 get/put adapter operations for later producers.
## @details
## This built-in module is concatenated into release artifacts during Make.
## The initial commands accept exact latest-object keys only, validate the
## storage bucket and selected endpoint, and pass arguments individually to
## the aws CLI.  Neither get nor put is called by the public entrypoint yet.
##
## The adapter does not interpret an error as "object missing".  The
## separate internal retrieval module implements the ADR-039 typed result
## contract, with a narrow confirmed NoSuchKey rule and private staging.
## This primitive retains the original nonzero AWS CLI exit status; callers
## must discard any failed or partial download without inspecting it as state.
## @see doc/adr/ADR-039-typed-s3-state-retrieval.md

## @fn certbotbot_storage_s3_validate_target()
## @brief Validates a bucket, latest-object key, and endpoint configuration.
## @param bucket Target bucket name.
## @param key Exact common or per-certificate latest archive object name.
## @retval 0 All supplied values are within the initial adapter grammar.
## @retval 64 A value is outside the supported grammar.
## @par Standard Output
## Nothing is written to STDOUT.
certbotbot_storage_s3_validate_target() {
  local LC_ALL=C
  local bucket=${1:-} key=${2:-} endpoint=${S3_ENDPOINT_URL:-}
  local environment=${ACME_ENVIRONMENT:-production} logical_key expected

  if (( $# != 2 )) ||
    [[ ! ${bucket} =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] ||
    [[ ${bucket} == *..* ]]; then
    printf '%s\n' 'invalid S3 bucket or latest-object key' >&2
    return 64
  fi

  # The S3 boundary enforces the environment namespace independently of
  # the key builder.  It must never accept a production key in staging mode.
  logical_key=${key}
  if [[ ${environment} == staging ]]; then
    if [[ ${key} != staging/* ]]; then
      printf '%s\n' 'staging writes require a staging-prefixed key' >&2
      return 64
    fi
    logical_key=${key#staging/}
  fi
  if ! expected="$(certbotbot_acme_object_key "${environment}" "${logical_key}")" ||
    [[ ${key} != "${expected}" ]]; then
    printf '%s\n' 'archive key does not belong to the selected ACME environment' >&2
    return 64
  fi

  if [[ -n ${endpoint} ]] &&
    [[ ! ${endpoint} =~ ^https?://[^[:space:]@/?#]+(/[^[:space:]?#]*)?$ ]]; then
    printf '%s\n' 'invalid S3 endpoint URL' >&2
    return 64
  fi
}

## @fn certbotbot_storage_s3_get()
## @brief Downloads one selected object to a producer-owned absolute pathname.
## @details
## The producer must stage the output in a private work directory and fully
## validate the object before extraction or use.  On failure, AWS CLI may leave
## a partial local file; this function makes no "object missing" inference.
## @param bucket Object-storage bucket.
## @param key Canonical latest-object key.
## @param destination Absolute local staging filename; may contain spaces.
## @retval 0 AWS CLI confirmed download success.
## @retval 64 Arguments or target configuration were invalid.
## @note Other statuses propagate directly from the AWS CLI.
## @par Standard Output
## Nothing is written to STDOUT.
certbotbot_storage_s3_get() {
  local bucket=${1:-} key=${2:-} destination=${3:-}
  local -a options=()

  if (( $# != 3 )) || [[ ${destination} != /* || -L ${destination} ]]; then
    printf '%s\n' 'invalid S3 download destination' >&2
    return 64
  fi
  certbotbot_storage_s3_validate_target "${bucket}" "${key}" || return $?

  if [[ -n ${S3_ENDPOINT_URL:-} ]]; then
    options=(--endpoint-url "${S3_ENDPOINT_URL}")
  fi
  certbotbot_command_aws "${options[@]}" s3api get-object \
    --bucket "${bucket}" --key "${key}" "${destination}" >/dev/null
}

## @fn certbotbot_storage_s3_put()
## @brief Uploads a prepared ordinary regular file under one latest-object key.
## @details
## The producing workflow owns archive validation, encryption, and publication
## ordering.  This operation does not inspect archive bytes or select fallback
## encryption formats; it only transfers an already approved local file.
## @param bucket Object-storage bucket.
## @param key Canonical latest-object key.
## @param source Absolute local staging filename; may contain spaces.
## @retval 0 AWS CLI confirmed upload success.
## @retval 64 Arguments or source were invalid.
## @note Other statuses propagate directly from the AWS CLI.
## @par Standard Output
## Nothing is written to STDOUT.
certbotbot_storage_s3_put() {
  local bucket=${1:-} key=${2:-} source=${3:-}
  local -a options=()

  if (( $# != 3 )) || [[ ${source} != /* || ! -f ${source} ||
    ! -r ${source} || -L ${source} ]]; then
    printf '%s\n' 'invalid S3 upload source' >&2
    return 64
  fi
  certbotbot_storage_s3_validate_target "${bucket}" "${key}" || return $?

  if [[ -n ${S3_ENDPOINT_URL:-} ]]; then
    options=(--endpoint-url "${S3_ENDPOINT_URL}")
  fi
  certbotbot_command_aws "${options[@]}" s3api put-object \
    --bucket "${bucket}" --key "${key}" --body "${source}" >/dev/null
}

## @fn certbotbot_storage_s3_run()
## @brief Dispatches the built-in storage adapter's internal get/put operations.
## @param operation Either get or put, or an unsupported future operation.
## @param args Operation-specific validated arguments.
## @retval 64 Unsupported operation.
## @note Other statuses are propagated unchanged from selected operations.
## @par Standard Output
## Nothing is written to STDOUT.
certbotbot_storage_s3_run() {
  local operation=${1:-}
  shift || return 64
  case "${operation}" in
    get) certbotbot_storage_s3_get "$@" ;;
    put) certbotbot_storage_s3_put "$@" ;;
    *) return 64 ;;
  esac
}

certbotbot_provider_register storage s3 certbotbot_storage_s3_run
