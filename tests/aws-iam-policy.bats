#!/usr/bin/env bats

## @file tests/aws-iam-policy.bats
## @brief Offline least-privilege structural regression for task #292.
## @details
## Tests the tracked IAM identity-policy template, not live AWS authority.
## No sts, s3api, route53 or ACME calls are performed. Action/resource
## compatibility has been reviewed against official AWS and Certbot docs.
## The policy is unusable until an administrator replaces every placeholder.

setup() {
  POLICY="$BATS_TEST_DIRNAME/../doc/examples/aws-iam-policy.json"
  command -v jq >/dev/null 2>&1 || skip 'jq unavailable'
  [ -f "$POLICY" ]
}

@test "runtime policy is valid identity-policy JSON with five scoped statements" {
  run jq -e '
    .Version == "2012-10-17"
    and (.Statement | type == "array" and length == 5)
    and all(.Statement[]; .Effect == "Allow"
      and (.Sid | type == "string")
      and (.Resource != null)
      and (.Action != null))
    and (has("Principal") | not)
  ' "$POLICY"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
}

@test "bucket enumeration and exact current object have separate S3 ARNs" {
  run jq -e '
    [ .Statement[] | select(.Sid ==
      "InspectDedicatedBucketAndClassifyMissingCurrentKey") ] | length == 1
  ' "$POLICY"
  [ "$status" -eq 0 ]
  run jq -e '
    ([ .Statement[] | select(.Sid ==
      "InspectDedicatedBucketAndClassifyMissingCurrentKey") ][0] |
      .Action == "s3:ListBucket" and
      .Resource == "arn:aws:s3:::REPLACE_WITH_PRIVATE_BUCKET")
    and
    ([ .Statement[] | select(.Sid ==
      "ReadAndPublishOnlyTheAuthoritativeCurrentObject") ][0] |
      .Action == ["s3:GetObject", "s3:PutObject"] and
      .Resource ==
        "arn:aws:s3:::REPLACE_WITH_PRIVATE_BUCKET/REPLACE_WITH_CURRENT_KEY.tar.gz")
  ' "$POLICY"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
}

@test "runtime IAM action set excludes backups, provisioning, mutation and deletion" {
  run jq -e '
    ([.Statement[].Action] | flatten | sort) ==
      (["s3:ListBucket", "s3:GetObject", "s3:PutObject",
        "route53:ListHostedZones", "route53:GetChange",
        "route53:ChangeResourceRecordSets"] | sort)
  ' "$POLICY"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
  run jq -e '
    all(.Statement[];
      if (.Action | type) == "string" then
        (.Action | (startswith("iam:") or startswith("kms:") or
          startswith("sts:") or startswith("s3:Delete")) | not)
      else true end)
  ' "$POLICY"
  [ "$status" -eq 0 ]
}

@test "Route53 discovery is the only global wildcard and GetChange is change-scoped" {
  run jq -e '
    ([.Statement[] | select(.Resource == "*")] | length) == 1
    and
    ([.Statement[] | select(.Sid ==
      "DiscoverHostedZoneForCertbotRoute53Plugin")][0] |
      .Action == "route53:ListHostedZones" and .Resource == "*")
    and
    ([.Statement[] | select(.Sid ==
      "PollCertbotSubmittedRecordChange")][0] |
      .Action == "route53:GetChange" and
      .Resource == "arn:aws:route53:::change/*")
  ' "$POLICY"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
}

@test "DNS changes require exact zone, normalized TXT name and UPSERT/DELETE actions" {
  run jq -e '
    [.Statement[] | select(.Sid ==
      "ChangeOnlyExpectedDNS01TXTRecordInApprovedZone")][0] |
    .Action == "route53:ChangeResourceRecordSets"
    and .Resource ==
      "arn:aws:route53:::hostedzone/REPLACE_WITH_HOSTED_ZONE_ID"
    and .Condition."ForAllValues:StringEquals"."route53:ChangeResourceRecordSetsRecordTypes" ==
      ["TXT"]
    and .Condition."ForAllValues:StringEquals"."route53:ChangeResourceRecordSetsActions" ==
      ["UPSERT", "DELETE"]
    and .Condition."ForAllValues:StringEquals"."route53:ChangeResourceRecordSetsNormalizedRecordNames" ==
      ["_acme-challenge.REPLACE_WITH_LOWERCASE_DOMAIN"]
    and (.Condition.Null | length) == 3
    and all(.Condition.Null[]; . == "false")
  ' "$POLICY"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
}

@test "policy retains conspicuous placeholders rather than simulated real identity" {
  run jq -e '
    ([.. | strings | select(test("REPLACE_WITH_"))] | length) >= 4
    and
    (([.Statement[] | .Resource] | map(tostring) |
      join(" ")) | contains("arn:aws:iam::") | not)
  ' "$POLICY"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
}

@test "administrator guide explicitly refuses live CI provisioning and distinguishes roles" {
  GUIDE="$BATS_TEST_DIRNAME/../doc/examples/aws-bucket-bootstrap.md"
  [ -f "$GUIDE" ]
  grep -Fq 'No command in this document is invoked' "$GUIDE"
  grep -Fq 'Provisioning administrator' "$GUIDE"
  grep -Fq 'Certbotbot producer/registrar' "$GUIDE"
  grep -Fq 'Downstream read-only consumer' "$GUIDE"
  grep -Fq 'response' "$GUIDE" || grep -Fq '403' "$GUIDE"
  grep -Fq 'validate-policy' "$GUIDE"
  grep -Fq 'not a deployable policy' "$GUIDE"
}
