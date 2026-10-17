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

@test "real staging evidence remains an example, not an installed workflow" {
  [ -f "$BATS_TEST_DIRNAME/../examples/github-actions/real-staging-evidence.yml" ]
  [ ! -e "$BATS_TEST_DIRNAME/../.github/workflows/real-staging-evidence.yml" ]
  [ ! -e "$STAGING_TEST_MARKER" ]
}

@test "real Certbot README files are excluded without weakening archive validation" {
  command -v gpg >/dev/null 2>&1 || skip 'GPG is required'
  run env GPG_PASSPHRASE='credential-free packaging fixture' \
    bash -c '
    source "$1"
    source "$CERTBOTBOT_ARTIFACT" --version >/dev/null
    certbotbot_workspace_create || exit 80
    config=$CERTBOTBOT_WORKSPACE_CONFIG
    name=$CERTBOTBOT_STAGING_DOMAIN
    account=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    account_dir="$config/accounts/acme-staging-v02.api.letsencrypt.org/directory/$account"
    mkdir -p "$account_dir" "$config/archive/$name" \
      "$config/live/$name" "$config/renewal" "$config/combined"
    find "$config" -type d -exec chmod 0700 -- {} +
    for part in meta regr private_key; do
      printf "{\"fixture\":\"%s\"}\n" "$part" >"$account_dir/$part.json"
      chmod 0600 "$account_dir/$part.json"
    done
    for part in cert chain fullchain privkey; do
      printf "synthetic %s fixture\n" "$part" \
        >"$config/archive/$name/${part}1.pem"
      ln -s "../../archive/$name/${part}1.pem" \
        "$config/live/$name/$part.pem"
    done
    chmod 0600 "$config/archive/$name/"*1.pem
    printf "synthetic renewal metadata\n" \
      >"$config/renewal/$name.conf"
    printf "synthetic combined fixture\n" \
      >"$config/combined/$name.pem"
    cp -- "$config/combined/$name.pem" \
      "$config/live/$name/combined.pem"
    chmod 0600 "$config/renewal/$name.conf" \
      "$config/combined/$name.pem" \
      "$config/live/$name/combined.pem"
    printf "Certbot-generated README\n" >"$config/live/README"
    printf "Certbot-generated README\n" >"$config/live/$name/README"

    staging_save_archives || exit 81
    [[ -s $CERTBOTBOT_STAGING_OUTPUT_DIR/domain.tar.gz.enc &&
      -s $CERTBOTBOT_STAGING_OUTPUT_DIR/common.tar.gz.enc ]] || exit 82
    input="$(mktemp -- "$CERTBOTBOT_WORKSPACE_ROOT/cipher.XXXXXXXX")"
    plain="$(mktemp -- "$CERTBOTBOT_WORKSPACE_ROOT/plain.XXXXXXXX")"
    cp -- "$CERTBOTBOT_STAGING_OUTPUT_DIR/domain.tar.gz.enc" "$input"
    certbotbot_gpg_decrypt_archive "$input" "$plain" || exit 83
    certbotbot_archive_validate_domain "$plain" "$name" || exit 84
    if tar -tzf "$plain" | grep -Fq README; then
      exit 85
    fi
    certbotbot_workspace_destroy || exit 86
  ' _ "$STAGING_TEST_SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -e "$STAGING_TEST_MARKER" ]
}
