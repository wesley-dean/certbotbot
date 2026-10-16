# ADR-031: Read-Only Account and Lineage ACME Identity Validation

Date: 2026-10-16

## Status

Accepted

## Decision

Before any restored certificate lineage can be presented to Certbot, the
producer MUST establish that the lineage names one complete restored ACME
account under the currently selected Let's Encrypt production or staging
authority.  The first implementation provides an internal, read-only
validation function and remains disconnected from the public issuer.

Given an already validated common-account staging directory, an independently
validated domain-lineage staging directory, the lineage identity, and the
explicitly selected environment, the function reads
`renewal/<name>.conf` as untrusted *data*.  It requires exactly one
`[renewalparams]` section containing exactly one nonempty `server`,
`account`, and `authenticator` value.  The server must match the
fixed URL from ADR-030; the authenticator must equal `dns-route53`.
The account identifier must be a 32-64-character lowercase hexadecimal
value, and the matching account directory must exist below the correct
production/staging authority.  `meta.json`, `regr.json`, and
`private_key.json` must each be nonempty, owned, ordinary, non-symlinked
files with no group or other access.  Both staging roots must be owned,
private directories, and must match the staged roots recorded by the
producer process.

The validator must reject conflicting or duplicate identity fields,
unrecognized configuration sections, embedded NUL bytes, hook directives,
installer directives, and missing/insecure account files.  It must not
execute or source renewal metadata.  A recognized
`[acme_renewal_info]` section may contain additional non-identity data.
Non-identity options elsewhere are outside this helper's guarantee and
must undergo an independent semantic policy review before invoking
Certbot with restored state.

## Context

ADR-028 established an account-only common archive as portable ACME state
across Jenkins, GitHub Actions, and EC2.  ADR-030 established independent
storage namespaces and fixed endpoints for production and staging.  Those
controls protect archives at rest, but a domain archive can still refer to
the wrong account or ACME server.  Certbot's renewal configuration records
`account`, `server`, and `authenticator` under `[renewalparams]` and
also stores absolute paths to the lineage's archive and live files.
An archive-shaped, syntactically complete account record alone cannot
prove that a restored certificate refers to it.

The upstream Certbot reference documents these renewal fields and the
difference between production and staging ACME endpoints:

- https://eff-certbot.readthedocs.io/en/stable/using.html
- https://github.com/certbot/certbot/blob/main/certbot/docs/using.rst

The initial implementation is a narrow identity cross-check rather than a
complete Certbot renewal configuration interpreter.  A real integration
test against the supported Certbot version remains authoritative on the
final accepted renewal syntax and account selection behavior.

## Assumptions

- Archive manifest validation, isolated extraction, and post-extraction
  filesystem checks have already succeeded on both inputs.
- Only Let's Encrypt ACME v2 production/staging accounts and Route53 DNS-01
  are supported at present.
- The operating-system identity owns the private staging directories and
  no hostile process sharing that identity modifies them during the check.
- The selected mode was validated by the public input parser, then passed
  explicitly to the internal operation.
- A missing or unusable common account with an existing domain lineage
  is an error, not permission to generate a replacement registration.

## Alternatives considered

Using the global `ACME_ENVIRONMENT` value without inspecting restored
renewal metadata was rejected: it could pair production lineages with
staging accounts.  Accepting any existing account under either authority
was rejected for cross-environment confusion.  Parsing stored renewal
files as shell assignments, using `source` or `eval`, was rejected
because those files are externally stored data.  Treating an account
directory's existence as proof of server registration was rejected
because account JSON and remote ACME registration require further
verification.  Rewriting absolute renewal paths while inspecting
identity was deferred under ADR-025 until portability behavior has
been tested with actual Certbot artifacts.

## Promises

- Production lineages cannot reference a staging authority and pass.
- Staging lineages cannot reference a production authority and pass.
- Missing or ambiguous account identity fails before Certbot execution.
- The selected account must have a complete, private account-file triplet.
- No account JSON, shell code, or Certbot operation is executed.
- The same check is included in every standalone script flavor.

## Non-promises

A successful result does **not** prove that account JSON is well formed,
that Let's Encrypt recognizes the account, that the account owns or can
renew the selected lineage, that its email or terms state is correct,
or that Certbot will select the same account at runtime.  It does not
prove that absolute `archive_dir`, `cert`, `chain`,
`fullchain`, and `privkey` paths are portable between workspaces.
It also does not exhaustively approve unrelated Certbot configuration
options, verify that no other hook/config file is present in the merged
active configuration, or establish cryptographic certificate correctness.
ADR-029 covers the separate certificate integrity gate.

## Operational consequences and testing

Unit tests must exercise exact production/staging matching, cross-mode
rejection, missing keys, wrong/missing/duplicate account metadata,
unsupported authenticators, suspicious hook/installer directives,
unsafe renewal paths, NUL bytes, unrecognized sections, and owner-private
filesystem boundaries.  All tests must be network-free and run against
all three standalone Bash artifacts.

Before enabling issuance, a future PR must define safe account installation
and Certbot account selection, review all restored renewal options and
hook handling, and prove renewal metadata portability across independent
workspaces using real Certbot files.  A failed identity check must block
Certbot, S3 writes, and any new account registration.  Staging tests must
never mutate production archives.  The runtime release gate remains
disabled until end-to-end checks pass.

## Related decisions

ADR-018 governs requested lineage identity; ADR-019 governs the split-state
archive format; ADR-022 governs publication consistency; ADR-025 governs
renewal path portability; ADR-027 and ADR-028 govern isolated staging;
ADR-029 governs cryptographic integrity; ADR-030 governs the
production/staging authority and archive namespace.
