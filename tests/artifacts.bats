#!/usr/bin/env bats

setup() {
  : "${CERTBOTBOT_ARTIFACT:?CERTBOTBOT_ARTIFACT must identify the artifact under test}"
}

@test "artifact is executable" {
  [ -x "${CERTBOTBOT_ARTIFACT}" ]
}

@test "artifact has a .sha256 checksum companion" {
  [ -f "${CERTBOTBOT_ARTIFACT}.sha256" ]
  [ ! -e "${CERTBOTBOT_ARTIFACT}.256" ]
}

@test "checksum companion verifies the artifact bytes" {
  local artifact_dir artifact_name expected actual
  artifact_dir="$(dirname "${CERTBOTBOT_ARTIFACT}")"
  artifact_name="$(basename "${CERTBOTBOT_ARTIFACT}")"
  expected="$(awk '{print $1}' "${CERTBOTBOT_ARTIFACT}.sha256")"

  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "${CERTBOTBOT_ARTIFACT}" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "${CERTBOTBOT_ARTIFACT}" | awk '{print $1}')"
  else
    skip "No SHA-256 verification command is available"
  fi

  [ "${expected}" = "${actual}" ]
  grep -Fq "  ${artifact_name}" "${CERTBOTBOT_ARTIFACT}.sha256"
  [ -d "${artifact_dir}" ]
}

@test "artifact passes Bash syntax validation" {
  run bash -n "${CERTBOTBOT_ARTIFACT}"
  [ "${status}" -eq 0 ]
}
