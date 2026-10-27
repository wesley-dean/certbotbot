#!/usr/bin/env bash
# shellcheck shell=bash
## @file tests/helpers/lifecycle-fixture.bash
## @brief Construct a synthetic local ACME/S3/Certbot acceptance environment.
## @details
## Shared by the existing public-lifecycle Bats suite and the offline OCI
## producer tests.  Only synthetic account material and locally generated
## self-signed certificates are present.  Mock AWS rejects unrelated requests
## and records remote writes; no live DNS, S3, or issuer endpoint is contacted.
## @fn lifecycle_fixture_setup()
## @brief Prepare the synthetic S3 archive and mock executable boundaries.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Diagnostics from local fixture creation or tar.
## @retval 0 Local synthetic fixture was prepared.
## @note Nonzero statuses from required shell tools may propagate.

lifecycle_fixture_setup() {
  : "${BASH_STARTER_ARTIFACT:?Built artifact required}"
  ROOT="$(mktemp -d)"
  mkdir -m 700 "$ROOT/bin" "$ROOT/seed"
  mkdir -p "$ROOT/seed/accounts/acme-v02.api.letsencrypt.org/directory/account-id"
  printf '{"seed":"private"}\n' > "$ROOT/seed/accounts/acme-v02.api.letsencrypt.org/directory/account-id/private_key.json"
  printf '{"seed":"reg"}\n' > "$ROOT/seed/accounts/acme-v02.api.letsencrypt.org/directory/account-id/regr.json"
  printf '{"seed":"meta"}\n' > "$ROOT/seed/accounts/acme-v02.api.letsencrypt.org/directory/account-id/meta.json"
  chmod 600 "$ROOT/seed/accounts/acme-v02.api.letsencrypt.org/directory/account-id/"*.json
  tar -czf "$ROOT/remote.tar.gz" -C "$ROOT/seed" .
  export LIFECYCLE_REMOTE="$ROOT/remote.tar.gz"
  export LIFECYCLE_CALLS="$ROOT/calls"
  export LIFECYCLE_CONTEXTS="$ROOT/certbot-contexts"
  export LIFECYCLE_MODE=ok
  # Only task #59 tests enable registration-aware Certbot/S3 mock behavior.
  export LIFECYCLE_REGISTRATION_MOCK=false
  export LIFECYCLE_EXPECTED_KEY=latest.tar.gz
  export LIFECYCLE_BACKUP_KEY=archive-20261020.tar.gz
  export LIFECYCLE_BACKUP_REMOTE="$ROOT/dated-backup.tar.gz"
  export LIFECYCLE_BACKUP_META="$ROOT/dated-backup.meta"
  export LIFECYCLE_BACKUP_ENABLED_MOCK=false
  export LIFECYCLE_EXPECTED_CERT_NAME=example.com
  mkdir -m 700 "$ROOT/runner-temp"
  cat >"$ROOT/bin/aws" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == --no-cli-pager && "$2" == s3api ]] || exit 99
action="$3"
shift 3
if [[ "$action" == put-object && "${1:-}" == --generate-cli-skeleton &&
  "${2:-}" == input ]]; then
  printf '%s\n' '{"IfMatch":"","IfNoneMatch":""}'
  exit 0
fi
if [[ -n "${GPG_SYMMETRIC_KEY+x}" ||
  -n "${CERTBOTBOT_GPG_SECRET+x}" ]]; then
  printf '%s\n' 'aws:secret-inherited' >>"$LIFECYCLE_CALLS"
  exit 97
fi
bucket='' key='' body='' target='' metadata='' match='' none='' query=''
while (( $# )); do
  case "$1" in
    --bucket) bucket="$2"; shift 2 ;;
    --key) key="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --metadata) metadata="$2"; shift 2 ;;
    --if-match) match="$2"; shift 2 ;;
    --if-none-match) none="$2"; shift 2 ;;
    --query) query="$2"; shift 2 ;;
    --checksum-algorithm|--content-type|--output) shift 2 ;;
    *) target="$1"; shift ;;
  esac
done
printf 'aws:%s:%s:%s\n' "$action" "$bucket" "$key" >>"$LIFECYCLE_CALLS"
[[ "$bucket" == fixture-bucket ]] || exit 99
# HeadBucket is bucket-scoped and must not carry an object key.
[[ "$action" == head-bucket || "$key" == "$LIFECYCLE_EXPECTED_KEY" ||
  ( "$LIFECYCLE_BACKUP_ENABLED_MOCK" == true &&
    "$key" == "$LIFECYCLE_BACKUP_KEY" ) ]] || exit 99
if [[ "$key" == "$LIFECYCLE_BACKUP_KEY" &&
  "$LIFECYCLE_BACKUP_ENABLED_MOCK" == true ]]; then
  case "$action" in
    head-object)
      printf 'backup-head-state:remote=%s:meta=%s\n' \
        "$(test -f "$LIFECYCLE_BACKUP_REMOTE" && echo yes || echo no)" \
        "$(test -f "$LIFECYCLE_BACKUP_META" && echo yes || echo no)" >>"$LIFECYCLE_CALLS"
      [[ "${LIFECYCLE_BACKUP_MODE:-}" != head-failure ]] || exit 9
      if [[ "${LIFECYCLE_BACKUP_MODE:-}" == confirm-failure &&
        -f "$LIFECYCLE_BACKUP_REMOTE" ]]; then exit 9; fi
      [[ -f "$LIFECYCLE_BACKUP_REMOTE" ]] ||
        { printf '(404)\n' >&2; exit 9; }
      [[ -f "$LIFECYCLE_BACKUP_META" ]] || exit 9
      size="$(stat -c %s -- "$LIFECYCLE_BACKUP_REMOTE")" || exit 9
      # Preserve the exact five-tab-field v1 metadata fixture unchanged.
      printf '"backupetag01"\t%s\t' "$size"
      cat -- "$LIFECYCLE_BACKUP_META" || exit 9
      exit 0
      ;;
    get-object)
      [[ -f "$LIFECYCLE_BACKUP_REMOTE" && -n "$target" &&
        ! -e "$target" ]] || exit 9
      cp -- "$LIFECYCLE_BACKUP_REMOTE" "$target" || exit 9
      exit 0
      ;;
    put-object)
      if [[ "${LIFECYCLE_BACKUP_MODE:-}" == put-failure ]]; then exit 9; fi
      if [[ -f "$LIFECYCLE_BACKUP_REMOTE" ]]; then
        [[ "$match" == '"backupetag01"' && -z "$none" ]] || exit 9
      else
        [[ "$none" == '*' && -z "$match" ]] || exit 9
      fi
      [[ -n "$metadata" ]] || exit 9
      IFS=, read -r schema utc hash format encryption <<< "$metadata"
      printf '%s\t%s\t%s\t%s\t%s\n' \
        "${schema#*=}" "${utc#*=}" "${hash#*=}" \
        "${format#*=}" "${encryption#*=}" > "$LIFECYCLE_BACKUP_META"
      cp -- "$body" "$LIFECYCLE_BACKUP_REMOTE" || exit 9
      [[ "${LIFECYCLE_BACKUP_MODE:-}" != lost-response ]] || exit 9
      exit 0
      ;;
    *) exit 99 ;;
  esac
fi
case "$action" in
  head-object)
    case "$LIFECYCLE_MODE" in
      head-failure) exit 9 ;;
      head-denied)
        printf '%s\n' 'An error occurred (403), private-token-DO-NOT-LOG' >&2
        exit 9
        ;;
      head-service)
        printf '%s\n' 'An error occurred (500)' >&2
        exit 9
        ;;
      head-transport)
        printf '%s\n' 'Connect timeout on endpoint URL' >&2
        exit 9
        ;;
      head-ambiguous-missing)
        printf '%s\n' 'An error occurred (404)' >&2
        exit 9
        ;;
    esac
    [[ -f "$LIFECYCLE_REMOTE" ]] || { printf '(404)\n' >&2; exit 1; }
    if [[ "$LIFECYCLE_REGISTRATION_MOCK" == true &&
      "$query" == ETag ]]; then
      printf '%s\n' '"0123456789abcdef0123456789abcdef"'
    fi
    ;;
  get-object)
    if [[ "${LIFECYCLE_REGISTER_CALL:-false}" == true &&
      "$match" != 0123456789abcdef0123456789abcdef ]]; then
      exit 9
    fi
    case "$LIFECYCLE_MODE" in
      get-failure) exit 9 ;;
      get-partial)
        printf '%s\n' 'incomplete local download' >"$target"
        exit 9
        ;;
      get-empty)
        : >"$target"
        exit 0
        ;;
      get-corrupt)
        printf '%s\n' 'corrupt gzip data, not an archive' >"$target"
        exit 0
        ;;
    esac
    cp "$LIFECYCLE_REMOTE" "$target" || exit 9
    ;;
  put-object)
    # Permit a successful local Certbot operation with an independent remote
    # failure, including acceptance followed by a lost response.
    put_mode="${LIFECYCLE_PUT_MODE:-$LIFECYCLE_MODE}"
    if [[ "${LIFECYCLE_REGISTER_CALL:-false}" == true ]]; then
      if [[ -f "$LIFECYCLE_REMOTE" ]]; then
        [[ "$match" == 0123456789abcdef0123456789abcdef &&
          -z "$none" ]] || exit 9
      else
        [[ "$none" == '*' && -z "$match" ]] || exit 9
      fi
      [[ "$put_mode" != conditional-conflict ]] || exit 9
    fi
    if [[ "$put_mode" == put-failure ]]; then
      printf '%s\n' 'AWS failure mock-private-PUT-TOKEN' >&2
      exit 9
    fi
    cp "$body" "$LIFECYCLE_REMOTE" || exit 9
    # A lost response cannot prove whether S3 accepted the put.
    if [[ "$put_mode" == put-after-write-failure ]]; then
      printf '%s\n' 'AWS lost-response mock-private-PUT-TOKEN' >&2
      exit 9
    fi
    exit 0
    ;;
  head-bucket)
    [[ "$LIFECYCLE_MODE" == head-ambiguous-missing ]] && exit 9
    exit 0
    ;;
  *) exit 99 ;;
esac
MOCK
  cat >"$ROOT/bin/certbot" <<'MOCK'
#!/usr/bin/env bash
verb="$1"
shift
# Registration's account probe supplies global options before show_account.
if [[ "${LIFECYCLE_REGISTRATION_MOCK:-false}" == true &&
  "$verb" == --config-dir ]]; then
  set -- --config-dir "$@"
  verb=show_account
fi
if [[ -n "${GPG_SYMMETRIC_KEY+x}" ||
  -n "${CERTBOTBOT_GPG_SECRET+x}" ]]; then
  printf '%s\n' 'certbot:secret-inherited' >>"$LIFECYCLE_CALLS"
  exit 97
fi
printf 'certbot:%s\n' "$verb" >>"$LIFECYCLE_CALLS"
config='' work='' logs='' name='' account='' reconcile=false
sanext='' contact='' server=''
while (( $# )); do
  case "$1" in
    --config-dir) config="$2"; shift 2 ;;
    --work-dir) work="$2"; shift 2 ;;
    --logs-dir) logs="$2"; shift 2 ;;
    --cert-name) name="$2"; shift 2 ;;
    --account) account="$2"; shift 2 ;;
    --email) contact="$2"; shift 2 ;;
    --server) server="$2"; shift 2 ;;
    -d) sanext+="${sanext:+,}DNS:$2"; shift 2 ;;
    --renew-with-new-domains) reconcile=true; shift ;;
    *) shift ;;
  esac
done
printf 'certbot-context:%s:%s:%s:%s:%s:%s\n' \
  "$verb" "$config" "$work" "$logs" "$name" "$account" \
  >>"$LIFECYCLE_CONTEXTS"
printf 'certbot-sans:%s:%s\n' "$verb" "$sanext" \
  >>"$LIFECYCLE_CONTEXTS"
if [[ "$reconcile" == true ]]; then
  printf 'certbot-reconcile:%s\n' "$name" >>"$LIFECYCLE_CONTEXTS"
fi
case "$verb" in
  plugins) printf '* dns-route53\n' ;;
  show_account)
    [[ "$account" == account-id ]] || exit 91
    if [[ "${LIFECYCLE_REGISTER_CALL:-false}" == true ]]; then
      case "$server" in
        https://acme-v02.api.letsencrypt.org/directory)
          host=acme-v02.api.letsencrypt.org ;;
        https://acme-staging-v02.api.letsencrypt.org/directory)
          host=acme-staging-v02.api.letsencrypt.org ;;
        *) exit 91 ;;
      esac
      [[ -f "$config/accounts/$host/directory/account-id/regr.json" ]] ||
        exit 91
    fi
    ;;
  register)
    [[ "${LIFECYCLE_REGISTER_CALL:-false}" == true &&
      "${LIFECYCLE_REGISTRATION_MOCK:-false}" == true ]] || exit 98
    [[ "$LIFECYCLE_MODE" != register-failure ]] || exit 9
    [[ "$contact" == operator@example.org ]] || exit 91
    case "$server" in
      https://acme-v02.api.letsencrypt.org/directory)
        host=acme-v02.api.letsencrypt.org ;;
      https://acme-staging-v02.api.letsencrypt.org/directory)
        host=acme-staging-v02.api.letsencrypt.org ;;
      *) exit 91 ;;
    esac
    location="$config/accounts/$host/directory/account-id"
    mkdir -p -- "$location" || exit 92
    chmod 700 "$config/accounts" "$config/accounts/$host" \\
      "$config/accounts/$host/directory" "$location" || exit 92
    printf '%s\\n' '{"key":"synthetic-private-DO-NOT-LOG"}' \\
      >"$location/private_key.json" || exit 92
    printf '%s\\n' '{"body":{"contact":["mailto:operator@example.org"]}}' \\
      >"$location/regr.json" || exit 92
    printf '%s\\n' '{"creation":"synthetic"}' \\
      >"$location/meta.json" || exit 92
    chmod 600 "$location/"*.json || exit 92
    [[ "$LIFECYCLE_MODE" != register-partial-failure ]] || exit 9
    ;;
  certonly)
    [[ "$LIFECYCLE_MODE" == certbot-failure ]] && exit 9
    [[ "$account" == account-id &&
      "$name" == "$LIFECYCLE_EXPECTED_CERT_NAME" ]] || exit 91
    mkdir -p "$config/archive/$name" "$config/live/$name" "$config/renewal"
    [[ -n "$sanext" ]] || exit 92
    # Simulate a provider that succeeds but issues a different SAN set.
    if [[ "$LIFECYCLE_MODE" == reconcile-wrong-sans &&
      "$reconcile" == true ]]; then
      sanext='DNS:example.com,DNS:unrequested.other.net'
    fi
    if [[ "$reconcile" == true ]]; then
      # Reconciliation reuses the original lineage key and path links.
      [[ -f "$config/archive/$name/privkey1.pem" ]] || exit 92
      openssl req -x509 -new -days 4 -subj '/CN=example.com' \
        -key "$config/archive/$name/privkey1.pem" \
        -addext "subjectAltName=$sanext" \
        -out "$config/archive/$name/cert1.pem" >/dev/null 2>&1 || exit 92
    else
      openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
        -subj '/CN=example.com' -addext "subjectAltName=$sanext" \
        -keyout "$config/archive/$name/privkey1.pem" \
        -out "$config/archive/$name/cert1.pem" >/dev/null 2>&1 || exit 92
      chmod 600 "$config/archive/$name/privkey1.pem"
    fi
    cp "$config/archive/$name/cert1.pem" "$config/archive/$name/chain1.pem"
    cp "$config/archive/$name/cert1.pem" "$config/archive/$name/fullchain1.pem"
    if [[ "$LIFECYCLE_MODE" == bad-fullchain ]]; then
      printf '%s\n' 'not a certificate' >"$config/archive/$name/fullchain1.pem"
    fi
    if [[ "$reconcile" != true ]]; then
      for part in cert chain fullchain privkey; do
        ln -s "../../archive/$name/${part}1.pem" "$config/live/$name/$part.pem"
      done
      cat >"$config/renewal/$name.conf" <<EOF
version = 5.8.0
archive_dir = $config/archive/$name
cert = $config/live/$name/cert.pem
privkey = $config/live/$name/privkey.pem
chain = $config/live/$name/chain.pem
fullchain = $config/live/$name/fullchain.pem
[renewalparams]
account = account-id
authenticator = dns-route53
server = https://acme-v02.api.letsencrypt.org/directory
EOF
      chmod 600 "$config/renewal/$name.conf"
    fi
    ;;
  renew)
    [[ "$LIFECYCLE_MODE" == certbot-failure ]] && exit 9
    if [[ "$LIFECYCLE_MODE" == renew-partial-failure ]]; then
      printf '%s\n' '{"meta":"interrupted"}' \
        >"$config/accounts/acme-v02.api.letsencrypt.org/directory/account-id/meta.json"
      exit 9
    elif [[ "$LIFECYCLE_MODE" == renew-bad-leaf ]]; then
      openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
        -subj '/CN=example.com' \
        -addext 'subjectAltName=DNS:example.com,DNS:*.example.com' \
        -keyout "$work/unpublished-key.pem" \
        -out "$config/archive/$name/cert1.pem" >/dev/null 2>&1 || exit 93
      cp "$config/archive/$name/cert1.pem" \
        "$config/archive/$name/fullchain1.pem"
      cp "$config/archive/$name/cert1.pem" \
        "$config/archive/$name/chain1.pem"
    elif [[ "$LIFECYCLE_MODE" == renew-bad-chain ]]; then
      printf '%s\n' 'invalid PEM chain' \
        >"$config/archive/$name/chain1.pem"
    elif [[ "$LIFECYCLE_MODE" == renew-unsafe-metadata ]]; then
      printf '%s\n' 'renew_hook = /bin/true' \
        >>"$config/renewal/$name.conf"
    elif [[ "$LIFECYCLE_MODE" == metadata-changed ]]; then
      printf '%s\n' '{"meta":"renewed"}' \
        >"$config/accounts/acme-v02.api.letsencrypt.org/directory/account-id/meta.json"
    elif [[ "$LIFECYCLE_MODE" == renew-changed ]]; then
      # Preserve previously issued unrelated SANs on simulated due renewal.
      prior_sans="$(openssl x509 -in "$config/archive/$name/cert1.pem" \
        -noout -ext subjectAltName 2>/dev/null)" || exit 93
      prior_sans="${prior_sans#*$'\n'}"
      [[ -n "$prior_sans" && "$prior_sans" != *$'\n'* ]] || exit 93
      openssl req -x509 -new \
        -key "$config/archive/$name/privkey1.pem" \
        -days 4 -subj '/CN=example.com' \
        -addext "subjectAltName=$prior_sans" \
        -out "$config/archive/$name/cert1.pem" >/dev/null 2>&1 || exit 93
      cp "$config/archive/$name/cert1.pem" \
        "$config/archive/$name/chain1.pem"
      cp "$config/archive/$name/cert1.pem" \
        "$config/archive/$name/fullchain1.pem"
    fi
    exit 0
    ;;
  *) exit 98 ;;
esac
MOCK
  chmod 755 "$ROOT/bin/"*
  export PATH="$ROOT/bin:$PATH"
  unset DOMAIN S3_BUCKET S3_KEY S3_KEY_TEMPLATE BACKUP_KEY_TEMPLATE
  unset CERT_NAME ADDITIONAL_SANS
  unset GPG_SYMMETRIC_KEY CERTBOTBOT_GPG_SECRET ARCHIVE_ENCRYPTION
  unset ARCHIVE_MIGRATION ARCHIVE_MIGRATION_BACKUP_CONFIRMED
  unset DATED_BACKUP_ENABLED
  export UPLOAD_NO_RENEWAL=false INCLUDE_SUBDOMAINS=true
}
