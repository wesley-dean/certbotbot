#!/usr/bin/env bats

setup() {
  : "${CERTBOTBOT_ARTIFACT:?CERTBOTBOT_ARTIFACT must identify the artifact under test}"
  unset DNS_BACKEND STORAGE_BACKEND CERTIFICATES ACME_ENVIRONMENT
}

@test "help describes the certificate interface and implementation state" {
  run "${CERTBOTBOT_ARTIFACT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--validate"* ]]
  [[ "${output}" == *"not implemented"* ]]
}

@test "version exposes the build provenance" {
  run "${CERTBOTBOT_ARTIFACT}" --version
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"version:"* ]]
  [[ "${output}" == *"build-date:"* ]]
  [[ "${output}" == *"build-commit:"* ]]
}

@test "primary name adds the apex and wildcard" {
  run "${CERTBOTBOT_ARTIFACT}" --validate foo.com
  [ "${status}" -eq 0 ]
  [ "${output}" = $'foo.com\tfoo.com *.foo.com' ]
}

@test "wildcard-only primary canonicalizes lineage identity" {
  run "${CERTBOTBOT_ARTIFACT}" --validate '*.foo.com'
  [ "${status}" -eq 0 ]
  [ "${output}" = $'foo.com\tfoo.com *.foo.com' ]
}

@test "quoted and separate SAN arguments yield identical output" {
  run "${CERTBOTBOT_ARTIFACT}" --validate 'foo.com www.foo.com'
  [ "${status}" -eq 0 ]
  [ "${output}" = $'foo.com\tfoo.com *.foo.com www.foo.com' ]
  run "${CERTBOTBOT_ARTIFACT}" --validate foo.com www.foo.com
  [ "${status}" -eq 0 ]
  [ "${output}" = $'foo.com\tfoo.com *.foo.com www.foo.com' ]
}

@test "secondary SANs are literal and distinct" {
  run "${CERTBOTBOT_ARTIFACT}" --validate foo.com api.foo.com '*.bar.com'
  [ "${status}" -eq 0 ]
  [ "${output}" = $'foo.com\tfoo.com *.foo.com api.foo.com *.bar.com' ]
}

@test "input normalization removes duplicates and folds ASCII case" {
  run "${CERTBOTBOT_ARTIFACT}" --validate FOO.COM '*.foo.com' foo.com WWW.FOO.COM
  [ "${status}" -eq 0 ]
  [ "${output}" = $'foo.com\tfoo.com *.foo.com www.foo.com' ]
}

@test "multiline CERTIFICATES creates independent lineages" {
  run env CERTIFICATES=$'foo.com www.foo.com\n*.bar.com mail.bar.com' \
    "${CERTBOTBOT_ARTIFACT}" --validate
  [ "${status}" -eq 0 ]
  [ "${output}" = $'foo.com\tfoo.com *.foo.com www.foo.com\nbar.com\tbar.com *.bar.com mail.bar.com' ]
}

@test "blank lines do not create empty certificate lineages" {
  run env CERTIFICATES=$'\nfoo.com\n\t\nbar.com\n' \
    "${CERTBOTBOT_ARTIFACT}" --validate
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "file mode reads lineages without shell evaluation" {
  local file="${BATS_TEST_TMPDIR}/certificates.txt"
  printf '%s\n' 'foo.com www.foo.com' 'bar.com' >"${file}"
  run "${CERTBOTBOT_ARTIFACT}" --certificates-file "${file}" --validate
  [ "${status}" -eq 0 ]
  [ "${output}" = $'foo.com\tfoo.com *.foo.com www.foo.com\nbar.com\tbar.com *.bar.com' ]
}

@test "CRLF certificate file is accepted" {
  local file="${BATS_TEST_TMPDIR}/certificates.txt"
  printf 'foo.com\r\nbar.com\r\n' >"${file}"
  run "${CERTBOTBOT_ARTIFACT}" --certificates-file "${file}" --validate
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "duplicate lineages are rejected before publication" {
  run env CERTIFICATES=$'foo.com\n*.FOO.com' "${CERTBOTBOT_ARTIFACT}" --validate
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"duplicate certificate lineage"* ]]
}

@test "empty input does not renew all certificates" {
  run env CERTIFICATES= "${CERTBOTBOT_ARTIFACT}" --validate
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"at least one certificate group"* ]]
}

@test "incomplete and unknown options fail" {
  run "${CERTBOTBOT_ARTIFACT}" --certificates-file
  [ "${status}" -eq 64 ]
  run "${CERTBOTBOT_ARTIFACT}" --unrecognized foo.com
  [ "${status}" -eq 64 ]
}

@test "file and environment source modes cannot be mixed" {
  local file="${BATS_TEST_TMPDIR}/certificates.txt"
  printf 'foo.com\n' >"${file}"
  run env CERTIFICATES=bar.com "${CERTBOTBOT_ARTIFACT}" --certificates-file "${file}" --validate
  [ "${status}" -eq 64 ]
}

@test "environment and positional sources cannot be mixed" {
  run env CERTIFICATES=bar.com "${CERTBOTBOT_ARTIFACT}" --validate foo.com
  [ "${status}" -eq 64 ]
}

@test "bad DNS and storage backend names fail closed" {
  run "${CERTBOTBOT_ARTIFACT}" --validate --dns-backend cloudflare foo.com
  [ "${status}" -eq 69 ]
  run "${CERTBOTBOT_ARTIFACT}" --validate --storage-backend minio foo.com
  [ "${status}" -eq 69 ]
}

@test "compiled route53 and s3 identifiers are valid" {
  run "${CERTBOTBOT_ARTIFACT}" --validate --dns-backend route53 --storage-backend s3 foo.com
  [ "${status}" -eq 0 ]
}

@test "invalid hostname punctuation is rejected as data" {
  run "${CERTBOTBOT_ARTIFACT}" --validate 'foo.com;touch /tmp/unwanted' 
  [ "${status}" -eq 64 ]
  run "${CERTBOTBOT_ARTIFACT}" --validate 'foo..com'
  [ "${status}" -eq 64 ]
}

@test "non-ASCII names are rejected independently of the host locale" {
  run env LC_ALL=C.UTF-8 "${CERTBOTBOT_ARTIFACT}" --validate 'éxample.com'
  [ "${status}" -eq 64 ]
}

@test "invalid wildcard placement is rejected" {
  run "${CERTBOTBOT_ARTIFACT}" --validate '*.*.foo.com'
  [ "${status}" -eq 64 ]
  run "${CERTBOTBOT_ARTIFACT}" --validate 'foo*.com'
  [ "${status}" -eq 64 ]
}

@test "embedded newline in a positional argument is rejected" {
  run "${CERTBOTBOT_ARTIFACT}" --validate $'foo.com\nbar.com'
  [ "${status}" -eq 64 ]
}

@test "ordinary certificate issuance always fails until implemented" {
  run "${CERTBOTBOT_ARTIFACT}" foo.com www.foo.com
  [ "${status}" -eq 69 ]
  [[ "${output}" == *"certificate issuance is not implemented"* ]]
}
