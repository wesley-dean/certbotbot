#!/usr/bin/env bash
#
# A credential-free Certbot 5.8.0 portability and no-op renewal smoke test.
# Synthetic account records cannot establish ACME registration validity.
# This exercises read-only inspection and a no-op renewal decision after relocating
# one validated certificate lineage between disposable producer workspaces.

set -euo pipefail
umask 077

: "${CERTBOTBOT_ARTIFACT:?Provide an absolute standalone artifact path}"
: "${CERTBOT:?Provide a pinned Certbot executable}"
[[ "$CERTBOTBOT_ARTIFACT" == /* && -f "$CERTBOTBOT_ARTIFACT" ]] || exit 64
[[ "$CERTBOT" == /* && -x "$CERTBOT" ]] || exit 64

tmp="$(mktemp -d)"
cleanup() {
  rm -rf -- "$tmp"
}
trap cleanup EXIT

mkdir -m 0700 "$tmp/archives" "$tmp/source" "$tmp/new-parent"
original="$tmp/source/config"
mkdir -m 0700 "$original" "$tmp/source/work" "$tmp/source/logs"
mkdir -m 0700 "$original/archive" "$original/live" "$original/renewal" \
  "$original/combined" "$original/archive/example.com" "$original/live/example.com"

# Locally issued X.509 fixture with a private CA/issuer chain.  Certbot
# validates fullchain == leaf + chain even for read-only inspection.
# No real account, ACME challenge, server, or network endpoint is used.
openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/issuer.key"
openssl req -new -x509 -key "$tmp/issuer.key" -days 90 \
  -subj '/CN=Local fixture CA' \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -out "$tmp/issuer.crt"
openssl ecparam -name prime256v1 -genkey -noout \
  -out "$original/archive/example.com/privkey1.pem"
openssl req -new -key "$original/archive/example.com/privkey1.pem" \
  -subj '/CN=example.com' -out "$tmp/leaf.csr"
printf '%s\n' \
  'basicConstraints=critical,CA:FALSE' \
  'keyUsage=critical,digitalSignature' \
  'extendedKeyUsage=serverAuth' \
  'subjectAltName=DNS:example.com,DNS:*.example.com' >"$tmp/leaf.ext"
openssl x509 -req -in "$tmp/leaf.csr" \
  -CA "$tmp/issuer.crt" -CAkey "$tmp/issuer.key" \
  -CAcreateserial -days 90 -extfile "$tmp/leaf.ext" \
  -out "$original/archive/example.com/cert1.pem"
cp "$tmp/issuer.crt" "$original/archive/example.com/chain1.pem"
cat "$original/archive/example.com/cert1.pem" \
  "$original/archive/example.com/chain1.pem" \
  >"$original/archive/example.com/fullchain1.pem"
chmod 0600 -- "$original/archive/example.com/privkey1.pem"

for kind in cert privkey chain fullchain; do
  ln -s "../../archive/example.com/${kind}1.pem" \
    "$original/live/example.com/$kind.pem"
done
{
  cat "$original/live/example.com/fullchain.pem"
  printf '\n'
  cat "$original/live/example.com/privkey.pem"
} >"$original/combined/example.com.pem"
cp "$original/combined/example.com.pem" \
  "$original/live/example.com/combined.pem"
chmod 0600 -- "$original/combined/example.com.pem" \
  "$original/live/example.com/combined.pem"

account=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cat >"$original/renewal/example.com.conf" <<RENEWAL
version = 5.8.0
archive_dir = $original/archive/example.com
cert = $original/live/example.com/cert.pem
privkey = $original/live/example.com/privkey.pem
chain = $original/live/example.com/chain.pem
fullchain = $original/live/example.com/fullchain.pem

[renewalparams]
account = $account
server = https://acme-v02.api.letsencrypt.org/directory
authenticator = dns-route53
key_type = ecdsa
RENEWAL
chmod 0600 "$original/renewal/example.com.conf"
old_digest="$(sha256sum "$original/archive/example.com/privkey1.pem" | cut -d ' ' -f1)"

# The first runner can inspect its local certificate without contacting ACME.
"$CERTBOT" certificates --non-interactive --config-dir "$original" \
  --work-dir "$tmp/source/work" --logs-dir "$tmp/source/logs" \
  >"$tmp/first-certs.out" 2>"$tmp/first-certs.err"
if ! grep -Fq 'Certificate Name: example.com' "$tmp/first-certs.out"; then
  printf '%s\n' 'Certbot did not recognize the local source lineage:' >&2
  cat "$tmp/first-certs.out" "$tmp/first-certs.err" >&2
  exit 1
fi

tar -czf "$tmp/archives/example.com-latest.tar.gz" \
  -C "$original" archive live renewal combined

account_src="$tmp/source/common"
account_base="$account_src/accounts/acme-v02.api.letsencrypt.org/directory/$account"
mkdir -p "$account_base"
chmod 0700 "$account_src" "$account_src/accounts" \
  "$account_src/accounts/acme-v02.api.letsencrypt.org" \
  "$account_src/accounts/acme-v02.api.letsencrypt.org/directory" \
  "$account_base"
for file in meta regr private_key; do
  printf '{"fixture":"%s"}\n' "$file" >"$account_base/$file.json"
  chmod 0600 -- "$account_base/$file.json"
done
old_account_digest="$(sha256sum -- "$account_base/private_key.json" | cut -d ' ' -f1)"
tar -czf "$tmp/archives/common-latest.tar.gz" -C "$account_src" accounts

source "$CERTBOTBOT_ARTIFACT" --version >/dev/null
export ACME_ENVIRONMENT=production
export CERTBOTBOT_TMPDIR="$tmp/new-parent"
certbotbot_workspace_create
certbotbot_restore_domain "$tmp/archives/example.com-latest.tar.gz" example.com
certbotbot_common_restore "$tmp/archives/common-latest.tar.gz"
certbotbot_renewal_path_preview example.com production

# This import is STRICTLY TEST-ONLY and read-only from Certbot's perspective.
# No producer function installs a preview; ADR-033 permits this isolated
# inspection fixture and explicitly forbids activating issuance.
new="$CERTBOTBOT_WORKSPACE_CONFIG"
for directory in archive live combined; do
  cp -a -- "$CERTBOTBOT_RESTORE_ROOT/$directory" "$new/$directory"
done
# This account merge is confined to disposable CI test state; synthetic JSON
# must never be treated as a usable or remotely registered ACME identity.
cp -a -- "$CERTBOTBOT_COMMON_STAGE/accounts" "$new/accounts"
new_account_digest="$(sha256sum -- "$new/accounts/acme-v02.api.letsencrypt.org/directory/$account/private_key.json" | cut -d ' ' -f1)"
[[ "$new_account_digest" == "$old_account_digest" ]]
mkdir -m 0700 "$new/renewal"
cp -- "$CERTBOTBOT_RENEWAL_PREVIEW" "$new/renewal/example.com.conf"
chmod 0600 -- "$new/renewal/example.com.conf"
new_digest="$(sha256sum "$new/archive/example.com/privkey1.pem" | cut -d ' ' -f1)"
[[ "$old_digest" == "$new_digest" ]]
cmp -s -- "$new/live/example.com/combined.pem" \
  "$original/live/example.com/combined.pem"

# Delete the predecessor's complete workspace to rule out path dependence.
rm -rf -- "$tmp/source"
[[ ! -e "$original" ]]

"$CERTBOT" certificates --non-interactive --config-dir "$new" \
  --work-dir "$CERTBOTBOT_WORKSPACE_WORK" \
  --logs-dir "$CERTBOTBOT_WORKSPACE_LOGS" \
  >"$tmp/restored-certs.out" 2>"$tmp/restored-certs.err"
grep -Fq 'Certificate Name: example.com' "$tmp/restored-certs.out"
grep -Fq 'example.com' "$tmp/restored-certs.out"
if grep -Fq "$original" "$new/renewal/example.com.conf"; then
  printf '%s\n' 'Relocated renewal file still references the deleted source' >&2
  exit 1
fi

# Certbot's own no-op renewal decision must not require a predecessor
# filesystem or contact an ACME endpoint.  A Python sitecustomize guard
# denies socket connection APIs, records attempted network access, and makes
# unexpected renewal attempts fail rather than contacting Let's Encrypt.
mkdir -m 0700 "$tmp/no-network"
cat >"$tmp/no-network/sitecustomize.py" <<'PY'
import os
import socket

def deny_network(operation):
    def report(*args, **kwargs):
        with open(os.environ["CERTBOTBOT_NETWORK_MARKER"], "a", encoding="utf-8") as marker:
            marker.write(operation + "\n")
        raise OSError("Unexpected network operation: " + operation)
    return report

socket.socket.connect = deny_network("socket.connect")
socket.socket.connect_ex = deny_network("socket.connect_ex")
socket.create_connection = deny_network("socket.create_connection")
socket.getaddrinfo = deny_network("socket.getaddrinfo")
PY
marker="$tmp/network-attempts"
# Sanity-check the guard before invoking Certbot.  No network call is made
# because the in-process socket implementation is intercepted.
if env PYTHONPATH="$tmp/no-network" CERTBOTBOT_NETWORK_MARKER="$marker" \
  "${CERTBOT%/certbot}/python" -c \
  'import socket; socket.create_connection(("127.0.0.1", 9))' \
  >"$tmp/guard.out" 2>"$tmp/guard.err"; then
  printf '%s\n' 'Test network guard failed to intercept an outbound call' >&2
  exit 1
fi
[[ -s "$marker" ]]
rm -f -- "$marker"

cp -- "$new/renewal/example.com.conf" "$tmp/pre-noop-renewal.conf"
before_conf="$(sha256sum -- "$new/renewal/example.com.conf" | cut -d ' ' -f1)"
before_cert="$(sha256sum -- "$new/archive/example.com/cert1.pem" | cut -d ' ' -f1)"
before_key="$(sha256sum -- "$new/archive/example.com/privkey1.pem" | cut -d ' ' -f1)"
# Do not use --dry-run: that requests ACME authorization even if not due.
# --no-directory-hooks prevents a test fixture from running discovered hooks.
if ! env PYTHONPATH="$tmp/no-network" CERTBOTBOT_NETWORK_MARKER="$marker" \
  "$CERTBOT" renew --non-interactive --cert-name example.com \
  --no-directory-hooks --no-random-sleep-on-renew \
  --config-dir "$new" --work-dir "$CERTBOTBOT_WORKSPACE_WORK" \
  --logs-dir "$CERTBOTBOT_WORKSPACE_LOGS" \
  >"$tmp/noop-renew.out" 2>"$tmp/noop-renew.err"; then
  printf '%s\n' 'Certbot failed the offline restored-state no-op renewal:' >&2
  cat "$tmp/noop-renew.out" "$tmp/noop-renew.err" >&2
  exit 1
fi
if ! grep -Eqi 'not (yet )?due|no renewals were attempted|not scheduled for renewal' \
  "$tmp/noop-renew.out" "$tmp/noop-renew.err"; then
  printf '%s\n' 'Certbot returned success without a recognizable no-op decision:' >&2
  cat "$tmp/noop-renew.out" "$tmp/noop-renew.err" >&2
  exit 1
fi
# Certbot 5.8.0 may request ACME Renewal Information (ARI) even when its
# certificate is not due.  DNS resolution is blocked by the guard, and
# Certbot still returns the correct non-renewal decision.  Reject any
# attempted socket connection or unrecognized network API use.
if [[ -e "$marker" ]]; then
  if grep -Evq '^socket[.]getaddrinfo$' "$marker" ||
    ! grep -Fq 'ACME Renewal Information (ARI)' "$tmp/noop-renew.err"; then
    printf '%s
' 'Unexpected network behavior during Certbot no-op:' >&2
    cat "$marker" "$tmp/noop-renew.out" "$tmp/noop-renew.err" >&2
    exit 1
  fi
fi
# The observed Certbot 5.8.0 no-op can cache ARI retry metadata even when
# no certificate is renewed.  The ONLY authorized config change in this
# synthetic fixture is appending that two-line section.
if [[ "$(sha256sum -- "$new/renewal/example.com.conf" | cut -d ' ' -f1)" != "$before_conf" ]]; then
  ari_tail="$(tail -n 2 "$new/renewal/example.com.conf")"
  if [[ $ari_tail != $'[acme_renewal_info]\nari_retry_after = '* ]] ||
    ! tail -n 1 "$new/renewal/example.com.conf" |
      grep -Eq '^ari_retry_after = [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$' ||
    ! head -n -2 "$new/renewal/example.com.conf" |
      cmp -s - "$tmp/pre-noop-renewal.conf"; then
    printf '%s\n' 'Unexpected Certbot no-op renewal metadata change:' >&2
    diff -u "$tmp/pre-noop-renewal.conf" "$new/renewal/example.com.conf" >&2 || :
    exit 1
  fi
fi
# A future publisher must treat this as durable lineage state, even when
# no certificate was reissued.  Prove the accepted metadata can be archived
# with the regular per-domain archive contract.
tar -czf "$tmp/archives/post-noop-domain.tar.gz" \
  -C "$new" archive live renewal combined
tar -xOzf "$tmp/archives/post-noop-domain.tar.gz" \
  renewal/example.com.conf | cmp -s - "$new/renewal/example.com.conf"
[[ "$(sha256sum -- "$new/archive/example.com/cert1.pem" | cut -d ' ' -f1)" == "$before_cert" ]]
[[ "$(sha256sum -- "$new/archive/example.com/privkey1.pem" | cut -d ' ' -f1)" == "$before_key" ]]

certbotbot_renewal_preview_discard
certbotbot_restore_discard
certbotbot_common_discard
certbotbot_workspace_destroy
printf '%s\n' 'Real Certbot 5.8.0 lineage loading and offline no-op renewal passed across isolated workspaces'
