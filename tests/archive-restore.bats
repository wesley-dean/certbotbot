#!/usr/bin/env bats

setup() {
  : "${BASH_STARTER_ARTIFACT:?Artifact under test is required}"
  TEST_ROOT="$(mktemp -d)"
  SOURCE="$TEST_ROOT/source"
  WORKSPACE="$TEST_ROOT/workspace"
  ARCHIVE="$TEST_ROOT/seeded.tar.gz"
  mkdir -m 700 "$SOURCE" "$WORKSPACE"
  mkdir -p "$SOURCE/accounts/acme-v02.api.letsencrypt.org/directory/account-001"
  printf '{"fixture":"registered-account"}\n' >"$SOURCE/accounts/acme-v02.api.letsencrypt.org/directory/account-001/private_key.json"
  chmod 600 "$SOURCE/accounts/acme-v02.api.letsencrypt.org/directory/account-001/private_key.json"
}

teardown() {
  rm -rf -- "$TEST_ROOT"
}

make_archive() {
  tar -czf "$ARCHIVE" -C "$SOURCE" .
}

restore_archive() {
  run bash -c '
    source "$1" --help >/dev/null
    certbotbot_archive_restore "$2" "$3"
  ' _ "$BASH_STARTER_ARTIFACT" "$ARCHIVE" "$WORKSPACE"
}

make_lineage() {
  local piece
  mkdir -p "$SOURCE/archive/example.com" "$SOURCE/live/example.com" "$SOURCE/renewal"
  for piece in cert chain fullchain privkey; do
    printf 'mocked-%s\n' "$piece" >"$SOURCE/archive/example.com/${piece}1.pem"
    ln -s "../../archive/example.com/${piece}1.pem" "$SOURCE/live/example.com/$piece.pem"
  done
  printf 'archive_dir = /etc/letsencrypt/archive/example.com\n' >"$SOURCE/renewal/example.com.conf"
  chmod 600 "$SOURCE/renewal/example.com.conf"
}

@test "workspace creator returns a private 0700 absolute directory" {
  run bash -c '
    source "$1" --help >/dev/null
    certbotbot_workspace_create
  ' _ "$BASH_STARTER_ARTIFACT"
  [ "$status" -eq 0 ]
  [ -d "$output" ]
  [ "$(stat -c %a "$output")" = 700 ]
  rm -rf -- "$output"
}

@test "restores seeded account-only archive without activating host state" {
  make_archive
  restore_archive
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cmp "$SOURCE/accounts/acme-v02.api.letsencrypt.org/directory/account-001/private_key.json" \
    "$WORKSPACE/config/accounts/acme-v02.api.letsencrypt.org/directory/account-001/private_key.json"
  [ "$(stat -c %a "$WORKSPACE/config")" = 700 ]
  [ "$(stat -c %a "$WORKSPACE/config/accounts/acme-v02.api.letsencrypt.org/directory/account-001/private_key.json")" = 600 ]
  [ ! -e "$WORKSPACE/config/renewal" ]
}

@test "restored existing lineage retains PEM link relationships and canonical renewal paths" {
  make_lineage
  make_archive
  restore_archive
  [ "$status" -eq 0 ]
  local piece
  for piece in cert chain fullchain privkey; do
    [ -L "$WORKSPACE/config/live/example.com/$piece.pem" ]
    [ "$(readlink "$WORKSPACE/config/live/example.com/$piece.pem")" = "../../archive/example.com/${piece}1.pem" ]
    cmp "$SOURCE/archive/example.com/${piece}1.pem" "$WORKSPACE/config/live/example.com/$piece.pem"
  done
  grep -Fq '/etc/letsencrypt/archive/example.com' "$WORKSPACE/config/renewal/example.com.conf"
}

@test "refuses an existing configuration tree without modifying it" {
  make_archive
  mkdir "$WORKSPACE/config"
  printf 'preserved' >"$WORKSPACE/config/marker"
  restore_archive
  [ "$status" -eq 64 ]
  [ "$(cat "$WORKSPACE/config/marker")" = preserved ]
  [ ! -e "$WORKSPACE/config/accounts" ]
}

@test "refuses non-private and symlink-aliased workspaces" {
  make_archive
  chmod 755 "$WORKSPACE"
  restore_archive
  [ "$status" -eq 64 ]
  chmod 700 "$WORKSPACE"
  ln -s "$WORKSPACE" "$TEST_ROOT/alias"
  WORKSPACE="$TEST_ROOT/alias"
  restore_archive
  [ "$status" -eq 64 ]
}

@test "malicious symlink archive fails without leaving config or staging files" {
  make_lineage
  rm "$SOURCE/live/example.com/cert.pem"
  ln -s ../../../../etc/passwd "$SOURCE/live/example.com/cert.pem"
  make_archive
  printf 'unrelated' >"$WORKSPACE/keep"
  restore_archive
  [ "$status" -eq 65 ]
  [ "$(cat "$WORKSPACE/keep")" = unrelated ]
  [ ! -e "$WORKSPACE/config" ]
  [ "$(find "$WORKSPACE" -mindepth 1 -maxdepth 1 -print | wc -l)" -eq 1 ]
}

@test "truncated gzip input fails without extracting partial certificate state" {
  make_archive
  truncate -s -8 "$ARCHIVE"
  restore_archive
  [ "$status" -eq 65 ]
  [ ! -e "$WORKSPACE/config" ]
  [ -z "$(find "$WORKSPACE" -mindepth 1 -print)" ]
}

@test "unsupported FIFO member never becomes a real filesystem object" {
  mkfifo "$SOURCE/accounts/untrusted-pipe"
  make_archive
  restore_archive
  [ "$status" -eq 65 ]
  [ ! -e "$WORKSPACE/config" ]
  [ -z "$(find "$WORKSPACE" -mindepth 1 -print)" ]
}

@test "archive from a fresh runner restores without consuming unrelated local state" {
  make_archive
  printf 'unrelated-existing-account' >"$WORKSPACE/unrelated"
  restore_archive
  [ "$status" -eq 0 ]
  [ "$(cat "$WORKSPACE/unrelated")" = unrelated-existing-account ]
  [ ! -e "$WORKSPACE/config/live" ]
}

@test "invalid arguments cannot delete an owned directory" {
  make_archive
  run bash -c '
    source "$1" --help >/dev/null
    certbotbot_archive_restore "$2" /
  ' _ "$BASH_STARTER_ARTIFACT" "$ARCHIVE"
  [ "$status" -eq 64 ]
  [ -d "$SOURCE" ]
}

@test "private restoration has no network or Certbot side effects" {
  make_archive
  mkdir "$TEST_ROOT/bin"
  for command in aws certbot; do
    printf '#!/usr/bin/env bash\nprintf "unexpected external call" >&2\nexit 99\n' >"$TEST_ROOT/bin/$command"
    chmod 755 "$TEST_ROOT/bin/$command"
  done
  PATH="$TEST_ROOT/bin:$PATH" restore_archive
  [ "$status" -eq 0 ]
  [[ "$output" != *'unexpected external call'* ]]
}

@test "validated safe file modes survive restore without exposing private keys" {
  make_lineage
  chmod 644 "$SOURCE/archive/example.com/cert1.pem"
  chmod 600 "$SOURCE/archive/example.com/privkey1.pem"
  chmod 600 "$SOURCE/renewal/example.com.conf"
  make_archive
  restore_archive
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$WORKSPACE/config/archive/example.com/cert1.pem")" = 644 ]
  [ "$(stat -c %a "$WORKSPACE/config/archive/example.com/privkey1.pem")" = 600 ]
  [ "$(stat -c %a "$WORKSPACE/config/renewal/example.com.conf")" = 600 ]
  [ "$(stat -c %a "$WORKSPACE/config")" = 700 ]
  [ -L "$WORKSPACE/config/live/example.com/cert.pem" ]
  [ "$(readlink "$WORKSPACE/config/live/example.com/cert.pem")" = \
    '../../archive/example.com/cert1.pem' ]
}
