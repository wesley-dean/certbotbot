#!/usr/bin/env bats

## @file tests/client-extract.bats
## @brief Verifies the consumer's private, no-clobber certificate extraction.
## @details
## Uses mocked read-only AWS calls and real local GNU tar/gzip archives.
## No live S3 credentials, issuer operations or runtime vendor files are used.

setup() {
  TEST_ROOT="$(mktemp -d)"
  mkdir -m 700 "$TEST_ROOT/private"
  mkdir "$TEST_ROOT/bin" "$TEST_ROOT/source"
  mkdir -p "$TEST_ROOT/source/accounts/acme-v02.api.letsencrypt.org/directory/account-001"
  printf 'ACCOUNT_PRIVATE_KEY_SENTINEL\n' >"$TEST_ROOT/source/accounts/acme-v02.api.letsencrypt.org/directory/account-001/private_key.json"
  chmod 600 "$TEST_ROOT/source/accounts/acme-v02.api.letsencrypt.org/directory/account-001/private_key.json"
  OBJECT="$TEST_ROOT/current.tar.gz"
  CLIENT="$TEST_ROOT/client.bash"
  if [[ -n "${BASH_STARTER_CLIENT_ARTIFACT:-}" ]]; then
    # The shipped executable was assembled and checksum-verified by Make/CI.
    # Copy it outside the source checkout for black-box invocation.
    [[ -f "$BASH_STARTER_CLIENT_ARTIFACT" && -x "$BASH_STARTER_CLIENT_ARTIFACT" ]] || return 1
    cp -- "$BASH_STARTER_CLIENT_ARTIFACT" "$CLIENT"
  else
    {
    cat "$BATS_TEST_DIRNAME/../lib/client-config.bash"
    cat "$BATS_TEST_DIRNAME/../lib/filename.bash"
    # Replaced by digest-verified embedded mktext in task #54.
    cat <<'RENDERER'
mktext() {
  [[ "$1" == render ]] || return 1
  local -n fields="$2"
  local value
  IFS= read -r value || :
  value="${value//\{YEAR\}/${fields[YEAR]}}"
  value="${value//\{MONTH\}/${fields[MONTH]}}"
  value="${value//\{DOM\}/${fields[DOM]}}"
  printf '%s' "$value"
}
RENDERER
    cat "$BATS_TEST_DIRNAME/../lib/client-crypto.bash"
    cat "$BATS_TEST_DIRNAME/../lib/client-s3.bash"
    cat "$BATS_TEST_DIRNAME/../lib/archive.bash"
    cat "$BATS_TEST_DIRNAME/../lib/restore.bash"
    cat "$BATS_TEST_DIRNAME/../lib/client-extract.bash"
    cat "$BATS_TEST_DIRNAME/../src/client.bash"
    } >"$CLIENT"
  fi
  chmod 700 "$CLIENT"
  cat >"$TEST_ROOT/bin/aws" <<'AWS'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1-}" == --version ]]; then
  printf 'aws-cli/2.22.0 Python/3.12\n'
  exit 0
fi
[[ "${1-}" == --no-cli-pager && "${2-}" == s3api ]] || exit 91
printf '%s\n' "$3" >>"$MOCK_S3_LOG"
case "$3" in
  head-object)
    if [[ "${MOCK_S3_MODE:-ok}" == absent ]]; then
      printf 'An error occurred (404) when calling HeadObject\n' >&2
      exit 254
    fi
    if [[ "${MOCK_S3_MODE:-ok}" == denied ]]; then
      printf 'AccessDenied ACCOUNT_PRIVATE_KEY_SENTINEL\n' >&2
      exit 254
    fi
    ;;
  head-bucket)
    [[ "${MOCK_S3_MODE:-ok}" == absent ]] || exit 254
    ;;
  get-object)
    if [[ "${MOCK_S3_MODE:-ok}" == getfailed ]]; then
      printf 'transport error ACCOUNT_PRIVATE_KEY_SENTINEL\n' >&2
      exit 255
    fi
    cp -- "$MOCK_S3_OBJECT" "${@: -1}"
    ;;
  *) exit 99 ;;
esac
AWS
  chmod 700 "$TEST_ROOT/bin/aws"
  make_object
}

teardown() {
  rm -rf -- "$TEST_ROOT"
}

make_object() {
  tar -czf "$OBJECT" -C "$TEST_ROOT/source" .
}

make_lineage() {
  local name="$1" piece
  mkdir -p "$TEST_ROOT/source/archive/$name" "$TEST_ROOT/source/live/$name" "$TEST_ROOT/source/renewal"
  for piece in cert chain fullchain privkey; do
    printf '%s-material-for-%s\n' "$piece" "$name" >"$TEST_ROOT/source/archive/$name/${piece}1.pem"
    ln -s "../../archive/$name/${piece}1.pem" "$TEST_ROOT/source/live/$name/$piece.pem"
  done
  printf 'archive_dir = /etc/letsencrypt/archive/%s\n' "$name" >"$TEST_ROOT/source/renewal/$name.conf"
  chmod 600 "$TEST_ROOT/source/renewal/$name.conf"
}

invoke() {
  run env -u S3_BUCKET -u S3_KEY -u S3_KEY_TEMPLATE \
    -u GPG_SYMMETRIC_KEY -u ARCHIVE_ENCRYPTION \
    PATH="$TEST_ROOT/bin:$PATH" \
    MOCK_S3_LOG="$TEST_ROOT/aws.log" MOCK_S3_OBJECT="$OBJECT" \
    MOCK_S3_MODE="${MOCK_S3_MODE:-ok}" \
    bash "$CLIENT" --destination "$TEST_ROOT/private/cert-state" \
      --s3-bucket fixture-bucket "$@"
}

@test "account-only plaintext archive activates new private directory" {
  invoke
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_ROOT/private/cert-state" ]
  local key="$TEST_ROOT/private/cert-state/accounts/acme-v02.api.letsencrypt.org/directory/account-001/private_key.json"
  [ -f "$key" ]
  [ "$(cat "$key")" = ACCOUNT_PRIVATE_KEY_SENTINEL ]
  [ "$(stat -c %a "$key")" = 600 ]
  [ "$(stat -c %a "$TEST_ROOT/private/cert-state")" = 700 ]
  [ "$(stat -c %a "$TEST_ROOT/private/cert-state/accounts")" = 700 ]
  [ ! -e "$TEST_ROOT/private/cert-state/live" ]
  [ "$(grep -c '^get-object$' "$TEST_ROOT/aws.log")" -eq 1 ]
  [ "$(find "$TEST_ROOT/private" -maxdepth 1 -name '.certbotbot-client.*' | wc -l)" -eq 0 ]
}

@test "complete multi-lineage archive preserves exact PEM links and renewal contents" {
  make_lineage one.example
  make_lineage two.example
  # An issuer-valid archive can contain public-readable PEM; client always
  # narrows regular-file modes before activating any account/key state.
  chmod 644 "$TEST_ROOT/source/archive/one.example/privkey1.pem"
  make_object
  invoke
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_ROOT/private/cert-state" ]
  local name part base="$TEST_ROOT/private/cert-state"
  for name in one.example two.example; do
    for part in cert chain fullchain privkey; do
      [ -L "$base/live/$name/$part.pem" ]
      [ "$(readlink "$base/live/$name/$part.pem")" = "../../archive/$name/${part}1.pem" ]
      cmp "$TEST_ROOT/source/archive/$name/${part}1.pem" "$base/live/$name/$part.pem"
      [ "$(stat -c %a "$base/archive/$name/${part}1.pem")" = 600 ]
    done
    grep -Fq "/etc/letsencrypt/archive/$name" "$base/renewal/$name.conf"
    [ "$(stat -c %a "$base/renewal/$name.conf")" = 600 ]
  done
  [ ! -e "$TEST_ROOT/private/cert-state/certbot" ]
}

@test "corrupt gzip and unrelated plaintext are refused without partial destination" {
  printf 'not a tar body ACCOUNT_PRIVATE_KEY_SENTINEL\n' >"$OBJECT"
  invoke
  [ "$status" -eq 65 ]
  [ -z "$output" ] || [[ "$output" != *ACCOUNT_PRIVATE_KEY_SENTINEL* ]]
  [ ! -e "$TEST_ROOT/private/cert-state" ]
  [ -z "$(find "$TEST_ROOT/private" -mindepth 1 -print)" ]
  make_object
  truncate -s -8 "$OBJECT"
  invoke
  [ "$status" -eq 65 ]
  [ ! -e "$TEST_ROOT/private/cert-state" ]
}

@test "recognized encrypted GnuPG envelope is never decrypted or activated" {
  printf 'CERTBOTBOT-GPG-OCB-V1\nACCOUNT_PRIVATE_KEY_SENTINEL\n' >"$OBJECT"
  invoke
  [ "$status" -eq 65 ]
  [[ "$output" != *ACCOUNT_PRIVATE_KEY_SENTINEL* ]]
  [ ! -e "$TEST_ROOT/private/cert-state" ]
  [ ! -e "$TEST_ROOT/private/cert-state/accounts" ]
}

@test "absolute and traversal tar members fail before any extraction" {
  tar -czf "$OBJECT" --transform='s,^accounts,../accounts,' \
    -C "$TEST_ROOT/source" accounts
  invoke
  [ "$status" -eq 65 ]
  [ ! -e "$TEST_ROOT/private/cert-state" ]
  [ ! -e "$TEST_ROOT/accounts" ]
  tar -czf "$OBJECT" --transform='s,^accounts,/accounts,' \
    -C "$TEST_ROOT/source" accounts
  invoke
  [ "$status" -eq 65 ]
  [ ! -e "$TEST_ROOT/private/cert-state" ]
}

@test "escaping PEM links, missing targets, and special files never activate" {
  make_lineage one.example
  rm "$TEST_ROOT/source/live/one.example/privkey.pem"
  ln -s ../../../../etc/passwd "$TEST_ROOT/source/live/one.example/privkey.pem"
  make_object
  invoke
  [ "$status" -eq 65 ]
  [ ! -e "$TEST_ROOT/private/cert-state" ]
  rm "$TEST_ROOT/source/live/one.example/privkey.pem"
  ln -s ../../archive/one.example/privkey1.pem "$TEST_ROOT/source/live/one.example/privkey.pem"
  rm "$TEST_ROOT/source/archive/one.example/privkey1.pem"
  make_object
  invoke
  [ "$status" -eq 65 ]
  mkfifo "$TEST_ROOT/source/accounts/unsupported-fifo"
  make_object
  invoke
  [ "$status" -eq 65 ]
  [ -z "$(find "$TEST_ROOT/private" -mindepth 1 -print)" ]
}

@test "hardlink and duplicate tar entries are not accepted" {
  printf 'data\n' >"$TEST_ROOT/source/accounts/hard-source"
  ln "$TEST_ROOT/source/accounts/hard-source" "$TEST_ROOT/source/accounts/hard-copy"
  make_object
  invoke
  [ "$status" -eq 65 ]
  rm "$TEST_ROOT/source/accounts/hard-copy"
  tar -czf "$OBJECT" -C "$TEST_ROOT/source" . -C "$TEST_ROOT/source" .
  invoke
  [ "$status" -eq 65 ]
  [ ! -e "$TEST_ROOT/private/cert-state" ]
}

@test "malformed or excessive content cannot escape to a sibling path" {
  truncate -s 34000000 "$TEST_ROOT/source/accounts/padded"
  make_object
  invoke
  [ "$status" -eq 65 ]
  [ ! -e "$TEST_ROOT/private/cert-state" ]
  [ ! -e "$TEST_ROOT/private/unrelated" ]
  [ -z "$(find "$TEST_ROOT/private" -mindepth 1 -print)" ]
}

@test "already existing directory, regular file, or symlink never changes" {
  mkdir "$TEST_ROOT/private/cert-state"
  printf 'original\n' >"$TEST_ROOT/private/cert-state/keep"
  invoke
  [ "$status" -eq 73 ]
  [ "$(cat "$TEST_ROOT/private/cert-state/keep")" = original ]
  [ ! -e "$TEST_ROOT/aws.log" ]
  rm -r "$TEST_ROOT/private/cert-state"
  printf 'original bytes\n' >"$TEST_ROOT/private/cert-state"
  invoke
  [ "$status" -eq 73 ]
  [ "$(cat "$TEST_ROOT/private/cert-state")" = 'original bytes' ]
  rm "$TEST_ROOT/private/cert-state"
  ln -s "$TEST_ROOT/source" "$TEST_ROOT/private/cert-state"
  invoke
  [ "$status" -eq 73 ]
  [ -L "$TEST_ROOT/private/cert-state" ]
  [ ! -e "$TEST_ROOT/aws.log" ]
}

@test "unsafe and missing destination parent are rejected before S3 access" {
  chmod 0777 "$TEST_ROOT/private"
  invoke
  [ "$status" -eq 73 ]
  [ ! -e "$TEST_ROOT/aws.log" ]
  chmod 0700 "$TEST_ROOT/private"
  mv "$TEST_ROOT/private" "$TEST_ROOT/renamed"
  invoke
  [ "$status" -eq 73 ]
  [ ! -e "$TEST_ROOT/aws.log" ]
}

@test "remote absence and authorization failure never present a destination" {
  MOCK_S3_MODE=absent invoke
  [ "$status" -eq 66 ]
  [ ! -e "$TEST_ROOT/private/cert-state" ]
  rm "$TEST_ROOT/aws.log"
  MOCK_S3_MODE=denied invoke
  [ "$status" -eq 69 ]
  [[ "$output" != *ACCOUNT_PRIVATE_KEY_SENTINEL* ]]
  [ ! -e "$TEST_ROOT/private/cert-state" ]
}

@test "incomplete GetObject leaves neither extracted tree nor temporary bytes" {
  MOCK_S3_MODE=getfailed invoke
  [ "$status" -eq 69 ]
  [ ! -e "$TEST_ROOT/private/cert-state" ]
  [ -z "$(find "$TEST_ROOT/private" -mindepth 1 -print)" ]
}

@test "archived renewal text is inert and cannot execute installed hooks" {
  make_lineage one.example
  printf 'renew_hook = touch /tmp/DO_NOT_EXECUTE_CERTBOTBOT_CLIENT\n' >"$TEST_ROOT/source/renewal/one.example.conf"
  make_object
  invoke
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_ROOT/private/cert-state" ]
  [ ! -e /tmp/DO_NOT_EXECUTE_CERTBOTBOT_CLIENT ]
  grep -Fq 'renew_hook = touch' "$TEST_ROOT/private/cert-state/renewal/one.example.conf"
}


# Real-GnuPG cryptographic fixtures (task #186). The mandatory runner-level
# capability policy is governed by task #188; unsupported runners skip here.
make_authenticated_object() {
  local secret="${1:-CLIENT_CRYPTO_TEST_SENTINEL_FIXTURE_KEY_256_BITS}"
  command -v gpg >/dev/null 2>&1 || skip 'real GnuPG not installed'
  mkdir -m 700 "$TEST_ROOT/fixture-gnupg"
  if ! (umask 077; gpg --no-options --homedir "$TEST_ROOT/fixture-gnupg" \
    --batch --yes --no-tty --pinentry-mode loopback --no-symkey-cache \
    --passphrase-fd 3 --symmetric --force-ocb --cipher-algo AES256 \
    --s2k-mode 3 --s2k-digest-algo SHA512 --s2k-count 16777216 \
    --output "$TEST_ROOT/fixture.gpg" "$OBJECT" \
    3<<<"$secret" >/dev/null 2>&1); then
    skip 'GnuPG cannot emit ADR-031 authenticated OCB fixture'
  fi
  { printf 'CERTBOTBOT-GPG-OCB-V1\n'; cat "$TEST_ROOT/fixture.gpg"; } >"$TEST_ROOT/encrypted-object"
  mv -T -- "$TEST_ROOT/encrypted-object" "$OBJECT"
}

encrypted_invoke() {
  local secret="${1:-CLIENT_CRYPTO_TEST_SENTINEL_FIXTURE_KEY_256_BITS}"
  run env -u ARCHIVE_ENCRYPTION -u S3_BUCKET -u S3_KEY -u S3_KEY_TEMPLATE \
    GPG_SYMMETRIC_KEY="$secret" PATH="$TEST_ROOT/bin:$PATH" \
    MOCK_S3_LOG="$TEST_ROOT/aws.log" MOCK_S3_OBJECT="$OBJECT" \
    bash "$CLIENT" --destination "$TEST_ROOT/private/cert-state" \
      --s3-bucket fixture-bucket --archive-encryption gpg-ocb
}

@test "real authenticated OCB object restores all certificate lineages privately" {
  make_lineage one.example
  make_lineage two.example
  make_object
  make_authenticated_object
  encrypted_invoke
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_ROOT/private/cert-state" ]
  [ "$(grep -c '^get-object$' "$TEST_ROOT/aws.log")" -eq 1 ]
  [ -z "$(find "$TEST_ROOT/private" -maxdepth 1 -name '.certbotbot-client.*' -print)" ]
  local base="$TEST_ROOT/private/cert-state" name item
  for name in one.example two.example; do
    for item in cert chain fullchain privkey; do
      [ -L "$base/live/$name/$item.pem" ]
      [ "$(readlink "$base/live/$name/$item.pem")" = "../../archive/$name/${item}1.pem" ]
      [ "$(stat -c %a "$base/archive/$name/${item}1.pem")" = 600 ]
    done
  done
  [ "$(cat "$base/accounts/acme-v02.api.letsencrypt.org/directory/account-001/private_key.json")" = ACCOUNT_PRIVATE_KEY_SENTINEL ]
}

@test "wrong key or appended ciphertext fails without partial destination or leaked bytes" {
  make_object
  make_authenticated_object
  encrypted_invoke WRONG_CLIENT_CRYPTO_TEST_SENTINEL_KEY
  [ "$status" -eq 65 ]
  [[ "$output" != *ACCOUNT_PRIVATE_KEY_SENTINEL* ]]
  [[ "$output" != *WRONG_CLIENT_CRYPTO_TEST_SENTINEL_KEY* ]]
  [ ! -e "$TEST_ROOT/private/cert-state" ]
  [ -z "$(find "$TEST_ROOT/private" -mindepth 1 -print)" ]
  [ "$(grep -c '^get-object$' "$TEST_ROOT/aws.log")" -eq 1 ]
  rm -f "$TEST_ROOT/aws.log"
  printf '\001' >>"$OBJECT"
  encrypted_invoke
  [ "$status" -eq 65 ]
  [ ! -e "$TEST_ROOT/private/cert-state" ]
  [ -z "$(find "$TEST_ROOT/private" -mindepth 1 -print)" ]
  [ "$(grep -c '^get-object$' "$TEST_ROOT/aws.log")" -eq 1 ]
}

@test "authenticated unsafe tar remains unauthorized archive content" {
  make_lineage one.example
  rm "$TEST_ROOT/source/live/one.example/privkey.pem"
  ln -s ../../../../etc/passwd "$TEST_ROOT/source/live/one.example/privkey.pem"
  make_object
  make_authenticated_object
  encrypted_invoke
  [ "$status" -eq 65 ]
  [ ! -e "$TEST_ROOT/private/cert-state" ]
  [ -z "$(find "$TEST_ROOT/private" -mindepth 1 -print)" ]
  [ "$(grep -c '^get-object$' "$TEST_ROOT/aws.log")" -eq 1 ]
}
