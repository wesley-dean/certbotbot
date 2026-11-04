#!/usr/bin/env bats

setup() {
  : "${BASH_STARTER_ARTIFACT:?Artifact under test is required}"
  ROOT="$(mktemp -d)"
  WORKSPACE="$ROOT/workspace"
  mkdir -p "$WORKSPACE/config/live/example.com" "$ROOT/bin"
  printf 'synthetic private fixture\n' >"$WORKSPACE/config/live/example.com/cert.pem"
  printf 'synthetic private fixture\n' >"$WORKSPACE/config/live/example.com/chain.pem"
  printf 'synthetic private fixture\n' >"$WORKSPACE/config/live/example.com/privkey.pem"
  printf 'synthetic private fixture\n' >"$WORKSPACE/config/live/example.com/fullchain.pem"
  cat >"$ROOT/bin/openssl" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == x509 ]] || exit 1
case " $* " in
  *" -checkend "*) [[ "$CERT_VERIFY_CASE" != expiry ]] ;;
  *" /chain.pem "*) [[ "$CERT_VERIFY_CASE" != chain ]] ;;
  *) exit 1 ;;
esac
MOCK
  chmod 755 "$ROOT/bin/openssl"
  export PATH="$ROOT/bin:$PATH"
}

teardown() {
  rm -rf -- "$ROOT"
}

verify() {
  run bash -c '
    source "$1" --help >/dev/null
    certbotbot_state_preflight() {
      CERTBOTBOT_LINEAGE_STATE=present
      return 0
    }
    certbotbot_renewal_map() { return 0; }
    certbotbot_renew_sans_match() {
      [[ "$CERT_VERIFY_CASE" != sans ]]
    }
    certbotbot_verify_material "$2" example.com example.com
  ' _ "$BASH_STARTER_ARTIFACT" "$WORKSPACE"
}

@test "SAN mismatch yields only the fixed SAN stage and existing refusal" {
  export CERT_VERIFY_CASE=sans
  verify
  [ "$status" -eq 65 ]
  [[ "$output" == *'certificate verification stage=sans'* ]]
  [[ "$output" == *'selected certificate or chain is unusable'* ]]
  [[ "$output" != *'synthetic private fixture'* ]]
}

@test "expiry failure yields only the fixed expiry stage" {
  export CERT_VERIFY_CASE=expiry
  verify
  [ "$status" -eq 65 ]
  [[ "$output" == *'certificate verification stage=expiry'* ]]
  [[ "$output" != *'stage=sans'* ]]
  [[ "$output" != *'synthetic private fixture'* ]]
}

@test "chain parse failure yields only the fixed chain stage" {
  export CERT_VERIFY_CASE=chain
  verify
  [ "$status" -eq 65 ]
  [[ "$output" == *'certificate verification stage=chain'* ]]
  [[ "$output" != *'stage=expiry'* ]]
  [[ "$output" != *'synthetic private fixture'* ]]
}
