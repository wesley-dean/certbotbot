#!/usr/bin/env bash
set -euo pipefail

: "${CERTBOTBOT_ARTIFACT:?CERTBOTBOT_ARTIFACT must identify the artifact under test}"

bash -n "${CERTBOTBOT_ARTIFACT}"
"${CERTBOTBOT_ARTIFACT}" --help >/dev/null
"${CERTBOTBOT_ARTIFACT}" --version >/dev/null
"${CERTBOTBOT_ARTIFACT}" --validate foo.com www.foo.com |
  grep -F -- 'foo.com *.foo.com www.foo.com' >/dev/null

if "${CERTBOTBOT_ARTIFACT}" foo.com >/dev/null 2>&1; then
  printf '%s\n' 'unimplemented certificate issuance unexpectedly succeeded' >&2
  exit 1
else
  [[ "$?" -eq 69 ]]
fi
