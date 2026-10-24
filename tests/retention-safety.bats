#!/usr/bin/env bats

# ADR-034 black-box destructive boundary tests. Each standalone release
# artifact is sourced in a fresh Bash process. Fake AWS implements only
# exact-scoped ListObjectsV2, HeadObject and conditional DeleteObject.
# Test storage is private to Bats; no real S3/IAM/ACME requests occur.
setup() {
  : "${BASH_STARTER_ARTIFACT:?Built standalone artifact required}"
  ROOT="$(mktemp -d)"
  mkdir -m 700 "$ROOT/bin" "$ROOT/state" "$ROOT/objects"
  export ROOT
  export RETENTION_SAFETY_CALLS="$ROOT/calls"
  export RETENTION_SAFETY_MODE=normal
  export RETENTION_SAFETY_COUNT=2
  export RETENTION_SAFETY_TEMPLATE='archive-{YEAR}{MONTH}{DOM}.tar.gz'
  export RETENTION_SAFETY_CURRENT=latest.tar.gz
  export RETENTION_SAFETY_ENCRYPTION=none
  export RETENTION_SAFETY_PUBLISHED=true
  export RETENTION_SAFETY_BACKUP_STATUS=confirmed
  export PATH="$ROOT/bin:$PATH"
  unset BACKUP_RETENTION_COUNT DATED_BACKUP_ENABLED
  unset S3_KEY S3_KEY_TEMPLATE BACKUP_KEY_TEMPLATE S3_BUCKET
  local date
  for date in 20261020 20261019 20261018 20261017; do
    printf 'protected-fixture:%s\n' "$date" \
      >"$ROOT/objects/archive-$date.tar.gz"
  done
  for date in 20261020 20261019; do
    printf 'other-template:%s\n' "$date" \
      >"$ROOT/objects/renewal-$date.tar.gz"
  done
  printf 'latest must remain untouched\n' >"$ROOT/current-proof"

  cat >"$ROOT/bin/aws" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == --no-cli-pager && "$2" == s3api ]] || exit 98
action="$3"
shift 3
if [[ "${1:-}" == --generate-cli-skeleton && "${2:-}" == input ]]; then
  case "$action" in
    delete-object)
      [[ "$RETENTION_SAFETY_MODE" != no-delete-support ]] || exit 9
      printf '{"IfMatch":""}\n'
      exit 0 ;;
    list-objects-v2)
      [[ "$RETENTION_SAFETY_MODE" != no-list-support ]] || exit 9
      printf '{"ContinuationToken":"","EncodingType":""}\n'
      exit 0 ;;
    *) exit 98 ;;
  esac
fi
bucket='' key='' prefix='' token='' match='' encoding='' paginate=false
while (( $# )); do
  case "$1" in
    --bucket) bucket="$2"; shift 2 ;;
    --key) key="$2"; shift 2 ;;
    --prefix) prefix="$2"; shift 2 ;;
    --continuation-token) token="$2"; shift 2 ;;
    --if-match) match="$2"; shift 2 ;;
    --encoding-type) encoding="$2"; shift 2 ;;
    --no-paginate) paginate=true; shift ;;
    --max-keys|--query|--output) shift 2 ;;
    *) exit 98 ;;
  esac
done
[[ "$bucket" == fixture-bucket ]] || exit 98
printf '%s|%s|%s|%s|%s\n' \
  "$action" "$prefix" "$key" "$token" "$match" >>"$RETENTION_SAFETY_CALLS"
case "$action" in
  list-objects-v2)
    [[ "$encoding" == url && "$paginate" == true ]] || exit 98
    case "$prefix" in archive-|renewal-) ;; *) exit 98 ;; esac
    case "$RETENTION_SAFETY_MODE" in
      list-denied) exit 9 ;;
      list-malformed) printf 'unknown-response\n'; exit 0 ;;
      list-count-mismatch)
        printf 'false|null|2|url|archive-|archive-20261020.tar.gz\n'
        exit 0 ;;
      list-duplicate)
        printf 'false|null|3|url|archive-|archive-20261020.tar.gz,archive-20261019.tar.gz,archive-20261019.tar.gz\n'
        exit 0 ;;
      list-unsafe-key)
        printf 'false|null|2|url|archive-|archive-20261020.tar.gz,archive-%%2Fprivate.tar.gz\n'
        exit 0 ;;
      list-future-date)
        printf 'false|null|2|url|archive-|archive-20261020.tar.gz,archive-20261021.tar.gz\n'
        exit 0 ;;
      list-invalid-date)
        printf 'false|null|2|url|archive-|archive-20261020.tar.gz,archive-20260230.tar.gz\n'
        exit 0 ;;
      list-no-new-backup)
        printf 'false|null|2|url|archive-|archive-20261019.tar.gz,archive-20261018.tar.gz\n'
        exit 0 ;;
      list-truncated-no-token)
        printf 'true|null|2|url|archive-|archive-20261020.tar.gz,archive-20261019.tar.gz\n'
        exit 0 ;;
      list-repeated-token)
        printf 'true|NEXT|2|url|archive-|archive-20261020.tar.gz,archive-20261019.tar.gz\n'
        exit 0 ;;
      list-second-page-denied)
        [[ -z "$token" ]] || exit 9
        printf 'true|NEXT|2|url|archive-|archive-20261020.tar.gz,archive-20261019.tar.gz\n'
        exit 0 ;;
      list-wrong-prefix)
        printf 'false|null|1|url|other-|archive-20261020.tar.gz\n'
        exit 0 ;;
      list-overlong)
        printf 'false|null|99999|url|archive-|\n'
        exit 0 ;;
      *)
        if [[ "$prefix" == renewal- ]]; then
          printf 'false|null|2|url|renewal-|renewal-20261020.tar.gz,renewal-20261019.tar.gz\n'
          exit 0
        fi
        if [[ "$RETENTION_SAFETY_MODE" == list-two-pages ||
          "$RETENTION_SAFETY_MODE" == list-two-pages-with-unrelated ]]; then
          if [[ -z "$token" ]]; then
            printf 'true|NEXT|2|url|archive-|archive-20261020.tar.gz,archive-20261019.tar.gz\n'
          elif [[ "$token" == NEXT ]]; then
            if [[ "$RETENTION_SAFETY_MODE" == list-two-pages-with-unrelated ]]; then
              printf 'false|null|3|url|archive-|archive-20261018.tar.gz,archive-20261017.tar.gz,archive-notes.txt\n'
            else
              printf 'false|null|2|url|archive-|archive-20261018.tar.gz,archive-20261017.tar.gz\n'
            fi
          else
            exit 9
          fi
          exit 0
        fi
        printf 'false|null|4|url|archive-|archive-20261020.tar.gz,archive-20261019.tar.gz,archive-20261018.tar.gz,archive-20261017.tar.gz\n'
        ;;
    esac
    ;;
  head-object)
    [[ -f "$ROOT/objects/$key" ]] || {
      printf 'An error occurred (404) when calling the HeadObject operation\n' >&2
      exit 9
    }
    if [[ "$RETENTION_SAFETY_MODE" == head-denied &&
      "$key" == archive-20261018.tar.gz ]]; then
      printf 'AccessDenied\n' >&2
      exit 9
    fi
    if [[ "$RETENTION_SAFETY_MODE" == head-post-denied &&
      -f "$ROOT/deleted-marker-$key" ]]; then
      printf 'AccessDenied\n' >&2
      exit 9
    fi
    date="$key"
    date="${date#*-}"
    date="${date%.tar.gz}"
    schema=v1
    identity="$RETENTION_SAFETY_HASH"
    archive_format=tar.gz
    encryption="$RETENTION_SAFETY_ENCRYPTION"
    size=101
    etag="etag$date"
    [[ "$date" != 20261020 ]] || etag=todayetag
    if [[ "$RETENTION_SAFETY_MODE" == foreign-schema &&
      "$date" == 20261019 ]]; then schema=foreign; fi
    if [[ "$RETENTION_SAFETY_MODE" == foreign-current-key &&
      "$date" == 20261019 ]]; then identity=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff; fi
    if [[ "$RETENTION_SAFETY_MODE" == foreign-format &&
      "$date" == 20261019 ]]; then archive_format=zip; fi
    if [[ "$RETENTION_SAFETY_MODE" == foreign-encryption &&
      "$date" == 20261019 ]]; then encryption=gpg-ocb; fi
    if [[ "$RETENTION_SAFETY_MODE" == invalid-size &&
      "$date" == 20261019 ]]; then size=0; fi
    if [[ "$RETENTION_SAFETY_MODE" == fresh-etag-changed &&
      "$date" == 20261020 ]]; then etag=changedetag; fi
    if [[ "$RETENTION_SAFETY_MODE" == invalid-etag &&
      "$date" == 20261019 ]]; then etag='unsafe*'; fi
    if [[ "$RETENTION_SAFETY_MODE" == head-post-present &&
      -f "$ROOT/deleted-marker-$key" ]]; then etag=etag$date; fi
    printf '"%s"\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$etag" "$size" "$schema" "$date" "$identity" \
      "$archive_format" "$encryption"
    ;;
  head-bucket)
    [[ "$RETENTION_SAFETY_MODE" != head-bucket-denied ]] || exit 9
    ;;
  delete-object)
    [[ -n "$key" && -f "$ROOT/objects/$key" ]] || exit 9
    [[ "$key" != latest.tar.gz &&
      "$key" != archive-20261020.tar.gz &&
      "$match" != '*' && -n "$match" ]] || exit 9
    date="$key"
    date="${date#*-}"
    date="${date%.tar.gz}"
    [[ "$match" == "\"etag$date\"" ]] || exit 9
    case "$RETENTION_SAFETY_MODE" in
      delete-conflict) exit 9 ;;
      delete-uncertain)
        rm -f -- "$ROOT/objects/$key"
        : >"$ROOT/deleted-marker-$key"
        exit 9 ;;
      partial-delete-failure)
        if [[ "$key" != archive-20261017.tar.gz ]]; then exit 9; fi ;;
    esac
    : >"$ROOT/deleted-marker-$key"
    [[ "$RETENTION_SAFETY_MODE" == head-post-present ]] ||
      rm -f -- "$ROOT/objects/$key"
    ;;
  *)
    exit 98 ;;
esac
MOCK
  chmod 755 "$ROOT/bin/aws"
}

teardown() {
  rm -rf -- "$ROOT"
}

run_retention_safety() {
  run bash -c '
    source "$BASH_STARTER_ARTIFACT" --help >/dev/null || exit $?
    date() { printf "20261020\n"; }
    local_args=(--s3-bucket fixture-bucket --s3-key "$RETENTION_SAFETY_CURRENT"
      --dated-backup-enabled true
      --backup-retention-count "$RETENTION_SAFETY_COUNT")
    local_args+=(--backup-key-template "$RETENTION_SAFETY_TEMPLATE")
    certbotbot_config_resolve "${local_args[@]}" example.com || exit $?
    certbotbot_filename_resolve || exit $?
    certbotbot_retention_preflight || exit $?
    CERTBOTBOT_ARCHIVE_ENCRYPTION="$RETENTION_SAFETY_ENCRYPTION"
    certbotbot_backup_scope "$CERTBOTBOT_S3_KEY" || exit $?
    export RETENTION_SAFETY_HASH="$CERTBOTBOT_BACKUP_KEY_HASH"
    CERTBOTBOT_BACKUP_ETAG="\"todayetag\""
    CERTBOTBOT_S3_PUBLISHED="$RETENTION_SAFETY_PUBLISHED"
    CERTBOTBOT_S3_BACKUP_STATUS="$RETENTION_SAFETY_BACKUP_STATUS"
    rc=0
    certbotbot_retention_apply "$ROOT/state" fixture-bucket \
      "$CERTBOTBOT_S3_KEY" || rc=$?
    printf "deleted=%s\n" "$CERTBOTBOT_RETENTION_DELETED"
    exit "$rc"
  '
}

assert_no_deletion() {
  if [[ -f "$RETENTION_SAFETY_CALLS" ]]; then
    ! grep -q '^delete-object|' "$RETENTION_SAFETY_CALLS"
  fi
  [ -f "$ROOT/objects/archive-20261020.tar.gz" ]
  [ -f "$ROOT/objects/archive-20261019.tar.gz" ]
  [ -f "$ROOT/objects/archive-20261018.tar.gz" ]
  [ -f "$ROOT/objects/archive-20261017.tar.gz" ]
  [ -f "$ROOT/current-proof" ]
}

@test "complete paginated list HEADs all candidates before deleting exactly oldest two" {
  export RETENTION_SAFETY_MODE=list-two-pages
  run_retention_safety
  [ "$status" -eq 0 ]
  [ "$output" = deleted=2 ]
  [ "$(grep -c '^list-objects-v2|' "$RETENTION_SAFETY_CALLS")" -eq 2 ]
  [ "$(grep -c '^head-object|' "$RETENTION_SAFETY_CALLS")" -eq 6 ]
  [ "$(grep -c '^delete-object|' "$RETENTION_SAFETY_CALLS")" -eq 2 ]
  [ -f "$ROOT/objects/archive-20261020.tar.gz" ]
  [ -f "$ROOT/objects/archive-20261019.tar.gz" ]
  [ ! -e "$ROOT/objects/archive-20261018.tar.gz" ]
  [ ! -e "$ROOT/objects/archive-20261017.tar.gz" ]
  [ -f "$ROOT/current-proof" ]
  local heads_last delete_first
  heads_last="$(grep -n '^head-object|' "$RETENTION_SAFETY_CALLS" | head -n 4 | tail -n 1)"
  delete_first="$(grep -n '^delete-object|' "$RETENTION_SAFETY_CALLS" | head -n 1)"
  [ "${heads_last%%:*}" -lt "${delete_first%%:*}" ]
  [ "$(grep '^delete-object|' "$RETENTION_SAFETY_CALLS" | sed -n '1p' | cut -d'|' -f3)" = archive-20261017.tar.gz ]
}

@test "unrelated nonmatching object under the anchored prefix does not consume retention" {
  export RETENTION_SAFETY_MODE=list-two-pages-with-unrelated
  run_retention_safety
  [ "$status" -eq 0 ]
  [ "$output" = deleted=2 ]
  ! grep -q 'head-object||archive-notes.txt' "$RETENTION_SAFETY_CALLS"
  ! grep -q 'delete-object||archive-notes.txt' "$RETENTION_SAFETY_CALLS"
}

@test "keep count equal to candidate count means no deletion" {
  export RETENTION_SAFETY_COUNT=4
  run_retention_safety
  [ "$status" -eq 0 ]
  [ "$output" = deleted=0 ]
  assert_no_deletion
}

@test "keep count above candidate count preserves all eligible objects" {
  export RETENTION_SAFETY_COUNT=5
  run_retention_safety
  [ "$status" -eq 0 ]
  [ "$output" = deleted=0 ]
  assert_no_deletion
}

@test "switching dated template scopes cleanup without adopting old template" {
  export RETENTION_SAFETY_COUNT=1
  export RETENTION_SAFETY_TEMPLATE='renewal-{YEAR}{MONTH}{DOM}.tar.gz'
  run_retention_safety
  [ "$status" -eq 0 ]
  [ "$output" = deleted=1 ]
  [ -f "$ROOT/objects/archive-20261017.tar.gz" ]
  [ -f "$ROOT/objects/renewal-20261020.tar.gz" ]
  [ ! -e "$ROOT/objects/renewal-20261019.tar.gz" ]
  ! grep -q '^delete-object||archive-' "$RETENTION_SAFETY_CALLS"
}

@test "denied listing aborts with zero HEADs and zero deletes" {
  export RETENTION_SAFETY_MODE=list-denied
  run_retention_safety
  [ "$status" -eq 74 ]
  [ "$output" != deleted=0 ]
  assert_no_deletion
  ! grep -q '^head-object|' "$RETENTION_SAFETY_CALLS"
}

@test "malformed listing aborts without speculative deletions" {
  export RETENTION_SAFETY_MODE=list-malformed
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
}

@test "incomplete reported KeyCount aborts before any HEAD or DELETE" {
  export RETENTION_SAFETY_MODE=list-count-mismatch
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
  ! grep -q '^head-object|' "$RETENTION_SAFETY_CALLS"
}

@test "duplicate listed key aborts with no deletions" {
  export RETENTION_SAFETY_MODE=list-duplicate
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
}

@test "escaped unsafe key in scoped enumeration fails closed" {
  export RETENTION_SAFETY_MODE=list-unsafe-key
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
}

@test "future-dated matching key fails before any deletion" {
  export RETENTION_SAFETY_MODE=list-future-date
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
}

@test "impossible Gregorian date fails before any deletion" {
  export RETENTION_SAFETY_MODE=list-invalid-date
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
}

@test "missing newly confirmed recovery copy makes all deletion ineligible" {
  export RETENTION_SAFETY_MODE=list-no-new-backup
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
}

@test "truncated page without continuation token fails closed" {
  export RETENTION_SAFETY_MODE=list-truncated-no-token
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
}

@test "repeated continuation token aborts before any delete" {
  export RETENTION_SAFETY_MODE=list-repeated-token
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
}

@test "denied second page never deletes from partial listing" {
  export RETENTION_SAFETY_MODE=list-second-page-denied
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
}

@test "mismatched returned Prefix fails closed" {
  export RETENTION_SAFETY_MODE=list-wrong-prefix
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
}

@test "out-of-bounds page size refuses incomplete listing" {
  export RETENTION_SAFETY_MODE=list-overlong
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
}

@test "unverified matching v1 schema aborts entire retention" {
  export RETENTION_SAFETY_MODE=foreign-schema
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
}

@test "foreign current key digest aborts all destructive activity" {
  export RETENTION_SAFETY_MODE=foreign-current-key
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
}

@test "mixed archive format aborts instead of deleting other objects" {
  export RETENTION_SAFETY_MODE=foreign-format
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
}

@test "mixed encryption mode aborts instead of adopting foreign copy" {
  export RETENTION_SAFETY_MODE=foreign-encryption
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
}

@test "zero byte matching object aborts before deletion" {
  export RETENTION_SAFETY_MODE=invalid-size
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
}

@test "invalid ETag aborts before destructive operation" {
  export RETENTION_SAFETY_MODE=invalid-etag
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
}

@test "changed ETag of just published backup prevents deletion" {
  export RETENTION_SAFETY_MODE=fresh-etag-changed
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
}

@test "HEAD denial of any candidate aborts whole deletion plan" {
  export RETENTION_SAFETY_MODE=head-denied
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
}

@test "failed backup publication blocks inventory access entirely" {
  export RETENTION_SAFETY_BACKUP_STATUS=failed
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
  [ ! -e "$RETENTION_SAFETY_CALLS" ]
}

@test "unconfirmed backup publication blocks inventory access" {
  export RETENTION_SAFETY_BACKUP_STATUS=pending
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
  [ ! -e "$RETENTION_SAFETY_CALLS" ]
}

@test "failed current publication blocks inventory access" {
  export RETENTION_SAFETY_PUBLISHED=false
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
  [ ! -e "$RETENTION_SAFETY_CALLS" ]
}

@test "conditional delete conflict stops without unconditional fallback" {
  export RETENTION_SAFETY_MODE=delete-conflict
  run_retention_safety
  [ "$status" -eq 74 ]
  assert_no_deletion
  [ "$(grep -c '^delete-object|' "$RETENTION_SAFETY_CALLS")" -eq 1 ]
  ! grep -q 'delete-object||||[*]' "$RETENTION_SAFETY_CALLS"
}

@test "lost DeleteObject response is uncertain and never retried" {
  export RETENTION_SAFETY_MODE=delete-uncertain
  run_retention_safety
  [ "$status" -eq 74 ]
  [ ! -e "$ROOT/objects/archive-20261017.tar.gz" ]
  [ -f "$ROOT/objects/archive-20261018.tar.gz" ]
  [ -f "$ROOT/objects/archive-20261020.tar.gz" ]
  [ "$(grep -c '^delete-object|' "$RETENTION_SAFETY_CALLS")" -eq 1 ]
}

@test "accepted delete with object still visible stops all later deletes" {
  export RETENTION_SAFETY_MODE=head-post-present
  run_retention_safety
  [ "$status" -eq 74 ]
  [ -f "$ROOT/objects/archive-20261017.tar.gz" ]
  [ -f "$ROOT/objects/archive-20261018.tar.gz" ]
  [ "$(grep -c '^delete-object|' "$RETENTION_SAFETY_CALLS")" -eq 1 ]
}

@test "accepted deletion followed by inaccessible confirmation stops further deletes" {
  export RETENTION_SAFETY_MODE=head-post-denied
  run_retention_safety
  [ "$status" -eq 74 ]
  [ ! -e "$ROOT/objects/archive-20261017.tar.gz" ]
  [ -f "$ROOT/objects/archive-20261018.tar.gz" ]
  [ "$(grep -c '^delete-object|' "$RETENTION_SAFETY_CALLS")" -eq 1 ]
}

@test "partial cleanup preserves all newer copies after second deletion failure" {
  export RETENTION_SAFETY_MODE=partial-delete-failure
  run_retention_safety
  [ "$status" -eq 74 ]
  [[ "$output" == *'deleted=1'* ]]
  [ ! -e "$ROOT/objects/archive-20261017.tar.gz" ]
  [ -f "$ROOT/objects/archive-20261018.tar.gz" ]
  [ -f "$ROOT/objects/archive-20261019.tar.gz" ]
  [ -f "$ROOT/objects/archive-20261020.tar.gz" ]
  [ -f "$ROOT/current-proof" ]
  [ "$(grep -c '^delete-object|' "$RETENTION_SAFETY_CALLS")" -eq 2 ]
}
