#!/usr/bin/env bats

## This suite exercises pre-publication filesystem logic in an isolated Bats
## directory.  Fake PEM bytes are sufficient for testing link and output
## handling; cryptographic key/certificate matching remains a later gate.

setup() {
  : "${CERTBOTBOT_ARTIFACT:?CERTBOTBOT_ARTIFACT must identify the built release}"
  export CERTBOTBOT_TMPDIR="${BATS_TEST_TMPDIR}"
}

create_lineage() {
  local root="${1}" name="${2}" kind
  mkdir -p "${root}/archive/${name}" "${root}/live/${name}"
  for kind in cert chain fullchain privkey; do
    printf '%s\n' "${kind} for ${name}" >"${root}/archive/${name}/${kind}1.pem"
    ln -s "../../archive/${name}/${kind}1.pem" "${root}/live/${name}/${kind}.pem"
  done
  chmod 0600 "${root}/archive/${name}/privkey1.pem"
}

@test "workspace creates three private Certbot directories and removes them" {
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    [[ -d "${CERTBOTBOT_WORKSPACE_CONFIG}" ]] || exit
    [[ -d "${CERTBOTBOT_WORKSPACE_WORK}" ]] || exit
    [[ -d "${CERTBOTBOT_WORKSPACE_LOGS}" ]] || exit
    for path in "${CERTBOTBOT_WORKSPACE_ROOT}" "${CERTBOTBOT_WORKSPACE_CONFIG}" "${CERTBOTBOT_WORKSPACE_WORK}" "${CERTBOTBOT_WORKSPACE_LOGS}"; do
      [[ "$(stat -c "%a" "$path")" == 700 ]] || exit
    done
    original=${CERTBOTBOT_WORKSPACE_ROOT}
    certbotbot_workspace_destroy || exit
    [[ ! -e "${original}" ]] && [[ -z "${CERTBOTBOT_WORKSPACE_ROOT}" ]]
  ' _ "${CERTBOTBOT_ARTIFACT}"
  [ "${status}" -eq 0 ]
}

@test "workspace refuses repeated allocation without cleanup" {
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_workspace_create || exit
    certbotbot_workspace_create
    result=$?
    certbotbot_workspace_destroy || exit
    [[ "${result}" -eq 64 ]]
  ' _ "${CERTBOTBOT_ARTIFACT}"
  [ "${status}" -eq 0 ]
}

@test "workspace rejects a symlinked parent" {
  local real_parent="${BATS_TEST_TMPDIR}/real"
  mkdir -p "${real_parent}"
  ln -s "${real_parent}" "${BATS_TEST_TMPDIR}/link"
  export CERTBOTBOT_TMPDIR="${BATS_TEST_TMPDIR}/link"
  run bash -c 'source "$1" --version >/dev/null; certbotbot_workspace_create' \
    _ "${CERTBOTBOT_ARTIFACT}"
  [ "${status}" -eq 64 ]
  [ -z "$(find "${real_parent}" -mindepth 1 -print)" ]
}

@test "workspace cleanup refuses to delete a different directory" {
  local sentinel="${BATS_TEST_TMPDIR}/sentinel"
  mkdir -p "${sentinel}"
  printf 'preserve\n' >"${sentinel}/marker"
  run bash -c '
    source "$1" --version >/dev/null
    CERTBOTBOT_WORKSPACE_ROOT="$2"
    certbotbot_workspace_destroy
  ' _ "${CERTBOTBOT_ARTIFACT}" "${sentinel}"
  [ "${status}" -eq 73 ]
  [ -f "${sentinel}/marker" ]
}

@test "PEM assembly generates both identical restricted regular files" {
  local root="${BATS_TEST_TMPDIR}/config" actual
  mkdir -m 0700 "${root}"
  create_lineage "${root}" example.com
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_pem_assemble "$2" example.com
  ' _ "${CERTBOTBOT_ARTIFACT}" "${root}"
  [ "${status}" -eq 0 ]
  [ -f "${root}/combined/example.com.pem" ]
  [ -f "${root}/live/example.com/combined.pem" ]
  [ ! -L "${root}/live/example.com/combined.pem" ]
  [ "$(stat -c '%a' "${root}/combined/example.com.pem")" = 600 ]
  [ "$(stat -c '%a' "${root}/live/example.com/combined.pem")" = 600 ]
  cmp "${root}/combined/example.com.pem" "${root}/live/example.com/combined.pem"
  actual="$(cat "${root}/combined/example.com.pem")"
  [ "${actual}" = $'fullchain for example.com\n\nprivkey for example.com' ]
}

@test "two lineage archives produce independent combined PEM files" {
  local root="${BATS_TEST_TMPDIR}/config"
  mkdir -m 0700 "${root}"
  create_lineage "${root}" example.com
  create_lineage "${root}" example.net
  run bash -c '
    source "$1" --version >/dev/null
    certbotbot_pem_assemble "$2" example.com || exit
    certbotbot_pem_assemble "$2" example.net
  ' _ "${CERTBOTBOT_ARTIFACT}" "${root}"
  [ "${status}" -eq 0 ]
  grep -F 'example.com' "${root}/combined/example.com.pem"
  grep -F 'example.net' "${root}/combined/example.net.pem"
  ! grep -F 'example.net' "${root}/combined/example.com.pem"
}

@test "PEM assembly refuses symlink escape before creating outputs" {
  local root="${BATS_TEST_TMPDIR}/config"
  mkdir -m 0700 "${root}"
  create_lineage "${root}" example.com
  rm "${root}/live/example.com/privkey.pem"
  ln -s "../../../../outside-key.pem" "${root}/live/example.com/privkey.pem"
  run bash -c 'source "$1" --version >/dev/null; certbotbot_pem_assemble "$2" example.com' \
    _ "${CERTBOTBOT_ARTIFACT}" "${root}"
  [ "${status}" -eq 64 ]
  [ ! -e "${root}/combined/example.com.pem" ]
  [ ! -e "${root}/live/example.com/combined.pem" ]
}

@test "PEM assembly refuses private keys readable by other users" {
  local root="${BATS_TEST_TMPDIR}/config"
  mkdir -m 0700 "${root}"
  create_lineage "${root}" example.com
  chmod 0644 "${root}/archive/example.com/privkey1.pem"
  run bash -c 'source "$1" --version >/dev/null; certbotbot_pem_assemble "$2" example.com' \
    _ "${CERTBOTBOT_ARTIFACT}" "${root}"
  [ "${status}" -eq 64 ]
  [ ! -e "${root}/combined/example.com.pem" ]
}

@test "PEM assembly refuses a missing standard live certificate link" {
  local root="${BATS_TEST_TMPDIR}/config"
  mkdir -m 0700 "${root}"
  create_lineage "${root}" example.com
  rm "${root}/live/example.com/chain.pem"
  run bash -c 'source "$1" --version >/dev/null; certbotbot_pem_assemble "$2" example.com' \
    _ "${CERTBOTBOT_ARTIFACT}" "${root}"
  [ "${status}" -eq 64 ]
  [ ! -e "${root}/combined/example.com.pem" ]
}

@test "PEM assembly refuses existing combined symlinks" {
  local root="${BATS_TEST_TMPDIR}/config"
  mkdir -m 0700 "${root}"
  create_lineage "${root}" example.com
  ln -s /dev/null "${root}/live/example.com/combined.pem"
  run bash -c 'source "$1" --version >/dev/null; certbotbot_pem_assemble "$2" example.com' \
    _ "${CERTBOTBOT_ARTIFACT}" "${root}"
  [ "${status}" -eq 64 ]
  [ ! -e "${root}/combined/example.com.pem" ]
}

@test "PEM assembly refuses a symlinked lineage parent directory" {
  local root="${BATS_TEST_TMPDIR}/config"
  mkdir -m 0700 "${root}"
  create_lineage "${root}" example.com
  mv "${root}/live/example.com" "${root}/live/real"
  ln -s real "${root}/live/example.com"
  run bash -c 'source "$1" --version >/dev/null; certbotbot_pem_assemble "$2" example.com' \
    _ "${CERTBOTBOT_ARTIFACT}" "${root}"
  [ "${status}" -eq 64 ]
}

@test "PEM assembly does not invoke Certbot, AWS, or shell hooks" {
  local root="${BATS_TEST_TMPDIR}/config"
  mkdir -m 0700 "${root}"
  create_lineage "${root}" example.com
  local fake_dir="${BATS_TEST_TMPDIR}/fake"
  mkdir -p "${fake_dir}"
  printf '#!/usr/bin/env bash\nexit 99\n' >"${fake_dir}/certbot"
  printf '#!/usr/bin/env bash\nexit 99\n' >"${fake_dir}/aws"
  chmod 0700 "${fake_dir}/certbot" "${fake_dir}/aws"
  export PATH="${fake_dir}:${PATH}"
  run bash -c 'source "$1" --version >/dev/null; certbotbot_pem_assemble "$2" example.com' \
    _ "${CERTBOTBOT_ARTIFACT}" "${root}"
  [ "${status}" -eq 0 ]
}
