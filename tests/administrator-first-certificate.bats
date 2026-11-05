#!/usr/bin/env bats

## @file tests/administrator-first-certificate.bats
## @brief Offline review of first-certificate onboarding contracts.
## @details
## Verifies documentation order, internal links, actual producer/client
## option names and fenced Bash syntax WITHOUT executing any examples.
## No AWS, Let's Encrypt, Route53, certificate or Jenkins requests occur.

setup() {
  DOC="$BATS_TEST_DIRNAME/../doc/administrator-first-certificate.md"
  ROOT="$BATS_TEST_DIRNAME/.."
  [ -f "$DOC" ]
}

@test "exactly requested first sentence precedes all headings and prose" {
  run head -n 1 "$DOC"
  [ "$status" -eq 0 ]
  [ "$output" = 'I want a certificate for example.com.' ]
  grep -Fq 'reserved illustrative domain' "$DOC"
  grep -Fq 'not a deployable policy' "$ROOT/doc/examples/aws-bucket-bootstrap.md"
}

@test "walkthrough steps are ordered registration then issuance then retrieval then renewal" {
  local prev=0 pos header
  for header in \
    '## 1. Choose an environment' \
    '## 2. Provision the bucket' \
    '## 3. Acquire and independently verify' \
    '## 4. Register the' \
    '## 5. Issue the first' \
    '## 6. Independently retrieve' \
    '## 7. After a successful' \
    '## 8. Fail-closed troubleshooting' \
    '## 9. Story #284 reviewer'; do
    pos="$(grep -nF "$header" "$DOC" | head -n 1 | cut -d: -f1)"
    [ -n "$pos" ]
    (( pos > prev ))
    prev="$pos"
  done
}

@test "all fenced Bash examples pass Bash syntax without any cloud requests" {
  local generated
  generated="$(mktemp)" || return 1
  awk '
    BEGIN { fence=sprintf("%c%c%c",96,96,96) }
    $0 == fence "bash" { inside=1; blocks++; next }
    $0 == fence && inside { inside=0; complete++; print ""; next }
    inside { print }
    END { if (inside || blocks != complete || blocks < 7) exit 1 }
  ' "$DOC" >"$generated" || { rm -f "$generated"; return 1; }
  run bash -n "$generated"
  rm -f "$generated"
  [ "$status" -eq 0 ]
}

@test "manual privileged steps are labeled and placeholders are guarded" {
  grep -Fq 'LIVE OPERATOR-ONLY' "$DOC"
  grep -Fq 'REPLACE_WITH_PRIVATE_BUCKET' "$DOC"
  grep -Fq 'REPLACE_WITH_REVIEWED_RUNTIME_PROFILE' "$DOC"
  grep -Fq 'REPLACE_WITH_CONTACT_EMAIL' "$DOC"
  grep -Fq 'REPLACE_WITH_REVIEWED_PRODUCER_SHA256' "$DOC"
  grep -Fq 'REPLACE_WITH_REVIEWED_CLIENT_SHA256' "$DOC"
  grep -Fq 'No real IAM' "$DOC"
}

@test "registrar, producer and consumer documented flags exist in actual parsers" {
  local opt
  for opt in --email --agree-tos --eff-email-signup \
    --acme-environment --archive-encryption --s3-bucket \
    --s3-key --no-env; do
    grep -Fq -- "$opt" "$ROOT/lib/register-config.bash"
  done
  for opt in --acme-environment --archive-encryption --s3-bucket \
    --s3-key --cert-name --include-subdomains --domain \
    --renew-all --remove-orphans --desired-cert-name \
    --upload-no-renewal; do
    grep -Fq -- "$opt" "$ROOT/src/main.bash"
  done
  for opt in --destination --archive-encryption --s3-bucket --s3-key; do
    grep -Fq -- "$opt" "$ROOT/lib/client-config.bash"
  done
}

@test "staging registration and issue use same explicit CA and current key" {
  grep -Fq -- '--email "$CONTACT_EMAIL"' "$DOC"
  grep -Fq -- '--agree-tos true' "$DOC"
  grep -Fq -- '--eff-email-signup false' "$DOC"
  [ "$(grep -Fc -- '--acme-environment "$CA_ENVIRONMENT"' "$DOC")" -eq 2 ]
  [ "$(grep -Fc -- '--s3-key "$CURRENT_KEY"' "$DOC")" -ge 3 ]
  grep -Fq -- 'CURRENT_KEY=staging-current.tar.gz' "$DOC"
  grep -Fq -- 'production-current.tar.gz' "$DOC"
  grep -Fq -- '--include-subdomains false' "$DOC"
  grep -Fq -- '--include-subdomains true' "$DOC"
}

@test "read-only retrieval and private-key verification are not server installation" {
  grep -Fq -- 'certbotbot-client.bash' "$DOC"
  grep -Fq -- '--destination "$RESTORED"' "$DOC"
  grep -Fq -- 'openssl x509 -in "$CERT"' "$DOC"
  grep -Fq -- 'openssl pkey -in "$KEY"' "$DOC"
  grep -Fq 'Installation is a separate operation' "$DOC"
  grep -Fq 'not publicly trusted' "$DOC"
}

@test "bulk and destructive controls are opt-in, incompatible and not registration" {
  grep -Fq 'RENEW_ALL=true' "$DOC"
  grep -Fq 'REMOVE_ORPHANS=true' "$DOC"
  grep -Fq 'destructive' "$DOC"
  grep -Fq 'BACKUP_RETENTION_COUNT' "$DOC"
  grep -Fq 'S3 PutObject' "$DOC"
  grep -Fq 'uncertain' "$DOC"
  grep -Fq 'local Pebble' "$DOC"
}

@test "operator entrypoints crosslink first-certificate guide" {
  local path
  for path in README.md doc/configuration-reference.md \
    doc/acme-account-registration-contract.md \
    doc/examples/jenkins.md doc/examples/github-actions.md \
    doc/container-deployment.md doc/client-retrieval.md \
    doc/client-settings.md doc/examples/certbotbot-client.md \
    doc/release-verification.md doc/examples/aws-bucket-bootstrap.md; do
    grep -Fq 'administrator-first-certificate.md' "$ROOT/$path"
  done
}

@test "every relative Markdown target in walkthrough exists in repo" {
  local target relative
  while IFS= read -r relative; do
    [[ -n "$relative" ]] || continue
    case "$relative" in
      http:*|https:*|mailto:*) continue ;;
    esac
    target="${relative%%#*}"
    [ -e "$ROOT/doc/$target" ] || {
      printf 'Missing relative guide link: %s\n' "$target" >&3
      return 1
    }
  done < <(
    grep -oE '\]\([^)]+\)' "$DOC" |
      sed -e 's/^](//' -e 's/)$//' | sort -u
  )
}

@test "story acceptance crosswalk has all four groups and evidence limits" {
  grep -Fq '## 9. Story #284 reviewer and acceptance crosswalk' "$DOC"
  for section in \
    '**1. Complete supported-option documentation**' \
    '**2. Safe Jenkins example**' \
    '**3. From-zero-S3 operator guide**' \
    '**4. Verification and evidence boundaries**'; do
    grep -Fq "$section" "$DOC"
  done
  grep -Fq 'No live AWS IAM Access Analyzer result' "$DOC"
  grep -Fq 'CODEOWNERS' "$DOC"
}
