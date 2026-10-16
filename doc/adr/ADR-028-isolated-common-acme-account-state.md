# ADR-028: Isolated, Account-Only Common ACME State

Date: 2026-10-16

## Status

Accepted

## Decision

The first release's common state archive is a producer-only container for
Certbot's Let's Encrypt ACME v2 account records.  It holds no domain lineage
data, user-installed Certbot renewal hooks, or arbitrary configuration files.
The permitted roots are `accounts/acme-v02.api.letsencrypt.org/directory/`
and `accounts/acme-staging-v02.api.letsencrypt.org/directory/`.  Every account
directory has a lowercase hexadecimal identifier between 32 and 64 characters
long and contains exactly `meta.json`, `regr.json`, and `private_key.json`
as ordinary nonempty files.  Multiple complete accounts may be preserved,
up to a conservative upper bound of 16; account selection is a separate
future function.

All archived entries must be relative to the logical Certbot config root and
confined to approved account paths.  Directories and JSON files must not
grant group/other permissions.  Symlinks, hard links, special files, duplicate
entries, and unexpected account contents are rejected.  Compressed size,
listing length, member count, and aggregate declared data size are bounded.

The producer first copies the archive bytes into its private workspace.
It validates that copy with a narrowly parsed GNU tar manifest, extracts
into a **new, isolated** private directory, and then independently inspects
every actual filesystem object for type, path, ownership, and permissions.
A failure discards the staging result without changing active Certbot state.
A success produces a staged directory that must be explicitly discarded
or consumed by a future reviewed operation.  It is not installed into
`config/`, used to select an account, or forwarded to deployment hosts.

## Location-independent producer invariant

The common archive is the **durable shared ACME account state required to
reconstruct a renewal-capable producer on a completely new execution node**.
It is neither an optional cache nor just a disaster-recovery backup.  Jenkins,
GitHub Actions, and EC2 must be able to restore the same account identity from
the same storage collection without any prior machine's home directory,
Certbot state, temporary workspace, or locally generated account key.

A successful full producer run starts with an empty private workspace, fetches
the common archive and requested domain archives, restores the original
registered account and lineage, performs only the requested operation, and
publishes updated durable state.  The entire local workspace may then be
discarded without compromising the next run.  Cloud/DNS credentials, GPG
passphrases, platform tooling, and runtime settings are injected into each
runner independently; they are not part of the archived ACME account.

The current account-only allowlist is a hypothesis about the supported
Certbot version's shared persistence needs, not an excuse to lose required
state.  Before enabling issuance, integration tests MUST prove that the
archive plus the selected lineage archive suffices for a new runner to reuse
the same ACME account.  If any additional shared files are necessary,
review and amend this ADR and the allowed archive layout.

An existing lineage alongside a missing or unusable common archive MUST
fail closed rather than registering a new unrelated account.  Truly empty
storage may initialize new account state when explicitly allowed.

## Context and constraints

ADR-019 requires one common shared account archive plus separately
composable per-certificate archives.  ADR-027 established that per-certificate
state must be extracted only in isolated, validated staging.  Certbot
stores ACME account identities separately from certificate lineages;
`private_key.json` is sensitive credential material and `regr.json` and
`meta.json` are necessary registration records.

The first release supports Let's Encrypt DNS-based challenges only.
Supporting another ACME server, migrating legacy Certbot account layouts,
or preserving additional shared configuration needs new documented path
rules and corresponding threat-model/tests.  These constraints are more
important than silently accepting unfamiliar state.

## Assumptions

- The issuer process and its operating-system identity are trusted.
- The operator supplies account archives created by an approved producer.
- The installed Certbot version retains the documented account layout.
- No arbitrary third-party plugin or Certbot renewal hook is part of the
  first-release trust boundary.
- A private workspace is not protection against other processes running
  with the same operating-system identity.

## Alternatives considered

Copying the entire `/etc/letsencrypt` configuration tree into common
state was rejected because it couples unrelated lineages and carries
potentially executable hooks.  Blindly accepting any account-like JSON
file was rejected because account keys and registration metadata require
an inspectable trust boundary.  Directly extracting the common archive
into active Certbot directories was rejected for the same reasons as
domain archives in ADR-027.  Automatically registering a replacement
account after an unreadable archive was rejected because it can destroy
lineage continuity and hide corruption.

## Promises

- A common archive cannot include a certificate lineage or unexpected
  external script and pass validation.
- Missing parts of an account record fail validation.
- Account keys and metadata are staged without group/world access.
- Stage restoration does not mutate active configuration or publish S3 data.
- Consumers of TLS certificates never need the common account archive.

## Non-promises and residual risks

The validator does not parse or authenticate the JSON payloads, prove
registration with Let's Encrypt, verify the account key against a server,
or choose which account Certbot should use.  A valid archive may contain
deliberately misleading JSON or obsolete accounts.  The workflow does not
handle GPG-encrypted archives until the separate encryption layer exists.
GNU tar and GNU find retain their implementation and decompression-related
risks; stage cleanup cannot securely erase all copies of secret material.

## Operational constraints and verification

Only explicit `common-latest.tar.gz` plaintext archive structure is
governed here; the encrypted form preserves identical members after GPG
decryption.  The producer must use existing private workspace guards,
validate input bytes before extraction, reject every unapproved filesystem
entry after extraction, and keep active Certbot configuration unchanged.

Behavioral tests must include complete production and staging accounts,
missing account keys, permissive key modes, arbitrary configuration,
unexpected symlinks, duplicate members, invalid account roots, successful
staging/disposal, and failure without active-state mutation.  All three
standalone script flavors must pass the same behavior suite.

Before permitting real issuance, a subsequent change must verify and
select a restored account with Certbot, reconcile its association with
the requested ACME server and configured email, and demonstrate the
renewal configuration portability required by ADR-025.

## Related decisions

ADR-019 defines the common/domain archive separation.  ADR-020 governs
only bundled backends.  ADR-021 governs optional GPG protection.
ADR-022 governs shared-storage serialization.  ADR-025 governs Certbot
renewal-state portability.  ADR-026 and ADR-027 establish validation
and isolated staging of domain archives.
