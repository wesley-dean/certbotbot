# MVP Certificate Lineage Naming Contract

Status: normative selected-certificate naming specification for approved
task #92 and story #87. This document elaborates the **existing**
[ADR-020](adr/ADR-020-one-selected-certificate-and-one-durable-archive.md);
it introduces no competing architecture or new CLI flag. It should be read
with the [MVP configuration contract](mvp-configuration.md),
[ADR-023](adr/ADR-023-fail-closed-restored-acme-preflight.md) and
[ADR-026](adr/ADR-026-controlled-existing-lineage-san-reconciliation.md).

## Public inputs and precedence

An MVP invocation manages exactly **one certificate** identified by one
primary DNS name and, optionally, its complementary apex/wildcard SAN.
The supported lineage-name setting is `CERT_NAME` in the literal .env file
or exported process environment, and `--cert-name NAME` (or
`--cert-name=NAME`) on the command line. The existing resolver applies
CLI > environment > literal .env > built-in derived-name default
independently for this setting. An empty `CERT_NAME` means derive
the name from the selected SAN set; an empty value does not select an
existing archive lineage by guessing.

An explicit name must pass the same canonical ASCII DNS-label validation
as a non-wildcard DNS identity: two or more labels, lower-case letters,
digits and interior hyphens, labels 1-63 characters, full name no longer
than 253 characters, no leading/trailing dot, and **no wildcard**.
Unlike the primary `DOMAIN`, an explicit `CERT_NAME` must already use
lowercase canonical syntax; it is not normalized silently. Invalid values
fail with status 64 **before any S3/Certbot call**. Literal .env contents
are never sourced, interpolated, or evaluated as shell code.

The lineage identifier is separate from the requested certificate SANs.
Using `CERT_NAME=renewal.example.com` does not automatically add
`renewal.example.com` to the certificate's SAN list. It is also distinct
from the selected S3 **object key**, whose MVP default is `latest.tar.gz`;
changing one setting does not change either of the others.

## Deterministic default

When no explicit name is supplied, select the shortest **full textual**
string from the requested and derived, deduplicated SAN list. The wildcard
prefix `*.` counts as two characters. In the event of an exact length
tie, the required ordering is deterministic ASCII lexical ordering of
canonical lowercase SAN strings; the first name in the caller's input
is not itself the tie-break. This last rule is prospective: the MVP's
one-primary-name plus optional complement cannot produce an equal-length
pair of distinct accepted SANs. Additional-SAN input is a later milestone
and must test cross-locale ordering before it becomes a public interface.

| Situation | Name and behavior | Remote archive |
| --- | --- | --- |
| `example.com`, complement enabled, no override | `example.com` (shorter than `*.example.com`) | Same configured key |
| `*.example.com`, complement enabled, no override | `example.com` (derived apex is shorter) | Same configured key |
| `example.com`, complement disabled, no override | `example.com` | Same configured key |
| `*.example.com`, complement disabled, no override | `*.example.com` would be derived but is not a valid non-wildcard Certbot lineage name; fail status 64 before cloud access | Unchanged |
| Explicit `--cert-name issued.example.com` | Use `issued.example.com` as lineage identifier, issue SANs from the selected primary name/complement | Same configured key |
| `CERT_NAME=file.example.com` in .env, `CERT_NAME=env.example.com` exported, `--cert-name cli.example.com` | Use `cli.example.com` (highest precedence) | Same configured key |
| Distinct equal-length SANs (future multi-SAN capability only) | Use ASCII-lexically first SAN, independent of order; no such public MVP invocation exists | No additional key |
| Explicit empty name or absent `CERT_NAME` | Compute the deterministic default; never guess from host files | Same configured key |
| Invalid explicit name (wildcard, uppercase, unsafe punctuation, traversal, trailing dot) | Reject status 64, before S3/Certbot | Unchanged |
| Archive contains no lineage but valid existing ACME account | Issue the resolved lineage name explicitly | One existing object updated after verified success |
| Archive contains exactly the resolved selected lineage | Preserve that lineage for selected-only no-op, renewal, or approved same-apex SAN reconciliation | Same configured key |
| Archive contains another, legacy, extra, orphan, or conflicting lineage name | Fail closed rather than rename, number, migrate or add a second lineage | Unchanged |
| SAN policy changes but resolves to a **different** implicit name | Fail against the existing archive; supply the *original* `CERT_NAME` explicitly where the approved same-apex SAN change is otherwise valid | Unchanged on conflict |

The fourth row is an important exception to an otherwise general shortest-SAN
rule: the public MVP refuses a wildcard-only **derived certificate lineage
name**, because a Certbot lineage identifier must be non-wildcard.
The wildcard SAN remains valid certificate input when a separate explicit
non-wildcard `CERT_NAME` is supplied.

## Existing lineage identity and conflict policy

The archive may contain only an existing production ACME account (first
issuance), or exactly the selected verified Certbot lineage and that account.
Before calling Certbot, the private workspace restores and validates the
archive against the selected identity. The selected `--cert-name` is passed
to issuance/renewal; the tool must not accept Certbot's automatic suffixes
or select an unrelated archived name.

A stored lineage is durable identity, **not** a name to recompute from the
new leaf's SAN list. If a change in `INCLUDE_SUBDOMAINS` changes the
implicitly derived identifier, the operator must supply the preserved
original `CERT_NAME` for same-lineage reconciliation or accept a
nonzero conflict. ADR-026 permits only bounded same-apex/wildcard SAN
reconciliation; it does not permit renaming or migrating a lineage.
Arbitrary or legacy names in the same single-archive layout cannot be
inferred from common names, directory contents, or a loose SAN match.
A migration command and multiple independently named lineages belong to
later, separately approved product scope.

## Error, security and test boundaries

Identity parsing/validation occurs before remote mutation, and must avoid
logging raw unexpected input. An invalid name returns 64. A conflicting
or structurally unsafe restored lineage fails with a stage-specific nonzero
status after a read but before issuance/renewal or publication. If a selected
Certbot operation or post-operation archive check fails, PutObject must not
be invoked. This contract does not promise distributed locking or recovery
from a failed/in-flight PutObject; remote state can be uncertain once a write
has started.

Current supporting evidence includes `tests/config-identity.bats` for
literal configuration precedence, explicit override, apex/wildcard default
and malformed identifiers, and `tests/public-lifecycle.bats` for
restored-lineage and independent-runner continuity. Task #93 will review
the actual public integration against this entire contract. Task #94 owns
additional black-box matrices for conflicts, stable explicit overrides,
SAN transitions, and all three release artifacts. Only the supported
one-primary-name case is claimed as implemented in milestone #1.

No new accepted ADR is required for this task because ADR-020, ADR-023,
ADR-025 and ADR-026 already govern the relevant choices. If task #93
finds a conflict between maintained source and those decisions, the source
or bounded integration behavior must be corrected; this spec cannot silently
supersede the ADRs.
