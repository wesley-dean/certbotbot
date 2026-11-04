#!/usr/bin/env bats

# Task #100: public executable acceptance using actual verified artifacts.
# This suite uses only synthetic local AWS/Certbot doubles and real GNU
# tar/gzip/OpenSSL. The CI matrix independently runs all three producer flavors.

setup() {
  source "$BATS_TEST_DIRNAME/helpers/lifecycle-fixture.bash"
  lifecycle_fixture_setup
  unset RENEW_ALL REMOVE_ORPHANS
}

teardown() {
  rm -rf -- "$ROOT"
}

bulk_run() {
  local runner="${LIFECYCLE_RUNNER_TMPDIR:-$ROOT/runner-temp}"
  run env TMPDIR="$runner" "$BASH_STARTER_ARTIFACT" \
    --s3-bucket fixture-bucket "$@"
}

bulk_seed_two() {
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
  bulk_run example.com
  [ "$status" -eq 0 ] || return 1
  export LIFECYCLE_EXPECTED_CERT_NAME=other.org
  bulk_run --cert-name other.org other.org
  [ "$status" -eq 0 ] || return 1
  tar -tzf "$LIFECYCLE_REMOTE" | grep -Fxq './renewal/example.com.conf' ||
    return 1
  tar -tzf "$LIFECYCLE_REMOTE" | grep -Fxq './renewal/other.org.conf'
}

bulk_no_write() {
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS" &&
    ! grep -q '^certbot:register$' "$LIFECYCLE_CALLS" &&
    [[ "$output" != *published=true* ]]
}

bulk_named_once() {
  [ "$(grep -c "^certbot-context:renew:.*:$1:account-id$" \
    "$LIFECYCLE_CONTEXTS")" -eq 1 ]
}

bulk_extract_state() {
  local dest="$1"
  mkdir -m 700 "$dest" || return 1
  tar -xzf "$LIFECYCLE_REMOTE" -C "$dest"
}

bulk_gpg_available() {
  local version major minor patch
  command -v gpg >/dev/null 2>&1 || skip 'GnuPG not installed'
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

@test "mixed changed and unchanged archived lineages publish a complete single object" {
  bulk_seed_two
  bulk_extract_state "$ROOT/before"
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
  export LIFECYCLE_RENEW_CHANGED_NAME=example.com
  bulk_run --renew-all true
  [ "$status" -eq 0 ]
  [[ "$output" == *'checked=2; renewed=1; metadata-only=0; unchanged=1; issued=0; published=true'* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 2 ]
  bulk_named_once example.com
  bulk_named_once other.org
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
  bulk_extract_state "$ROOT/after"
  ! cmp -s "$ROOT/before/archive/example.com/cert1.pem" \
    "$ROOT/after/archive/example.com/cert1.pem"
  cmp -s "$ROOT/before/archive/other.org/cert1.pem" \
    "$ROOT/after/archive/other.org/cert1.pem"
  cmp -s "$ROOT/before/renewal/other.org.conf" \
    "$ROOT/after/renewal/other.org.conf"
  cmp -s "$ROOT/before/accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json" \
    "$ROOT/after/accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json"
}

@test "fresh third runner verifies both stored lineages and makes no unnecessary PUT" {
  local runner
  for runner in first second third; do
    mkdir -m 700 "$ROOT/runner-$runner"
  done
  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/runner-first"
  bulk_seed_two
  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/runner-second"
  export LIFECYCLE_RENEW_CHANGED_NAME=other.org
  bulk_run --renew-all true
  [ "$status" -eq 0 ]
  [[ "$output" == *'renewed=1'* && "$output" == *'published=true'* ]]
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/stable.tar.gz"
  unset LIFECYCLE_RENEW_CHANGED_NAME
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
  export LIFECYCLE_RUNNER_TMPDIR="$ROOT/runner-third"
  bulk_run --renew-all true
  [ "$status" -eq 0 ]
  [[ "$output" == *'checked=2; renewed=0; metadata-only=0; unchanged=2; issued=0; published=false'* ]]
  bulk_named_once example.com
  bulk_named_once other.org
  bulk_no_write
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/stable.tar.gz"
  for runner in first second third; do
    [ -z "$(find "$ROOT/runner-$runner" -mindepth 1 -print -quit)" ]
  done
}

@test "second lineage failure after first renewal leaves authoritative archive intact" {
  bulk_seed_two
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/stable.tar.gz"
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
  export LIFECYCLE_RENEW_CHANGED_NAME=example.com
  export LIFECYCLE_RENEW_FAIL_NAME=other.org
  bulk_run --renew-all true
  [ "$status" -ne 0 ]
  bulk_named_once example.com
  bulk_named_once other.org
  bulk_no_write
  [[ "$output" != *'bulk checked='* ]]
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/stable.tar.gz"
}

@test "provider changing a different lineage is rejected before S3 publication" {
  bulk_seed_two
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/stable.tar.gz"
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_RENEW_NON_TARGET_MUTATION_NAME=example.com
  bulk_run --renew-all true
  [ "$status" -ne 0 ]
  bulk_no_write
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/stable.tar.gz"
}

@test "metadata-only account renewal is distinguished from certificate replacement" {
  bulk_seed_two
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_MODE=metadata-changed
  bulk_run --renew-all true
  [ "$status" -eq 0 ]
  [[ "$output" == *'checked=2; renewed=0; metadata-only=1; unchanged=1; issued=0; published=true'* ]]
  [ "$(grep -c '^certbot:renew$' "$LIFECYCLE_CALLS")" -eq 2 ]
  [ "$(grep -c '^aws:put-object:' "$LIFECYCLE_CALLS")" -eq 1 ]
}

@test "lineages sharing a SAN are still two independent exact-name operations" {
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
  bulk_run example.com
  [ "$status" -eq 0 ]
  export LIFECYCLE_EXPECTED_CERT_NAME=second.example.net
  bulk_run --cert-name second.example.net example.com
  [ "$status" -eq 0 ]
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
  bulk_run --renew-all true
  [ "$status" -eq 0 ]
  [[ "$output" == *'checked=2; renewed=0; metadata-only=0; unchanged=2; issued=0; published=false'* ]]
  bulk_named_once example.com
  bulk_named_once second.example.net
  ! grep -q '^certbot:certonly$' "$LIFECYCLE_CALLS"
  bulk_no_write
}

@test "default selected-only mode does not touch unrelated complete lineage" {
  bulk_seed_two
  bulk_extract_state "$ROOT/before"
  : >"$LIFECYCLE_CALLS"
  : >"$LIFECYCLE_CONTEXTS"
  export LIFECYCLE_RENEW_CHANGED_NAME=example.com
  bulk_run --renew-all false example.com
  [ "$status" -eq 0 ]
  bulk_named_once example.com
  ! grep -q '^certbot-context:renew:.*:other.org:account-id$' \
    "$LIFECYCLE_CONTEXTS"
  bulk_extract_state "$ROOT/after"
  cmp -s "$ROOT/before/renewal/other.org.conf" \
    "$ROOT/after/renewal/other.org.conf"
  diff -qr "$ROOT/before/archive/other.org" \
    "$ROOT/after/archive/other.org" >/dev/null
  for part in cert chain fullchain privkey; do
    [[ "$(readlink -- "$ROOT/before/live/other.org/$part.pem")" == \
      "$(readlink -- "$ROOT/after/live/other.org/$part.pem")" ]]
  done
}

@test "incomplete archived triplet aborts before invoking Certbot" {
  bulk_seed_two
  bulk_extract_state "$ROOT/bad"
  rm -- "$ROOT/bad/live/other.org/privkey.pem"
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/bad" .
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/stable.tar.gz"
  : >"$LIFECYCLE_CALLS"
  bulk_run --renew-all true
  [ "$status" -ne 0 ]
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
  bulk_no_write
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/stable.tar.gz"
}

@test "invalid unselected X509 leaf rejects bulk before provider work" {
  bulk_seed_two
  bulk_extract_state "$ROOT/bad"
  printf 'not a certificate\n' >"$ROOT/bad/archive/other.org/cert1.pem"
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/bad" .
  : >"$LIFECYCLE_CALLS"
  bulk_run --renew-all true
  [ "$status" -ne 0 ]
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
  bulk_no_write
}

@test "duplicate archived tar member cannot cause repeated renewal" {
  bulk_seed_two
  bulk_extract_state "$ROOT/bad"
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/bad" . ./renewal/other.org.conf
  : >"$LIFECYCLE_CALLS"
  bulk_run --renew-all true
  [ "$status" -ne 0 ]
  ! grep -q '^certbot:renew$' "$LIFECYCLE_CALLS"
  bulk_no_write
}

@test "missing account key is rejected without implicit registration" {
  bulk_seed_two
  bulk_extract_state "$ROOT/bad"
  rm -- "$ROOT/bad/accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json"
  tar -czf "$LIFECYCLE_REMOTE" -C "$ROOT/bad" .
  : >"$LIFECYCLE_CALLS"
  bulk_run --renew-all true
  [ "$status" -ne 0 ]
  ! grep -q '^certbot:' "$LIFECYCLE_CALLS"
  bulk_no_write
}

@test "configuration precedence makes CLI RENEW_ALL override environment and file" {
  local cfg="$ROOT/bulk.env"
  bulk_seed_two
  printf 'RENEW_ALL=true\n' >"$cfg"
  export RENEW_ALL=false
  : >"$LIFECYCLE_CALLS"
  bulk_run --config "$cfg"
  [ "$status" -eq 64 ]
  ! grep -q '^aws:' "$LIFECYCLE_CALLS"
  bulk_run --config "$cfg" --renew-all true
  [ "$status" -eq 0 ]
  [[ "$output" == *'bulk checked=2'* ]]
  unset RENEW_ALL
  bulk_run --config "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *'bulk checked=2'* ]]
}

@test "failed S3 PutObject reports uncertain remote outcome and no complete summary" {
  bulk_seed_two
  : >"$LIFECYCLE_CALLS"
  export LIFECYCLE_RENEW_CHANGED_NAME=example.com
  export LIFECYCLE_PUT_MODE=put-failure
  bulk_run --renew-all true
  [ "$status" -ne 0 ]
  [[ "$output" == *'remote state is uncertain'* ]]
  [[ "$output" != *'bulk checked='* ]]
  [ "$(grep -c '^aws:put-object:fixture-bucket:latest.tar.gz$' \
    "$LIFECYCLE_CALLS")" -eq 1 ]
  # Real S3 may have accepted a failed/uncertain request; this fixture
  # does NOT prove remote rollback or authorize an automatic retry.
}

@test "authenticated encrypted archive permits domainless verified bulk no-op" {
  bulk_gpg_available
  bulk_seed_two
  export GPG_SYMMETRIC_KEY=bulk-test-key-only-not-a-secret-7296
  bulk_run --archive-migration plaintext-to-gpg-ocb \
    --archive-migration-backup-confirmed true example.com
  [ "$status" -eq 0 ]
  head -c 22 "$LIFECYCLE_REMOTE" |
    cmp -s - <(printf 'CERTBOTBOT-GPG-OCB-V1\n')
  cp -- "$LIFECYCLE_REMOTE" "$ROOT/encrypted.tar"
  : >"$LIFECYCLE_CALLS"
  bulk_run --renew-all true
  [ "$status" -eq 0 ]
  [[ "$output" == *'checked=2; renewed=0; metadata-only=0; unchanged=2; issued=0; published=false'* ]]
  cmp -s "$LIFECYCLE_REMOTE" "$ROOT/encrypted.tar"
  ! grep -q '^aws:put-object:' "$LIFECYCLE_CALLS"
  ! grep -q 'secret-inherited' "$LIFECYCLE_CALLS"
  [[ "$output" != *bulk-test-key-only-not-a-secret-7296* ]]
}
