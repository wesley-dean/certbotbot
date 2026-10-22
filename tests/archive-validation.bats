#!/usr/bin/env bats

## @file tests/archive-validation.bats
## @brief Exercises tar/gzip preflight with actual local hostile fixtures.
## @details
## No archive under test is extracted. Each artifact embeds the same validator.

setup() {
  : "$BASH_STARTER_ARTIFACT"
  TEST_ROOT="$(mktemp -d)"
  mkdir -p "$TEST_ROOT/tree/accounts/acme-v02.api.letsencrypt.org/directory/id"
  printf '{"key":"fixture"}\n' >"$TEST_ROOT/tree/accounts/acme-v02.api.letsencrypt.org/directory/id/private_key.json"
  chmod 600 "$TEST_ROOT/tree/accounts/acme-v02.api.letsencrypt.org/directory/id/private_key.json"
  ARCHIVE="$TEST_ROOT/test.tar.gz"
}

teardown() {
  rm -rf -- "$TEST_ROOT"
}

check_archive() {
  run bash -c '
    source "$1" --help >/dev/null
    certbotbot_archive_validate "$2"
  ' _ "$BASH_STARTER_ARTIFACT" "$ARCHIVE"
}

make_archive() {
  tar -czf "$ARCHIVE" -C "$TEST_ROOT/tree" .
}

make_lineage() {
  mkdir -p "$TEST_ROOT/tree/archive/example.com" "$TEST_ROOT/tree/live/example.com"
  local component
  for component in cert chain fullchain privkey; do
    printf '%s\n' "fake-$component" >"$TEST_ROOT/tree/archive/example.com/$component"1.pem
    ln -s "../../archive/example.com/$component"1.pem "$TEST_ROOT/tree/live/example.com/$component.pem"
  done
}

@test "seeded account-only archive passes format validation" {
  make_archive
  check_archive
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "relative Certbot PEM links pass with regular archive targets" {
  make_lineage
  make_archive
  check_archive
  [ "$status" -eq 0 ]
}

@test "POSIX ustar archive headers are supported" {
  tar --format=ustar -czf "$ARCHIVE" -C "$TEST_ROOT/tree" .
  check_archive
  [ "$status" -eq 0 ]
}

@test "GNU long-name extension is rejected" {
  mkdir -p "$TEST_ROOT/tree/accounts/$(printf 'a%.0s' {1..110})"
  make_archive
  check_archive
  [ "$status" -eq 65 ]
}

@test "escape through live certificate symlinks is rejected" {
  make_lineage
  rm "$TEST_ROOT/tree/live/example.com/cert.pem"
  ln -s ../../../../etc/passwd "$TEST_ROOT/tree/live/example.com/cert.pem"
  make_archive
  check_archive
  [ "$status" -eq 65 ]
}

@test "missing symlink target is rejected" {
  make_lineage
  rm "$TEST_ROOT/tree/archive/example.com/cert1.pem"
  make_archive
  check_archive
  [ "$status" -eq 65 ]
}

@test "traversal member name is rejected" {
  tar -czf "$ARCHIVE" --transform='s,^accounts,../accounts,' -C "$TEST_ROOT/tree" accounts
  check_archive
  [ "$status" -eq 65 ]
}

@test "absolute member name is rejected" {
  tar -czf "$ARCHIVE" --transform='s,^accounts,/accounts,' -C "$TEST_ROOT/tree" accounts
  check_archive
  [ "$status" -eq 65 ]
}

@test "hardlinked tar members are rejected" {
  printf 'extra\n' >"$TEST_ROOT/tree/accounts/link-source"
  ln "$TEST_ROOT/tree/accounts/link-source" "$TEST_ROOT/tree/accounts/link-dest"
  make_archive
  check_archive
  [ "$status" -eq 65 ]
}

@test "FIFO tar members are rejected" {
  mkfifo "$TEST_ROOT/tree/accounts/untrusted-pipe"
  make_archive
  check_archive
  [ "$status" -eq 65 ]
}

@test "duplicate tar members are rejected" {
  tar -czf "$ARCHIVE" -C "$TEST_ROOT/tree" . -C "$TEST_ROOT/tree" .
  check_archive
  [ "$status" -eq 65 ]
}

@test "world-writable private account members are rejected" {
  chmod 666 "$TEST_ROOT/tree/accounts/acme-v02.api.letsencrypt.org/directory/id/private_key.json"
  make_archive
  check_archive
  [ "$status" -eq 65 ]
}

@test "truncated compressed stream is rejected" {
  make_archive
  truncate -s -8 "$ARCHIVE"
  check_archive
  [ "$status" -eq 65 ]
}

@test "expanded archives larger than 32 MiB are rejected" {
  truncate -s 34000000 "$TEST_ROOT/tree/accounts/large-data"
  make_archive
  check_archive
  [ "$status" -eq 65 ]
}

@test "missing file is rejected without leaking archive contents" {
  ARCHIVE="$TEST_ROOT/absent.tar.gz"
  check_archive
  [ "$status" -eq 64 ]
  [[ "$output" != *private_key.json* ]]
}

@test "format preflight does not enable certificate lifecycle" {
  make_archive
  check_archive
  [ "$status" -eq 0 ]
  run "$BASH_STARTER_ARTIFACT" --s3-bucket fixture-bucket example.com
  [ "$status" -eq 69 ]
}
