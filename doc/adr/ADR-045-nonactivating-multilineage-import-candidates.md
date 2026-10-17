# ADR-045: Complete, Non-Activating Multi-Lineage Import Candidates

Date: 2026-10-16

## Status

Accepted

## Decision

Add an **internal, disposable, non-activating import candidate** that
combines one validated shared ACME account archive with multiple selected
certificate-lineage archives. The candidate must remain in a new,
owner-private directory **separate from the active Certbot configuration**.
This decision advances testing of complete multi-lineage assembly but
does **not** authorize product activation, renewal, issuance, or S3 writes.
ADR-037 remains authoritative and unsuperseded.

A candidate is prepared only from a complete, explicitly supplied list
of canonical, unique lineage names and corresponding archive paths.
The common archive and every lineage archive are copied into private,
mode-0600 snapshots before any validation. The existing ADR-037/038
batch assessor checks those frozen bytes and the selected ACME environment
before the candidate receives any account or lineage contents. Thus a
later rejected source archive cannot leave earlier approved lineages
as ambient state, and caller mutations to archive paths after copying
cannot change which bytes are assembled.

After the batch passes, the builder:

1. Restores the frozen common account archive using ADR-028 validation,
   copies the checked account tree into a newly created candidate
   `config/accounts` directory, and retains the checked common stage for
   per-lineage identity checks.
2. Creates private candidate `archive`, `live`, `renewal`, and
   `combined` directories. Restores each frozen domain independently
   under ADR-027, checks its account/CA association and complete
   ADR-038 renewal-option allowlist, and copies only that lineage's
   approved files and relative live symlinks into candidate storage.
3. Invokes ADR-032's renewal-path preview in a **subshell** that uses
   the candidate's own `config` pathname as the target. The caller's
   recorded active config remains unchanged; a successful preview is
   copied only to the candidate's `renewal/<name>.conf`. The preview
   must never be used to install an active renewal configuration or
   invoke Certbot under this ADR.
4. Rechecks each copied certificate and private-key symlink and
   disposes of temporary common/domain/preview stages. The snapshots
   are removed once assembly completes. Only after all lineages
   succeed are the candidate root and config pathname exposed via
   caller-facing variables.
5. On **any** rejection, discards the entire partially assembled
   private candidate and every stage it owns. Cleanup failures
   override the earlier status. An already populated active config
   is an immediate preflight rejection, with no cleanup of files
   owned by another caller.

The caller explicitly discards a successful candidate. The builder
must not rename the candidate into the recorded active config,
change the active config's contents, invoke Certbot, contact DNS,
read or write S3, or select an ACME account for registration.
It is a local preparation boundary only.

## Context and drivers

ADR-037 separates safe, isolated assessment from withheld active
Certbot import. The existing batch assessor validates multiple
archives but intentionally discards every staging tree and never
produces a combined filesystem candidate. Independent tests already
establish isolated account and domain restoration, identity
verification, renewal grammar, path rebasing, and some synthetic
Certbot portability, but not safe coexistence in one assembled
candidate under the current intended filesystem layout.

A complete, inspectable private candidate allows failure and conflict
tests to be performed before selecting an activating strategy.
This work does not establish that Certbot recognizes a registered
ACME account in its assembled state. The separately distributed
real staging example (ADR-044) has not yet supplied that evidence.

## Material assumptions and constraints

- The first release supports only the selected built-in Route53
  authenticator and an explicitly selected Let's Encrypt production
  or staging account authority.
- The input archives are owned and readable but untrusted. The
  project validators, not archive producer assertions, determine
  accepted member paths, renewal options, and symlinks.
- Bash 4.3, GNU tar, and the approved private workspace model remain
  the supported runtime baseline.
- A trusted producer process controls its exclusive local workspace.
  Another process with the same OS identity can still race files
  and is outside this module's stated threat boundary.
- The candidate's directory is not the active Certbot config.
  Its absolute renewal paths intentionally refer to that private
  candidate so it may be inspected without mutating active state.
- One invocation requests at most 32 lineages, with an account
  archive and one archive per distinct lineage. Two lineages may
  coexist but must not share `archive/<name>`, `live/<name>`,
  `renewal/<name>.conf`, or `combined/<name>.pem` paths.
- Structural assessment does not prove certificate trust, key
  correspondence, exact requested SANs, or genuine ACME registration.
  ADR-029/036 certificate checks and live staging evidence remain
  mandatory for eventual use.

## Alternatives considered

**Direct sequential copying into the active config** was rejected by
ADR-037 because a later failure could leave an incomplete, usable
Certbot tree and because real account continuity is unproven.

**Keep only the prior batch assessment as an import plan** was
rejected because it does not exercise multi-lineage tree composition
or rebased renewal files coexisting in the same directory.

**Read archive files separately for assessment and assembly** was
rejected because the resulting content could differ even in a
single invocation. The builder freezes each archive exactly once.

**Expose a partial candidate during construction** was rejected;
external code could mistake a subset for completed import state.

**Edit archived renewal files directly** was rejected by ADR-032.
A separate preview targets only the private candidate and preserves
the archived original.

**Move the candidate into active config after local checks** was
rejected because ADR-037 requires genuine staging account reuse,
multiple real lineages, an explicit rollback design, and a separate
Accepted activation ADR first.

**Implement a generic filesystem transaction manager** was rejected:
the current problem is restricted to a fresh, owner-private
candidate, not arbitrary preexisting Certbot installations.

## Failure semantics and security

A completed candidate is either wholly returned or wholly discarded.
This guarantees **failure atomicity of candidate preparation**, not
atomic active activation. External side effects must remain absent.
Invalid names, duplicate archive paths, reused accounts, foreign
environments, unsupported renewal keys, symlink violations, and
late assembly errors fail closed. An existing candidate owned by
the caller is never replaced or deleted implicitly.

The builder uses owner-private paths and never follows arbitrary
archive symlinks. The previous account and domain validators remain
the authority for member and filesystem restrictions. Filesystem
deletion does not securely erase private keys from disk, swap,
snapshots, or backups. Same-user adversarial replacement is not
prevented by permission modes alone.

A successful candidate must not be exposed as a product feature or
treated as a token authorizing issuance. Even with subsequent
genuine staging evidence, an activating ADR must define a precise
atomic install/rollback protocol, active config conflict behavior,
validation against selected real SANs, and compatibility with
future Certbot renewal metadata changes.

## Tests and acceptance

The all-artifact Bats matrix must verify an independent single-lineage
candidate, a common account and two coexisting lineages, unchanged
active config, correct private candidate-relative renewal paths,
correct relative live symlinks, private owner-only modes,
and explicit complete disposal.

Negative tests must cover a rejected later lineage, foreign account,
duplicate identity/archive, preexisting active files, and an
already-owned prior candidate. The tests must assert the absence
of Certbot, Route53, and S3 calls, and that the public entrypoint
continues to exit status 69. Synthetic account JSON and PEM strings
are suitable only for these **structural** guarantees; they do not
count as live ACME evidence or signed certificate trust.

## Relationships

ADR-019 defines common/domain archive identity; ADR-027/028 private
restore; ADR-030/031 account/CA authority; ADR-032 non-activating path
preview; ADR-037 the withheld active-import boundary; ADR-038 strict
renewal-option parsing; ADR-042 cryptographic publication checks;
and ADR-044 the separately authorized staging test example.
