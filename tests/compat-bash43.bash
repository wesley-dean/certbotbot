#!/usr/bin/env bash
set -euo pipefail

: "${CERTBOTBOT_ARTIFACT:?CERTBOTBOT_ARTIFACT must identify the artifact under test}"

bash -n "${CERTBOTBOT_ARTIFACT}"
"${CERTBOTBOT_ARTIFACT}" --help >/dev/null
"${CERTBOTBOT_ARTIFACT}" version >/dev/null
"${CERTBOTBOT_ARTIFACT}" plugins | grep -F 'noop' >/dev/null
"${CERTBOTBOT_ARTIFACT}" run noop
