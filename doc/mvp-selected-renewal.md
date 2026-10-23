# MVP Selected-Lineage Renewal Contract

The module described here is a component of the approved task #26.
It does not activate the public five-step lifecycle.

## Interface

`certbotbot_provider_renew WORKSPACE CERT_NAME SAN [SAN ...]`

The caller supplies an owned, canonical mode-0700 workspace with restored
`config/` and one complete previously registered account and selected
lineage. The requested DNS names are literal, validated, deduplicated, and
either one name or an apex and its wildcard complement. The selected
certificate name is a stable non-wildcard identity, independent of SANs.

The provider inspects `config/live/CERT_NAME/cert.pem` using an installed
OpenSSL executable and requires an exact DNS-only SAN set equal to the
requested set. The comparison is order-independent. It rejects SAN changes
before any Certbot subprocess. Task #23 will later add the deliberate
existing-lineage SAN reconciliation path.

The provider uses the installed Certbot and Route53 plugin, checks that
the plugin is available, and validates the selected restored account
with `certbot show_account`. The provider then prepares the selected
renewal metadata with the ADR-022 reversible path mapper and invokes
`certbot renew --cert-name NAME` with explicit private directory options,
production ACME server, noninteractive mode, and directory-hook suppression.
No global renewal, force renewal, implicit account creation, or fallback
to the host's account is permitted.

On successful Certbot completion, local state preflight and desired SANs
are checked again; `finalize` returns exactly the supported renewal paths
to canonical `/etc/letsencrypt` references. Any failure blocks success.
The provider does not publish or package anything.

## Results

The provider clears two variables at entry and on failure:

- `CERTBOTBOT_RENEWAL_OCCURRED=true|false`: current selected certificate
  bytes or live symlink target changed.
- `CERTBOTBOT_DURABLE_CHANGED=true|false`: canonical restored
  configuration state changed, including account files and metadata.

A successful unchanged no-op sets both to false. A changed account file
without changed certificate sets renewal=false and durable=true. A
renewed certificate normally sets both true. A failed Certbot command,
post-state validation, or path finalization sets neither result.

Status 64 means invalid invocation/workspace/SAN values; 65 means
unsupported or conflicting restored state, SAN drift or post-state
integrity; 69 means missing provider tools or unsuitable Certbot account;
74 means Certbot failed or local private staging failed.

These variables report **local state only** and never imply remote upload.
The public lifecycle now combines verified durable changes with the
approved UPLOAD_NO_RENEWAL policy (ADR-029); this provider remains
independent and does not call S3 directly.

## Safety and acceptance evidence

Tests use a mock Certbot executable that implements named renewal and
account probe and a mock OpenSSL executable to expose deterministic SANs.
The mocks simulate unchanged no-op, changed certificate, account metadata
changes, subprocess failure, wrong SANs, missing account/plugin, unsafe
workspaces and corrupted post-renewal state. They assert no S3 calls,
no hook commands, and identical outcomes across all three standalone
artifacts. Actual Certbot behavior still requires later compatibility
tests before deployment.
