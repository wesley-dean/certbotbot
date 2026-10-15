#!/usr/bin/env bash
set -euo pipefail

: "${BASH_STARTER_ARTIFACT:?BASH_STARTER_ARTIFACT must identify the artifact under test}"

bash -n "${BASH_STARTER_ARTIFACT}"
"${BASH_STARTER_ARTIFACT}" --help >/dev/null
"${BASH_STARTER_ARTIFACT}" version >/dev/null
"${BASH_STARTER_ARTIFACT}" plugins | grep -F 'noop' >/dev/null
"${BASH_STARTER_ARTIFACT}" run noop
