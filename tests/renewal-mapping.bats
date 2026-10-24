#!/usr/bin/env bats

setup() {
  : "${BASH_STARTER_ARTIFACT:?Artifact under test is required}"
  TEST_ROOT="$(mktemp -d)"
  CONFIG="$TEST_ROOT/config"
  NAME=example.com
  mkdir -m 700 "$CONFIG"
  mkdir -p "$CONFIG/accounts/acme-v02.api.letsencrypt.org/directory/account-id" \
    "$CONFIG/archive/$NAME" "$CONFIG/live/$NAME" "$CONFIG/renewal"
  local account="$CONFIG/accounts/acme-v02.api.letsencrypt.org/directory/account-id"
  printf '{"key":"test"}\n' >"$account/private_key.json"
  printf '{"registration":"test"}\n' >"$account/regr.json"
  printf '{"meta":"test"}\n' >"$account/meta.json"
  chmod 600 "$account/"*.json
  local part
  for part in cert chain fullchain privkey; do
    printf 'fixture:%s\n' "$part" >"$CONFIG/archive/$NAME/${part}1.pem"
    ln -s "../../archive/$NAME/${part}1.pem" "$CONFIG/live/$NAME/$part.pem"
  done
  chmod 600 "$CONFIG/archive/$NAME/privkey1.pem"
  RENEWAL="$CONFIG/renewal/$NAME.conf"
  cat >"$RENEWAL" <<'CONF'
# Certbot-generated renewal configuration
# renew_before_expiry = 30 days
version = 5.8.0
archive_dir = /etc/letsencrypt/archive/example.com
cert = /etc/letsencrypt/live/example.com/cert.pem
privkey = /etc/letsencrypt/live/example.com/privkey.pem
chain = /etc/letsencrypt/live/example.com/chain.pem
fullchain = /etc/letsencrypt/live/example.com/fullchain.pem

# Options used in the renewal process
[renewalparams]
account = account-id
authenticator = dns-route53
server = https://acme-v02.api.letsencrypt.org/directory
key_type = ecdsa

[acme_renewal_info]
ari_retry_after = 2026-10-21T00:00:00
CONF
  chmod 600 "$RENEWAL"
}

teardown() {
  rm -rf -- "$TEST_ROOT"
}

map_renewal() {
  run bash -c '
    source "$1" --help >/dev/null
    certbotbot_renewal_map "$2" "$3" "$4"
  ' _ "$BASH_STARTER_ARTIFACT" "$CONFIG" "$NAME" "$1"
}

@test "prepare maps exactly five paths into a private root" {
  map_renewal prepare
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -Fxq "archive_dir = $CONFIG/archive/$NAME" "$RENEWAL"
  local part
  for part in cert privkey chain fullchain; do
    grep -Fxq "$part = $CONFIG/live/$NAME/$part.pem" "$RENEWAL"
  done
  ! grep -q '^archive_dir = /etc/letsencrypt' "$RENEWAL"
  grep -Fxq 'server = https://acme-v02.api.letsencrypt.org/directory' "$RENEWAL"
}

@test "prepare and finalize are byte-for-byte reversible" {
  cp -- "$RENEWAL" "$TEST_ROOT/original"
  map_renewal prepare
  [ "$status" -eq 0 ]
  map_renewal finalize
  [ "$status" -eq 0 ]
  cmp "$TEST_ROOT/original" "$RENEWAL"
  [ "$(stat -c %a "$RENEWAL")" = 600 ]
}

@test "finalize recognizes newly generated runtime renewal references" {
  sed -i "s|/etc/letsencrypt/|$CONFIG/|g" "$RENEWAL"
  map_renewal finalize
  [ "$status" -eq 0 ]
  grep -Fxq 'archive_dir = /etc/letsencrypt/archive/example.com' "$RENEWAL"
  grep -Fxq 'fullchain = /etc/letsencrypt/live/example.com/fullchain.pem' "$RENEWAL"
}

@test "second prepare fails without replacing already mapped file" {
  map_renewal prepare
  [ "$status" -eq 0 ]
  cp "$RENEWAL" "$TEST_ROOT/previous"
  map_renewal prepare
  [ "$status" -eq 65 ]
  cmp "$TEST_ROOT/previous" "$RENEWAL"
}

@test "finalize rejects canonical inputs without any modification" {
  cp "$RENEWAL" "$TEST_ROOT/previous"
  map_renewal finalize
  [ "$status" -eq 65 ]
  cmp "$TEST_ROOT/previous" "$RENEWAL"
}

@test "partial path rewriting cannot leave partial changes" {
  sed -i 's|/etc/letsencrypt/live/example.com/cert.pem|/var/tmp/evil/cert.pem|' "$RENEWAL"
  cp "$RENEWAL" "$TEST_ROOT/previous"
  map_renewal prepare
  [ "$status" -eq 65 ]
  cmp "$TEST_ROOT/previous" "$RENEWAL"
}

@test "foreign selected lineage paths are rejected" {
  sed -i 's|/archive/example.com|/archive/other.example.com|' "$RENEWAL"
  map_renewal prepare
  [ "$status" -eq 65 ]
}

@test "duplicate path-bearing keys fail closed" {
  printf 'cert = /etc/letsencrypt/live/example.com/cert.pem\n' >>"$RENEWAL"
  cp "$RENEWAL" "$TEST_ROOT/previous"
  map_renewal prepare
  [ "$status" -eq 65 ]
  cmp "$TEST_ROOT/previous" "$RENEWAL"
}

@test "missing path-bearing key fails before any rewrite" {
  sed -i '/^chain = /d' "$RENEWAL"
  map_renewal prepare
  [ "$status" -eq 65 ]
}

@test "hidden unknown absolute paths are rejected" {
  printf 'custom_path = /etc/letsencrypt/account-secret\n' >>"$RENEWAL"
  map_renewal prepare
  [ "$status" -eq 65 ]
}

@test "command-bearing renewal hook fields cannot cross boundary" {
  printf 'post_hook = /bin/sh -c evil\n' >>"$RENEWAL"
  map_renewal prepare
  [ "$status" -eq 65 ]
  [[ "$output" != *evil* ]]
}

@test "unsupported renewal sections cannot silently bypass mapping" {
  printf '[[webroot_map]]\nexample.com = /tmp/www\n' >>"$RENEWAL"
  map_renewal prepare
  [ "$status" -eq 65 ]
}

@test "symlinked renewal file is rejected without mutation" {
  mv "$RENEWAL" "$TEST_ROOT/original"
  ln -s "$TEST_ROOT/original" "$RENEWAL"
  map_renewal prepare
  [ "$status" -eq 65 ]
  grep -Fxq 'archive_dir = /etc/letsencrypt/archive/example.com' "$TEST_ROOT/original"
}

@test "symlinked, unsafe or noncanonical config root is rejected" {
  ln -s "$CONFIG" "$TEST_ROOT/alias"
  CONFIG="$TEST_ROOT/alias"
  map_renewal prepare
  [ "$status" -eq 64 ]
  CONFIG="$TEST_ROOT/config"
  chmod 755 "$CONFIG"
  map_renewal prepare
  [ "$status" -eq 64 ]
}

@test "invalid mapping mode and selected name are rejected" {
  map_renewal mysterious
  [ "$status" -eq 64 ]
  NAME='*.example.com'
  map_renewal prepare
  [ "$status" -eq 64 ]
}

@test "missing selected lineage has no implicit preparation" {
  rm "$RENEWAL"
  map_renewal prepare
  [ "$status" -eq 65 ]
  [ ! -e "$RENEWAL" ]
}

@test "missing final newline and embedded binary data are rejected" {
  printf 'not-a-complete-line' >>"$RENEWAL"
  map_renewal prepare
  [ "$status" -eq 65 ]
  sed -i '$d' "$RENEWAL"
  printf '\0' >>"$RENEWAL"
  map_renewal prepare
  [ "$status" -eq 65 ]
}

@test "account key, relative symlinks and certificate bytes remain unchanged" {
  cp "$CONFIG/accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json" "$TEST_ROOT/key"
  cp "$CONFIG/archive/example.com/cert1.pem" "$TEST_ROOT/leaf"
  map_renewal prepare
  [ "$status" -eq 0 ]
  map_renewal finalize
  [ "$status" -eq 0 ]
  cmp "$TEST_ROOT/key" "$CONFIG/accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json"
  cmp "$TEST_ROOT/leaf" "$CONFIG/archive/example.com/cert1.pem"
  [ "$(readlink "$CONFIG/live/example.com/cert.pem")" = '../../archive/example.com/cert1.pem' ]
}

@test "only local file operations occur and public lifecycle remains unavailable" {
  mkdir "$TEST_ROOT/bin"
  local name
  for name in aws certbot; do
    printf '#!/usr/bin/env bash\necho UNEXPECTED_REMOTE_CALL >&2\nexit 99\n' >"$TEST_ROOT/bin/$name"
    chmod 755 "$TEST_ROOT/bin/$name"
  done
  PATH="$TEST_ROOT/bin:$PATH" map_renewal prepare
  [ "$status" -eq 0 ]
  [[ "$output" != *UNEXPECTED_REMOTE_CALL* ]]
  run "$BASH_STARTER_ARTIFACT" --s3-bucket fixture-bucket example.com
  [ "$status" -eq 69 ]
}
