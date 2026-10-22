#!/usr/bin/env bash
set -euo pipefail

: "${BASH_STARTER_ARTIFACT:?BASH_STARTER_ARTIFACT must identify the artifact under test}"

bash -n "${BASH_STARTER_ARTIFACT}"
"${BASH_STARTER_ARTIFACT}" --help >/dev/null
"${BASH_STARTER_ARTIFACT}" --version >/dev/null

# The complete certificate lifecycle is not yet available in this draft.
# Preflight must fail explicitly rather than claim issuance succeeded.
if "${BASH_STARTER_ARTIFACT}" --s3-bucket fixture-bucket example.com >/dev/null 2>&1; then
  printf '%s\n' 'Unexpected successful certificate processing' >&2
  exit 1
fi
