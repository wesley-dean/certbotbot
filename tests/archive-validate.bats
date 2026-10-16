#!/usr/bin/env bats

## The archive validator operates on attacker-controlled tar metadata and never
## extracts it.  Fixture bytes are synthetic; cryptographic validation and
## Certbot renewal metadata portability are separate production gates.

setup() {
  : "${CERTBOTBOT_ARTIFACT:?Missing built certbotbot artifact}"
  export CERTBOTBOT_ARCHIVE_FIXTURE_ROOT="${BATS_TEST_TMPDIR}/source"
  export CERTBOTBOT_ARCHIVE_FILE="${BATS_TEST_TMPDIR}/domain.tar.gz"
  mkdir -p "${CERTBOTBOT_ARCHIVE_FIXTURE_ROOT}"
}

make_domain_fixture() {
  local root="${CERTBOTBOT_ARCHIVE_FIXTURE_ROOT}" name=${1:-example.com} kind
  mkdir -p "${root}/archive/${name}" "${root}/live/${name}" \
    "${root}/renewal" "${root}/combined"
  for kind in cert chain fullchain privkey; do
    printf '%s\n' "${kind} for ${name}" >"${root}/archive/${name}/${kind}1.pem"
    ln -s "../../archive/${name}/${kind}1.pem" \
      "${root}/live/${name}/${kind}.pem"
  done
  chmod 0600 "${root}/archive/${name}/privkey1.pem"
  printf '%s\n' 'version = 5.0.0' >"${root}/renewal/${name}.conf"
  printf '%s\n' 'combined material' >"${root}/combined/${name}.pem"
  printf '%s\n' 'combined material' >"${root}/live/${name}/combined.pem"
  chmod 0600 "${root}/combined/${name}.pem" \
    "${root}/live/${name}/combined.pem"
}

pack_domain_fixture() {
  tar -czf "${CERTBOTBOT_ARCHIVE_FILE}" -C "${CERTBOTBOT_ARCHIVE_FIXTURE_ROOT}" \
    archive live renewal combined
}

validate_domain_fixture() {
  run bash -c 'source "$1" --version >/dev/null; certbotbot_archive_validate_domain "$2" "$3"' \
    _ "${CERTBOTBOT_ARTIFACT}" "${CERTBOTBOT_ARCHIVE_FILE}" "${1:-example.com}"
}

@test "complete domain archive manifest is accepted without extraction" {
  make_domain_fixture
  pack_domain_fixture
  validate_domain_fixture
  [ "${status}" -eq 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}/config" ]
}

@test "unrelated certificate identity is rejected" {
  make_domain_fixture
  pack_domain_fixture
  validate_domain_fixture example.net
  [ "${status}" -eq 64 ]
}

@test "archive missing combined PEM is rejected" {
  make_domain_fixture
  rm "${CERTBOTBOT_ARCHIVE_FIXTURE_ROOT}/combined/example.com.pem"
  pack_domain_fixture
  validate_domain_fixture
  [ "${status}" -eq 64 ]
}

@test "archive missing live symlink target is rejected" {
  make_domain_fixture
  rm "${CERTBOTBOT_ARCHIVE_FIXTURE_ROOT}/archive/example.com/privkey1.pem"
  pack_domain_fixture
  validate_domain_fixture
  [ "${status}" -eq 64 ]
}

@test "archive symlink targeting another lineage is rejected" {
  make_domain_fixture
  rm "${CERTBOTBOT_ARCHIVE_FIXTURE_ROOT}/live/example.com/privkey.pem"
  ln -s ../../archive/another.com/privkey1.pem \
    "${CERTBOTBOT_ARCHIVE_FIXTURE_ROOT}/live/example.com/privkey.pem"
  pack_domain_fixture
  validate_domain_fixture
  [ "${status}" -eq 64 ]
}

@test "archive symlink targeting an absolute path is rejected" {
  make_domain_fixture
  rm "${CERTBOTBOT_ARCHIVE_FIXTURE_ROOT}/live/example.com/privkey.pem"
  ln -s /etc/shadow "${CERTBOTBOT_ARCHIVE_FIXTURE_ROOT}/live/example.com/privkey.pem"
  pack_domain_fixture
  validate_domain_fixture
  [ "${status}" -eq 64 ]
}

@test "archive private-key permissions cannot expose other readers" {
  make_domain_fixture
  chmod 0644 "${CERTBOTBOT_ARCHIVE_FIXTURE_ROOT}/archive/example.com/privkey1.pem"
  pack_domain_fixture
  validate_domain_fixture
  [ "${status}" -eq 64 ]
}

@test "archive combined PEM permissions cannot expose other readers" {
  make_domain_fixture
  chmod 0644 "${CERTBOTBOT_ARCHIVE_FIXTURE_ROOT}/combined/example.com.pem"
  pack_domain_fixture
  validate_domain_fixture
  [ "${status}" -eq 64 ]
}

@test "archive hard links are rejected" {
  make_domain_fixture
  ln "${CERTBOTBOT_ARCHIVE_FIXTURE_ROOT}/archive/example.com/cert1.pem" \
    "${CERTBOTBOT_ARCHIVE_FIXTURE_ROOT}/archive/example.com/unexpected.pem"
  pack_domain_fixture
  validate_domain_fixture
  [ "${status}" -eq 64 ]
}

@test "archive FIFO entries are rejected" {
  make_domain_fixture
  mkfifo "${CERTBOTBOT_ARCHIVE_FIXTURE_ROOT}/archive/example.com/pipe"
  pack_domain_fixture
  validate_domain_fixture
  [ "${status}" -eq 64 ]
}

@test "archive unexpected files are rejected" {
  make_domain_fixture
  printf '%s\n' 'unrelated' >"${CERTBOTBOT_ARCHIVE_FIXTURE_ROOT}/live/example.com/extra.pem"
  pack_domain_fixture
  validate_domain_fixture
  [ "${status}" -eq 64 ]
}

@test "archive duplicate member names are rejected" {
  make_domain_fixture
  tar -czf "${CERTBOTBOT_ARCHIVE_FILE}" -C "${CERTBOTBOT_ARCHIVE_FIXTURE_ROOT}" \
    archive live renewal combined archive/example.com/cert1.pem
  validate_domain_fixture
  [ "${status}" -eq 64 ]
}

@test "archive traversal member names are rejected" {
  make_domain_fixture
  tar -czf "${CERTBOTBOT_ARCHIVE_FILE}" \
    --transform='s|^archive/example.com/cert1.pem$|../../escape.pem|' \
    -C "${CERTBOTBOT_ARCHIVE_FIXTURE_ROOT}" archive live renewal combined
  validate_domain_fixture
  [ "${status}" -eq 64 ]
  [ ! -e "${BATS_TEST_TMPDIR}/escape.pem" ]
}

@test "archive compressed metadata with embedded filename newline is rejected" {
  make_domain_fixture
  printf '%s\n' 'unexpected' >"${CERTBOTBOT_ARCHIVE_FIXTURE_ROOT}/archive/example.com/bad"$'\n'"name.pem"
  pack_domain_fixture
  validate_domain_fixture
  [ "${status}" -eq 64 ]
}

@test "archive rejects oversized regular file member" {
  make_domain_fixture
  truncate -s 9000000 "${CERTBOTBOT_ARCHIVE_FIXTURE_ROOT}/archive/example.com/cert1.pem"
  pack_domain_fixture
  validate_domain_fixture
  [ "${status}" -eq 64 ]
}

@test "truncated gzip archive is never accepted" {
  make_domain_fixture
  pack_domain_fixture
  truncate -s 20 "${CERTBOTBOT_ARCHIVE_FILE}"
  validate_domain_fixture
  [ "${status}" -ne 0 ]
}

@test "archive rejection leaves nearby files unchanged" {
  make_domain_fixture
  printf '%s\n' 'marker' >"${BATS_TEST_TMPDIR}/sentinel"
  printf '%s\n' 'unrelated' >"${CERTBOTBOT_ARCHIVE_FIXTURE_ROOT}/archive/example.com/unexpected.txt"
  pack_domain_fixture
  validate_domain_fixture
  [ "${status}" -eq 64 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/sentinel")" = marker ]
  [ ! -e "${BATS_TEST_TMPDIR}/config" ]
}
