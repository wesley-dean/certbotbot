# ADR-032: Validated, Non-Activating Renewal Path Rebase Preview

Date: 2026-10-16

## Status

Accepted

## Decision

Develop an internal, **non-activating preview** of Certbot renewal configuration
path relocation as an intermediate step toward a stateless certificate producer.
The preview is deliberately narrower than production restoration.  It must not
edit the archived renewal file, install or merge state into the active Certbot
config directory, call Certbot, or authorize remote publication.

A candidate renewal file first passes ADR-031's existing selected-account and
ACME-environment identity checks.  The path preview independently requires
exactly one top-level `archive_dir`, `cert`, `chain`, `fullchain`, and
`privkey` field.  Their original absolute values must describe one and only
one lineage rooted under the **same former config directory**:

- `<old-config>/archive/<name>`
- `<old-config>/live/<name>/cert.pem`
- `<old-config>/live/<name>/chain.pem`
- `<old-config>/live/<name>/fullchain.pem`
- `<old-config>/live/<name>/privkey.pem`

The old base path must be absolute, non-root, and free of noncanonical
repeated separators and dot-segments.  The preview refuses absent or
duplicate fields, cross-lineage references, extra top-level path-like keys,
and relocated `config_dir`, `work_dir`, or `logs_dir` settings in
renewal parameters.  Hooks and identity conflicts are already refused by
the preceding ADR-031 guard.

Only after every check succeeds may the helper create a mode-0600 temporary
file under the current producer-owned workspace.  The five authorized
path values are emitted with the **current recorded config root**, while
all other allowed lines are preserved.  The original staged renewal file
remains byte-identical.  Preview disposal is explicit and restricted to
its recorded private file.  A preview may not be used to overwrite the
active Certbot renewal file or be passed to the Certbot process yet.

## Context and rationale

The shared ACME account archive and selected per-lineage archive are
intended to let a Jenkins worker, GitHub Actions runner, or EC2 instance
resume the same Certbot state without previous-runner local files.  However,
Certbot writes absolute paths into renewal configuration files.  ADR-025
correctly forbids assuming that changing `--config-dir` rewrites them
and requires a demonstrated portable renewal strategy with real
Certbot state before live issuance.

Certbot's upstream guidance discourages manually editing renewal files
without validating the resulting behavior.  This preview is an
inspectable, fail-closed preparation mechanism and does not claim
to satisfy that upstream validation:

- https://certbot.eff.org/docs/using.html
- https://github.com/certbot/certbot/blob/main/certbot/docs/using.rst

## Why this does not supersede ADR-025

ADR-025 remains authoritative.  This ADR authorizes a testable isolated
candidate transformation, **not** a decision to deploy transformed
renewal metadata into a functional issuer.  The consequential choice
of a production portability approach remains contingent upon real
Certbot compatibility evidence, including no-op renewal, SAN changes,
account continuity, and export/restore across distinct workspace roots.

The helper also cannot establish that every non-path renewal setting is
safe.  Any future activation must review the complete supported
Certbot configuration grammar, identify and reject inherited hooks or
foreign credential paths, and apply additional semantic checks before
importing state.

## Assumptions

- The requesting lineage and ACME environment have been validated.
- Both original common and domain archives have been separately validated
  and staged according to ADR-027 and ADR-028.
- The current producer has an exclusive private workspace and its
  `config/` directory exists with mode 0700.
- An attacker sharing the producer's own OS credentials lies outside the
  private-workspace isolation guarantee.
- Original absolute path strings are inspected as untrusted data only;
  the producer never traverses or opens them.

## Alternatives considered

A persistent volume shared by Jenkins, GitHub Actions, and EC2 was
rejected because it violates the project's stateless-runner requirement.
Blind replacement of a former `/etc/letsencrypt` prefix was rejected
because it cannot detect inconsistent roots, foreign lineages, or
unreviewed path-bearing options.  Direct editing of staged or published
renewal files was rejected because it makes testing destructive and risks
invalidating the last known good archive.  Relying on `--config-dir`
alone was rejected because archived absolute paths can remain stale.
Using relative paths in the published renewal configuration was
deferred until validated against the supported Certbot version.

## Promises and failure behavior

- A mismatched account/environment identity prevents preview creation.
- Five path fields must agree on one original lineage and root.
- A valid preview uses only the current producer's recorded config root.
- Malformed or unsupported inputs leave original staged data untouched.
- The preview does not call Certbot, ACME, AWS, or publication backends.
- Every standalone Bash artifact exposes identical validation behavior.

## Non-promises

A successful preview is not evidence that Certbot can renew from it.
The helper does not validate account JSON, certificate key matching,
all renewal options, file contents referenced at the new paths, or
the ability to archive the updated file safely.  It neither selects
nor registers an account.  It is not a migration mechanism for
arbitrary historical Certbot renewal configuration formats.

## Verification and follow-up

Bats tests must cover a consistent historical root, distinct new runner
root, production and staging identities, mismatched path roots,
cross-lineage paths, duplicate/missing path keys, unapproved legacy
directory overrides, inherited hooks, ownership, cleanup, and unchanged
original archive data.  Each of the three standalone artifacts must
pass the same tests on Bash 4.3+.

Before using these preview bytes with Certbot, an independent PR must
use actual supported Certbot-generated renewal files, test successful
restoration under different absolute workspace roots, verify a no-op
renewal and deliberate SAN change, and demonstrate original ACME account
continuity.  Only then may an ADR extend this preview into an activated
state import.  The release gate remains disabled until that evidence
and the remaining publication/security checks are complete.

## Related decisions

ADR-019 defines durable split-state archives.  ADR-022 governs
publication.  ADR-025 governs portable renewal behavior.  ADR-027 and
ADR-028 establish isolated staging.  ADR-031 establishes the
account/environment prerequisite.  ADR-029 governs cryptographic
certificate validation.
