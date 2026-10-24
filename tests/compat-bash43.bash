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

# Exercise actual bundled mktext date rendering under the minimum Bash floor.
# An executable-only argument test would not cover nameref/context behavior.
source "$BASH_STARTER_ARTIFACT" --help >/dev/null
date() { printf '20261020\n'; }
certbotbot_config_resolve --s3-bucket fixture-bucket \
  --s3-key-template 'archive-{YEAR}{MONTH}{DOM}.tar.gz' \
  --backup-key-template 'recovery-{YEAR}{MONTH}{DOM}.tar.gz' \
  example.com
certbotbot_filename_resolve
if [[ "$CERTBOTBOT_S3_KEY" != archive-20261020.tar.gz ||
  "$CERTBOTBOT_BACKUP_KEY" != recovery-20261020.tar.gz ||
  "$CERTBOTBOT_FILENAME_DATE" != 20261020 ]]; then
  printf '%s\n' 'Bash 4.3 filename-template compatibility failed' >&2
  exit 1
fi
