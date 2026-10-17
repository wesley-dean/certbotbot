#!/usr/bin/env bats

## @file tests/import-candidate.bats
## @brief Verifies complete inactive two-lineage assembly and fail-closed cleanup.
## @details
## The account JSON and PEMs are synthetic. The tested candidate must never
## be installed to the recorded active Certbot config or passed to Certbot.

setup() {
  : "${CERTBOTBOT_ARTIFACT:?Standalone artifact required}"
  export CERTBOTBOT_TMPDIR="$BATS_TEST_TMPDIR"
  export ASSEMBLY_SOURCE="$BATS_TEST_TMPDIR/source"
  export ASSEMBLY_COMMON="$BATS_TEST_TMPDIR/common.tar.gz"
  export ASSEMBLY_ACCOUNT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export ASSEMBLY_EXTERNAL_CALLS="$BATS_TEST_TMPDIR/external-calls"
  export ASSEMBLY_BIN="$BATS_TEST_TMPDIR/bin"
  umask 077
  mkdir -m 0700 "$ASSEMBLY_SOURCE" "$ASSEMBLY_BIN"
  cat >"$ASSEMBLY_BIN/aws" <<'AWS'
#!/usr/bin/env bash
printf 'forbidden aws\n' >>"$ASSEMBLY_EXTERNAL_CALLS"
exit 99
AWS
  cat >"$ASSEMBLY_BIN/certbot" <<'CERTBOT'
#!/usr/bin/env bash
printf 'forbidden certbot\n' >>"$ASSEMBLY_EXTERNAL_CALLS"
exit 99
CERTBOT
  chmod 0700 "$ASSEMBLY_BIN/aws" "$ASSEMBLY_BIN/certbot"
}

common_archive() {
  local host=acme-v02.api.letsencrypt.org
  local account="$ASSEMBLY_SOURCE/accounts/$host/directory/$ASSEMBLY_ACCOUNT"
  local kind=''
  mkdir -p "$account"
  chmod 0700 "$ASSEMBLY_SOURCE/accounts" \
    "$ASSEMBLY_SOURCE/accounts/$host" \
    "$ASSEMBLY_SOURCE/accounts/$host/directory" "$account"
  for kind in meta regr private_key; do
    printf '{"fixture":"%s"}\n' "$kind" >"$account/$kind.json"
    chmod 0600 "$account/$kind.json"
  done
  tar -czf "$ASSEMBLY_COMMON" -C "$ASSEMBLY_SOURCE" accounts
}

lineage_archive() {
  local name=$1 root="$ASSEMBLY_SOURCE/$1" kind=''
  mkdir -p "$root/archive/$name" "$root/live/$name" \
    "$root/combined" "$root/renewal"
  chmod 0700 "$root" "$root/archive" "$root/archive/$name" \
    "$root/live" "$root/live/$name" "$root/renewal" "$root/combined"
  for kind in cert chain fullchain privkey; do
    printf '%s synthetic fixture\n' "$kind" \
      >"$root/archive/$name/${kind}1.pem"
    ln -s "../../archive/$name/${kind}1.pem" \
      "$root/live/$name/$kind.pem"
  done
  printf 'combined synthetic fixture\n' >"$root/combined/$name.pem"
  cp -- "$root/combined/$name.pem" "$root/live/$name/combined.pem"
  chmod 0600 "$root/archive/$name/privkey1.pem" \
    "$root/combined/$name.pem" "$root/live/$name/combined.pem"
  cat >"$root/renewal/$name.conf" <<RENEWAL
version = 5.8.0
archive_dir = /previous-runner/config/archive/$name
cert = /previous-runner/config/live/$name/cert.pem
privkey = /previous-runner/config/live/$name/privkey.pem
chain = /previous-runner/config/live/$name/chain.pem
fullchain = /previous-runner/config/live/$name/fullchain.pem

[renewalparams]
account = $ASSEMBLY_ACCOUNT
server = https://acme-v02.api.letsencrypt.org/directory
authenticator = dns-route53
key_type = ecdsa
RENEWAL
  pack_lineage "$name"
}

pack_lineage() {
  local name=$1
  tar -czf "$BATS_TEST_TMPDIR/$name.tar.gz" \
    -C "$ASSEMBLY_SOURCE/$name" archive live renewal combined
}

run_prepare() {
  run env PATH="$ASSEMBLY_BIN:$PATH" bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit 80
    shift
    certbotbot_import_candidate_prepare "$@"
    status=$?
    printf "result=%s\n" "$status"
    if (( status == 0 )); then
      target=$CERTBOTBOT_IMPORT_CANDIDATE_CONFIG
      root=$CERTBOTBOT_IMPORT_CANDIDATE_ROOT
      [[ -d $root && -d $target &&
        "$(stat -c "%a" "$root")" == 700 &&
        "$(stat -c "%a" "$target")" == 700 ]] || exit 81
      [[ -d $target/accounts && ! -e $root/snapshots ]] || exit 82
      [[ "$CERTBOTBOT_WORKSPACE_CONFIG" != "$target" ]] || exit 83
      for (( i=0; i<($#-2); i+=2 )); do
        name=${@:i+3:1}
        [[ -f $target/renewal/$name.conf &&
          -f $target/combined/$name.pem &&
          -L $target/live/$name/cert.pem ]] || exit 84
        grep -Fxq "archive_dir = $target/archive/$name" \
          "$target/renewal/$name.conf" || exit 85
        grep -Fxq "cert = $target/live/$name/cert.pem" \
          "$target/renewal/$name.conf" || exit 86
        certbotbot_pem_check_link "$target" "$name" cert || exit 87
        certbotbot_pem_check_link "$target" "$name" privkey || exit 88
        printf "lineage=%s\n" "$name"
      done
      certbotbot_import_candidate_discard || exit 89
    else
      [[ -z $CERTBOTBOT_IMPORT_CANDIDATE_ROOT &&
        -z $CERTBOTBOT_IMPORT_CANDIDATE_CONFIG ]] || exit 90
    fi
    [[ -z $CERTBOTBOT_COMMON_STAGE &&
      -z $CERTBOTBOT_RESTORE_ROOT &&
      -z $CERTBOTBOT_RENEWAL_PREVIEW ]] || exit 91
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_CONFIG" \
      -mindepth 1 -print -quit)" ]] || exit 92
    [[ -z "$(find "$CERTBOTBOT_WORKSPACE_ROOT" \
      -mindepth 1 -maxdepth 1 ! -name config ! -name work \
      ! -name logs -print -quit)" ]] || exit 93
    certbotbot_workspace_destroy || exit 94
  ' _ "$CERTBOTBOT_ARTIFACT" "$@"
}

@test "one lineage assembles privately with rebased renewal and explicit disposal" {
  common_archive
  lineage_archive example.com
  run_prepare "$ASSEMBLY_COMMON" production \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz"
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=0'* && "$output" == *'lineage=example.com'* ]]
  [ ! -e "$ASSEMBLY_EXTERNAL_CALLS" ]
}

@test "two independent lineages coexist without shared-state overwrite" {
  common_archive
  lineage_archive example.com
  lineage_archive example.net
  run_prepare "$ASSEMBLY_COMMON" production \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    example.net "$BATS_TEST_TMPDIR/example.net.tar.gz"
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=0'* &&
    "$output" == *'lineage=example.com'* &&
    "$output" == *'lineage=example.net'* ]]
  [ ! -e "$ASSEMBLY_EXTERNAL_CALLS" ]
}

@test "invalid second lineage rejects whole candidate and preserves empty active state" {
  common_archive
  lineage_archive example.com
  lineage_archive example.net
  printf 'post_hook = /bin/sh\n' \
    >>"$ASSEMBLY_SOURCE/example.net/renewal/example.net.conf"
  pack_lineage example.net
  run_prepare "$ASSEMBLY_COMMON" production \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    example.net "$BATS_TEST_TMPDIR/example.net.tar.gz"
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=64'* && "$output" != *'lineage='* ]]
  [ ! -e "$ASSEMBLY_EXTERNAL_CALLS" ]
}

@test "account mismatch in second lineage rejects complete batch" {
  common_archive
  lineage_archive example.com
  lineage_archive example.net
  sed -i 's/account = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/account = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/' \
    "$ASSEMBLY_SOURCE/example.net/renewal/example.net.conf"
  pack_lineage example.net
  run_prepare "$ASSEMBLY_COMMON" production \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    example.net "$BATS_TEST_TMPDIR/example.net.tar.gz"
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=65'* && "$output" != *'lineage='* ]]
}

@test "duplicate identity is rejected before any staging or external action" {
  common_archive
  lineage_archive example.com
  run_prepare "$ASSEMBLY_COMMON" production \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz" \
    example.com "$BATS_TEST_TMPDIR/example.com.tar.gz"
  [ "$status" -eq 0 ]
  [[ "$output" == *'result=64'* ]]
  [ ! -e "$ASSEMBLY_EXTERNAL_CALLS" ]
}

@test "a populated active config is never replaced, cleaned, or merged" {
  common_archive
  lineage_archive example.com
  run env PATH="$ASSEMBLY_BIN:$PATH" bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    printf "preserve\n" >"$CERTBOTBOT_WORKSPACE_CONFIG/.marker"
    certbotbot_import_candidate_prepare "$2" production example.com "$3"
    result=$?
    [[ $result == 64 &&
      "$(cat "$CERTBOTBOT_WORKSPACE_CONFIG/.marker")" == preserve &&
      -z $CERTBOTBOT_IMPORT_CANDIDATE_ROOT ]] || exit 1
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ASSEMBLY_COMMON" \
    "$BATS_TEST_TMPDIR/example.com.tar.gz"
  [ "$status" -eq 0 ]
  [ ! -e "$ASSEMBLY_EXTERNAL_CALLS" ]
}

@test "a second prepare never replaces an owned successful candidate" {
  common_archive
  lineage_archive example.com
  run env PATH="$ASSEMBLY_BIN:$PATH" bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit 1
    certbotbot_import_candidate_prepare "$2" production example.com "$3" ||
      exit 2
    previous=$CERTBOTBOT_IMPORT_CANDIDATE_ROOT
    certbotbot_import_candidate_prepare "$2" production example.com "$3"
    result=$?
    [[ $result == 64 &&
      $previous == "$CERTBOTBOT_IMPORT_CANDIDATE_ROOT" &&
      -d $previous ]] || exit 3
    certbotbot_import_candidate_discard || exit 4
    certbotbot_workspace_destroy
  ' _ "$CERTBOTBOT_ARTIFACT" "$ASSEMBLY_COMMON" \
    "$BATS_TEST_TMPDIR/example.com.tar.gz"
  [ "$status" -eq 0 ]
}

@test "public certificate issuance remains disabled" {
  run "$CERTBOTBOT_ARTIFACT" example.com
  [ "$status" -eq 69 ]
  [ ! -e "$ASSEMBLY_EXTERNAL_CALLS" ]
}
