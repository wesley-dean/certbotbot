# shellcheck shell=bash
## @file lib/plugins/noop.bash
## @brief Provides the reference no-operation plugin for the starter repository.
## @details
## This plugin exists for two reasons.  First, it gives the starter executable a
## harmless behavior that can prove plugin discovery, registration, dispatch,
## artifact assembly, and testing.  Second, it is a concrete template for future
## plugins: define a well-documented implementation function, then register that
## function through the core registry without modifying a central dispatcher.
##
## Derived projects may keep, rename, replace, or delete this plugin once their
## own extension points are established.

## @fn bash_starter_plugin_noop()
## @brief Completes successfully without producing output or changing state.
## @details
## The noop implementation intentionally ignores its arguments.  A real plugin
## should document and validate its own argument contract rather than relying on
## the registry dispatcher to interpret plugin-specific values.
## @param ... Arguments are accepted and intentionally ignored.
## @retval 0 Always.
## @par Examples
## @code
## bash_starter_plugin_noop
## @endcode
bash_starter_plugin_noop() {
  : "$@"
  return 0
}

bash_starter_plugin_register \
  "noop" \
  "bash_starter_plugin_noop" \
  "Reference plugin that performs no operation."
