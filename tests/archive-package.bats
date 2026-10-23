#!/usr/bin/env bats

## @file tests/archive-package.bats
## @brief Verifies one locally validated canonical Certbot tar.gz candidate.
## @details
## Uses actual tar and gzip without AWS, Certbot or ACME access. Tests
## candidate refusal, untouched source state and distinct-runner roundtrip.

setup() {
  : "${BASH_STARTER_ARTIFACT:?Built artifact must be selected}"
  ROOT="$(mktemp -d)"
  WORKSPACE="$ROOT/producer"
  CONFIG="$WORKSPACE/config"
  SELECTED=example.com
  CANDIDATE="$WORKSPACE/candidate.tar.gz"
  mkdir -m 700 "$WORKSPACE" "$CONFIG"
  mkdir -p "$CONFIG/accounts/acme-v02.api.letsencrypt.org/directory/account-id"
  mkdir -p "$CONFIG/archive/$SELECTED" "$CONFIG/live/$SELECTED" "$CONFIG/renewal"
  ACCOUNT="$CONFIG/accounts/acme-v02.api.letsencrypt.org/directory/account-id"
  printf '{"fixture":"account-key"}\n' >"$ACCOUNT/private_key.json"
  printf '{"fixture":"registration"}\n' >"$ACCOUNT/regr.json"
  printf '{"fixture":"metadata"}\n' >"$ACCOUNT/meta.json"
  chmod 600 "$ACCOUNT/"*.json
  local part
  for part in cert chain fullchain privkey; do
    printf 'version-one-%s\n' "$part" >"$CONFIG/archive/$SELECTED/${part}1.pem"
    ln -s "../../archive/$SELECTED/${part}1.pem" \
      "$CONFIG/live/$SELECTED/$part.pem"
  done
  chmod 600 "$CONFIG/archive/$SELECTED/privkey1.pem"
  cat >"$CONFIG/renewal/$SELECTED.conf" <<'CONF'
version = 5.8.0
archive_dir = /etc/letsencrypt/archive/example.com
cert = /etc/letsencrypt/live/example.com/cert.pem
privkey = /etc/letsencrypt/live/example.com/privkey.pem
chain = /etc/letsencrypt/live/example.com/chain.pem
fullchain = /etc/letsencrypt/live/example.com/fullchain.pem
[renewalparams]
account = account-id
authenticator = dns-route53
server = https://acme-v02.api.letsencrypt.org/directory
CONF
  chmod 600 "$CONFIG/renewal/$SELECTED.conf"
}

teardown() {
  rm -rf -- "$ROOT"
}

package_candidate() {
  run bash -c '
    source "$1" --help >/dev/null
    certbotbot_archive_package "$2" "$3"
  ' _ "$BASH_STARTER_ARTIFACT" "$WORKSPACE" "$SELECTED"
}

verify_renewal() {
  run bash -c '
    source "$1" --help >/dev/null
    certbotbot_renewal_map "$2" "$3" verify
  ' _ "$BASH_STARTER_ARTIFACT" "$CONFIG" "$SELECTED"
}

@test "selected complete lineage produces one private validated archive" {
  package_candidate
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$CANDIDATE" ]
  [ "$(stat -c %a "$CANDIDATE")" = 600 ]
  run bash -c '
    source "$1" --help >/dev/null
    certbotbot_archive_validate "$2"
  ' _ "$BASH_STARTER_ARTIFACT" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "candidate has relative members without host and staging paths" {
  package_candidate
  [ "$status" -eq 0 ]
  run tar -tzf "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"./accounts/"* ]]
  [[ "$output" == *"./archive/example.com/"* ]]
  [[ "$output" == *"./live/example.com/"* ]]
  [[ "$output" == *"./renewal/example.com.conf"* ]]
  [[ "$output" != *"config/"* ]]
  [[ "$output" != *"$ROOT"* ]]
  [[ "$output" != *"/etc/letsencrypt"* ]]
}

@test "full archive restores selected account and lineage in another workspace" {
  package_candidate
  [ "$status" -eq 0 ]
  local other="$ROOT/second-runner"
  mkdir -m 700 "$other"
  run bash -c '
    source "$1" --help >/dev/null
    certbotbot_archive_restore "$2" "$3" || exit $?
    certbotbot_state_preflight "$3/config" "$4"
  ' _ "$BASH_STARTER_ARTIFACT" "$CANDIDATE" "$other" "$SELECTED"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cmp "$ACCOUNT/private_key.json" \
    "$other/config/accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json"
  cmp "$CONFIG/renewal/$SELECTED.conf" "$other/config/renewal/$SELECTED.conf"
  local part
  for part in cert chain fullchain privkey; do
    cmp "$CONFIG/archive/$SELECTED/${part}1.pem" \
      "$other/config/archive/$SELECTED/${part}1.pem"
    [ "$(readlink "$other/config/live/$SELECTED/$part.pem")" = \
      "../../archive/$SELECTED/${part}1.pem" ]
  done
  [ "$(stat -c %a "$other/config/archive/$SELECTED/privkey1.pem")" = 600 ]
}

@test "reader and publisher format gates share the exact candidate bytes" {
  package_candidate
  [ "$status" -eq 0 ]
  local first="$ROOT/new-runner"
  mkdir -m 700 "$first"
  run bash -c '
    source "$1" --help >/dev/null
    certbotbot_archive_restore "$2" "$3" &&
      certbotbot_archive_package "$3" "$4"
  ' _ "$BASH_STARTER_ARTIFACT" "$CANDIDATE" "$first" "$SELECTED"
  [ "$status" -eq 0 ]
  [ -f "$first/candidate.tar.gz" ]
  run bash -c '
    source "$1" --help >/dev/null
    certbotbot_archive_validate "$2"
  ' _ "$BASH_STARTER_ARTIFACT" "$first/candidate.tar.gz"
  [ "$status" -eq 0 ]
}

@test "read-only canonical renewal verification preserves all source bytes" {
  cp "$CONFIG/renewal/$SELECTED.conf" "$ROOT/renewal-original"
  verify_renewal
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cmp "$ROOT/renewal-original" "$CONFIG/renewal/$SELECTED.conf"
}

@test "private runner paths are refused without modifying renewal metadata" {
  sed -i "s|/etc/letsencrypt/|$CONFIG/|g" "$CONFIG/renewal/$SELECTED.conf"
  cp "$CONFIG/renewal/$SELECTED.conf" "$ROOT/original"
  verify_renewal
  [ "$status" -eq 65 ]
  package_candidate
  [ "$status" -eq 65 ]
  [ ! -e "$CANDIDATE" ]
  cmp "$ROOT/original" "$CONFIG/renewal/$SELECTED.conf"
}

@test "missing or duplicated canonical paths cannot enter published archive" {
  sed -i '/^cert = /d' "$CONFIG/renewal/$SELECTED.conf"
  package_candidate
  [ "$status" -eq 65 ]
  [ ! -e "$CANDIDATE" ]
  printf 'cert = /etc/letsencrypt/live/example.com/cert.pem\n' \
    >>"$CONFIG/renewal/$SELECTED.conf"
  printf 'cert = /etc/letsencrypt/live/example.com/cert.pem\n' \
    >>"$CONFIG/renewal/$SELECTED.conf"
  package_candidate
  [ "$status" -eq 65 ]
  [ ! -e "$CANDIDATE" ]
}

@test "foreign or missing selected lineage and account-only tree fail closed" {
  SELECTED=other.example.com
  package_candidate
  [ "$status" -eq 65 ]
  SELECTED=example.com
  rm -rf -- "$CONFIG/archive/$SELECTED" \
    "$CONFIG/live/$SELECTED" "$CONFIG/renewal/$SELECTED.conf"
  package_candidate
  [ "$status" -eq 65 ]
  [ ! -e "$CANDIDATE" ]
}

@test "missing existing account cannot yield a candidate" {
  rm -rf "$CONFIG/accounts"
  package_candidate
  [ "$status" -eq 65 ]
  [ ! -e "$CANDIDATE" ]
}

@test "existing candidate is never overwritten" {
  printf 'preserve-me\n' >"$CANDIDATE"
  package_candidate
  [ "$status" -eq 64 ]
  [ "$(cat "$CANDIDATE")" = preserve-me ]
}

@test "dangling destination symlink cannot redirect local publication" {
  ln -s "$ROOT/target" "$CANDIDATE"
  package_candidate
  [ "$status" -eq 64 ]
  [ ! -e "$ROOT/target" ]
}

@test "unsafe or symlinked workspace stops before staging" {
  chmod 755 "$WORKSPACE"
  package_candidate
  [ "$status" -eq 64 ]
  chmod 700 "$WORKSPACE"
  ln -s "$WORKSPACE" "$ROOT/alias"
  WORKSPACE="$ROOT/alias"
  CANDIDATE="$WORKSPACE/candidate.tar.gz"
  package_candidate
  [ "$status" -eq 64 ]
  [ ! -e "$CANDIDATE" ]
}

@test "world-readable certificate private key is rejected" {
  chmod 644 "$CONFIG/archive/$SELECTED/privkey1.pem"
  package_candidate
  [ "$status" -eq 65 ]
  [ ! -e "$CANDIDATE" ]
}

@test "unexpected source members cannot be silently dropped" {
  printf 'unauthorized\n' >"$CONFIG/unauthorized"
  package_candidate
  [ "$status" -eq 65 ]
  [ ! -e "$CANDIDATE" ]
}

@test "executable archived renewal hooks cannot reach candidate archive" {
  printf 'post_hook = /bin/echo forbidden\n' >>"$CONFIG/renewal/$SELECTED.conf"
  package_candidate
  [ "$status" -eq 65 ]
  [ ! -e "$CANDIDATE" ]
}

@test "tar command failure cleans only staged file and preserves source" {
  mkdir "$ROOT/bin"
  printf '#!/usr/bin/env bash\nexit 25\n' >"$ROOT/bin/tar"
  chmod 755 "$ROOT/bin/tar"
  run bash -c '
    PATH="$1:$PATH"
    source "$2" --help >/dev/null
    certbotbot_archive_package "$3" "$4"
  ' _ "$ROOT/bin" "$BASH_STARTER_ARTIFACT" "$WORKSPACE" "$SELECTED"
  [ "$status" -eq 74 ]
  [ ! -e "$CANDIDATE" ]
  [ -f "$ACCOUNT/private_key.json" ]
  [ -z "$(find "$WORKSPACE" -maxdepth 1 -name '.candidate.*' -print)" ]
}

@test "publisher never executes AWS, Certbot or host hooks" {
  mkdir "$ROOT/bin"
  local program
  for program in aws certbot; do
    printf '#!/usr/bin/env bash\nprintf "REMOTE TOOL CALLED" >&2\nexit 99\n' \
      >"$ROOT/bin/$program"
    chmod 755 "$ROOT/bin/$program"
  done
  run bash -c '
    PATH="$1:$PATH"
    source "$2" --help >/dev/null
    certbotbot_archive_package "$3" "$4"
  ' _ "$ROOT/bin" "$BASH_STARTER_ARTIFACT" "$WORKSPACE" "$SELECTED"
  [ "$status" -eq 0 ]
  [[ "$output" != *'REMOTE TOOL CALLED'* ]]
}

@test "public CLI remains unimplemented until validated S3 publication" {
  package_candidate
  [ "$status" -eq 0 ]
  run "$BASH_STARTER_ARTIFACT" --s3-bucket seeded-bucket example.com
  [ "$status" -eq 69 ]
}
