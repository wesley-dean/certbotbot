#!/usr/bin/env bats

setup() {
  : "${BASH_STARTER_ARTIFACT:?BASH_STARTER_ARTIFACT must identify the artifact under test}"
}

@test "artifact is executable" {
  [ -x "${BASH_STARTER_ARTIFACT}" ]
}

@test "artifact has a .sha256 checksum companion" {
  [ -f "${BASH_STARTER_ARTIFACT}.sha256" ]
  [ ! -e "${BASH_STARTER_ARTIFACT}.256" ]
}

@test "checksum companion verifies the artifact bytes" {
  local artifact_dir artifact_name expected actual
  artifact_dir="$(dirname "${BASH_STARTER_ARTIFACT}")"
  artifact_name="$(basename "${BASH_STARTER_ARTIFACT}")"
  expected="$(awk '{print $1}' "${BASH_STARTER_ARTIFACT}.sha256")"

  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "${BASH_STARTER_ARTIFACT}" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "${BASH_STARTER_ARTIFACT}" | awk '{print $1}')"
  else
    skip "No SHA-256 verification command is available"
  fi

  [ "${expected}" = "${actual}" ]
  grep -Fq "  ${artifact_name}" "${BASH_STARTER_ARTIFACT}.sha256"
  [ -d "${artifact_dir}" ]
}

@test "artifact passes Bash syntax validation" {
  run bash -n "${BASH_STARTER_ARTIFACT}"
  [ "${status}" -eq 0 ]
}
