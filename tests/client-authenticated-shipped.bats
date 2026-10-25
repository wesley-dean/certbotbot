#!/usr/bin/env bats

# ADR-037 task #187: independent black-box acceptance of the shipped client.
# The actual assembled, checksum-verified binary is run outside the checkout.
# Only AWS is mocked. Positive crypto uses a real installed GnuPG executable.

setup() {
  : "${BASH_STARTER_CLIENT_ARTIFACT:?verified client artifact required}"
  : "${BASH_STARTER_ARTIFACT:?producer artifact required}"

  TEST_ROOT="$(mktemp -d)"
  RUNTIME="$TEST_ROOT/runtime"
  BIN="$RUNTIME/bin"
  SOURCE="$TEST_ROOT/source"
  ARCHIVE="$TEST_ROOT/current.tar.gz"
  OBJECT="$TEST_ROOT/current-object"
  AWS_LOG="$TEST_ROOT/aws.log"
  GPG_LOG="$TEST_ROOT/gpg.log"
  DESTINATION="$RUNTIME/private/restored"
  CLIENT="$RUNTIME/certbotbot-client.bash"
  REAL_GPG_BIN="$(type -P gpg || :)"
  TEST_KEY="$(LC_ALL=C od -An -tx1 -N32 /dev/urandom | tr -d ' \n')"

  mkdir -p "$BIN" "$RUNTIME/private" "$SOURCE/accounts/acme-v02.api.letsencrypt.org/directory/account-001"
  chmod 0700 "$RUNTIME/private"
  cp -- "$BASH_STARTER_CLIENT_ARTIFACT" "$CLIENT"
  cp -- "$BASH_STARTER_CLIENT_ARTIFACT.sha256" "$RUNTIME/certbotbot-client.bash.sha256"
  chmod 0700 "$CLIENT"
  printf '%s\n' 'ACCOUNT_PRIVATE_KEY_SENTINEL_FOR_187' \
    >"$SOURCE/accounts/acme-v02.api.letsencrypt.org/directory/account-001/private_key.json"

  cat >"$BIN/aws" <<'AWS'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${GPG_SYMMETRIC_KEY+x}" && -z "${CERTBOTBOT_CLIENT_GPG_SECRET+x}" ]] || exit 96
if [[ "${1-}" == --version ]]; then
  printf 'aws-cli/2.22.0 Python/3.12\n'
  exit 0
fi
[[ "${1-}" == --no-cli-pager && "${2-}" == s3api ]] || exit 97
operation="${3-}"
candidate="${@: -1}"
bucket='' key=''
while (( $# )); do
  case "$1" in
    --bucket) bucket="${2-}"; shift 2 ;;
    --key) key="${2-}"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s|%s|%s\n' "$operation" "$bucket" "$key" >>"$MOCK_AWS_LOG"
[[ "$bucket" == fixture-bucket && "$key" == current-client.tar.gz ]] || exit 98
case "$operation" in
  head-object)
    [[ "${MOCK_AWS_MODE:-ok}" != denied ]] || {
      printf 'AccessDenied ACCOUNT_PRIVATE_KEY_SENTINEL_FOR_187\n' >&2
      exit 254
    }
    ;;
  get-object)
    cp -- "$MOCK_AWS_OBJECT" "$candidate"
    ;;
  *) exit 99 ;;
esac
AWS
  chmod 0700 "$BIN/aws"

  cat >"$BIN/gpg" <<'GPG'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${GPG_SYMMETRIC_KEY+x}" && -z "${CERTBOTBOT_CLIENT_GPG_SECRET+x}" ]] || exit 96
printf '%s\n' "$*" >>"$MOCK_GPG_LOG"
case "${MOCK_GPG_MODE:-normal}" in
  missing) exit 127 ;;
  old)
    if [[ "${1-}" == --version ]]; then
      printf 'gpg (GnuPG) 2.2.21\n'
      exit 0
    fi
    exit 127
    ;;
esac
[[ -n "${REAL_GPG_BIN:-}" ]] || exit 127
exec "$REAL_GPG_BIN" "$@"
GPG
  chmod 0700 "$BIN/gpg"

  export MOCK_AWS_LOG="$AWS_LOG" MOCK_AWS_OBJECT="$OBJECT"
  export MOCK_GPG_LOG="$GPG_LOG" REAL_GPG_BIN
  export PATH="$BIN:$PATH"
  unset GPG_SYMMETRIC_KEY ARCHIVE_ENCRYPTION S3_BUCKET S3_KEY S3_KEY_TEMPLATE
}

teardown() {
  unset GPG_SYMMETRIC_KEY
  rm -rf -- "$TEST_ROOT"
}

require_real_ocb() {
  [[ -x "$REAL_GPG_BIN" ]] || skip 'SKIP: real GnuPG unavailable; NOT crypto evidence'
  local version major minor patch
  version="$("$REAL_GPG_BIN" --version 2>/dev/null)" ||
    skip 'SKIP: GnuPG version unavailable; NOT crypto evidence'
  [[ "$version" =~ gpg\ \(GnuPG\)\ ([0-9]+)\.([0-9]+)\.([0-9]+) ]] ||
    skip 'SKIP: unknown GnuPG version; NOT crypto evidence'
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"
  if (( major < 2 || (major == 2 &&
    (minor < 4 || (minor == 4 && patch < 7))) )); then
    skip 'SKIP: GnuPG 2.4.7+ unavailable; NOT crypto evidence'
  fi
}

make_lineage() {
  local name="$1" part
  mkdir -p "$SOURCE/archive/$name" "$SOURCE/live/$name" "$SOURCE/renewal"
  for part in cert chain fullchain privkey; do
    printf '%s-%s-original-material\n' "$name" "$part" \
      >"$SOURCE/archive/$name/${part}1.pem"
    ln -s "../../archive/$name/${part}1.pem" \
      "$SOURCE/live/$name/$part.pem"
  done
  printf 'archive_dir = /etc/letsencrypt/archive/%s\n' "$name" \
    >"$SOURCE/renewal/$name.conf"
}

make_archive() {
  tar -czf "$ARCHIVE" -C "$SOURCE" .
  cp -- "$ARCHIVE" "$OBJECT"
}

encrypt_archive() {
  # Fixture identity matches ADR-031. This is real symmetric encryption,
  # not a fake crypto stub or a precomputed fixture.
  local mode="${1:-ocb}"
  require_real_ocb
  mkdir -m 0700 "$TEST_ROOT/fixture-gnupg"
  local -a args=(--no-options --homedir "$TEST_ROOT/fixture-gnupg"
    --batch --yes --no-tty --pinentry-mode loopback --no-symkey-cache
    --passphrase-fd 3 --symmetric --cipher-algo AES256
    --s2k-mode 3 --s2k-digest-algo SHA512 --s2k-count 16777216)
  if [[ "$mode" == ocb ]]; then args+=(--force-ocb); fi
  if ! (umask 077; "$REAL_GPG_BIN" "${args[@]}" \
    --output "$TEST_ROOT/fixture.gpg" "$ARCHIVE" \
    3<<<"$TEST_KEY" >/dev/null 2>&1); then
    skip 'SKIP: real GnuPG cannot produce fixture; NOT crypto evidence'
  fi
  { printf 'CERTBOTBOT-GPG-OCB-V1\n'; cat "$TEST_ROOT/fixture.gpg"; } >"$OBJECT"
}

invoke() {
  local destination="${1:-$DESTINATION}"
  shift || :
  run bash "$CLIENT" --destination "$destination" \
    --s3-bucket fixture-bucket --s3-key current-client.tar.gz "$@"
}

run_encrypted() {
  export GPG_SYMMETRIC_KEY="${TEST_INVOKE_KEY:-$TEST_KEY}"
  invoke "${1:-$DESTINATION}" --archive-encryption gpg-ocb
  unset GPG_SYMMETRIC_KEY
}

assert_one_read() {
  [ -f "$AWS_LOG" ]
  [ "$(grep -c '^head-object|fixture-bucket|current-client.tar.gz$' "$AWS_LOG")" -eq 1 ]
  [ "$(grep -c '^get-object|fixture-bucket|current-client.tar.gz$' "$AWS_LOG")" -eq 1 ]
  ! grep -Ev '^(head-object|get-object)\|fixture-bucket\|current-client\.tar\.gz$' "$AWS_LOG"
}

assert_no_activation() {
  [ ! -e "$DESTINATION" ]
  [ ! -L "$DESTINATION" ]
  [ -z "$(find "$RUNTIME/private" -mindepth 1 -print)" ]
  [[ "$output" != *ACCOUNT_PRIVATE_KEY_SENTINEL_FOR_187* ]]
  [[ "$output" != *"$TEST_KEY"* ]]
  [[ "$output" != *PRIVATE_STATE_SHOULD_NOT_LEAK* ]]
}

assert_rejected_encrypted() {
  [ "$status" -eq 65 ]
  [[ "$output" == *'certbotbot-client:'* ]]
  assert_no_activation
  assert_one_read
}

@test "shipped artifact has checked checksum, shared provenance, and no runtime checkout" {
  run bash -c 'cd "$1" && sha256sum -c certbotbot-client.bash.sha256' _ "$RUNTIME"
  [ "$status" -eq 0 ]
  [ "$output" = 'certbotbot-client.bash: OK' ]
  [ ! -e "$RUNTIME/src" ]
  [ ! -e "$RUNTIME/lib" ]
  [ ! -e "$RUNTIME/vendor" ]
  [ ! -e "$RUNTIME/certbotbot.bash" ]
  run "$CLIENT" --version
  [ "$status" -eq 0 ]
  local client_version="$output"
  run "$BASH_STARTER_ARTIFACT" --version
  [ "$status" -eq 0 ]
  [ "$output" = "$client_version" ]
  ! grep -Eq '^certbotbot_(renew|publish|reconcile|certbot|crypto|backup|s3_put)[a-z_]*\(\)' "$CLIENT"
  ! grep -Eiq 's3api (put-object|delete-object|list-object-versions)' "$CLIENT"
}

@test "plaintext without key never calls GnuPG and restores account state" {
  make_archive
  MOCK_GPG_MODE=missing invoke "$DESTINATION" --archive-encryption none
  [ "$status" -eq 0 ]
  [ "$output" = "$DESTINATION" ]
  [ ! -e "$GPG_LOG" ]
  [ "$(cat "$DESTINATION/accounts/acme-v02.api.letsencrypt.org/directory/account-001/private_key.json")" = ACCOUNT_PRIVATE_KEY_SENTINEL_FOR_187 ]
  [ "$(stat -c %a "$DESTINATION")" = 700 ]
  assert_one_read
}

@test "exported key with explicit plaintext mode is a local status 64 conflict" {
  make_archive
  export GPG_SYMMETRIC_KEY="$TEST_KEY"
  invoke "$DESTINATION" --archive-encryption none
  unset GPG_SYMMETRIC_KEY
  [ "$status" -eq 64 ]
  assert_no_activation
  [ ! -e "$AWS_LOG" ]
}

@test "real producer OCB account-only archive restores privately" {
  make_archive
  encrypt_archive
  run_encrypted
  [ "$status" -eq 0 ]
  [ "$output" = "$DESTINATION" ]
  local private="$DESTINATION/accounts/acme-v02.api.letsencrypt.org/directory/account-001/private_key.json"
  [ "$(cat "$private")" = ACCOUNT_PRIVATE_KEY_SENTINEL_FOR_187 ]
  [ "$(stat -c %a "$private")" = 600 ]
  [ "$(stat -c %a "$DESTINATION")" = 700 ]
  [ -z "$(find "$RUNTIME/private" -maxdepth 1 -name '.certbotbot-client.*' -print)" ]
  [ -s "$GPG_LOG" ]
  ! grep -Fq -- "$TEST_KEY" "$GPG_LOG"
  assert_one_read
}

@test "real encrypted multi-lineage archive is identical to plaintext restoration" {
  make_lineage one.example
  make_lineage two.example
  make_archive
  invoke "$RUNTIME/private/plain" --archive-encryption none
  [ "$status" -eq 0 ]
  encrypt_archive
  run_encrypted
  [ "$status" -eq 0 ]
  [ "$output" = "$DESTINATION" ]
  diff -r -- "$RUNTIME/private/plain" "$DESTINATION"
  local name part
  for name in one.example two.example; do
    for part in cert chain fullchain privkey; do
      [ -L "$DESTINATION/live/$name/$part.pem" ]
      [ "$(readlink "$DESTINATION/live/$name/$part.pem")" = "../../archive/$name/${part}1.pem" ]
      [ "$(stat -c %a "$DESTINATION/archive/$name/${part}1.pem")" = 600 ]
    done
  done
  [ "$(grep -c '^get-object|' "$AWS_LOG")" -eq 2 ]
  ! grep -Ev '^(head-object|get-object)\|fixture-bucket\|current-client\.tar\.gz$' "$AWS_LOG"
}

@test "missing key and incompatible GnuPG fail before any S3 lookup" {
  make_archive
  invoke "$DESTINATION" --archive-encryption gpg-ocb
  [ "$status" -eq 64 ]
  [ ! -e "$AWS_LOG" ]
  MOCK_GPG_MODE=old
  export MOCK_GPG_MODE GPG_SYMMETRIC_KEY="$TEST_KEY"
  invoke "$DESTINATION" --archive-encryption gpg-ocb
  unset GPG_SYMMETRIC_KEY
  [ "$status" -eq 69 ]
  [ ! -e "$AWS_LOG" ]
  assert_no_activation
}

@test "wrong secret cannot authenticate a real OCB payload" {
  make_archive
  encrypt_archive
  TEST_INVOKE_KEY="$TEST_KEY-wrong" run_encrypted
  assert_rejected_encrypted
  [[ "$output" != *"$TEST_KEY-wrong"* ]]
}

@test "changed authenticated ciphertext or tag never activates state" {
  make_archive
  encrypt_archive
  local offset original octal
  offset=$(( $(stat -c %s "$OBJECT") - 6 ))
  original="$(od -An -tu1 -N1 -j "$offset" -- "$OBJECT")"
  printf -v octal '\\%03o' "$(( original ^ 1 ))"
  printf '%b' "$octal" |
    dd of="$OBJECT" bs=1 seek="$offset" conv=notrunc status=none
  run_encrypted
  assert_rejected_encrypted
}

@test "truncated and trailing ciphertext are both refused without fallback" {
  make_archive
  encrypt_archive
  truncate -s -1 "$OBJECT"
  run_encrypted
  assert_rejected_encrypted
  rm -f "$AWS_LOG"
  { printf 'CERTBOTBOT-GPG-OCB-V1\n'; cat "$TEST_ROOT/fixture.gpg"; printf '\000'; } >"$OBJECT"
  run_encrypted
  assert_rejected_encrypted
}

@test "altered or future envelope cannot select another format or key" {
  make_archive
  encrypt_archive
  sed -i '1s/V1/V2/' "$OBJECT"
  run_encrypted
  assert_rejected_encrypted
  rm -f "$AWS_LOG"
  cp -- "$TEST_ROOT/fixture.gpg" "$OBJECT"
  run_encrypted
  assert_rejected_encrypted
}

@test "legacy CFB/MDC OpenPGP payload is rejected even with correct secret" {
  make_archive
  encrypt_archive legacy
  run_encrypted
  assert_rejected_encrypted
}

@test "encrypted mode cannot downgrade to valid plaintext archive" {
  require_real_ocb
  make_archive
  run_encrypted
  assert_rejected_encrypted
}

@test "authenticated traversal, duplicate entries and hardlinks cannot activate" {
  require_real_ocb
  tar -czf "$ARCHIVE" --transform='s,^accounts,../accounts,' -C "$SOURCE" accounts
  encrypt_archive
  run_encrypted
  assert_rejected_encrypted

  rm -f "$AWS_LOG" "$TEST_ROOT/fixture.gpg"
  tar -czf "$ARCHIVE" -C "$SOURCE" accounts -C "$SOURCE" accounts
  encrypt_archive
  run_encrypted
  assert_rejected_encrypted

  rm -f "$AWS_LOG" "$TEST_ROOT/fixture.gpg"
  printf 'extra\n' >"$SOURCE/accounts/regular"
  ln "$SOURCE/accounts/regular" "$SOURCE/accounts/hardlinked"
  make_archive
  encrypt_archive
  run_encrypted
  assert_rejected_encrypted
}

@test "authenticated escaping links and unsupported fifo are rejected" {
  make_lineage one.example
  rm "$SOURCE/live/one.example/privkey.pem"
  ln -s ../../../../etc/passwd "$SOURCE/live/one.example/privkey.pem"
  make_archive
  encrypt_archive
  run_encrypted
  assert_rejected_encrypted

  rm -f "$AWS_LOG" "$TEST_ROOT/fixture.gpg"
  rm "$SOURCE/live/one.example/privkey.pem"
  ln -s ../../archive/one.example/privkey1.pem "$SOURCE/live/one.example/privkey.pem"
  mkfifo "$SOURCE/accounts/untrusted-fifo"
  make_archive
  encrypt_archive
  run_encrypted
  assert_rejected_encrypted
}

@test "authenticated decompressed content beyond 32 MiB is rejected" {
  truncate -s 34000000 "$SOURCE/accounts/oversized"
  make_archive
  encrypt_archive
  run_encrypted
  assert_rejected_encrypted
}

@test "authenticated tar exceeding 2048 members is rejected" {
  mkdir -p "$SOURCE/keys"
  local i
  for (( i=0; i<2050; i++ )); do
    printf -v entry 'member-%04d' "$i"
    : >"$SOURCE/keys/$entry"
  done
  make_archive
  encrypt_archive
  run_encrypted
  assert_rejected_encrypted
}

@test "an occupied destination cannot be replaced or cause S3 access" {
  make_archive
  encrypt_archive
  printf 'original\n' >"$DESTINATION"
  run_encrypted
  [ "$status" -eq 73 ]
  [ "$(cat "$DESTINATION")" = original ]
  [ ! -e "$AWS_LOG" ]
  [ ! -e "$GPG_LOG" ]
  [[ "$output" != *"$TEST_KEY"* ]]
}

@test "unsafe destination parent refuses encryption before remote access" {
  make_archive
  encrypt_archive
  chmod 0777 "$RUNTIME/private"
  run_encrypted
  [ "$status" -eq 73 ]
  [ ! -e "$AWS_LOG" ]
  [ ! -e "$DESTINATION" ]
  [ ! -e "$GPG_LOG" ]
}
