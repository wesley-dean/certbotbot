#!/usr/bin/env bats

## @file tests/gpg-archives.bats
## @brief Exercises private symmetric GPG archive preparation and restoration.
## @details
## These tests use a disposable fixture passphrase, a new workspace per test,
## and no AWS/ACME credentials. Production secrets must never be used in CI.

setup() {
  : "${CERTBOTBOT_ARTIFACT:?A standalone artifact is required}"
  export CERTBOTBOT_TMPDIR="$BATS_TEST_TMPDIR"
  unset GPG_PASSPHRASE || :
}

@test "AES-256 encryption and decryption round-trip private archive bytes" {
  run env GPG_PASSPHRASE='test-only strong archive secret' bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    plain="$CERTBOTBOT_WORKSPACE_ROOT/source.tar.gz"
    cipher="$CERTBOTBOT_WORKSPACE_ROOT/archive.tar.gz.enc"
    restored="$CERTBOTBOT_WORKSPACE_ROOT/restored.tar.gz"
    printf "test-only portable account bytes\n" >"$plain"
    : >"$cipher"
    : >"$restored"
    chmod 0600 -- "$plain" "$cipher" "$restored"
    certbotbot_gpg_encrypt_archive "$plain" "$cipher" || exit 1
    [[ -s $cipher ]] && ! cmp -s -- "$plain" "$cipher" || exit 2
    certbotbot_gpg_decrypt_archive "$cipher" "$restored" || exit 3
    cmp -s -- "$plain" "$restored" || exit 4
    [[ "$(stat -c "%a" "$cipher")" == 600 &&
      "$(stat -c "%a" "$restored")" == 600 ]] || exit 5
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "wrong passphrase fails decryption and truncates its private destination" {
  run env GPG_PASSPHRASE=correct-test-secret bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    plain="$CERTBOTBOT_WORKSPACE_ROOT/plain"
    cipher="$CERTBOTBOT_WORKSPACE_ROOT/cipher"
    restored="$CERTBOTBOT_WORKSPACE_ROOT/restored"
    printf "sensitive fixture\n" >"$plain"
    : >"$cipher"
    : >"$restored"
    chmod 0600 -- "$plain" "$cipher" "$restored"
    certbotbot_gpg_encrypt_archive "$plain" "$cipher" || exit 1
    if GPG_PASSPHRASE=incorrect-test-secret \
      certbotbot_gpg_decrypt_archive "$cipher" "$restored"; then
      exit 2
    else
      result=$?
    fi
    [[ "$result" -eq 65 && ! -s "$restored" ]] || exit 3
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "corrupted ciphertext is refused without leaving plaintext output" {
  run env GPG_PASSPHRASE=correct-test-secret bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    plain="$CERTBOTBOT_WORKSPACE_ROOT/plain"
    cipher="$CERTBOTBOT_WORKSPACE_ROOT/cipher"
    restored="$CERTBOTBOT_WORKSPACE_ROOT/restored"
    printf "sensitive fixture\n" >"$plain"
    : >"$cipher"
    : >"$restored"
    chmod 0600 -- "$plain" "$cipher" "$restored"
    certbotbot_gpg_encrypt_archive "$plain" "$cipher" || exit 1
    printf "not a GPG encrypted archive" >"$cipher"
    if certbotbot_gpg_decrypt_archive "$cipher" "$restored"; then
      exit 2
    else
      result=$?
    fi
    [[ "$result" -eq 65 && ! -s "$restored" ]] || exit 3
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT"
  [ "$status" -eq 0 ]
}

@test "unset passphrase cannot encrypt without a fail-closed error" {
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    plain="$CERTBOTBOT_WORKSPACE_ROOT/plain"
    cipher="$CERTBOTBOT_WORKSPACE_ROOT/cipher"
    printf "fixture\n" >"$plain"
    : >"$cipher"
    if certbotbot_gpg_encrypt_archive "$plain" "$cipher"; then
      exit 1
    else
      result=$?
    fi
    [[ $result == 64 && ! -s $cipher ]] || exit 2
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT"
  [ "$status" -eq 0 ]
}

@test "newline-containing passphrase is rejected before GPG execution" {
  run env GPG_PASSPHRASE=$'invalid\nsecret' bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    plain="$CERTBOTBOT_WORKSPACE_ROOT/plain"
    cipher="$CERTBOTBOT_WORKSPACE_ROOT/cipher"
    printf "fixture\n" >"$plain"
    : >"$cipher"
    certbotbot_gpg_encrypt_archive "$plain" "$cipher"
    result=$?
    [[ $result == 64 && ! -s $cipher ]] || exit 1
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT"
  [ "$status" -eq 0 ]
}

@test "output symlink is rejected without following it" {
  run env GPG_PASSPHRASE=secret bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    plain="$CERTBOTBOT_WORKSPACE_ROOT/plain"
    target="$CERTBOTBOT_WORKSPACE_ROOT/target"
    cipher="$CERTBOTBOT_WORKSPACE_ROOT/cipher"
    printf "fixture\n" >"$plain"
    printf "preserve\n" >"$target"
    ln -s -- "$target" "$cipher"
    certbotbot_gpg_encrypt_archive "$plain" "$cipher"
    result=$?
    [[ $result == 64 &&
      "$(cat "$target")" == preserve ]] || exit 1
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT"
  [ "$status" -eq 0 ]
}

@test "a traced shell cannot access the encryption passphrase" {
  run env GPG_PASSPHRASE='must-not-appear-on-xtrace' bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    plain="$CERTBOTBOT_WORKSPACE_ROOT/plain"
    cipher="$CERTBOTBOT_WORKSPACE_ROOT/cipher"
    printf "fixture\n" >"$plain"
    : >"$cipher"
    set -x
    certbotbot_gpg_encrypt_archive "$plain" "$cipher"
    status=$?
    set +x
    [[ $status == 64 && ! -s $cipher ]] || exit 1
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT"
  [ "$status" -eq 0 ]
  [[ "$output" != *'must-not-appear-on-xtrace'* ]]
}
