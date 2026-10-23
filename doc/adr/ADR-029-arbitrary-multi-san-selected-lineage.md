# ADR-029: Arbitrary DNS SAN Sets on One Stable Certificate Lineage

Date: 2026-10-23

## Status

Accepted

## Context

Approved story #15 permits a primary DNS identity and multiple additional DNS
subject alternative names (SANs) on **one selected certificate lineage**.
Additional names may be unrelated to the primary identity: for example,
`example.com`, `api.example.net`, and `service.other.org` may appear on
the same issued certificate. The Product Owner clarified on October 20, 2026,
that `INCLUDE_SUBDOMAINS` applies separately to **every** explicitly supplied
name. Story #15 and task #44 currently bear the authoritative `approved`
labels under ADR-019.

The original MVP's ADR-020 allows one public primary name, and ADR-026
limits existing-lineage SAN reconciliation to one apex/wildcard pair.
Those restrictions conflict with the additional-SAN feature. At the same
time, stable Certbot lineage selection, safe archive handling, registered
ACME account continuity, no-op behavior, and one existing authoritative
S3 object remain intentional security and compatibility boundaries.

A **different approved story #56** will permit multiple independent,
potentially unrelated certificate lineages in the **same** archive. That
later work must change the archive preflight and packaging rules. It is
not a prerequisite for putting unrelated DNS SANs on one certificate,
and must not be conflated with a single invocation managing several
certificates.

## Decision Drivers

- Satisfy story #15 for unrelated DNS names without requiring a shared apex.
- Preserve backward compatibility for invocations without additional SANs.
- Define an unambiguous CLI, environment, and literal `.env` input schema.
- Make precedence and ordering deterministic across independent runners.
- Avoid implicit Certbot lineage renaming, numbering, or unrelated selection.
- Reject untrusted input and incomplete certificate state before mutations.
- Preserve ADR-025's due-renewal and unchanged-no-op behavior.
- Keep Bash 4.3 support without introducing new runtime dependencies.
- Separate task #44's architectural contract from task #45's implementation.

## Decision

### Public interface

Exactly one **primary DNS name** remains required. It uses the existing
`--domain NAME`, `--domain=NAME`, single positional `DNS_NAME`,
or `DOMAIN` setting, with the existing conflict rules.

Additional SANs use a new **repeatable** CLI option:
`--san NAME` or `--san=NAME`. Multiple distinct occurrences are legal,
including repeats of the same DNS identity. Every `--san` supplies
exactly one name, never a comma-separated list. Positional arguments
still supply **only the primary**; additional positional names are errors,
including after `--`. No `--sans` or other undocumented synonym is added.

In the exported environment or literal `.env`, the new optional
`ADDITIONAL_SANS` setting is a comma-separated list of DNS names:
`api.example.net,service.other.org`. There is no shell-style array,
space-delimited list, globbing, expansion, quoting of individual elements,
or backslash escaping within this list. The existing `.env` outer
single/double quote removal is permitted; thereafter all list tokens
must be literal DNS names. Empty `ADDITIONAL_SANS` means **no extras**;
an empty element (including leading/trailing/doubled commas) is invalid.

The additional-SAN **collection** has one source-selected precedence:
one or more CLI `--san` flags **replace** the entire environment/file
list; otherwise an explicitly exported `ADDITIONAL_SANS` replaces the
file value; otherwise the literal file value is used; otherwise the
collection is empty. CLI values are not appended to lower-priority values.
Primary name, `INCLUDE_SUBDOMAINS`, `CERT_NAME`, and S3 options
retain their independently resolved existing precedence of
CLI > exported environment > literal `.env` > default.

CLI `--san` flags, whether repeated or not, are the only exception to
the MVP rule against duplicate options. Duplicates for `--domain`,
`--cert-name`, and other single-valued flags remain invalid. A
repeated `ADDITIONAL_SANS` assignment in `.env` is also invalid.

### DNS names, expansion, and order

Each explicit primary/additional DNS name is ASCII case-normalized to
lowercase and then validated using the existing DNS identity grammar:
two or more labels, a maximum 253-character ordinary name, labels
1-63 characters, lowercase ASCII letters/digits/interior hyphens,
and only a possible **leading** `*.` wildcard. IDNs must already be
valid ASCII A-labels. Reject trailing dots, whitespace, shell expression
syntax, empty names, malformed wildcards, and invalid labels.

For each explicitly supplied identity, in primary-then-additional input
order, append that literal canonical name. Only if
`INCLUDE_SUBDOMAINS=true`, append **one** complementary name: ordinary
`foo.example.net` adds `*.foo.example.net`; explicit
`*.foo.example.net` adds `foo.example.net`. Treat each explicit
identity independently, including names from unrelated zones.
**Do not recurse** on derived names. Deduplicate all explicit and
derived identities by their canonical string, keeping the first
occurrence. This stable first-occurrence order preserves MVP
argument order when no extras are given. Exact SAN equality is
**set-based**, independent of that argument order.

The explicit collection, including the primary, is bounded to **100
entries** before de-duplication; the final unique expanded SAN set is
bounded to **100 names**. These are project-defined safety caps, not
a promise of acceptance by any ACME server. A larger input or expanded
set fails before cloud or Certbot operations. Multiple textually equal
names, including a name supplied explicitly and also derived as a
complement, are valid and silently deduplicated after validation.
No unrelated names are discovered from certificate contents, zones,
renewal configuration, or other archived lineages.

Examples:

| Primary | Additional names | Complement setting | Effective unique names, in order |
| --- | --- | --- | --- |
| `example.com` | none | true | `example.com`, `*.example.com` |
| `example.com` | `api.example.net`, `service.other.org` | true | `example.com`, `*.example.com`, `api.example.net`, `*.api.example.net`, `service.other.org`, `*.service.other.org` |
| `*.example.com` | `api.other.org`, `*.api.other.org` | true | `*.example.com`, `example.com`, `api.other.org`, `*.api.other.org` |
| `example.com` | `*.other.org`, `example.com` | false | `example.com`, `*.other.org` |

### Identity, reconciliation, and persistence

The desired SAN list is **one certificate's name set**, never a list
of independently managed certificate lineages. The existing
`CERT_NAME` explicit override continues to identify exactly one
non-wildcard lineage; an absent override continues to derive the
shortest full textual SAN name with an ASCII lexical tie-break
(`LC_ALL=C`), independent of input order. In particular, wildcard
prefixes count toward length, and a wildcard-only derived lineage
name is invalid.

On a subsequent invocation the selected **established lineage name**
is authoritative, not recomputed from the restored certificate's
current SANs. Adding a shorter SAN may change the default-derived
`CERT_NAME`; if so, the call must use an explicit established
`CERT_NAME` to target the existing lineage, or fail closed before
Certbot. No implicit renaming, numbered replacement, or choice of
an unrelated archived lineage is authorized.

Once the selected existing lineage and production ACME account have
passed preflight, compare its actual supported DNS-only leaf SAN set
against the fully resolved requested set. If the sets match, use
ordinary selected-only `certbot renew --cert-name` under ADR-025,
preserving due-renewal and unchanged-no-op classification. If they
differ, update **only that same existing selected lineage** with
`certbot certonly --cert-name NAME --renew-with-new-domains`,
exact separate `-d` arguments, the previously restored account,
Route53 DNS-01, production ACME server, private directories, and
noninteractive hook suppression under ADR-026's remaining gates.

Unlike ADR-026's previous restriction, the old and requested valid
SAN sets may have **different DNS apexes or no overlap at all**.
There is no domain-relationship check. A wholly disjoint transition
still requires the **same explicit selected lineage** and every
normal state, authority, and publication gate. A new absent lineage
uses the existing selected-only issuance provider, with the expanded
desired SANs only after normal preflight.

The requested SAN collection must be valid, canonical, nonempty,
distinct after expansion, and within limits before provider execution.
The actual certificate's complete DNS-only SAN extension must likewise
be validated (including count and uniqueness), not treated as a
failed equality check that silently licenses reissuance of an
unparseable certificate. In particular, malformed/duplicate/non-DNS
actual extensions **fail closed** before Certbot. A successful
reconciliation must result in the **exact desired set**, verified
selected identity and account, usable certificate/key, canonical
renewal metadata, actual certificate replacement, and valid candidate
archive before any PutObject. Provider zero exit is insufficient.

No change is made to the one mandatory seeded S3 object (default
`latest.tar.gz`), private workspace, stable account, no-op upload
policy, or no-rollback/no-concurrent-writer limitation in ADR-020
through ADR-028. Other independent lineages in one archive remain
unsupported by the current implementation **until story #56 is
implemented under a separate archive-compatibility ADR**. That is a
sequencing limitation, not a claim that the feature forbids unrelated
certificates in the eventual Milestone #2 product.

## Promises

- Unrelated DNS SANs may share one explicitly selected certificate.
- The complement rule applies once to every explicit identity when enabled.
- Name and collection parsing are deterministic and independent of shell
  interpolation and process locale for the naming tie-break.
- The chosen old lineage name, restored account, and one archive key are
  preserved; a failed stage does not authorize publication.
- Matching SAN sets never force issuance merely because extra-name
  configuration was supplied.

## Non-Promises

- A single invocation cannot issue or renew multiple lineages.
- This ADR does not implement multiple preserved lineages or permit
  additional S3 keys. Story #56 governs common-archive lineages later.
- Distinct DNS zones may need independently authorized Route53 access.
  Accepted configuration is not proof of ACME validation eligibility,
  successful DNS challenge, CA issuance, or certificate trust.
- There are no distributed locks, in-place Certbot rollback, guaranteed
  remote rollback after a failed PutObject, or live-service E2E guarantees.

## Adversary and Failure Model

Untrusted CLI, exported environment, and literal `.env` names can
be malformed, excessively numerous, repeated, or designed to become
Certbot options or shell syntax. Normalize and validate before any
AWS/Certbot operation; never evaluate strings or concatenate commands.
Emit fixed diagnostics with no raw input, secret account identity, or
private-key material.

A restored certificate may contain malformed SAN data, unknown SAN
types, duplicates, missing lineage files, executable renewal hooks,
or conflicting account information. Reject structurally unsupported
state before provider execution and before publication. Avoid a
comparison routine that treats an invalid existing SAN set as ordinary
drift. Independent provider failure, account mismatch, incomplete
post-state, wrong key/certificate, and candidate serialization failure
leave only disposable local state. A provider can still create external
ACME/DNS side effects before a later failure. Unrelated domain names
increase the operator-controlled Route53/ACME authorization scope, not
the authority granted to code by default.

## Operational Constraints

- MUST apply the resolved complement rule independently to every
  explicit primary and additional name; MUST NOT recurse.
- MUST allow unrelated DNS zones in one SAN set.
- MUST use one source-selected additional-name collection and preserve
  the precedence of other settings.
- MUST validate and deduplicate names before any AWS or Certbot call;
  MUST reject malformed or excessive inputs.
- MUST preserve existing single-primary argument behavior without extras.
- MUST use exact selected `CERT_NAME` and account for issuance, renewal,
  and reconciliation, never global renew or implicit lineage selection.
- MUST distinguish valid-but-different actual SANs from malformed
  existing SANs; both before and after Certbot, validate all SAN types.
- MUST keep no-op semantics, single-key persistence, candidate checks,
  and security gates of ADR-020 through ADR-028.
- MUST separately review archive changes for story #56 rather than
  assuming multi-SAN approval authorizes multi-lineage storage.

## Considered Alternatives

**Restrict additional names to the primary apex:** rejected; conflicts
with the approved story and would exclude unrelated DNS zones.

**Treat each extra name as a separate certificate:** rejected for
story #15; it would evade stable selected-lineage semantics and is
different from approved story #56.

**Permit multiple primary positional identities:** rejected for this
scope because it could mean multiple SANs or multiple certificate
targets. A separate `--san` flag makes the distinction explicit.

**Append CLI values to environment/file values:** rejected because
lower-precedence, potentially stale names would silently persist and
change issuance authority.

**Use a shell array, whitespace list, or eval in `.env`:** rejected
because delimiter and evaluation ambiguity is unsuitable near
credentials and externally authorized certificate names.

**Reject repeated explicit names:** rejected because repetitions
arising from a caller or the complement rule are harmless when
validated and deduplicated consistently.

**Sort all SAN arguments lexically:** rejected for compatibility with
existing primary-first MVP argument order. Set comparison and
shortest-name tie-breaking remain independent of input order.

**Choose a new `CERT_NAME` when SAN membership changes:** rejected:
a certificate's durable lineage identity is not its changing SAN list.

**Reconcile every mismatch as if it were valid SAN drift:** rejected.
An unsupported/malformed existing leaf cannot be trusted merely
because it differs from the requested set.

**Force renewal for matching SANs:** rejected as unnecessary issuance
and contrary to ADR-025's due-renewal/no-op contract.

## Consequences and Compatibility

This is a **design-only task #44**. The interface described here is a
normative target for task #45 and is **not implemented yet**. Until #45
is merged, the public executable continues to reject `--san`,
`ADDITIONAL_SANS` is not recognized as a literal file key, and
the provider continues enforcing the MVP one-or-two-name policy.
Task #46 supplies the broad black-box, negative-security,
Bash-4.3, and three-release-artifact verification matrix.

Single-primary existing invocations and their provider argument order
retain their prior meaning. One-lineage archive compatibility remains
unchanged. The expanded SAN set can increase provider arguments,
certificate issuance authority across zones, and operator DNS/IAM
configuration requirements; these are deliberate and testable.
The selected lineage's stable identity remains explicit during
membership changes, especially when a new shorter name would
otherwise change the default derived certificate name.

## Superseded Decisions

This ADR supersedes **only** ADR-020's MVP one-input-identity
restriction and ADR-026's same-apex/apex-wildcard-only SAN transition
restriction, for **one selected certificate with multiple DNS SANs**.
It does not supersede ADR-020's one authoritative archive,
ADR-023's currently one-lineage archive preflight, ADR-025's
due-renewal/no-op policy, or ADR-026's explicit cert-name, account,
hook, path, and post-validation gates. Story #56 will separately
address the **archive-lineage count** and relevant earlier ADRs.

## Related Decisions and Follow-Ups

- ADR-019: approved-label authorization and PR review.
- ADR-020: chosen certificate, name derivation, configuration
  precedence, and one existing S3 object.
- ADR-022/023: portable archive and account/lineage preflight.
- ADR-024/025/026: selected provider, matching-SAN no-op renewal,
  and verified SAN change.
- ADR-027/028: verified package and one-key publication.
- Story #15, tasks #44-#46: one selected lineage with additional SANs.
- Story #56, tasks #60-#62: later independent unrelated lineages in
  one common archive; not implied by this ADR.
