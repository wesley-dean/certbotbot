#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/s3.bash
## @brief Retrieves one mandatory S3 archive without trusting its contents.
## @details
## This first-party AWS CLI boundary follows ADR-020 and ADR-021. A successful
## read makes unvalidated bytes available only within a private workspace. It
## never extracts the archive, reads local Certbot state, issues a certificate,
## or publishes anything. All external output is withheld from CLI diagnostics.
## The archive validator, not this module, determines whether those bytes may
## become active certificate state.

## @fn certbotbot_s3_report()
## @brief Reports a static, non-sensitive failure with a defined status.
## @param message Literal error message containing no cloud output.
## @param status Defined nonzero status for this adapter.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## One static diagnostic.
## @retval 64 Invalid arguments.
## @retval 66 Seeded object positively absent.
## @retval 69 AWS state unavailable or uncertain.
## @retval 74 Download or local staging failure.
certbotbot_s3_report() {
  printf 'certbotbot: %s\n' "$1" >&2
  return "$2"
}

## @fn certbotbot_s3_fetch()
## @brief Stages the selected existing S3 archive inside an owned workspace.
## @details
## The caller must provide a newly created absolute workspace with mode 0700
## and ensure it is cleaned after use. This function refuses to overwrite a
## pre-existing downloaded.tar.gz file. It uses a successful HeadObject call
## to permit a GetObject download. A HeadObject 404 is confirmed through a
## successful HeadBucket request before declaring the seeded key absent.
## Inability to read the remote object is never an invitation to bootstrap.
##
## A nonempty GetObject result is promoted only after AWS reports success.
## Neither completeness of the tar stream nor trust in archive members is
## established here. The caller must separately verify both before extraction.
## AWS stderr and metadata are captured in private files and never repeated.
## @param workspace Private absolute directory owned by the invocation.
## @param bucket Exact existing S3 bucket name.
## @param key Exact selected S3 object key.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed safe diagnostics only; external output is never copied here.
## @retval 0 Unvalidated nonempty bytes staged at downloaded.tar.gz.
## @retval 64 Invalid workspace or configuration.
## @retval 66 A confirmed missing seeded S3 object.
## @retval 69 AWS client unavailable or remote state uncertain.
## @retval 74 Transfer, local staging, or zero-length download failed.
## @par Examples
## @code
## workspace="$(umask 077; mktemp -d)" || exit 1
## certbotbot_s3_fetch "$workspace" "$CERTBOTBOT_S3_BUCKET" "$CERTBOTBOT_S3_KEY"
## # Validate downloaded.tar.gz before extracting or using its contents.
## @endcode
certbotbot_s3_fetch() {
  local workspace="${1:-}" bucket="${2:-}" key="${3:-}"
  local target candidate error_file mode

  if [[ "$workspace" != /* || ! -d "$workspace" || -L "$workspace" ||
    -z "$bucket" || -z "$key" ]]; then
    certbotbot_s3_report 'invalid S3 staging arguments' 64
    return 64
  fi
  mode="$(stat -c %a -- "$workspace" 2>/dev/null)" ||
    { certbotbot_s3_report 'unsafe S3 staging directory' 64; return 64; }
  if [[ "$mode" != 700 ]]; then
    certbotbot_s3_report 'unsafe S3 staging directory' 64
    return 64
  fi

  target="$workspace/downloaded.tar.gz"
  if [[ -e "$target" || -L "$target" ]]; then
    certbotbot_s3_report 'S3 staging target already exists' 64
    return 64
  fi
  if ! command -v aws >/dev/null 2>&1; then
    certbotbot_s3_report 'AWS CLI v2 is required' 69
    return 69
  fi

  candidate="$(umask 077; mktemp "$workspace/s3-object.XXXXXXXX")" ||
    { certbotbot_s3_report 'cannot stage S3 object locally' 74; return 74; }
  error_file="$(umask 077; mktemp "$workspace/s3-error.XXXXXXXX")" ||
    { rm -f -- "$candidate"; certbotbot_s3_report 'cannot stage S3 object locally' 74; return 74; }

  if ! aws --no-cli-pager s3api head-object \
    --bucket "$bucket" --key "$key" --output json \
    >/dev/null 2>"$error_file"; then
    if grep -Eq '\((404|NoSuchKey)\)' "$error_file" &&
      aws --no-cli-pager s3api head-bucket --bucket "$bucket" \
        --output json >/dev/null 2>"$error_file"; then
      rm -f -- "$candidate" "$error_file"
      certbotbot_s3_report 'existing S3 archive was not found' 66
      return 66
    fi
    rm -f -- "$candidate" "$error_file"
    certbotbot_s3_report 'S3 object cannot be inspected safely' 69
    return 69
  fi

  if ! aws --no-cli-pager s3api get-object \
    --bucket "$bucket" --key "$key" --output json "$candidate" \
    >/dev/null 2>"$error_file"; then
    rm -f -- "$candidate" "$error_file"
    certbotbot_s3_report 'S3 archive download failed' 74
    return 74
  fi
  if [[ ! -s "$candidate" ]] || ! ln -- "$candidate" "$target"; then
    rm -f -- "$candidate" "$error_file"
    certbotbot_s3_report 'S3 archive staging failed' 74
    return 74
  fi

  rm -f -- "$candidate" "$error_file"
  return 0
}
