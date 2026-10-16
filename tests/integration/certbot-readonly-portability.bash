#!/usr/bin/env bash
#
# A network-free ACME smoke test, using the real Certbot 5.8.0 CLI in CI.
# Synthetic account records cannot establish ACME registration validity.
# This exercises only the read-only "certificates" command after relocating
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

# Locally created, short-lived self-signed X.509 fixture.  No real account,
# challenge, server, or network endpoint is used.
openssl ecparam -name prime256v1 -genkey -noout \
  -out "$original/archive/example.com/privkey1.pem"
openssl req -new -x509 \
  -key "$original/archive/example.com/privkey1.pem" \
  -days 7 -subj '/CN=example.com' \
  -addext 'subjectAltName=DNS:example.com,DNS:*.example.com' \
  -out "$original/archive/example.com/cert1.pem"
cp "$original/archive/example.com/cert1.pem" \
  "$original/archive/example.com/chain1.pem"
cp "$original/archive/example.com/cert1.pem" \
  "$original/archive/example.com/fullchain1.pem"
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

certbotbot_renewal_preview_discard
certbotbot_restore_discard
certbotbot_common_discard
certbotbot_workspace_destroy
printf '%s\n' 'Real Certbot 5.8.0 read-only lineage inspection passed across isolated workspaces'
