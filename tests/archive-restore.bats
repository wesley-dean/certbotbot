#!/usr/bin/env bats

## Isolated restoration tests.  Fixture PEMs are synthetic and deliberately
## do not establish key/certificate cryptographic validity or ACME readiness.

setup() {
  : "$CERTBOTBOT_ARTIFACT"
  export CERTBOTBOT_TMPDIR="$BATS_TEST_TMPDIR"
  export ARCHIVE_FIXTURE_ROOT="$BATS_TEST_TMPDIR/input"
  export ARCHIVE_FIXTURE_PATH="$BATS_TEST_TMPDIR/domain.tar.gz"
  mkdir -p "$ARCHIVE_FIXTURE_ROOT"
}

make_archive() {
  local name=${1:-example.com} root="$ARCHIVE_FIXTURE_ROOT" kind
  mkdir -p "$root/archive/$name" "$root/live/$name" \
    "$root/renewal" "$root/combined"
  for kind in cert chain fullchain privkey; do
    printf '%s\n' "$kind certificate fixture" >"$root/archive/$name/${kind}1.pem"
    ln -s "../../archive/$name/${kind}1.pem" "$root/live/$name/$kind.pem"
  done
  printf '%s\n' 'version = 5.0.0' >"$root/renewal/$name.conf"
  printf '%s\n' 'fullchain plus private key fixture' >"$root/combined/$name.pem"
  cp "$root/combined/$name.pem" "$root/live/$name/combined.pem"
  chmod 0600 "$root/archive/$name/privkey1.pem" \
    "$root/combined/$name.pem" "$root/live/$name/combined.pem"
  tar -czf "$ARCHIVE_FIXTURE_PATH" -C "$root" archive live renewal combined
}

@test "valid lineage restores to private staging and leaves config untouched" {
  make_archive
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    printf "unchanged\n" >"$CERTBOTBOT_WORKSPACE_CONFIG/marker"
    certbotbot_restore_domain "$2" example.com || exit
    [[ "$CERTBOTBOT_RESTORE_ROOT" == "$CERTBOTBOT_WORKSPACE_ROOT"/restore.* ]] || exit
    [[ "$(stat -c "%a" "$CERTBOTBOT_RESTORE_ROOT")" == 700 ]] || exit
    [[ -L "$CERTBOTBOT_RESTORE_ROOT/live/example.com/privkey.pem" ]] || exit
    [[ -f "$CERTBOTBOT_RESTORE_ROOT/combined/example.com.pem" ]] || exit
    [[ "$(stat -c "%a" "$CERTBOTBOT_RESTORE_ROOT/combined/example.com.pem")" == 600 ]] || exit
    [[ "$(cat "$CERTBOTBOT_WORKSPACE_CONFIG/marker")" == unchanged ]] || exit
    original="$CERTBOTBOT_RESTORE_ROOT"
    certbotbot_restore_discard || exit
    [[ ! -e "$original" ]] || exit
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ARCHIVE_FIXTURE_PATH"
  [ "$status" -eq 0 ]
}

@test "valid input is rejected when no private workspace exists" {
  make_archive
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_restore_domain "$2" example.com
  ' _ "$CERTBOTBOT_ARTIFACT" "$ARCHIVE_FIXTURE_PATH"
  [ "$status" -eq 64 ]
}

@test "a second restore cannot overwrite an undiscarded staging result" {
  make_archive
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    certbotbot_restore_domain "$2" example.com || exit
    certbotbot_restore_domain "$2" example.com
    rc=$?
    certbotbot_restore_discard || exit
    certbotbot_workspace_destroy || exit
    [[ "$rc" == 64 ]]
  ' _ "$CERTBOTBOT_ARTIFACT" "$ARCHIVE_FIXTURE_PATH"
  [ "$status" -eq 0 ]
}

@test "wrong lineage fails without changing active config" {
  make_archive
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    printf "safe\n" >"$CERTBOTBOT_WORKSPACE_CONFIG/marker"
    certbotbot_restore_domain "$2" example.net
    rc=$?
    [[ "$rc" == 64 ]] || exit
    [[ -z "$CERTBOTBOT_RESTORE_ROOT" ]] || exit
    [[ "$(cat "$CERTBOTBOT_WORKSPACE_CONFIG/marker")" == safe ]] || exit
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ARCHIVE_FIXTURE_PATH"
  [ "$status" -eq 0 ]
}

@test "cross-lineage symlink fails before extraction" {
  make_archive
  rm "$ARCHIVE_FIXTURE_ROOT/live/example.com/privkey.pem"
  ln -s /etc/shadow "$ARCHIVE_FIXTURE_ROOT/live/example.com/privkey.pem"
  tar -czf "$ARCHIVE_FIXTURE_PATH" -C "$ARCHIVE_FIXTURE_ROOT" \
    archive live renewal combined
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    certbotbot_restore_domain "$2" example.com
    rc=$?
    [[ "$rc" == 64 && -z "$CERTBOTBOT_RESTORE_ROOT" ]] || exit
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ARCHIVE_FIXTURE_PATH"
  [ "$status" -eq 0 ]
}

@test "corrupt gzip does not leave a restoration directory" {
  make_archive
  truncate -s 8 "$ARCHIVE_FIXTURE_PATH"
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    certbotbot_restore_domain "$2" example.com
    rc=$?
    [[ "$rc" != 0 && -z "$CERTBOTBOT_RESTORE_ROOT" ]] || exit
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ARCHIVE_FIXTURE_PATH"
  [ "$status" -eq 0 ]
}

@test "symlink input archive is refused" {
  make_archive
  ln -s "$ARCHIVE_FIXTURE_PATH" "$BATS_TEST_TMPDIR/archive-link"
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    certbotbot_restore_domain "$2" example.com
    rc=$?
    certbotbot_workspace_destroy || exit
    [[ "$rc" == 64 ]]
  ' _ "$CERTBOTBOT_ARTIFACT" "$BATS_TEST_TMPDIR/archive-link"
  [ "$status" -eq 0 ]
}

@test "restored tree inspector detects an unexpected file" {
  make_archive
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    certbotbot_restore_domain "$2" example.com || exit
    printf "unexpected\n" >"$CERTBOTBOT_RESTORE_ROOT/extra.txt"
    certbotbot_restore_inspect_tree "$CERTBOTBOT_RESTORE_ROOT" example.com
    rc=$?
    certbotbot_restore_discard || exit
    certbotbot_workspace_destroy || exit
    [[ "$rc" == 64 ]]
  ' _ "$CERTBOTBOT_ARTIFACT" "$ARCHIVE_FIXTURE_PATH"
  [ "$status" -eq 0 ]
}

@test "restored tree inspector detects replaced leaf symlink" {
  make_archive
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    certbotbot_restore_domain "$2" example.com || exit
    rm "$CERTBOTBOT_RESTORE_ROOT/live/example.com/privkey.pem"
    ln -s /etc/shadow "$CERTBOTBOT_RESTORE_ROOT/live/example.com/privkey.pem"
    certbotbot_restore_inspect_tree "$CERTBOTBOT_RESTORE_ROOT" example.com
    rc=$?
    certbotbot_restore_discard || exit
    certbotbot_workspace_destroy || exit
    [[ "$rc" == 64 ]]
  ' _ "$CERTBOTBOT_ARTIFACT" "$ARCHIVE_FIXTURE_PATH"
  [ "$status" -eq 0 ]
}

@test "public issuing command remains disabled after restore implementation" {
  run "$CERTBOTBOT_ARTIFACT" example.com
  [ "$status" -eq 69 ]
}
