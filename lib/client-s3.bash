#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/client-s3.bash
## @brief Retrieves one selected current object without any S3 write authority.
## @details
## The caller owns an absolute private mode-0700 workspace. HeadObject 404
## proves absence only when HeadBucket succeeds. AWS errors are classified
## without exposing raw stderr or any downloaded content. The resulting
## downloaded.tar.gz contains *unvalidated* bytes for task #53.

## @fn certbotbot_client_s3_fetch()
## @brief Stages one nonempty current S3 object into a private workspace.
## @param workspace New private absolute staging directory (0700).
## @param bucket Operator-selected existing S3 bucket.
## @param key Exact selected current object key.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT; bytes staged as downloaded.tar.gz.
## @retval 0 Nonempty untrusted object staged.
## @retval 64 Invalid workspace or object selection.
## @retval 66 Confirmed absent key.
## @retval 69 Missing/incompatible AWS client or uncertain remote operation.
## @retval 74 Failed local staging or empty/partial download.
certbotbot_client_s3_fetch() {
  local workspace="${1:-}" bucket="${2:-}" key="${3:-}"
  local candidate error_file target aws_version mode
  [[ "$workspace" == /* && -d "$workspace" && ! -L "$workspace" &&
    -n "$bucket" && -n "$key" ]] ||
    { certbotbot_client_error 'invalid S3 staging arguments' 64; return 64; }
  mode="$(stat -c %a -- "$workspace" 2>/dev/null)" ||
    { certbotbot_client_error 'unsafe S3 staging directory' 64; return 64; }
  [[ "$mode" == 700 ]] ||
    { certbotbot_client_error 'unsafe S3 staging directory' 64; return 64; }
  target="$workspace/downloaded.tar.gz"
  [[ ! -e "$target" && ! -L "$target" ]] ||
    { certbotbot_client_error 'S3 staging target occupied' 74; return 74; }
  command -v aws >/dev/null 2>&1 ||
    { certbotbot_client_error 'AWS CLI v2 required' 69; return 69; }
  aws_version="$(aws --version 2>&1)" ||
    { certbotbot_client_error 'AWS CLI unavailable' 69; return 69; }
  [[ "$aws_version" == aws-cli/2.* ]] ||
    { certbotbot_client_error 'AWS CLI v2 required' 69; return 69; }
  candidate="$(umask 077; mktemp "$workspace/s3-object.XXXXXXXX")" ||
    { certbotbot_client_error 'cannot stage archive' 74; return 74; }
  error_file="$(umask 077; mktemp "$workspace/s3-error.XXXXXXXX")" ||
    { rm -f -- "$candidate"; certbotbot_client_error 'cannot stage archive' 74; return 74; }
  if ! aws --no-cli-pager s3api head-object \
    --bucket "$bucket" --key "$key" --output json \
    >/dev/null 2>"$error_file"; then
    if grep -Eq '\((404|NoSuchKey)\)' "$error_file" &&
      aws --no-cli-pager s3api head-bucket --bucket "$bucket" \
        --output json >/dev/null 2>"$error_file"; then
      rm -f -- "$candidate" "$error_file"
      certbotbot_client_error 'selected S3 archive not found' 66
      return 66
    fi
    rm -f -- "$candidate" "$error_file"
    certbotbot_client_error 'S3 object cannot be inspected safely' 69
    return 69
  fi
  if ! aws --no-cli-pager s3api get-object \
    --bucket "$bucket" --key "$key" --output json "$candidate" \
    >/dev/null 2>"$error_file"; then
    rm -f -- "$candidate" "$error_file"
    certbotbot_client_error 'S3 download unsuccessful or state uncertain' 69
    return 69
  fi
  if [[ ! -s "$candidate" ]] || ! ln -- "$candidate" "$target"; then
    rm -f -- "$candidate" "$error_file"
    certbotbot_client_error 'S3 download produced no usable staged bytes' 74
    return 74
  fi
  rm -f -- "$candidate" "$error_file"
}
