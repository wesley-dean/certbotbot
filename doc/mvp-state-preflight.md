# MVP Restored ACME State Preflight

This is a read-only local verification boundary after
`certbotbot_archive_restore`, before any certificate operation.
It is not a complete account-validation or renewal implementation.

## Interface and outcome

`certbotbot_state_preflight CONFIG_DIR CERT_NAME` accepts the fully isolated
restored configuration directory and the validated selected Certbot name.
It refuses symlink aliases, non-private or unowned configuration roots,
and unsafe unexpected account or lineage layouts.

On success it sets the caller-visible `CERTBOTBOT_LINEAGE_STATE` to
`absent` or `present` and writes nothing. Failure clears the state and
returns status 64 for invalid caller arguments or status 65 for inconsistent
restored state. Diagnostics are fixed strings and never include account data.

## Supported account contract

The seeded archive must contain precisely one account at
`accounts/acme-v02.api.letsencrypt.org/directory/<account-id>/`, with
nonempty, regular, non-symlink `private_key.json`, `regr.json`,
and `meta.json` files. The single production endpoint is an explicit
MVP compatibility restriction. Account files and their parent directory
must not be writable by group or others.

The presence of these files does **not** prove that the account remains
registered, belongs to the intended ACME server, or that credentials are
usable. A later Certbot check must validate actual account suitability
before any issuance attempt. No host account may be loaded as fallback.

## Lineage contract

An account-only archive without `live/`, `archive/`, or `renewal/`
may proceed to the later first-issuance decision. A complete lineage
requires all three paths with exactly the selected certificate name,
a nonempty `renewal/<name>.conf` and four canonical relative PEM
symlinks under `live/<name>/` resolving to regular files under
`archive/<name>/`. Missing, competing or partial lineage entries fail.

Renewal configuration must not contain executable hook directives. The
preflight conservatively rejects any occurrence of the word `hook` in a
renewal file, including ambiguous metadata, and refuses nonempty
`renewal-hooks/` contents. This intentionally sacrifices compatibility
with unreviewed hook settings rather than allowing archived commands
to cross the execution boundary.

Persisted renewal paths may still refer to `/etc/letsencrypt`. That is
expected and remains a later reversible path-mapping responsibility,
not proof that the restored state is already safe to use with Certbot.

## Explicit boundaries

Successful preflight does not:

- prove that account JSON is syntactically or semantically valid;
- establish remote ACME account registration;
- authorize Certbot network operations or archived shell hooks;
- normalize renewal absolute paths;
- create any lineage, certificate, account or S3 object;
- claim the public MVP certificate lifecycle has completed.

Those later gates must pass independently before the CLI returns success.
