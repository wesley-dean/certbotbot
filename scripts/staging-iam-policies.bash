#!/usr/bin/env bash
# shellcheck shell=bash
## @file scripts/staging-iam-policies.bash
## @brief Print narrowly scoped AWS IAM policies for manual ACME staging.
## @details
## Generates an OIDC trust or Route53 permissions policy from validated
## operator-selected identifiers, without accessing any cloud credentials,
## GitHub secrets, API, DNS record, or network. The example real staging
## workflow remains inactive until the operator explicitly installs it.
## Three concrete names correspond to three DNS-01 TXT challenge owners;
## the second lineage's wildcard shares the second-name challenge owner.
## @see doc/adr/ADR-056-offline-staging-iam-policies.md

set -euo pipefail
umask 077

## @fn staging_iam_usage()
## @brief Explain all required parameters and the document-only effect.
## @retval 0 Usage printed.
## @par STDIN
## Nothing is read from STDIN.
## @returns Usage text on STDOUT.
staging_iam_usage() {
  cat <<'HELP'
Usage: staging-iam-policies.bash --document trust|permissions \
  --account-id AWS_ACCOUNT_ID --repository OWNER/REPO \
  --zone-id ROUTE53_ZONE_ID --domain BASE \
  --extra-name EXTRA --second-name SECOND

Prints one JSON policy on STDOUT without network access or cloud changes.
All names must be canonical, concrete and in the same owned staging zone.
The trust policy requires a protected acme-staging GitHub environment.
HELP
}

## @fn staging_iam_invalid()
## @brief Reject requests with no policy output.
## @retval 64 Invalid input.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
staging_iam_invalid() {
  printf 'invalid staging IAM policy request (see --help)\n' >&2
  return 64
}

## @fn staging_iam_hostname()
## @brief Validate lower-case concrete ASCII DNS hostname labels.
## @param value Candidate domain or fully qualified subdomain.
## @retval 0 Canonical bounded non-wildcard hostname.
## @retval 1 Invalid name.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
staging_iam_hostname() {
  local value=${1:-} label=''
  local -a labels=()
  [[ -n $value && ${#value} -le 253 && $value == *.* &&
    $value != .* && $value != *. && $value != *'..'* &&
    $value != *'*'* && $value == "${value,,}" ]] || return 1
  local IFS='.'
  read -r -a labels <<< "$value"
  (( ${#labels[@]} >= 2 )) || return 1
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 &&
      $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

## @fn staging_iam_main()
## @brief Render exactly one validated least-privilege IAM policy.
## @param args One selector and six required, unique named parameters.
## @retval 0 Full JSON document printed.
## @retval 64 Missing, duplicate, invalid, or unsupported arguments.
## @note Neither calls AWS nor installs the inactive staging workflow.
## @par STDIN
## Nothing is read from STDIN.
## @returns One trust or permissions JSON policy on STDOUT.
staging_iam_main() {
  local document='' account='' repo='' zone='' domain='' extra='' second=''
  if (( $# == 1 )) && [[ $1 == --help ]]; then
    staging_iam_usage
    return 0
  fi
  while (( $# > 0 )); do
    if (( $# < 2 )); then
      staging_iam_invalid
      return 64
    fi
    case $1 in
      --document)
        [[ -z $document && -n $2 ]] || { staging_iam_invalid; return 64; }
        document=$2
        ;;
      --account-id)
        [[ -z $account && -n $2 ]] || { staging_iam_invalid; return 64; }
        account=$2
        ;;
      --repository)
        [[ -z $repo && -n $2 ]] || { staging_iam_invalid; return 64; }
        repo=$2
        ;;
      --zone-id)
        [[ -z $zone && -n $2 ]] || { staging_iam_invalid; return 64; }
        zone=$2
        ;;
      --domain)
        [[ -z $domain && -n $2 ]] || { staging_iam_invalid; return 64; }
        domain=$2
        ;;
      --extra-name)
        [[ -z $extra && -n $2 ]] || { staging_iam_invalid; return 64; }
        extra=$2
        ;;
      --second-name)
        [[ -z $second && -n $2 ]] || { staging_iam_invalid; return 64; }
        second=$2
        ;;
      *)
        staging_iam_invalid
        return 64
        ;;
    esac
    shift 2
  done

  if ! {
    [[ $document == trust || $document == permissions ]] &&
      [[ $account =~ ^[0-9]{12}$ ]] &&
      [[ $repo =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ &&
        ${#repo} -le 140 ]] &&
      [[ $zone =~ ^Z[A-Z0-9]{5,35}$ ]] &&
      staging_iam_hostname "$domain" &&
      staging_iam_hostname "$extra" &&
      staging_iam_hostname "$second" &&
      [[ $extra == *".$domain" && $second == *".$domain" &&
        $extra != "$second" ]]
  }; then
    staging_iam_invalid
    return 64
  fi

  if [[ $document == trust ]]; then
    cat <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowProtectedStagingEnvironmentOnly",
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::$account:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:$repo:environment:acme-staging"
        }
      }
    }
  ]
}
POLICY
  else
    cat <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ChangeOnlyApprovedStagingTXT",
      "Effect": "Allow",
      "Action": "route53:ChangeResourceRecordSets",
      "Resource": "arn:aws:route53:::hostedzone/$zone",
      "Condition": {
        "ForAllValues:StringEquals": {
          "route53:ChangeResourceRecordSetsNormalizedRecordNames": [
            "_acme-challenge.$domain",
            "_acme-challenge.$extra",
            "_acme-challenge.$second"
          ],
          "route53:ChangeResourceRecordSetsRecordTypes": ["TXT"],
          "route53:ChangeResourceRecordSetsActions": ["CREATE", "UPSERT", "DELETE"]
        },
        "Null": {
          "route53:ChangeResourceRecordSetsNormalizedRecordNames": "false",
          "route53:ChangeResourceRecordSetsRecordTypes": "false",
          "route53:ChangeResourceRecordSetsActions": "false"
        }
      }
    },
    {
      "Sid": "DiscoverStagingRoute53Zone",
      "Effect": "Allow",
      "Action": "route53:ListHostedZones",
      "Resource": "*"
    },
    {
      "Sid": "PollStagingDNSChange",
      "Effect": "Allow",
      "Action": "route53:GetChange",
      "Resource": "arn:aws:route53:::change/*"
    }
  ]
}
POLICY
  fi
}

staging_iam_main "$@"
