# shellcheck shell=bash
## @file src/main.bash
## @brief Defines the starter command-line interface and top-level dispatch.
## @details
## This file is intentionally small.  Core reusable behavior belongs under
## `lib/`, plugins belong under `lib/plugins/`, and this entrypoint translates
## command-line intent into those stable interfaces.  Keeping the entrypoint
## narrow makes it easier for projects created from this template to replace the
## example CLI without disturbing build, dependency, documentation, or plugin
## architecture.

## @fn bash_starter_usage()
## @brief Prints command-line usage for the starter executable.
## @details
## The displayed executable name comes from build metadata rather than being
## hard-coded in maintained source.  Changing `PROJECT_NAME` in the Makefile
## therefore updates both artifact names and the starter help surface.
## @par Standard Output
## A concise usage summary and available starter commands.
## @retval 0 Usage was printed.
bash_starter_usage() {
  printf 'Usage: %s [command]\n\n' "${BASH_STARTER_PROJECT_NAME}"
  cat <<'EOF'
Commands:
  help                 Show this help text.
  version              Show version and build provenance.
  plugins              List registered plugins.
  run <plugin> [args]  Execute a registered plugin.
EOF
}

## @fn bash_starter_version()
## @brief Prints version, build date, and build commit provenance.
## @details
## The values are injected by `make build` before maintained source is assembled.
## They remain executable assignments in every artifact flavor, so provenance is
## available even after full-line comments have been removed.
## @par Standard Output
## Project version, build date, and build commit on separate labeled lines.
## @retval 0 Version information was printed.
bash_starter_version() {
  printf 'version: %s\n' "${BASH_STARTER_VERSION}"
  printf 'build-date: %s\n' "${BASH_STARTER_BUILD_DATE}"
  printf 'build-commit: %s\n' "${BASH_STARTER_BUILD_COMMIT}"
}

## @fn bash_starter_main()
## @brief Dispatches the starter command-line interface.
## @param ... Command-line arguments supplied to the generated executable.
## @retval 0 The requested command completed successfully.
## @retval 64 The command line was invalid.
## @retval 69 A requested plugin was not registered.
## @par Examples
## @code
## bash_starter_main plugins
## bash_starter_main run noop
## @endcode
bash_starter_main() {
  local command="${1:-help}"

  case "${command}" in
    help | -h | --help)
      bash_starter_usage
      ;;
    version | -V | --version)
      bash_starter_version
      ;;
    plugins)
      bash_starter_plugin_list
      ;;
    run)
      shift
      if [[ $# -lt 1 ]]; then
        printf '%s\n' 'run requires a plugin name' >&2
        return 64
      fi
      bash_starter_plugin_run "$@"
      ;;
    *)
      printf 'unknown command: %s\n' "${command}" >&2
      bash_starter_usage >&2
      return 64
      ;;
  esac
}

bash_starter_main "$@"
