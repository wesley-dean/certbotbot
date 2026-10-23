#!/usr/bin/env bats

## @file tests/archive-layout.bats
## @brief Demonstrates standard tar/gzip roundtrips for the MVP layout.
## @details
## These are layout fixtures, not archive trust or Certbot execution checks.

setup() {
  : "${BASH_STARTER_ARTIFACT:?Artifact under test is required}"
  ARCHIVE_FIXTURE_ROOT="$(mktemp -d)"
  ARCHIVE_SOURCE="$ARCHIVE_FIXTURE_ROOT/runner-first"
  ARCHIVE_DEST="$ARCHIVE_FIXTURE_ROOT/unrelated-new-runner"
  ARCHIVE_FILE="$ARCHIVE_FIXTURE_ROOT/existing.tar.gz"
  mkdir -p "$ARCHIVE_SOURCE" "$ARCHIVE_DEST"
}

teardown() {
  rm -rf "$ARCHIVE_FIXTURE_ROOT"
}

seed_account() {
  local account="$ARCHIVE_SOURCE/accounts/acme-v02.api.letsencrypt.org/directory/account-test"
  mkdir -p "$account"
  printf '{"fixture":"account-key"}\n' >"$account/private_key.json"
  printf '{"fixture":"registration"}\n' >"$account/regr.json"
  printf '{"fixture":"metadata"}\n' >"$account/meta.json"
  chmod 600 "$account/"*.json
}

seed_lineage() {
  local archives="$ARCHIVE_SOURCE/archive/example.com"
  local live="$ARCHIVE_SOURCE/live/example.com"
  local renew="$ARCHIVE_SOURCE/renewal"
  mkdir -p "$archives" "$live" "$renew"
  printf '%s\n' 'fixture key (not cryptographic material)' >"$archives/privkey1.pem"
  printf '%s\n' 'fixture leaf certificate' >"$archives/cert1.pem"
  printf '%s\n' 'fixture chain' >"$archives/chain1.pem"
  printf '%s\n' 'fixture fullchain' >"$archives/fullchain1.pem"
  chmod 600 "$archives/privkey1.pem"
  printf '%s\n' 'Relative Certbot symlinks.' >"$live/README"
  local piece
  for piece in privkey cert chain fullchain; do
    ln -s "../../archive/example.com/$piece"1.pem "$live/$piece.pem"
  done
  cat >"$renew/example.com.conf" <<'CONF'
version = 5.8.0
archive_dir = /etc/letsencrypt/archive/example.com
cert = /etc/letsencrypt/live/example.com/cert.pem
privkey = /etc/letsencrypt/live/example.com/privkey.pem
chain = /etc/letsencrypt/live/example.com/chain.pem
fullchain = /etc/letsencrypt/live/example.com/fullchain.pem
[renewalparams]
authenticator = dns-route53
server = https://acme-v02.api.letsencrypt.org/directory
CONF
  chmod 600 "$renew/example.com.conf"
}

pack_fixture() {
  tar -czf "$ARCHIVE_FILE" -C "$ARCHIVE_SOURCE" .
}

@test "account-only seeded archive survives a distinct private root" {
  seed_account
  pack_fixture
  tar -tzf "$ARCHIVE_FILE" >/dev/null
  tar -xzf "$ARCHIVE_FILE" -C "$ARCHIVE_DEST"
  cmp "$ARCHIVE_SOURCE/accounts/acme-v02.api.letsencrypt.org/directory/account-test/private_key.json" \
    "$ARCHIVE_DEST/accounts/acme-v02.api.letsencrypt.org/directory/account-test/private_key.json"
  [ ! -d "$ARCHIVE_DEST/live" ]
  [ ! -d "$ARCHIVE_DEST/renewal" ]
}

@test "lineage retains versioned files, PEM symlinks and ACME account bytes" {
  seed_account
  seed_lineage
  pack_fixture
  tar -xzf "$ARCHIVE_FILE" -C "$ARCHIVE_DEST"
  local piece
  for piece in privkey cert chain fullchain; do
    [ -L "$ARCHIVE_DEST/live/example.com/$piece.pem" ]
    [ "$(readlink "$ARCHIVE_DEST/live/example.com/$piece.pem")" = "../../archive/example.com/$piece"1.pem ]
    cmp "$ARCHIVE_SOURCE/archive/example.com/$piece"1.pem \
      "$ARCHIVE_DEST/live/example.com/$piece.pem"
  done
  cmp "$ARCHIVE_SOURCE/renewal/example.com.conf" "$ARCHIVE_DEST/renewal/example.com.conf"
  cmp "$ARCHIVE_SOURCE/accounts/acme-v02.api.letsencrypt.org/directory/account-test/regr.json" \
    "$ARCHIVE_DEST/accounts/acme-v02.api.letsencrypt.org/directory/account-test/regr.json"
}

@test "canonical renewal metadata cannot be used as relocated path evidence" {
  seed_account
  seed_lineage
  pack_fixture
  tar -xzf "$ARCHIVE_FILE" -C "$ARCHIVE_DEST"
  grep -Fq 'archive_dir = /etc/letsencrypt/archive/example.com' "$ARCHIVE_DEST/renewal/example.com.conf"
  grep -Fq 'fullchain = /etc/letsencrypt/live/example.com/fullchain.pem' "$ARCHIVE_DEST/renewal/example.com.conf"
  ! grep -Fq "$ARCHIVE_SOURCE" "$ARCHIVE_DEST/renewal/example.com.conf"
  ! grep -Fq "$ARCHIVE_DEST" "$ARCHIVE_DEST/renewal/example.com.conf"
}

@test "archive members are relative to configuration directory contents" {
  seed_account
  seed_lineage
  pack_fixture
  local entries
  entries="$(tar -tzf "$ARCHIVE_FILE")"
  [[ "$entries" == *"./accounts/"* ]]
  [[ "$entries" == *"./live/"* ]]
  [[ "$entries" == *"./archive/"* ]]
  [[ "$entries" == *"./renewal/"* ]]
  [[ "$entries" != *"$ARCHIVE_SOURCE"* ]]
  [[ "$entries" != *"/etc/letsencrypt"* ]]
}

