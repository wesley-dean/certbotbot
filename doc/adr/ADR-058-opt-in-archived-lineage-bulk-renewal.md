# ADR-058: Explicit, Fail-Closed Renewal of Every Validated Archived Lineage

Date: 2026-11-04

## Status

Accepted

By repository convention this decision becomes operative on review and merge of
technical task #98's pull request. It defines a future implementation contract;
it does **not** claim that `RENEW_ALL` is already a recognized producer option.

## Decision

### Explicit mode and backward-compatible selection

Add the nonsecret scalar `RENEW_ALL`, defaulting to the exact literal
`false`, to the **ordinary producer**. Accept `true` or `false` only.
Expose `--renew-all true|false` (including the parser's existing
`--renew-all=true|false` style), exported `RENEW_ALL`, and literal
configuration-file `RENEW_ALL`. Apply the existing per-scalar
**CLI > exported environment > literal file > default** precedence.
An explicit `--no-env` suppresses application environment and file values,
including `RENEW_ALL`, but cannot suppress an explicit CLI option. Do not
add this behavior to `register`, the read-only client, or provider extra-argv.

When false, retain the entire existing ADR-030 ordinary selected-only
contract: one required runtime DNS identity, one stable lineage identity,
selected issuance/renewal/SAN reconciliation only, unchanged unselected
lineage state, one authoritative S3 object, and the normal no-op policy.
Do not reinterpret multiple `--san` arguments as multiple lineages.

When true, the operation is **a single bounded bulk transaction attempt
over the restored workspace**, not a global host renewal. It visits each
previously archived complete lineage **once** for an ordinary Certbot
due-renewal check, using that lineage's own existing canonical renewal
configuration. An optional ordinary selected target retains ordinary
selected behavior. Its independent selected action must not run a second
renewal of the same archived lineage.

### Presence and identity rules

The implementation must distinguish *presence of a selected input* from
its final value. In bulk mode, an invocation with **no effective selected
DNS identity and no independently supplied selected-only inputs** is
permitted solely when the already fetched, restored, fully validated archive
contains at least one complete lineage. A confirmed missing archive,
account-only archive, wrong CA/account, incomplete lineage, or malformed
renewal metadata does **not** become a successful empty scan. Do not invent
a synthetic selected DNS identity to satisfy the parser.

A supplied DNS identity follows normal name, SAN and selected-lineage
rules. A nonempty `CERT_NAME` or `ADDITIONAL_SANS` without a supplied
`DOMAIN`, or an explicitly empty/malformed `DOMAIN`, is an invalid
partial selected request; it never silently becomes domainless bulk mode.
A standalone non-default `INCLUDE_SUBDOMAINS` setting without a selected
identity is also invalid as it cannot meaningfully configure a selected
lineage. Defaults do not count as explicit selected input. Invalid or
duplicate CLI options continue to fail before contacting S3.

The selected name is resolved exactly as under ADR-020, story #87, and
ADR-029. It may be an existing archived lineage or, when a proper selected
DNS identity was supplied, an absent lineage for **explicit first issuance**.
No unnamed certificate is issued. No persisted SAN set is expanded to
match the runtime selected SANs on any *other* lineage. A selected existing
lineage may perform the previously authorized SAN reconciliation; an
unselected one may not.

### Deterministic archived inventory and bounded provider actions

First authenticate and validate the retrieved archive and existing account
using the current private-workspace, CA, and safe extraction boundaries.
Require a complete structural inventory and read-only canonical metadata
verification for **every** stored lineage, not merely the selected target.
Derive the initial bulk inventory from matching
`renewal/N.conf`, `live/N/`, and `archive/N/` triplets; use exact
case-sensitive lineage identities, not SAN overlap, Certbot list output or
filesystem enumeration order. Sort the unique initial names in C lexical
order. The archive's existing path, size, count, and type limits bound the
work. Refuse duplicates, unexpected members, cross-lineage links, missing
triplets, unsupported account configurations, or a zero-item inventory
when no selected issuance is expressly requested.

Take that initial inventory **before** any selected or bulk mutation.
Perform the ordinary selected operation at most once when supplied.
For bulk enumeration, skip an archived selected lineage that has already
received its selected operation. Never include a newly issued selected
lineage as another bulk-renew target in that same invocation. The remaining
original archived names are processed once in the stable sorted order.

Each existing unselected lineage is operated on through an exact
`certbot renew --cert-name NAME` call with the verified restored ACME
account, selected CA, private config/work/log paths, non-interactive and
no-directory-hooks flags, and existing Route53 plugin checks. Prepare and
finalize **only that lineage's** canonical renewal-path mapping around
its invocation; never call bare `certbot renew`, `certbot register`,
`--force-renewal`, or a generic wildcard/batch Certbot operation.
Use the lineage's **persisted** verified SANs, not the current
`DOMAIN`/`ADDITIONAL_SANS` or `INCLUDE_SUBDOMAINS`, for checks and
post-renewal certificate verification. Preserve exactly the same DNS
identity set across an unselected renewal; changes require separately
authorized selected reconciliation. Retain original CA/account context,
canonical links, private key restrictions, and hook refusal.

The existing unselected-state fingerprint remains obligatory for the
ordinary path. In the bulk path, replace that blanket comparison only
with an explicit, per-target mutation envelope: snapshot the non-target
lineages around each provider call and reject changes to them, unexpected
creation/removal/renaming, and modification of the original inventory
outside the currently authorized lineage. Only the current target's
validated state and permitted account metadata may change. Revalidate
the *whole* state between targets and before any candidate publication.
Never turn off the integrity checks merely because bulk mode is active.

### Status and publication policy

Classify the selected action separately as issued, renewed, metadata-only,
or unchanged, when applicable. Each archived lineage renewal/check has
exactly one internal result: certificate replaced, metadata-only durable
change, or unchanged. Detect actual certificate replacement using the
existing leaf-byte/link evidence, and other durable changes from verified
configuration state; Certbot exit zero does not prove issuance or change.
A failure is a failure rather than a fourth successful outcome.

Only after **all** selected and archived operations succeed, account
identity remains valid, complete lineage membership is checked, every
surviving certificate/key/SAN/chain passes verification, metadata is
canonical, and the full candidate is valid may the ordinary publisher
run. Compute aggregate `changed=true` when **any** successful target
or permitted account state has a durable change; otherwise it is false.
The existing `UPLOAD_NO_RENEWAL` truth table and exact retrieved S3
bucket/key apply, as do encryption, backup and retention policies.
A fully validated unchanged scan skips upload unless the override is true.
An issuance/renewal/mapping/validation/packaging failure aborts with
nonzero and **never intentionally publishes** partially changed state.
There is no successful partial-completion result.

Provide bounded, nonsecret aggregate counts (archived checked, renewed,
metadata-only, unchanged, and optional explicitly selected issuance) and
publication status **only on success**. Error diagnostics identify stages
without disclosing unselected DNS identities, PEM bytes, account IDs,
renewal-file contents, provider output, private paths, or credentials.
Do not claim that a successful local operation proves remote ACME,
Route53, AWS, or certificate deployment success.

A failed/uncertain S3 PutObject can have altered the remote key despite
a nonzero status; this design does not promise rollback, two-phase S3
commit, locking, or atomicity with optional dated backups/retention.
Writers to the same configured key still require operator serialization.

### Conflicting opt-ins

Before any S3 access, provider execution, or local mutation, reject an
invocation resolving both `RENEW_ALL=true` and `REMOVE_ORPHANS=true`
with a nonzero configuration error. `REMOVE_ORPHANS` is **not**
implemented by this decision; the future feature must honor this rejection
until separately approved governance specifies interaction, ordering, and
authority. Never infer a desired-lineage deletion set from the current
selected name or `--san`.

## Context and Drivers

Story #89 and design task #98 require scheduled checking of every archived
certificate without making ordinary runs global or causing implicit issuance.
ADR-030 already permits multiple complete independent lineages in one S3
archive, including overlapping SAN names, while expressly forbidding bulk
renewal. ADRs 024-026 constrain Certbot actions to an exact selected name,
and ADR-028 permits only complete verified publication to the retrieved key.
The existing public lifecycle verifies unselected state with a fingerprint
and requires a selected name even for account-only archives. The renewal
adapter already knows how to execute a named due-renewal and distinguish
certificate from metadata changes, but its selection and SAN assumptions
must be adapted *narrowly* by task #99. This ADR records that extension
before implementation; code and tests remain separate approved tasks.

## Assumptions and Constraints

- The one restored, previously registered account and selected
  production/staging CA remain the only ACME authority for a run.
- The archive is the complete portable Certbot configuration root, not
  a new manifest or per-lineage S3 object.
- Existing immutable, untrusted archive structure validation and safe
  path mapping run before any provider authority is exercised.
- Bash 4.3 and all three generated producer artifacts remain supported.
- Existing strict CLI parsing, literal config files, external AWS credential
  handling, provider-argv allowlists, and `--no-env` continue to apply.
- A requested new selected lineage is an explicit selected operation,
  not an implicit result of enumerating existing archived lineages.
- Failed local bulk work is disposable because it occurs only in an
  ephemeral owned workspace. S3 publication and external ACME activity
  are **not** reversible transactions.
- Task #99 implements the adapter and public interface; task #100
  supplies comprehensive fresh-runner and fault-mode evidence.

## Alternatives Considered

**Call unqualified `certbot renew`: rejected.** It would delegate
selection to Certbot, risk processing unknown lineages, and bypass exact
per-target containment and duplicate evidence.

**Use `--san` as a list of certificate lineages: rejected.**
Those are DNS names *inside one selected certificate* and overlap is legal.

**Require a selected DNS name in all bulk invocations: rejected.**
It defeats the approved scheduled-maintenance requirement for a
domainless invocation against an existing valid archive.

**Treat a domainless empty/account-only archive as success: rejected.**
No archived lineage can be proven checked, and the mode must not turn
missing state into implicit account registration.

**Disallow explicitly selected issuance in bulk mode: rejected.**
The story preserves ordinary explicitly selected certificate behavior;
scoped first issuance can coexist with checking only the *original*
archived inventory without granting implicit issuance.

**Renew a selected archived lineage twice: rejected.** It creates
unnecessary external activity and ambiguous changed/no-op reporting.

**Publish each successfully renewed lineage immediately: rejected.**
The one-key complete-archive contract and failure safety require one
validated final candidate or none, not repeated partial overwrites.

**Disable unselected mutation checks in bulk mode: rejected.** A
mode-specific per-target exception is necessary; unrestricted changes
remain security-relevant even with an explicit bulk opt-in.

**Allow combined pruning and renewal in arbitrary order: rejected.**
Story #88 has a separate unresolved destructive membership interface.
Implicit composition could silently delete or renew unintended lineages.

## Security and Failure Model

Assets include the existing ACME account credentials, all lineage private
keys, the sole authoritative S3 object, retained recovery generations,
and operator credentials. Trust crosses from a remote archive into local
parsed state, then into external Certbot/Route53/ACME processes, and finally
into S3 PutObject. An attacker or accidental archive corruption could
introduce incomplete triplets, malicious symlinks, hooks, alternative
accounts, cross-lineage mutation, or misleading identities. A faulty
provider can mutate non-target state, report success with no certificate
change, or fail after modifying the private workspace.

The controls are strict pre-extraction limits, full canonical inventory
preflight, case-sensitive exact names, only one named provider operation
at a time, per-target mutation envelopes, post-target and final full
validation, no raw provider output, and no publication after local failure.
Remaining risks are compromised runtime binaries/plugins, external ACME
effects before subsequent local failure, nontransactional S3 writes,
possible post-publication backup/retention faults, concurrent writers,
and limits of mocked protocol tests. Reassess if multi-account archives,
multiple providers, destructive-mode composition, new remote semantics,
or changed dependency/runtime authority is introduced.

## Verification and Migration

No migration of stored archives is necessary. The opt-in defaults off,
so account-only, one-lineage, multiple-lineage and overlapping-SAN
ordinary runs remain subject to existing rules. Task #99 must add the
configuration entry and routing, keep the legacy false branch intact,
and gate all provider effects on full preflight. Task #100 must verify
all three producer flavors, checksums, Bash 4.3 compatibility, mixed
changed/no-op lineages, optional selected issuance/reconciliation,
domainless invocation, exact-once enumeration, invalid archive and
conflicting opt-ins, fault nonpublication, metadata-only changes,
encrypted and no-env cases, and fresh-runner restored identity.

Mocked Certbot/AWS public-executable tests and the isolated
challenge-bypassed Pebble/SeaweedFS harness do not establish live
Route53 IAM/DNS propagation, AWS S3 behavior, or Let's Encrypt
staging interoperability. These remain distinct milestone-4 concerns.

## Relationship to Prior Decisions

This ADR **narrowly extends** ADR-030 and ADRs 024-026 only for
explicit `RENEW_ALL=true`, while preserving selected-only defaults,
account and CA rules, canonical archive limits, and scoped renewal
metadata. ADRs 020-023, 027-028, 029, 031, 033-034, 041-043,
051-056, and the live approval policy ADR-019 remain binding.
Story #88 and its separate design task #95 own destructive membership
and are neither implemented nor preapproved here.
