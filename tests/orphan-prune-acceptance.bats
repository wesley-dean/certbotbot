#!/usr/bin/env bats

# Task #97: independent public-executable acceptance of ADR-059.
# The existing CI matrix runs this file against development, ordinary, and
# minified artifacts after checksum/provenance verification. All cloud, DNS
# and ACME requests in this suite are handled by isolated synthetic doubles.

setup() {
  source "$BATS_TEST_DIRNAME/helpers/lifecycle-fixture.bash"
  lifecycle_fixture_setup
  unset RENEW_ALL REMOVE_ORPHANS DESIRED_CERT_NAMES
}

teardown() {
  rm -rf -- "$ROOT"
}

accept_run() {
  local runner="${LIFECYCLE_RUNNER_TMPDIR:-$ROOT/runner-temp}"
  run env TMPDIR="$runner" "$BASH_STARTER_ARTIFACT" \
    --s3-bucket fixture-bucket "$@"
}

accept_seed_two() {
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
  accept_run example.com
  [ "$status" -eq 0 ] || return 1
  export LIFECYCLE_EXPECTED_CERT_NAME=other.org
  accept_run --cert-name other.org other.org
  [ "$status" -eq 0 ] || return 1
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
}

accept_seed_three() {
  accept_seed_two || return 1
  # Independent identity with overlapping SANs, not an alias for the
  # selected certificate's storage membership.
  export LIFECYCLE_EXPECTED_CERT_NAME=alias.net
  accept_run --cert-name alias.net example.com
  [ "$status" -eq 0 ] || return 1
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
}

accept_extract() {
  local directory="$1"
  mkdir -m 700 "$directory" || return 1
  tar -xzf "$LIFECYCLE_REMOTE" -C "$directory"
}

accept_no_publish() {
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS" &&
    [[ "$output" != *'published=true'* ]] &&
    [[ "$output" != *'orphan desired='* ]]
}

accept_no_provider_or_publish() {
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS" &&
    accept_no_publish
}

accept_account_same() {
  diff -qr "$1/accounts" "$2/accounts" >/dev/null
}

accept_member_absent() {
  local name="$1" directory="$2"
  [ ! -e "$directory/renewal/$name.conf" ] &&
    [ ! -e "$directory/live/$name" ] &&
    [ ! -e "$directory/archive/$name" ]
}

accept_member_same() {
  local before="$1" after="$2" name="$3" part
  cmp -s "$before/renewal/$name.conf" "$after/renewal/$name.conf" &&
    diff -qr "$before/archive/$name" "$after/archive/$name" >/dev/null ||
    return 1
  for part in cert chain fullchain privkey; do
    [[ "$(readlink -- "$before/live/$name/$part.pem")" ==
      "$(readlink -- "$after/live/$name/$part.pem")" ]] || return 1
  done
  [ "$(stat -c '%a' "$before/archive/$name/privkey1.pem")" -eq 600 ]
  [ "$(stat -c '%a' "$after/archive/$name/privkey1.pem")" -eq 600 ]
}

accept_required_gpg() {
  local version major minor patch
  command -v gpg >/dev/null 2>&1 || skip 'GnuPG unavailable'
  version="$(gpg --version 2>/dev/null)"
  [[ "$version" =~ gpg\ \(GnuPG\)\ ([0-9]+)\.([0-9]+)\.([0-9]+) ]] ||
    skip 'GnuPG version unavailable'
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"
  if (( major < 2 || (major == 2 &&
    (minor < 4 || (minor == 4 && patch < 7))) )); then
    skip 'GnuPG 2.4.7+ required by ADR-031'
  fi
}

@test "default-false selected pass retains all three archived identities and bytes" {
  accept_seed_three
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
  accept_run example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=false'* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  ! grep -q '^certbot-context:renew:.*:alias.net:account-id$' \
    "$LIFECYCLE_CONTEXTS"
}

@test "pruning three overlapping-SAN lineages retains exactly requested two" {
  accept_seed_three
  accept_extract "$ROOT/before"
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
  # The CLI order differs from the archive member order; identity, not
  # SAN overlap or input order, determines which member is removed.
  accept_run --remove-orphans true --desired-cert-name alias.net \
    --desired-cert-name example.com example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'orphan desired=2; removed=1; published=true'* ]]
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot-context:renew:.*:alias.net:account-id$' \
    "$LIFECYCLE_CONTEXTS"
  accept_extract "$ROOT/after"
  accept_member_absent other.org "$ROOT/after"
  accept_member_same "$ROOT/before" "$ROOT/after" alias.net
  accept_member_same "$ROOT/before" "$ROOT/after" example.com
  accept_account_same "$ROOT/before" "$ROOT/after"
  [ -z "$(find "$ROOT/runner-temp" -mindepth 1 -print -quit)" ]
}

@test "fresh runner restores retained lineages and cannot recover pruned member" {
  local runner
  for runner in one two three four; do
    mkdir -m 700 "$ROOT/fresh-$runner"
  done
  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/fresh-one"
  accept_seed_two
  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/fresh-two"
  export LIFECYCLE_EXPECTED_CERT_NAME=alias.net
  accept_run --cert-name alias.net example.com
  [ "$status" -eq 0 ]
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/fresh-three"
  accept_run --remove-orphans true --desired-cert-name example.com \
    --desired-cert-name alias.net example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'removed=1; published=true'* ]]
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/post-prune.tar.gz"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/fresh-four"
  accept_run example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=false'* ]]
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/post-prune.tar.gz"
  accept_extract "$ROOT/restored"
  [ -f "$ROOT/restored/renewal/example.com.conf" ]
  [ -f "$ROOT/restored/renewal/alias.net.conf" ]
  accept_member_absent other.org "$ROOT/restored"
  for runner in one two three four; do
    [ -z "$(find "$ROOT/fresh-$runner" -mindepth 1 -print -quit)" ]
  done
}

@test "selected renewal and pruning are one complete durable publication" {
  accept_seed_three
  accept_extract "$ROOT/before"
  export LIFECYCLE_RENEW_CHANGED_NAME=example.com
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
  accept_run --remove-orphans true --desired-cert-name example.com \
    --desired-cert-name alias.net example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'removed=1; published=true'* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
  accept_extract "$ROOT/after"
  ! cmp -s "$ROOT/before/archive/example.com/cert1.pem" \
    "$ROOT/after/archive/example.com/cert1.pem"
  cmp -s "$ROOT/before/archive/example.com/privkey1.pem" \
    "$ROOT/after/archive/example.com/privkey1.pem"
  accept_member_same "$ROOT/before" "$ROOT/after" alias.net
  accept_member_absent other.org "$ROOT/after"
  accept_account_same "$ROOT/before" "$ROOT/after"
}

@test "new explicitly selected issuance may replace the original excluded member" {
  accept_seed_two
  accept_extract "$ROOT/before"
  export LIFECYCLE_EXPECTED_CERT_NAME=new.org
  : >"$LIFECYCLE_CALLS"
  accept_run --remove-orphans true --desired-cert-name example.com \
    --desired-cert-name new.org --cert-name new.org new.org
  [ "$status" -eq 0 ]
  [[ "$output" == *'desired=2; removed=1; published=true'* ]]
  [ "$(grep -c '^certbot:certonly$' "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot:renew$' "$LIFECYCLE_CALLS"
  accept_extract "$ROOT/after"
  accept_member_same "$ROOT/before" "$ROOT/after" example.com
  [ -f "$ROOT/after/renewal/new.org.conf" ]
  accept_member_absent other.org "$ROOT/after"
  accept_account_same "$ROOT/before" "$ROOT/after"
}

@test "invalid and absent desired collection never acquires S3 or Certbot authority" {
  accept_run --remove-orphans true example.com
  [ "$status" -eq 64 ]
  accept_run --remove-orphans true --desired-cert-name example.com
  [ "$status" -eq 64 ]
  accept_run --remove-orphans true --desired-cert-name other.org example.com
  [ "$status" -eq 64 ]
  export DESIRED_CERT_NAMES=',example.com'
  accept_run --remove-orphans true example.com
  [ "$status" -eq 64 ]
  export DESIRED_CERT_NAMES='example.com,,alias.net'
  accept_run --remove-orphans true example.com
  [ "$status" -eq 64 ]
  unset DESIRED_CERT_NAMES
  accept_run --remove-orphans true --desired-cert-name Example.com example.com
  [ "$status" -eq 64 ]
  accept_run --remove-orphans true --desired-cert-name '*.example.com' \
    example.com
  [ "$status" -eq 64 ]
  accept_run --remove-orphans true --desired-cert-name example.com \
    --desired-cert-name example.com example.com
  [ "$status" -eq 64 ]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
  accept_no_provider_or_publish
}

@test "unknown retained identity fails before selected issuance or renewal" {
  accept_seed_two
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  : >"$LIFECYCLE_CALLS"
  accept_run --remove-orphans true --desired-cert-name example.com \
    --desired-cert-name missing.net example.com
  [ "$status" -ne 0 ]
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
  accept_no_publish
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
}

@test "two destructive modes together refuse work before any remote read" {
  accept_run --remove-orphans true --desired-cert-name example.com \
    --renew-all true example.com
  [ "$status" -eq 64 ]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
  accept_no_provider_or_publish
}

@test "selected provider failure after restored preflight never deletes or publishes" {
  accept_seed_two
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_MODE=renew-partial-failure
  accept_run --remove-orphans true --desired-cert-name example.com example.com
  [ "$status" -ne 0 ]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  accept_no_publish
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
}

@test "non-target provider mutation is detected without any orphan deletion" {
  accept_seed_two
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_RENEW_NON_TARGET_MUTATION_NAME=example.com
  accept_run --remove-orphans true --desired-cert-name example.com example.com
  [ "$status" -ne 0 ]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  accept_no_publish
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
}

@test "unsafe cross-lineage symlink is not a deletable orphan" {
  accept_seed_two
  accept_extract "$ROOT/unsafe"
  rm -- "$ROOT/unsafe/live/other.org/cert.pem"
  ln -s ../../archive/example.com/cert1.pem \
    "$ROOT/unsafe/live/other.org/cert.pem"
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/unsafe" .
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/unsafe.tar.gz"
  : >"$LIFECYCLE_CALLS"
  accept_run --remove-orphans true --desired-cert-name example.com example.com
  [ "$status" -ne 0 ]
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
  accept_no_publish
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/unsafe.tar.gz"
}

@test "invalid unrelated archived leaf fails before selected work or pruning" {
  accept_seed_two
  accept_extract "$ROOT/bad"
  printf 'not an X509 certificate\n' >"$ROOT/bad/archive/other.org/cert1.pem"
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/bad" .
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/bad.tar.gz"
  : >"$LIFECYCLE_CALLS"
  accept_run --remove-orphans true --desired-cert-name example.com example.com
  [ "$status" -ne 0 ]
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
  accept_no_publish
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/bad.tar.gz"
}

@test "failed post-prune archive packaging retains original authoritative object" {
  accept_seed_two
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  cat >"$ROOT/bin/tar" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == --format=ustar ]]; then exit 27; fi
exec /usr/bin/tar "$@"
MOCK
  chmod 755 "$ROOT/bin/tar"
  : >"$LIFECYCLE_CALLS"
  accept_run --remove-orphans true --desired-cert-name example.com example.com
  [ "$status" -ne 0 ]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 1 ]
  accept_no_publish
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
}

@test "failed or lost current S3 PutObject reports uncertain remote result" {
  accept_seed_two
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_PUT_MODE=put-failure
  accept_run --remove-orphans true --desired-cert-name example.com example.com
  [ "$status" -ne 0 ]
  [[ "$output" == *'remote state is uncertain'* ]]
  [[ "$output" != *'orphan desired='* ]]
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  export LIFECYCLE_PUT_MODE=put-after-write-failure
  : >"$LIFECYCLE_CALLS"
  accept_run --remove-orphans true --desired-cert-name example.com example.com
  [ "$status" -ne 0 ]
  [[ "$output" == *'remote state is uncertain'* ]]
  [[ "$output" != *'orphan desired='* ]]
  # The simulated remote write DID succeed before response loss.
  ! cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
}

@test "CLI desired whole-collection wins despite stale environment and literal file" {
  accept_seed_three
  printf 'REMOVE_ORPHANS=true\nDESIRED_CERT_NAMES=example.com\n' \
    >"$ROOT/desired.env"
  export DESIRED_CERT_NAMES=example.com
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  : >"$LIFECYCLE_CALLS"
  accept_run --config "$ROOT/desired.env" \
    --desired-cert-name alias.net --desired-cert-name example.com \
    example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'desired=2; removed=1; published=true'* ]]
  accept_extract "$ROOT/after"
  [ -f "$ROOT/after/renewal/alias.net.conf" ]
  [ -f "$ROOT/after/renewal/example.com.conf" ]
  accept_member_absent other.org "$ROOT/after"
}

@test "no-env makes exported REMOVE_ORPHANS inert until CLI opts in" {
  accept_seed_two
  export REMOVE_ORPHANS=true DESIRED_CERT_NAMES=example.com
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  : >"$LIFECYCLE_CALLS"
  accept_run --no-env example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=false'* ]]
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/before.tar.gz"
  accept_run --no-env --remove-orphans true \
    --desired-cert-name example.com example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'removed=1; published=true'* ]]
}

@test "authenticated encrypted archive preserves verified selected state after pruning" {
  accept_required_gpg
  accept_seed_two
  export GPG_SYMMETRIC_KEY=orphan-acceptance-local-key-not-secret-76ca
  accept_run --archive-migration plaintext-to-gpg-ocb \
    --archive-migration-backup-confirmed true example.com
  [ "$status" -eq 0 ]
  : >"$LIFECYCLE_CALLS"
  accept_run --remove-orphans true --desired-cert-name example.com example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'removed=1; published=true'* ]]
  head -c 22 "$LIFECYCLE_REMOTE" |
    cmp -s - <(printf 'CERTBOTBOT-GPG-OCB-V1\n')
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/encrypted-after"
  : >"$LIFECYCLE_CALLS"
  accept_run example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *'published=false'* ]]
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/encrypted-after"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  ! grep -q 'secret-inherited' "$LIFECYCLE_CALLS"
  [[ "$output" != *orphan-acceptance-local-key-not-secret-76ca* ]]
}
