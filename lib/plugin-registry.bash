# shellcheck shell=bash
## @file lib/plugin-registry.bash
## @brief Provides the stable registry used by automatically discovered plugins.
## @details
## The build appends plugin files after this core module in deterministic lexical
## order.  Each plugin registers a logical name, a human-readable description,
## and the function that implements the plugin.  Runtime dispatch therefore
## depends on registry state rather than a central list of known plugin names.
##
## The registry deliberately owns only discovery metadata and dispatch.  A real
## project may add richer capability metadata, lifecycle hooks, or typed plugin
## categories, but those additions should extend this narrow contract rather than
## introduce plugin-specific branches into unrelated core code.

declare -a BASH_STARTER_PLUGIN_NAMES=()
declare -A BASH_STARTER_PLUGIN_FUNCTIONS=()
declare -A BASH_STARTER_PLUGIN_DESCRIPTIONS=()

## @fn bash_starter_plugin_register()
## @brief Registers one plugin implementation with the runtime registry.
## @details
## Registration is explicit even though source discovery is automatic.  This
## gives each plugin control over its public logical name while keeping the build
## independent of a hard-coded plugin inventory.  Duplicate names are rejected
## because silent replacement would make behavior depend on lexical file order.
##
## @param name Stable logical plugin name exposed to callers.
## @param function_name Bash function that implements the plugin.
## @param description Human-readable one-line plugin description.
## @retval 0 The plugin was registered.
## @retval 64 A required argument was empty or the name was already registered.
## @par Examples
## @code
## bash_starter_plugin_register "noop" "bash_starter_plugin_noop" "Do nothing"
## @endcode
bash_starter_plugin_register() {
  local name="${1:-}"
  local function_name="${2:-}"
  local description="${3:-}"

  if [[ -z "${name}" || -z "${function_name}" || -z "${description}" ]]; then
    printf '%s\n' 'plugin registration requires name, function, and description' >&2
    return 64
  fi

  if [[ -n "${BASH_STARTER_PLUGIN_FUNCTIONS[${name}]:-}" ]]; then
    printf 'plugin already registered: %s\n' "${name}" >&2
    return 64
  fi

  BASH_STARTER_PLUGIN_NAMES+=("${name}")
  BASH_STARTER_PLUGIN_FUNCTIONS["${name}"]="${function_name}"
  BASH_STARTER_PLUGIN_DESCRIPTIONS["${name}"]="${description}"
}

## @fn bash_starter_plugin_list()
## @brief Prints registered plugins and their descriptions.
## @details
## Plugins are emitted in registration order.  The build sorts plugin source
## paths lexically, making this output deterministic for a given source tree.
## @par Standard Output
## One tab-separated plugin name and description per line.
## @retval 0 The registry was printed successfully.
## @par Examples
## @code
## bash_starter_plugin_list
## @endcode
bash_starter_plugin_list() {
  local name

  for name in "${BASH_STARTER_PLUGIN_NAMES[@]}"; do
    printf '%s\t%s\n' "${name}" "${BASH_STARTER_PLUGIN_DESCRIPTIONS[${name}]}"
  done
}

## @fn bash_starter_plugin_run()
## @brief Dispatches execution to a registered plugin by logical name.
## @details
## The dispatcher validates registry membership before performing an associative
## array lookup.  Bash treats an empty associative-array subscript as an error,
## so the explicit empty-name guard is part of the public invalid-input contract,
## not merely defensive decoration.  Valid calls invoke the registered function
## with all remaining arguments unchanged.
## @param name Logical plugin name.
## @param ... Arguments forwarded to the plugin implementation.
## @retval 0 The selected plugin completed successfully.
## @retval 69 No plugin with the requested name is registered.
## @par Examples
## @code
## bash_starter_plugin_run noop
## @endcode
bash_starter_plugin_run() {
  local name="${1:-}"
  local function_name

  shift || true
  if [[ -z "${name}" ]]; then
    printf '%s\n' 'unknown plugin: ' >&2
    return 69
  fi

  function_name="${BASH_STARTER_PLUGIN_FUNCTIONS[${name}]:-}"
  if [[ -z "${function_name}" ]]; then
    printf 'unknown plugin: %s\n' "${name}" >&2
    return 69
  fi

  "${function_name}" "$@"
}
