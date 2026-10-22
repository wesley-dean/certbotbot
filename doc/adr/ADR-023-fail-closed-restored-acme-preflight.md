# ADR-023: Fail-Closed Preflight of Restored ACME State

Date: 2026-10-22

## Status

Accepted

## Decision

A restored Certbot configuration directory is not automatically suitable for
issuing or renewing certificates merely because tar validation and extraction
succeeded. Before any Certbot operation, the MVP performs a read-only
**local state preflight** on the isolated configuration tree.

The local preflight requires one unambiguous existing Let's Encrypt production
ACME account in `accounts/acme-v02.api.letsencrypt.org/directory/<id>/`,
with nonempty regular `private_key.json`, `regr.json`, and `meta.json`
files. The expected account host and endpoint path are fixed for MVP.
Zero accounts, competing account identities, unexpected account endpoints, and
missing/unsafe required files fail closed. No accounts are registered or
imported from the host.

For certificate identity, an archive may contain **no lineage** (first issue
into seeded account state) or **exactly the selected lineage**. A present
lineage must have a matching `renewal/<cert-name>.conf`, versioned archive
directory, and relative `live/<cert-name>/` PEM links whose targets resolve
to existing regular files in that lineage. An orphaned, incomplete, extra, or
differently named lineage is an error, not permission to create a numbered
replacement or silently migrate state.

The preflight rejects executable hook references within restored renewal
configuration and refuses to run restored hook scripts. It never sources,
evaluates, or executes archived content. It does not rewrite canonical
`/etc/letsencrypt` renewal paths. Path remapping and version-specific Certbot
verification remain mandatory gates before issuing or renewing.

## Context

ADR-020 mandates reuse of an existing ACME account and a stable selected
certificate identity. ADR-022 requires that archive bytes be validated and
restored privately, and that the metadata containing canonical absolute paths
must not be used unchanged when Certbot runs in a private workspace.

An account-only seeded archive is legitimate for first issuance. Conversely,
the existence of PEM data or of a `renewal/*.conf` filename does not prove
that the selected certificate belongs to the intended ACME account or is
renewable. Before Certbot execution the application must independently
establish unambiguous local state and then have Certbot validate the account
under its private configuration.

## Rejected alternatives

- **Treat the archive as proof of registration:** rejected. JSON-shaped local
  files cannot establish remote registration or suitability for issuing.
- **Select the first account when multiple are present:** rejected. Directory
  ordering and implicit selection could change the registration authority.
- **Fallback to the host's Certbot account:** rejected by ADR-020 and the
  requirement for independent runners.
- **Permit any extra lineages:** deferred beyond one selected certificate in
  MVP. Future multi-lineage support requires an explicit approved policy.
- **Execute archived renewal hook commands:** rejected as an untrusted code
  execution boundary unrelated to DNS-01 validation.
- **Rewrite arbitrary renewal metadata during preflight:** rejected. The
  separately governed reversible runtime mapping has yet to be implemented.

## Consequences and compatibility

The initial preflight deliberately supports only the conventional Let's Encrypt
production account layout. A staging ACME directory, different Certbot storage
dialect, multiple accounts, or a partially written lineage requires a deliberate
compatibility decision and tests rather than silently broadening authority.

For legitimate account-only state, local preflight succeeds with an
`absent` selected-lineage result. For one complete matching lineage it
succeeds with a `present` result. The report is returned as caller-visible
state, not printed to stdout. On error the result is cleared and fixed,
non-sensitive diagnostics are emitted; no mutations, network operations,
Certbot invocation, or S3 publication occur.

Crucially, successful local preflight is **necessary but insufficient** for
using the restored account. Certbot must still recognize the exact account,
and the runtime must map renewal metadata into its private configuration path
without touching host state. The public lifecycle must remain disabled until
these independent requirements are satisfied and mocked roundtrip tests pass.

## Security considerations and verification

ACME account private keys and PEM files must remain under a private,
caller-owned workspace. The validator must not print account IDs, full paths
or file contents. Any invalid state blocks issuance and upload. Tests cover
missing accounts/files, competing accounts, unsupported ACME endpoints,
account-only and selected-lineage fixtures, foreign lineages, broken/missing
live links, and archived executable hooks across all three artifacts.

This is a filesystem and trust-selection policy, not a JSON parser or a
remote account-registration test. Local file syntax and actual Certbot
interoperability are follow-up acceptance gates.

## Related decisions

ADR-008 requires documentation and behavioral tests before implementation.
ADR-020 governs selected identity and seeded archive. ADR-021 governs S3
lookup; ADR-022 governs safe archive restoration, hooks and canonical paths;
ADR-019 governs approval through current issue labels.
