# ADR-052: Preserve Certbot's Singleton DNS-01 Renewal Challenge Tuple

Date: 2026-11-03

## Status

Accepted

## Decision

The supported Certbot renewal configuration parser accepts exactly two representations of the single DNS-01 preferred challenge when the key is `pref_challs`: `dns-01` and `dns-01,`. The trailing comma is Certbot's serialized one-element sequence delimiter, not permission for an additional challenge. Both values remain unchanged through prepare, finalize, and read-only verify. The distinct `preferred_challenges` key, when present, continues to require exactly `dns-01` without a terminal comma. Any other challenge type, additional list entry, malformed delimiter, alternative whitespace within the value, or unknown configuration key fails closed before any write. No credentials, execution hooks, ACME account/server identity, DNS plugin, runtime paths, public options, or archive format may change.

## Context and Evidence

The native isolated milestone-16 Certbot/Pebble/SeaweedFS E2E run in PR #260 reached the synthetic Route53 change-status poll but failed with `unsupported renewal configuration` after issuance. Accepted ADR-051 addressed Certbot 5.8's three ephemeral directory flags but a subsequent real run remained red. Issue #266 introduced fixed-category diagnostics, and an independent native run reported the exact rejected field category `renewal-pref_challs`. The error category does not reveal the actual value. Documented Certbot renewal examples, including the historic Certbot preferred-challenge change and existing DNS-01 renewal configurations, show the one-element `dns-01,` spelling. The hypothesis that the real file uses that representation must still be verified by a successful E2E rerun; the present evidence does not justify broader acceptance.

This decision narrows compatibility handling of one already allowlisted DNS-01-only key. The five canonical path mappings and the exact ephemeral-directory omission allowed by ADR-051 are unchanged. ADR-022's demand for portable, fail-closed Certbot state remains governing.

## Security and Compatibility Boundaries

- Accept only `dns-01` and `dns-01,` when the key is `pref_challs`, and only `dns-01` for `preferred_challenges`.
- Preserve input bytes of the value and surrounding metadata; do not normalize, strip punctuation, reorder, evaluate, or regenerate configuration.
- Require account, server, authenticator, lineage, and certificate mappings exactly as before. Reject hooks, extra sections, unknown keys, second challenge entries, HTTP-01, arbitrary commas, and noncanonical private paths.
- Maintain parse-before-mutation, same-directory replacement, no partial updates after failure, and nonpublication of a rejected archive.
- Do not print untrusted renewal keys, values, paths, account data, provider responses, or certificate material. Fixed allowlisted refusal labels remain the only additional diagnostic.
- The private local integration harness bypasses challenge validation and mocks Route53. Success there is not proof of real DNS authorization, Let's Encrypt interoperability, IAM, or Amazon S3 compatibility.
- Certbot can change serialization again; such a format must fail closed and require new evidence, tests, and review rather than permissive parsing.

## Alternatives Considered

1. Reject the comma unconditionally: retains current behavior but refuses a documented single-element serialization of precisely the supported DNS-01 mode, preventing valid renewal archives.
2. Strip commas and reserialize all values: rejected because transformation can alter Certbot's native semantics and break byte-preserving archive portability.
3. Allow comma-delimited challenge lists: rejected because it would admit alternate ACME challenge modes beyond the DNS-01-only contract.
4. Permit the trailing comma for every challenge-related key: rejected because the evidence concerns only the native `pref_challs` representation.
5. Patch only the local test's generated renewal file: rejected because it would conceal a real producer defect and could generate a false-green E2E gate.
6. Relax the whole renewal schema or log raw native config: rejected as incompatible with ADR-022's untrusted-state controls and private-material boundaries.

## Consequences and Verification

The parser retains one additional exact native Certbot representation for the same single DNS-01 challenge and leaves it byte-for-byte unchanged. All existing canonical and private path, ACME, account, hook, and S3 safety gates retain their prior behavior. The original `dns-01` spelling remains accepted for backward compatibility. No migration or new public input is required.

Focused tests must establish prepare/finalize round-tripping, verify acceptance, coexistence with exactly verified ephemeral directory options, rejection and byte-preservation for HTTP-01/multiple/malformed challenge representations, and no widening of `preferred_challenges`. All shipped producer flavors must pass. The final PR #260 integration must also pass its genuine second Pebble ACME order, independent SeaweedFS publication/readback, no-op and seven negative scenarios, both no-egress probes, and cleanup before claiming milestone acceptance.

## Related Decisions

ADR-022 remains authoritative for portable Certbot archives and conservative renewal parsing. ADR-051 governs verified ephemeral directory option removal during finalize. ADR-047 governs deliberately bypassed local DNS validation, ADR-042 governs immutable ACME authority selection, and ADR-048 governs push-based test triggers. This ADR specifies one value-dialect compatibility exception and does not supersede any of those decisions.
