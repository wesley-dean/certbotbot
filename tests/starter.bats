#!/usr/bin/env bats

setup() {
  : "${CERTBOTBOT_ARTIFACT:?CERTBOTBOT_ARTIFACT must identify the artifact under test}"
}

@test "help describes the starter commands" {
  run "${CERTBOTBOT_ARTIFACT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"run <plugin> [args]"* ]]
}

@test "version reports all build provenance fields" {
  run "${CERTBOTBOT_ARTIFACT}" version
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"version:"* ]]
  [[ "${output}" == *"build-date:"* ]]
  [[ "${output}" == *"build-commit:"* ]]
}

@test "noop plugin is automatically registered exactly once" {
  run "${CERTBOTBOT_ARTIFACT}" plugins
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == $'noop\tReference plugin that performs no operation.' ]]
}

@test "noop plugin executes successfully without output" {
  run "${CERTBOTBOT_ARTIFACT}" run noop
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "noop plugin accepts arguments without changing observable behavior" {
  run "${CERTBOTBOT_ARTIFACT}" run noop alpha "two words"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "run without a plugin name is rejected before registry lookup" {
  run "${CERTBOTBOT_ARTIFACT}" run
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"run requires a plugin name"* ]]
  [[ "${output}" != *"bad array subscript"* ]]
}

@test "unknown plugin fails conservatively" {
  run "${CERTBOTBOT_ARTIFACT}" run missing-plugin
  [ "${status}" -eq 69 ]
  [[ "${output}" == *"unknown plugin: missing-plugin"* ]]
}

@test "unknown command is rejected" {
  run "${CERTBOTBOT_ARTIFACT}" definitely-not-a-command
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"unknown command"* ]]
}
