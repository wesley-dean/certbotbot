#!/usr/bin/env bats

setup() {
  : "${BASH_STARTER_ARTIFACT:?BASH_STARTER_ARTIFACT must identify the artifact under test}"
}

@test "help describes the starter commands" {
  run "${BASH_STARTER_ARTIFACT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"run <plugin> [args]"* ]]
}

@test "version reports all build provenance fields" {
  run "${BASH_STARTER_ARTIFACT}" version
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"version:"* ]]
  [[ "${output}" == *"build-date:"* ]]
  [[ "${output}" == *"build-commit:"* ]]
}

@test "noop plugin is automatically registered exactly once" {
  run "${BASH_STARTER_ARTIFACT}" plugins
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == $'noop\tReference plugin that performs no operation.' ]]
}

@test "noop plugin executes successfully without output" {
  run "${BASH_STARTER_ARTIFACT}" run noop
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "noop plugin accepts arguments without changing observable behavior" {
  run "${BASH_STARTER_ARTIFACT}" run noop alpha "two words"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "run without a plugin name is rejected before registry lookup" {
  run "${BASH_STARTER_ARTIFACT}" run
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"run requires a plugin name"* ]]
  [[ "${output}" != *"bad array subscript"* ]]
}

@test "unknown plugin fails conservatively" {
  run "${BASH_STARTER_ARTIFACT}" run missing-plugin
  [ "${status}" -eq 69 ]
  [[ "${output}" == *"unknown plugin: missing-plugin"* ]]
}

@test "unknown command is rejected" {
  run "${BASH_STARTER_ARTIFACT}" definitely-not-a-command
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"unknown command"* ]]
}
