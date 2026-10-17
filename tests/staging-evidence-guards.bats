#!/usr/bin/env bats

## @file tests/staging-evidence-guards.bats
## @brief Proves live staging evidence never starts without explicit consent.
## @details
## All tests are credential-free. Only guard and deliberately denied modes
## are invoked, with a fake Certbot marker proving zero external execution.
## @see doc/adr/ADR-044-opt-in-real-acme-portability-evidence.md

setup() {
  : "${CERTBOTBOT_ARTIFACT:?Compiled standalone artifact required}"
  export STAGING_TEST_SCRIPT="$BATS_TEST_DIRNAME/integration/live-staging-portability.bash"
  export CERTBOTBOT_STAGING_DOMAIN=example.com
  export CERTBOTBOT_STAGING_EXTRA_NAME=proof.example.com
  export CERTBOTBOT_STAGING_PHASE=issue
  export ACME_ENVIRONMENT=staging
  export CERTBOTBOT_STAGING_EMAIL=test@example.com
  export CERTBOTBOT_STAGING_CA_BUNDLE="$BATS_TEST_TMPDIR/staging.pem"
  export CERTBOTBOT_STAGING_OUTPUT_DIR="$BATS_TEST_TMPDIR/output"
  export CERTBOTBOT_TMPDIR="$BATS_TEST_TMPDIR/work"
  export STAGING_TEST_MARKER="$BATS_TEST_TMPDIR/attempted-certbot"
  mkdir -m 0700 "$CERTBOTBOT_STAGING_OUTPUT_DIR" "$CERTBOTBOT_TMPDIR"
  printf 'dummy staging CA fixture\n' >"$CERTBOTBOT_STAGING_CA_BUNDLE"
  cat >"$BATS_TEST_TMPDIR/fake-certbot" <<'CERTBOT'
#!/usr/bin/env bash
printf 'called\n' >>"$STAGING_TEST_MARKER"
exit 2
CERTBOT
  chmod 0700 "$BATS_TEST_TMPDIR/fake-certbot"
  export CERTBOT="$BATS_TEST_TMPDIR/fake-certbot"
  unset CERTBOTBOT_STAGING_CONFIRM || :
  unset GPG_PASSPHRASE || :
}

@test "guard approves canonical constrained owned DNS identities without side effects" {
  run bash "$STAGING_TEST_SCRIPT" guard
  [ "$status" -eq 0 ]
  [ ! -e "$STAGING_TEST_MARKER" ]
}

@test "unknown phase is rejected without external commands" {
  run bash "$STAGING_TEST_SCRIPT" issue-unsafe
  [ "$status" -eq 64 ]
  [ ! -e "$STAGING_TEST_MARKER" ]
}

@test "base lineage cannot use wildcard, uppercase, traversal, or injection" {
  local invalid=''
  for invalid in '*.example.com' EXAMPLE.COM ../example.com \
    'example.com;touch /tmp/unwanted' '-example.com'; do
    export CERTBOTBOT_STAGING_DOMAIN=$invalid
    run bash "$STAGING_TEST_SCRIPT" guard
    [ "$status" -eq 64 ]
  done
  [ ! -e "$STAGING_TEST_MARKER" ]
}

@test "extra SAN must be a canonical concrete child of the selected base" {
  local invalid=''
  for invalid in example.com proof.other.com '*.example.com' \
    'proof.EXAMPLE.com' '-bad.example.com'; do
    export CERTBOTBOT_STAGING_EXTRA_NAME=$invalid
    run bash "$STAGING_TEST_SCRIPT" guard
    [ "$status" -eq 64 ]
  done
  [ ! -e "$STAGING_TEST_MARKER" ]
}

@test "real staging issuance refuses absent operator consent" {
  export GPG_PASSPHRASE='CI fixture only'
  run bash "$STAGING_TEST_SCRIPT" issue
  [ "$status" -eq 64 ]
  [ ! -e "$STAGING_TEST_MARKER" ]
}

@test "staging consent alone cannot bypass required encryption secret" {
  export CERTBOTBOT_STAGING_CONFIRM=yes
  run bash "$STAGING_TEST_SCRIPT" issue
  [ "$status" -eq 64 ]
  [ ! -e "$STAGING_TEST_MARKER" ]
}

@test "newline-containing passphrase is refused before network access" {
  export CERTBOTBOT_STAGING_CONFIRM=yes
  export GPG_PASSPHRASE=$'secret\ninsecure'
  run bash "$STAGING_TEST_SCRIPT" issue
  [ "$status" -eq 64 ]
  [ ! -e "$STAGING_TEST_MARKER" ]
}

@test "public certificate issuance remains unavailable" {
  run "$CERTBOTBOT_ARTIFACT" example.com
  [ "$status" -eq 69 ]
  [ ! -e "$STAGING_TEST_MARKER" ]
}

@test "consent cannot be reused for a different staging phase" {
  export CERTBOTBOT_STAGING_CONFIRM=yes
  export CERTBOTBOT_STAGING_PHASE=change
  export GPG_PASSPHRASE='CI fixture only'
  run bash "$STAGING_TEST_SCRIPT" issue
  [ "$status" -eq 64 ]
  [ ! -e "$STAGING_TEST_MARKER" ]
}
