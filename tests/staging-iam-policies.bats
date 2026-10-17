#!/usr/bin/env bats

## @file tests/staging-iam-policies.bats
## @brief Verify offline, strictly scoped real-staging IAM policy documents.
## @details
## Every test runs without AWS or GitHub credentials, network, DNS access,
## or an installed real staging workflow. JSON parse and semantic checks
## use Python strictly as a test dependency, never as a runtime dependency.
## @see doc/adr/ADR-056-offline-staging-iam-policies.md

setup() {
  export IAM_RENDER="$BATS_TEST_DIRNAME/../scripts/staging-iam-policies.bash"
  export IAM_STDOUT="$BATS_TEST_TMPDIR/policy.json"
  export IAM_STDERR="$BATS_TEST_TMPDIR/errors.txt"
  export IAM_FORBIDDEN="$BATS_TEST_TMPDIR/forbidden"
  export IAM_PARAMS=unused
  [ -f "$IAM_RENDER" ]
  command -v python3 >/dev/null || skip 'Python JSON parser for development tests'
}

render_policy() {
  local kind=$1
  shift
  bash "$IAM_RENDER" \
    --document "$kind" \
    --account-id 123456789012 \
    --repository wesley-dean/certbotbot \
    --zone-id Z12345ABCDE \
    --domain staging.example.org \
    --extra-name proof.staging.example.org \
    --second-name second.staging.example.org \
    "$@" >"$IAM_STDOUT" 2>"$IAM_STDERR"
}

@test "trust document binds only the protected staging repository environment" {
  run render_policy trust
  [ "$status" -eq 0 ]
  run python3 -c '
import json, sys
p = json.load(open(sys.argv[1]))
assert p["Version"] == "2012-10-17"
assert len(p["Statement"]) == 1
s = p["Statement"][0]
assert s["Effect"] == "Allow"
assert s["Action"] == "sts:AssumeRoleWithWebIdentity"
assert s["Principal"]["Federated"] == (
    "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com")
c = s["Condition"]["StringEquals"]
assert c == {
    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
    "token.actions.githubusercontent.com:sub":
        "repo:wesley-dean/certbotbot:environment:acme-staging"
}
assert "pull_request" not in json.dumps(p)
' "$IAM_STDOUT"
  [ "$status" -eq 0 ]
  [ ! -s "$IAM_STDERR" ]
}

@test "DNS write authority is only three exact TXT challenge records" {
  run render_policy permissions
  [ "$status" -eq 0 ]
  run python3 -c '
import json, sys
p = json.load(open(sys.argv[1]))
s = p["Statement"]
assert len(s) == 3
w = s[0]
assert w["Effect"] == "Allow"
assert w["Action"] == "route53:ChangeResourceRecordSets"
assert w["Resource"] == "arn:aws:route53:::hostedzone/Z12345ABCDE"
c = w["Condition"]
assert c["ForAllValues:StringEquals"] == {
    "route53:ChangeResourceRecordSetsNormalizedRecordNames": [
        "_acme-challenge.staging.example.org",
        "_acme-challenge.proof.staging.example.org",
        "_acme-challenge.second.staging.example.org"
    ],
    "route53:ChangeResourceRecordSetsRecordTypes": ["TXT"],
    "route53:ChangeResourceRecordSetsActions": ["CREATE", "UPSERT", "DELETE"]
}
assert c["Null"] == {k:"false" for k in
    c["ForAllValues:StringEquals"].keys()}
assert {(x["Action"], x["Resource"]) for x in s[1:]} == {
    ("route53:ListHostedZones", "*"),
    ("route53:GetChange", "arn:aws:route53:::change/*")
}
assert all(x["Effect"] == "Allow" for x in s)
assert not any(x.get("Resource") == "*" and
    x["Action"] == "route53:ChangeResourceRecordSets" for x in s)
' "$IAM_STDOUT"
  [ "$status" -eq 0 ]
  [ ! -s "$IAM_STDERR" ]
}

@test "generator rejects missing, duplicate and unknown arguments before JSON" {
  local invalid=0
  run bash "$IAM_RENDER" --document permissions
  [ "$status" -eq 64 ]
  [[ $output != *'{'* ]]
  run render_policy trust --document permissions
  [ "$status" -eq 64 ]
  [ ! -s "$IAM_STDOUT" ]
  run render_policy trust --no-network yes
  [ "$status" -eq 64 ]
  [ ! -s "$IAM_STDOUT" ]
}

@test "invalid hosted zone and AWS account cannot produce IAM policy" {
  run render_policy permissions --account-id 0
  [ "$status" -eq 64 ]
  [ ! -s "$IAM_STDOUT" ]
  run render_policy permissions --zone-id 'Z12345/../../unsafe'
  [ "$status" -eq 64 ]
  [ ! -s "$IAM_STDOUT" ]
}

@test "invalid Github repository input never enters OIDC subject" {
  run render_policy trust --repository 'owner/repo:environment:prod'
  [ "$status" -eq 64 ]
  [ ! -s "$IAM_STDOUT" ]
  run render_policy trust --repository 'owner/repo"'
  [ "$status" -eq 64 ]
  [ ! -s "$IAM_STDOUT" ]
}

@test "out-of-zone and duplicate staging SANs are denied without JSON" {
  run render_policy permissions --extra-name outside.example.org
  [ "$status" -eq 64 ]
  [ ! -s "$IAM_STDOUT" ]
  run render_policy permissions --second-name proof.staging.example.org
  [ "$status" -eq 64 ]
  [ ! -s "$IAM_STDOUT" ]
  run render_policy permissions --second-name '*.staging.example.org'
  [ "$status" -eq 64 ]
  [ ! -s "$IAM_STDOUT" ]
}

@test "invalid DNS labels, uppercase or attempted interpolation are denied" {
  local bad=''
  for bad in 'SECOND.staging.example.org' 'x..staging.example.org' \
    '-x.staging.example.org' 'x.staging.example.org.' \
    'x.staging.example.org$(touch /tmp/certbotbot-unsafe)' \
    'x.staging.example.org\none' 'x.staging.example.org"'; do
    run render_policy permissions --second-name "$bad"
    [ "$status" -eq 64 ]
    [ ! -s "$IAM_STDOUT" ]
  done
  [ ! -e "$IAM_FORBIDDEN" ]
}

@test "policy generation requires no credentials or network-enabled command" {
  run env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY \
    -u GITHUB_TOKEN -u GH_TOKEN bash "$IAM_RENDER" \
      --document trust --account-id 123456789012 \
      --repository wesley-dean/certbotbot --zone-id Z12345ABCDE \
      --domain staging.example.org --extra-name proof.staging.example.org \
      --second-name second.staging.example.org
  [ "$status" -eq 0 ]
  [[ $output == *'"sts:AssumeRoleWithWebIdentity"'* ]]
  [ ! -e "$BATS_TEST_DIRNAME/../.github/workflows/real-staging-evidence.yml" ]
}
