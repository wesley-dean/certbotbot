#!/usr/bin/env bats

## These tests source each built artifact in --version mode, which retains the
## functions without executing issuance.  Real AWS and Certbot clients are never
## invoked; the injected PATH tools record each separate argv element.

setup() {
  : "${CERTBOTBOT_ARTIFACT:?Missing artifact under test}"
  export CERTBOTBOT_LOCK_DIR="${BATS_TEST_TMPDIR}/locks"
  export FAKE_AWS_ARGS="${BATS_TEST_TMPDIR}/aws-args"
  export FAKE_CERTBOT_ARGS="${BATS_TEST_TMPDIR}/certbot-args"
  local fake_dir="${BATS_TEST_TMPDIR}/fakes"

  mkdir -p "${fake_dir}"
  cat >"${fake_dir}/aws" <<'FAKE'
#!/usr/bin/env bash
printf '<%s>\n' "$@" >"${FAKE_AWS_ARGS:?}"
exit "${FAKE_AWS_STATUS:-0}"
FAKE
  cat >"${fake_dir}/certbot" <<'FAKE'
#!/usr/bin/env bash
printf '<%s>\n' "$@" >"${FAKE_CERTBOT_ARGS:?}"
exit "${FAKE_CERTBOT_STATUS:-0}"
FAKE
  chmod 0700 "${fake_dir}/aws" "${fake_dir}/certbot"
  export PATH="${fake_dir}:${PATH}"
  unset S3_ENDPOINT_URL FAKE_AWS_STATUS FAKE_CERTBOT_STATUS
}

@test "preflight never runs installed external commands" {
  run "${CERTBOTBOT_ARTIFACT}" --validate example.com
  [ "${status}" -eq 0 ]
  [ ! -e "${FAKE_AWS_ARGS}" ]
  [ ! -e "${FAKE_CERTBOT_ARGS}" ]
}

@test "Route53 probe invokes only certbot --version" {
  run bash -c 'source "$1" --version >/dev/null; certbotbot_dns_route53_run probe' \
    _ "${CERTBOTBOT_ARTIFACT}"
  [ "${status}" -eq 0 ]
  [ "$(cat "${FAKE_CERTBOT_ARGS}")" = '<--version>' ]
  [ ! -e "${FAKE_AWS_ARGS}" ]
}

@test "Route53 rejects issuing operations without running certbot" {
  run bash -c 'source "$1" --version >/dev/null; certbotbot_dns_route53_run certonly -d example.com' \
    _ "${CERTBOTBOT_ARTIFACT}"
  [ "${status}" -eq 69 ]
  [ ! -e "${FAKE_CERTBOT_ARGS}" ]
}

@test "Route53 uses a fixed DNS-only challenge option vector" {
  run bash -c 'source "$1" --version >/dev/null; certbotbot_dns_route53_challenge_args; printf "[%s]\n" "${CERTBOTBOT_DNS_CHALLENGE_ARGS[@]}"' \
    _ "${CERTBOTBOT_ARTIFACT}"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'[--dns-route53]\n[--preferred-challenges]\n[dns]' ]
  [ ! -e "${FAKE_CERTBOT_ARGS}" ]
}

@test "Certbot subprocess failures propagate without fallback" {
  export FAKE_CERTBOT_STATUS=27
  run bash -c 'source "$1" --version >/dev/null; certbotbot_dns_route53_run probe' \
    _ "${CERTBOTBOT_ARTIFACT}"
  [ "${status}" -eq 27 ]
}

@test "S3 put preserves endpoint, bucket, object key, and pathname as separate arguments" {
  local file="${BATS_TEST_TMPDIR}/archive with spaces.tar.gz"
  printf 'test fixture\n' >"${file}"
  export S3_ENDPOINT_URL='http://127.0.0.1:9000'
  run bash -c 'source "$1" --version >/dev/null; certbotbot_storage_s3_run put "$2" "$3" "$4"' \
    _ "${CERTBOTBOT_ARTIFACT}" 'certbot-archive' 'example.com-latest.tar.gz' "${file}"
  [ "${status}" -eq 0 ]
  local expected
  expected="$(printf '<%s>\n' \
    --endpoint-url "${S3_ENDPOINT_URL}" \
    s3api put-object \
    --bucket certbot-archive \
    --key example.com-latest.tar.gz \
    --body "${file}")"
  [ "$(cat "${FAKE_AWS_ARGS}")" = "${expected}" ]
  [ ! -e "${FAKE_CERTBOT_ARGS}" ]
}

@test "S3 get preserves complete target filename as one argument" {
  local target="${BATS_TEST_TMPDIR}/download with spaces.tar.gz.enc"
  run bash -c 'source "$1" --version >/dev/null; certbotbot_storage_s3_run get "$2" "$3" "$4"' \
    _ "${CERTBOTBOT_ARTIFACT}" certbot-archive example.com-latest.tar.gz.enc "${target}"
  [ "${status}" -eq 0 ]
  local expected
  expected="$(printf '<%s>\n' \
    s3api get-object \
    --bucket certbot-archive \
    --key example.com-latest.tar.gz.enc \
    "${target}")"
  [ "$(cat "${FAKE_AWS_ARGS}")" = "${expected}" ]
}

@test "S3 transfers propagate AWS CLI errors unchanged" {
  local file="${BATS_TEST_TMPDIR}/source.tar.gz"
  printf 'test fixture\n' >"${file}"
  export FAKE_AWS_STATUS=47
  run bash -c 'source "$1" --version >/dev/null; certbotbot_storage_s3_put "$2" "$3" "$4"' \
    _ "${CERTBOTBOT_ARTIFACT}" certbot-archive common-latest.tar.gz "${file}"
  [ "${status}" -eq 47 ]
  [ -f "${FAKE_AWS_ARGS}" ]
}

@test "bad object keys never call the AWS CLI" {
  local file="${BATS_TEST_TMPDIR}/source.tar.gz"
  printf 'test fixture\n' >"${file}"
  run bash -c 'source "$1" --version >/dev/null; certbotbot_storage_s3_put "$2" "$3" "$4"' \
    _ "${CERTBOTBOT_ARTIFACT}" certbot-archive '../../untrusted-latest.tar.gz' "${file}"
  [ "${status}" -eq 64 ]
  [ ! -e "${FAKE_AWS_ARGS}" ]
}

@test "invalid endpoint URLs do not forward credentials to an unexpected host" {
  local file="${BATS_TEST_TMPDIR}/source.tar.gz"
  printf 'test fixture\n' >"${file}"
  export S3_ENDPOINT_URL='http://user:pass@localhost:9000'
  run bash -c 'source "$1" --version >/dev/null; certbotbot_storage_s3_put "$2" "$3" "$4"' \
    _ "${CERTBOTBOT_ARTIFACT}" certbot-archive common-latest.tar.gz "${file}"
  [ "${status}" -eq 64 ]
  [ ! -e "${FAKE_AWS_ARGS}" ]
}

@test "S3 operations reject arbitrary operation names" {
  run bash -c 'source "$1" --version >/dev/null; certbotbot_storage_s3_run delete bucket key' \
    _ "${CERTBOTBOT_ARTIFACT}"
  [ "${status}" -eq 64 ]
  [ ! -e "${FAKE_AWS_ARGS}" ]
}

@test "local lock can be acquired and released repeatedly" {
  run bash -c 'source "$1" --version >/dev/null; certbotbot_lock_acquire bucket endpoint || exit; certbotbot_lock_release || exit; certbotbot_lock_acquire bucket endpoint || exit; certbotbot_lock_release' \
    _ "${CERTBOTBOT_ARTIFACT}"
  [ "${status}" -eq 0 ]
}

@test "local lock refuses a directory accessible by other users" {
  export CERTBOTBOT_LOCK_DIR="${BATS_TEST_TMPDIR}/insecure"
  mkdir -p "${CERTBOTBOT_LOCK_DIR}"
  chmod 0755 "${CERTBOTBOT_LOCK_DIR}"
  run bash -c 'source "$1" --version >/dev/null; certbotbot_lock_acquire bucket endpoint' \
    _ "${CERTBOTBOT_ARTIFACT}"
  [ "${status}" -eq 73 ]
}

@test "local lock refuses a symlinked lock directory" {
  local real_dir="${BATS_TEST_TMPDIR}/real-locks"
  mkdir -p "${real_dir}"
  export CERTBOTBOT_LOCK_DIR="${BATS_TEST_TMPDIR}/symlinked-locks"
  ln -s "${real_dir}" "${CERTBOTBOT_LOCK_DIR}"
  run bash -c 'source "$1" --version >/dev/null; certbotbot_lock_acquire bucket endpoint' \
    _ "${CERTBOTBOT_ARTIFACT}"
  [ "${status}" -eq 73 ]
}

@test "concurrent local writers sharing one storage collection cannot overlap" {
  local ready="${BATS_TEST_TMPDIR}/ready"
  bash -c 'source "$1" --version >/dev/null; certbotbot_lock_acquire bucket endpoint || exit; : >"$2"; sleep 2; certbotbot_lock_release' \
    _ "${CERTBOTBOT_ARTIFACT}" "${ready}" &
  local holder=$!
  local attempts
  for (( attempts=0; attempts<80; attempts++ )); do
    [ -f "${ready}" ] && break
    sleep 0.05
  done
  [ -f "${ready}" ]
  run bash -c 'source "$1" --version >/dev/null; certbotbot_lock_acquire bucket endpoint' \
    _ "${CERTBOTBOT_ARTIFACT}"
  [ "${status}" -eq 75 ]
  wait "${holder}"
}
