#!/usr/bin/env bats

## @file tests/staging-multilineage-guards.bats
## @brief Credential-free safety and archive-disjointness checks for ADR-053.
## @details
## Never invokes real Certbot, DNS, AWS, or production state mutation.
## Validates the disabled staging example and the isolated exported members
## for two entirely separate lineages in every standalone artifact flavor.
## @see doc/adr/ADR-053-two-real-lineage-staging-evidence.md

setup() {
  : "${CERTBOTBOT_ARTIFACT:?The compiled standalone artifact is required}"
  export STAGING_MULTI_SCRIPT="$BATS_TEST_DIRNAME/integration/live-staging-multilineage.bash"
  export CERTBOTBOT_STAGING_DOMAIN=example.com
  export CERTBOTBOT_STAGING_EXTRA_NAME=proof.example.com
  export CERTBOTBOT_STAGING_SECOND_NAME=second.example.com
  export CERTBOTBOT_STAGING_PHASE=issue-second
  export ACME_ENVIRONMENT=staging
  export CERTBOTBOT_STAGING_EMAIL=test@example.com
  export CERTBOTBOT_STAGING_CA_BUNDLE="$BATS_TEST_TMPDIR/staging-ca.pem"
  export CERTBOTBOT_STAGING_INPUT_DIR="$BATS_TEST_TMPDIR/input"
  export CERTBOTBOT_STAGING_OUTPUT_DIR="$BATS_TEST_TMPDIR/output"
  export STAGING_MULTI_MARKER="$BATS_TEST_TMPDIR/network-attempt"
  mkdir -m 0700 "$CERTBOTBOT_STAGING_INPUT_DIR" \
    "$CERTBOTBOT_STAGING_OUTPUT_DIR"
  printf 'synthetic CA input\n' >"$CERTBOTBOT_STAGING_CA_BUNDLE"
  cat >"$BATS_TEST_TMPDIR/certbot" <<'CERTBOT'
#!/usr/bin/env bash
printf 'external operation\n' >>"$STAGING_MULTI_MARKER"
exit 97
CERTBOT
  chmod 0700 "$BATS_TEST_TMPDIR/certbot"
  export CERTBOT="$BATS_TEST_TMPDIR/certbot"
  unset CERTBOTBOT_STAGING_CONFIRM GPG_PASSPHRASE || :
  unset CERTBOTBOT_EXPECTED_ACCOUNT_SHA256 || :
  unset CERTBOTBOT_EXPECTED_LEAF_SHA256 || :
  unset CERTBOTBOT_EXPECTED_SECOND_LEAF_SHA256 || :
}

@test "canonical separate second lineage is accepted by network-free guard" {
  run bash "$STAGING_MULTI_SCRIPT" guard
  [ "$status" -eq 0 ]
  [ ! -e "$STAGING_MULTI_MARKER" ]
}

@test "same SAN, base, wildcard, unrelated, uppercase or malformed lineage is refused" {
  local second=''
  for second in example.com proof.example.com '*.example.com' \
    'second.EXAMPLE.com' other.test invalid..example.com \
    '-evil.example.com' 'x.example.com/evil'; do
    CERTBOTBOT_STAGING_SECOND_NAME=$second \
      run bash "$STAGING_MULTI_SCRIPT" guard
    [ "$status" -eq 64 ]
  done
  [ ! -e "$STAGING_MULTI_MARKER" ]
}

@test "second lineage issuance cannot run without consent or encryption" {
  run bash "$STAGING_MULTI_SCRIPT" issue-second
  [ "$status" -eq 64 ]
  export CERTBOTBOT_STAGING_CONFIRM=yes
  run bash "$STAGING_MULTI_SCRIPT" issue-second
  [ "$status" -eq 64 ]
  [ ! -e "$STAGING_MULTI_MARKER" ]
}

@test "wrong phase, production context or multiline secret refuse all execution" {
  export CERTBOTBOT_STAGING_CONFIRM=yes
  export GPG_PASSPHRASE=synthetic-test-password
  export CERTBOTBOT_STAGING_PHASE=verify-two
  run bash "$STAGING_MULTI_SCRIPT" issue-second
  [ "$status" -eq 64 ]
  export CERTBOTBOT_STAGING_PHASE=issue-second
  export ACME_ENVIRONMENT=production
  run bash "$STAGING_MULTI_SCRIPT" issue-second
  [ "$status" -eq 64 ]
  export ACME_ENVIRONMENT=staging
  export GPG_PASSPHRASE=$'bad\nsecret'
  run bash "$STAGING_MULTI_SCRIPT" issue-second
  [ "$status" -eq 64 ]
  [ ! -e "$STAGING_MULTI_MARKER" ]
}

@test "read-only dual-lineage verification requires an independently recorded second leaf" {
  export CERTBOTBOT_STAGING_CONFIRM=yes
  export GPG_PASSPHRASE=synthetic-test-password
  export CERTBOTBOT_STAGING_PHASE=verify-two
  run bash "$STAGING_MULTI_SCRIPT" verify-two
  [ "$status" -eq 64 ]
  [ ! -e "$STAGING_MULTI_MARKER" ]
}

@test "each synthetic domain export contains only its own member paths" {
  run bash -c '
    set -euo pipefail
    umask 077
    source "$1" --version >/dev/null
    source "$2"
    CERTBOTBOT_WORKSPACE_ROOT="$3/work"
    mkdir -m 0700 -- "$CERTBOTBOT_WORKSPACE_ROOT"
    config="$CERTBOTBOT_WORKSPACE_ROOT/config"
    mkdir -m 0700 -- "$config/archive" "$config/live" \
      "$config/renewal" "$config/combined"
    for name in example.com second.example.com; do
      mkdir -m 0700 -- "$config/archive/$name" \
        "$config/live/$name"
      for kind in cert chain fullchain privkey; do
        printf "%s %s\n" "$name" "$kind" \
          >"$config/archive/$name/${kind}1.pem"
        ln -s "../../archive/$name/${kind}1.pem" \
          "$config/live/$name/$kind.pem"
      done
      printf "renewal options fixture\n" >"$config/renewal/$name.conf"
      printf "combined fixture\n" >"$config/combined/$name.pem"
      cp -- "$config/combined/$name.pem" \
        "$config/live/$name/combined.pem"
      chmod 0600 -- "$config/archive/$name/"* \
        "$config/live/$name/combined.pem" \
        "$config/combined/$name.pem"
      printf "Optional Certbot README\n" >"$config/live/$name/README"
    done
    staging_multi_pack_domain "$config" example.com "$3/base.tar.gz"
    staging_multi_pack_domain "$config" second.example.com "$3/second.tar.gz"
    certbotbot_archive_validate_domain "$3/base.tar.gz" example.com
    certbotbot_archive_validate_domain "$3/second.tar.gz" second.example.com
    tar -tzf "$3/base.tar.gz" >"$3/base.list"
    tar -tzf "$3/second.tar.gz" >"$3/second.list"
    ! grep -Fq "second.example.com" "$3/base.list"
    ! grep -Fq "example.com/" "$3/second.list"
    ! grep -Fq README "$3/base.list"
    ! grep -Fq README "$3/second.list"
  ' _ "$CERTBOTBOT_ARTIFACT" "$STAGING_MULTI_SCRIPT" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ ! -e "$STAGING_MULTI_MARKER" ]
}

@test "second lineage stages remain inactive examples, and issuer stays unavailable" {
  [ -f "$BATS_TEST_DIRNAME/../examples/github-actions/real-staging-evidence.yml" ]
  [ ! -e "$BATS_TEST_DIRNAME/../.github/workflows/real-staging-evidence.yml" ]
  run bash -n "$STAGING_MULTI_SCRIPT"
  [ "$status" -eq 0 ]
  run "$CERTBOTBOT_ARTIFACT" example.com
  [ "$status" -eq 69 ]
  [ ! -e "$STAGING_MULTI_MARKER" ]
}
