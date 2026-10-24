#!/usr/bin/env bats

# Task #85 focused public-artifact tests. Task #86 owns the broader
# multi-page, destructive-failure and mixed-scope adversarial matrix.
setup() {
  : "${BASH_STARTER_ARTIFACT:?Artifact under test is required}"
  ROOT="$(mktemp -d)"
  mkdir -m 700 "$ROOT/bin" "$ROOT/state"
  export ROOT
  export RETENTION_MOCK_CALLS="$ROOT/aws-calls"
  export RETENTION_MOCK_MODE=normal
  export PATH="$ROOT/bin:$PATH"
  unset DOMAIN S3_KEY S3_KEY_TEMPLATE BACKUP_KEY_TEMPLATE
  unset DATED_BACKUP_ENABLED BACKUP_RETENTION_COUNT
  cat >"$ROOT/bin/aws" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == --no-cli-pager && "$2" == s3api ]] || exit 98
action="$3"
shift 3
if [[ "${1:-}" == --generate-cli-skeleton && "${2:-}" == input ]]; then
  case "$action" in
    delete-object) printf '%s\n' '{"IfMatch":""}'; exit 0 ;;
    list-objects-v2)
      printf '%s\n' '{"ContinuationToken":"","EncodingType":""}'
      exit 0
      ;;
    *) exit 99 ;;
  esac
fi
bucket='' key='' prefix='' match='' encode='' paginate=false
while (( $# )); do
  case "$1" in
    --bucket) bucket="$2"; shift 2 ;;
    --key) key="$2"; shift 2 ;;
    --prefix) prefix="$2"; shift 2 ;;
    --if-match) match="$2"; shift 2 ;;
    --encoding-type) encode="$2"; shift 2 ;;
    --no-paginate) paginate=true; shift ;;
    --continuation-token|--max-keys|--query|--output) shift 2 ;;
    *) exit 98 ;;
  esac
done
printf '%s|%s|%s|%s\n' "$action" "$bucket" "$key" "$match" >>"$RETENTION_MOCK_CALLS"
[[ "$bucket" == bucket ]] || exit 90
case "$action" in
  list-objects-v2)
    [[ "$prefix" == archive- && "$encode" == url &&
      "$paginate" == true ]] || exit 90
    case "$RETENTION_MOCK_MODE" in
      list-denied) exit 9 ;;
      list-malformed) printf 'not-a-safe-page\n' ;;
      duplicate)
        printf 'false|null|3|url|archive-|archive-20261020.tar.gz,archive-20261019.tar.gz,archive-20261019.tar.gz\n'
        ;;
      *) printf 'false|null|3|url|archive-|archive-20261020.tar.gz,archive-20261019.tar.gz,archive-20261018.tar.gz\n' ;;
    esac
    ;;
  head-object)
    [[ "$key" == archive-20261020.tar.gz ||
      "$key" == archive-20261019.tar.gz ||
      "$key" == archive-20261018.tar.gz ]] || exit 90
    if [[ -f "$ROOT/deleted-$key" ]]; then printf '(404)\n' >&2; exit 9; fi
    date="${key#archive-}"
    date="${date%.tar.gz}"
    etag="etag$date"
    schema=v1
    if [[ "$RETENTION_MOCK_MODE" == foreign &&
      "$date" == 20261019 ]]; then schema=foreign; fi
    if [[ "$date" == 20261020 ]]; then etag=todayetag; fi
    printf '"%s"\t101\t%s\t%s\t%s\ttar.gz\tnone\n' \
      "$etag" "$schema" "$date" "$RETENTION_MOCK_HASH"
    ;;
  delete-object)
    [[ "$key" == archive-20261018.tar.gz &&
      "$match" == '"etag20261018"' ]] || exit 90
    [[ "$RETENTION_MOCK_MODE" != delete-denied ]] || exit 9
    : >"$ROOT/deleted-$key"
    ;;
  head-bucket) ;;
  *) exit 90 ;;
esac
MOCK
  chmod 755 "$ROOT/bin/aws"
}
teardown() {
  rm -rf -- "$ROOT"
}

@test "default disabled retention does not call AWS during naming preflight" {
  run bash -c '
    source "$BASH_STARTER_ARTIFACT" --help >/dev/null || exit $?
    certbotbot_config_resolve --s3-bucket bucket example.com || exit $?
    certbotbot_identity_resolve || exit $?
    certbotbot_filename_resolve || exit $?
    certbotbot_retention_preflight || exit $?
    printf "%s" "$CERTBOTBOT_BACKUP_RETENTION_COUNT"
  '
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]
  [ ! -e "$RETENTION_MOCK_CALLS" ]
}

@test "noncanonical counts and retention without backup opt-in reject before AWS" {
  local value
  for value in '' 00 01 -1 +1 1.5 abc 10001 999999; do
    run bash -c '
      source "$BASH_STARTER_ARTIFACT" --help >/dev/null || exit $?
      certbotbot_config_resolve --s3-bucket bucket \
        --dated-backup-enabled true --backup-retention-count "$1" example.com
    ' _ "$value"
    [ "$status" -eq 64 ]
  done
  run "$BASH_STARTER_ARTIFACT" --s3-bucket bucket \
    --backup-retention-count 1 example.com
  [ "$status" -eq 64 ]
  [ ! -e "$RETENTION_MOCK_CALLS" ]
}

@test "retention refuses unsafe or unanchored naming even when publication permits it" {
  run bash -c '
    source "$BASH_STARTER_ARTIFACT" --help >/dev/null || exit $?
    date() { printf "20261020\n"; }
    certbotbot_config_resolve --s3-bucket bucket \
      --dated-backup-enabled true --backup-retention-count 2 \
      --backup-key-template "{YEAR}{MONTH}{DOM}.tar.gz" example.com || exit $?
    certbotbot_filename_resolve || exit $?
    certbotbot_retention_preflight
  '
  [ "$status" -eq 64 ]
  [ ! -e "$RETENTION_MOCK_CALLS" ]
}

@test "full protected listing and all HEAD checks precede one ETag-only old deletion" {
  run bash -c '
    source "$BASH_STARTER_ARTIFACT" --help >/dev/null || exit $?
    date() { printf "20261020\n"; }
    certbotbot_config_resolve --s3-bucket bucket \
      --dated-backup-enabled true --backup-retention-count 2 example.com || exit $?
    certbotbot_filename_resolve || exit $?
    certbotbot_retention_preflight || exit $?
    certbotbot_backup_scope "$CERTBOTBOT_S3_KEY" || exit $?
    export RETENTION_MOCK_HASH="$CERTBOTBOT_BACKUP_KEY_HASH"
    CERTBOTBOT_BACKUP_ETAG="\"todayetag\""
    CERTBOTBOT_S3_BACKUP_STATUS=confirmed
    CERTBOTBOT_S3_PUBLISHED=true
    certbotbot_retention_apply "$ROOT/state" bucket latest.tar.gz || exit $?
    printf "deleted=%s" "$CERTBOTBOT_RETENTION_DELETED"
  '
  [ "$status" -eq 0 ]
  [ "$output" = deleted=1 ]
  grep -Fxq 'delete-object|bucket|archive-20261018.tar.gz|"etag20261018"' \
    "$RETENTION_MOCK_CALLS"
  ! grep -Eq 'delete-object[|]bucket[|](latest.tar.gz|archive-20261020.tar.gz)' \
    "$RETENTION_MOCK_CALLS"
  [ "$(grep -c '^head-object|' "$RETENTION_MOCK_CALLS")" -eq 4 ]
}

@test "incomplete inventory rejects every deletion after confirmed publication" {
  export RETENTION_MOCK_MODE=list-malformed
  run bash -c '
    source "$BASH_STARTER_ARTIFACT" --help >/dev/null || exit $?
    date() { printf "20261020\n"; }
    certbotbot_config_resolve --s3-bucket bucket \
      --dated-backup-enabled true --backup-retention-count 1 example.com || exit $?
    certbotbot_filename_resolve || exit $?
    certbotbot_retention_preflight || exit $?
    certbotbot_backup_scope "$CERTBOTBOT_S3_KEY" || exit $?
    export RETENTION_MOCK_HASH="$CERTBOTBOT_BACKUP_KEY_HASH"
    CERTBOTBOT_BACKUP_ETAG="\"todayetag\""
    CERTBOTBOT_S3_BACKUP_STATUS=confirmed
    CERTBOTBOT_S3_PUBLISHED=true
    certbotbot_retention_apply "$ROOT/state" bucket latest.tar.gz
  '
  [ "$status" -eq 74 ]
  ! grep -q '^delete-object|' "$RETENTION_MOCK_CALLS"
}

@test "foreign metadata aborts all deletions before any mutation" {
  export RETENTION_MOCK_MODE=foreign
  run bash -c '
    source "$BASH_STARTER_ARTIFACT" --help >/dev/null || exit $?
    date() { printf "20261020\n"; }
    certbotbot_config_resolve --s3-bucket bucket \
      --dated-backup-enabled true --backup-retention-count 1 example.com || exit $?
    certbotbot_filename_resolve || exit $?
    certbotbot_retention_preflight || exit $?
    certbotbot_backup_scope "$CERTBOTBOT_S3_KEY" || exit $?
    export RETENTION_MOCK_HASH="$CERTBOTBOT_BACKUP_KEY_HASH"
    CERTBOTBOT_BACKUP_ETAG="\"todayetag\""
    CERTBOTBOT_S3_BACKUP_STATUS=confirmed
    CERTBOTBOT_S3_PUBLISHED=true
    certbotbot_retention_apply "$ROOT/state" bucket latest.tar.gz
  '
  [ "$status" -eq 74 ]
  ! grep -q '^delete-object|' "$RETENTION_MOCK_CALLS"
}
