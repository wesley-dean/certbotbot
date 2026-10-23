# MVP Certbot/Route53 Provider Contract

This defines the first-party provider adapter for approved task #24.
Its first implemented action is selected-only first issuance into a
previously seeded, valid Let's Encrypt account state.  It is not yet
the public certificate lifecycle.

## Inputs

`certbotbot_provider_issue WORKSPACE CERT_NAME SAN [SAN ...]`

The workspace is an owned, new, canonical absolute mode-0700 directory
containing a restored private `config/` root.  The provider creates
private `work/` and `logs/` directories if absent.  A previously
created `work/` or `logs/` must also be owned, canonical, and 0700.

`CERT_NAME` is the already validated non-wildcard stable Certbot
lineage identity.  The SAN list has exactly one ordinary or leading
wildcard DNS name, or one apex and its exact wildcard complement.
Names must be lowercase, nonduplicated, and safe to pass as individual
`-d` arguments.  No additional or implicit DNS names are added.

The local state preflight must confirm one existing production account
and **no selected certificate lineage**.  A present, conflicting, or
partially restored lineage is refused.  The provider does not import
another host's account, select a default account, or create a new one.

## External command sequence

Using only the installed `certbot` binary from PATH and the
production Let's Encrypt directory, the provider performs:

1. `certbot plugins --authenticators`, rejecting a missing
   `dns-route53` authenticator.
2. `certbot show_account --account ACCOUNT_ID`, rejecting an account
   Certbot cannot load from the restored configuration.
3. `certbot certonly --dns-route53 --account ACCOUNT_ID --cert-name
   CERT_NAME -d SAN...`, with a fixed noninteractive, selected-only
   option set, explicit `--server`, `--config-dir`, `--work-dir`,
   `--logs-dir`, `--no-directory-hooks`, and
   `--preferred-challenges dns-01`.

No intermediate command output is forwarded.  Fixed non-secret
diagnostics distinguish missing provider, unavailable authenticator,
unsuitable account, and failed issuance.  A zero return means
Certbot's command completed, **not** that the result was validated
for requested SANs or safely persisted.

The caller must later validate the issued PEMs, private key, selected
lineage, account continuity, renewal configuration, and archive bytes,
then publish only after every gate succeeds.  Certificate updates and
reconciliation of SAN drift are handled in a separate task.

## Test boundary

The Bats suite places a controlled executable `certbot` mock in PATH,
checks the exact invocation order/arguments, and simulates plugin
absence, account failure, CLI failure, invalid SANs, and existing
lineages.  No live AWS, Route53, or ACME service is contacted in
MVP tests.  The public executable continues to return status 69 for
ordinary certificate requests.

See [ADR-024](adr/ADR-024-selected-only-certbot-route53-provider.md).
