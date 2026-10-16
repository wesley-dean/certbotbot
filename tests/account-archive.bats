#!/usr/bin/env bats

## Only synthetic account JSON is used here.  These tests verify the isolated
## filesystem contract, not real registration, signatures, or account selection.

setup() {
  : "$CERTBOTBOT_ARTIFACT"
  export CERTBOTBOT_TMPDIR="$BATS_TEST_TMPDIR"
  export COMMON_SOURCE="$BATS_TEST_TMPDIR/source"
  export COMMON_TAR="$BATS_TEST_TMPDIR/common.tar.gz"
  mkdir -p "$COMMON_SOURCE"
}

create_account() {
  local host=${1:-acme-v02.api.letsencrypt.org}
  local id=${2:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}
  local base="$COMMON_SOURCE/accounts/$host/directory/$id" file
  mkdir -p "$base"
  for file in meta regr private_key; do
    printf '{"fixture":"%s"}\n' "$file" >"$base/$file.json"
    chmod 0600 "$base/$file.json"
  done
  chmod 0700 "$COMMON_SOURCE/accounts" "$COMMON_SOURCE/accounts/$host" \
    "$COMMON_SOURCE/accounts/$host/directory" "$base"
}

pack_common() {
  tar -czf "$COMMON_TAR" -C "$COMMON_SOURCE" accounts
}

validate_common() {
  run bash -c 'source "$1" --version >/dev/null; certbotbot_common_validate "$2"' \
    _ "$CERTBOTBOT_ARTIFACT" "$COMMON_TAR"
}

@test "complete production ACME account manifest validates" {
  create_account
  pack_common
  validate_common
  [ "$status" -eq 0 ]
}

@test "complete staging and production accounts can coexist" {
  create_account
  create_account acme-staging-v02.api.letsencrypt.org \
    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  pack_common
  validate_common
  [ "$status" -eq 0 ]
}

@test "missing ACME account key fails validation" {
  create_account
  rm "$COMMON_SOURCE/accounts/acme-v02.api.letsencrypt.org/directory/"\
"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/private_key.json"
  pack_common
  validate_common
  [ "$status" -eq 64 ]
}

@test "readable account private key fails validation" {
  create_account
  chmod 0644 "$COMMON_SOURCE/accounts/acme-v02.api.letsencrypt.org/"\
"directory/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/private_key.json"
  pack_common
  validate_common
  [ "$status" -eq 64 ]
}

@test "unknown ACME server is not a supported account archive" {
  create_account acme.example.org
  pack_common
  validate_common
  [ "$status" -eq 64 ]
}

@test "unexpected account config and renewal hooks are rejected" {
  create_account
  printf '%s\n' dangerous >"$COMMON_SOURCE/accounts/cli.ini"
  pack_common
  validate_common
  [ "$status" -eq 64 ]
}

@test "unexpected account symlinks are rejected" {
  create_account
  local base="$COMMON_SOURCE/accounts/acme-v02.api.letsencrypt.org/"\
"directory/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  rm "$base/regr.json"
  ln -s /etc/passwd "$base/regr.json"
  pack_common
  validate_common
  [ "$status" -eq 64 ]
}

@test "duplicate common archive member is rejected" {
  create_account
  tar -czf "$COMMON_TAR" -C "$COMMON_SOURCE" accounts \
    accounts/acme-v02.api.letsencrypt.org/directory/\
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/private_key.json
  validate_common
  [ "$status" -eq 64 ]
}

@test "common archive restore creates private isolated account tree" {
  create_account
  pack_common
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    printf "untouched\n" >"$CERTBOTBOT_WORKSPACE_CONFIG/marker"
    certbotbot_common_restore "$2" || exit
    [[ "$CERTBOTBOT_COMMON_STAGE" == "$CERTBOTBOT_WORKSPACE_ROOT"/account.* ]] || exit
    [[ "$(stat -c "%a" "$CERTBOTBOT_COMMON_STAGE")" == 700 ]] || exit
    key="$CERTBOTBOT_COMMON_STAGE/accounts/acme-v02.api.letsencrypt.org/directory/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/private_key.json"
    [[ -f "$key" && "$(stat -c "%a" "$key")" == 600 ]] || exit
    [[ "$(cat "$CERTBOTBOT_WORKSPACE_CONFIG/marker")" == untouched ]] || exit
    old="$CERTBOTBOT_COMMON_STAGE"
    certbotbot_common_discard || exit
    [[ ! -e "$old" ]] || exit
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$COMMON_TAR"
  [ "$status" -eq 0 ]
}

@test "invalid archive leaves active Certbot configuration unchanged" {
  create_account
  printf '%s\n' BAD >"$COMMON_SOURCE/accounts/foreign.txt"
  pack_common
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    printf "safe\n" >"$CERTBOTBOT_WORKSPACE_CONFIG/marker"
    certbotbot_common_restore "$2"
    rc=$?
    [[ "$rc" == 64 && -z "$CERTBOTBOT_COMMON_STAGE" ]] || exit
    [[ "$(cat "$CERTBOTBOT_WORKSPACE_CONFIG/marker")" == safe ]] || exit
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$COMMON_TAR"
  [ "$status" -eq 0 ]
}

@test "account archive is rejected without a private producer workspace" {
  create_account
  pack_common
  run bash -c 'source "$1" --version >/dev/null; certbotbot_common_restore "$2"' \
    _ "$CERTBOTBOT_ARTIFACT" "$COMMON_TAR"
  [ "$status" -eq 64 ]
}

@test "second common restore refuses to overwrite undiscarded state" {
  create_account
  pack_common
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    certbotbot_common_restore "$2" || exit
    certbotbot_common_restore "$2"
    rc=$?
    certbotbot_common_discard || exit
    certbotbot_workspace_destroy || exit
    [[ "$rc" == 64 ]]
  ' _ "$CERTBOTBOT_ARTIFACT" "$COMMON_TAR"
  [ "$status" -eq 0 ]
}

@test "post-restore inspection rejects unexpected account entries" {
  create_account
  pack_common
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    certbotbot_common_restore "$2" || exit
    printf "unexpected\\n" >"$CERTBOTBOT_COMMON_STAGE/foreign.txt"
    certbotbot_common_inspect "$CERTBOTBOT_COMMON_STAGE"
    rc=$?
    certbotbot_common_discard || exit
    certbotbot_workspace_destroy || exit
    [[ "$rc" == 64 ]]
  ' _ "$CERTBOTBOT_ARTIFACT" "$COMMON_TAR"
  [ "$status" -eq 0 ]
}

@test "same common account archive restores on two fresh producer nodes" {
  create_account
  pack_common
  local previous='' output parent
  for parent in "$BATS_TEST_TMPDIR/jenkins" "$BATS_TEST_TMPDIR/actions"; do
    mkdir -p "$parent"
    run env CERTBOTBOT_TMPDIR="$parent" bash -c '
      source "$1" --version >/dev/null
      certbotbot_workspace_create || exit
      certbotbot_common_restore "$2" || exit
      key="$CERTBOTBOT_COMMON_STAGE/accounts/acme-v02.api.letsencrypt.org/directory/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/private_key.json"
      [[ -f "$key" ]] || exit
      digest="$(sha256sum -- "$key")" || exit
      printf "%s\n" "${digest%% *}"
      old="$CERTBOTBOT_COMMON_STAGE"
      certbotbot_common_discard || exit
      [[ ! -e "$old" ]] || exit
      certbotbot_workspace_destroy
    ' _ "$CERTBOTBOT_ARTIFACT" "$COMMON_TAR"
    [ "$status" -eq 0 ]
    if [[ -n $previous ]]; then
      [ "$output" = "$previous" ]
    fi
    previous="$output"
    [ -z "$(find "$parent" -mindepth 1 -print)" ]
  done
}

@test "common archive remains unavailable to the public issuing command" {
  run "$CERTBOTBOT_ARTIFACT" example.com
  [ "$status" -eq 69 ]
}
