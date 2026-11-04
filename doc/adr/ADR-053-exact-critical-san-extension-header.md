# ADR-053: Admit the Exact OpenSSL Critical DNS SAN Extension Header

Date: 2026-11-03

## Status

Accepted

## Decision

The selected-certificate SAN reader accepts three precise OpenSSL textual headers:
`X509v3 Subject Alternative Name:`, `X509v3 Subject Alternative Name: `,
and `X509v3 Subject Alternative Name: critical`, each immediately followed
by a newline and the existing single comma-separated line of DNS identities.
The added `critical` spelling represents the criticality attribute of the
same X.509 subjectAltName extension. It does not change which certificate
identities or alternative-name types are admissible.

The existing restrictions remain mandatory: only valid canonical DNS names,
between one and 100 unique entries, no unsupported SAN types, no extra lines,
and an exact requested SAN identity set. The reader does not strip or
normalize arbitrary attributes, prefixes, suffixes, whitespace or
unknown extension headers. The surrounding preflight, expiration,
fullchain/leaf, chain, private-key, and archive publication checks do not change.

## Why This Decision Is Required

In milestone 16, draft PR #260 progressed through a genuine Certbot/Pebble
issuance with deliberately bypassed DNS validation and a local synthetic
Route53 stub, but failed `issue-certificate-verification`. Accepted
diagnostic PR #269 established that the first failing verifier was SAN
verification. The sealed run [41772176673](https://github.com/wesley-dean/certbotbot/actions/runs/41772176673)
proved `san_substage=read`, so exact SAN identity comparison had not yet
been reached. An earlier test-only header probe had malformed Bash; its
`other` label is discarded as unreliable evidence. A rebuilt, packaging-
validated probe on attempt 2 of
[run 41775450237](https://github.com/wesley-dean/certbotbot/actions/runs/41775450237)
reported the exact bounded category `san_header=critical` after
native issuance. Neither certificate text nor its SAN values entered
the public CI log. The first attempt at that run failed earlier at
ACME registration and did not inform this decision.

The reader's existing allowlist permits only noncritical OpenSSL header
spellings; it therefore refuses native Certbot/Pebble material before
checking whether it contains the supported DNS-only identities.
An extension marked critical is required to be understood by consumers,
but criticality is not a new DNS SAN type or a reason to waive identity
checks. Supporting the observed exact spelling repairs compatibility
without expanding the certificate identity contract.

## Assumptions and Constraints

- The producer invokes a trusted installed OpenSSL; textual output is
  potentially version-sensitive and continues to fail closed on change.
- The observed value is the exact literal `critical` suffix in the header.
  Other attributes or suffixes are not covered by the evidence.
- All certificate contents, SAN names, private paths, account identifiers,
  provider output, and private keys must remain absent from diagnostics.
- A local challenge-validation-bypassed Pebble issuance is not evidence
  of live Let's Encrypt, Route53, AWS, or DNS propagation interoperability.
- Existing accepted ADR-022, ADR-024, and ADR-047 remain authoritative.
- Real protocol acceptance must use the unmodified shipped producer artifact.

## Alternatives Considered

1. **Reject critical SAN extensions forever.** Rejected because native
   Certbot/Pebble produces the observed exact variant while satisfying the
   supported extension semantics, making the current strict text parser a
   compatibility obstacle rather than an identity protection.
2. **Ignore the SAN header entirely and search the output for DNS values.**
   Rejected because it could silently admit malformed extension structure
   or unexpected non-DNS entries.
3. **Strip all header attributes, whitespace, or punctuation.** Rejected
   because it would create a general format allowlist with no evidence.
4. **Allow arbitrary criticality markers on all OpenSSL extensions.**
   Rejected because the evidence concerns only the subjectAltName header.
5. **Patch issued certificates or bypass verification in the E2E test.**
   Rejected because it would conceal a production defect and weaken the
   real lifecycle acceptance boundary.
6. **Replace OpenSSL parsing with a new dependency or broad ASN.1 parser.**
   Rejected for this narrow issue; it increases the trusted implementation
   surface without evidence that a larger redesign is required.

## Consequences

The one additional header is recognized, preserving all existing
DNS-name, structural, certificate-integrity and nonpublication-on-failure
checks. Existing noncritical certificates behave identically. The change
introduces no public flags, migrations, new data format, provider
permissions, or network connections. A future OpenSSL header change may
still fail safely and require a new explicit decision.

## Required Verification

Focused tests must prove critical-header acceptance while refusing
malformed critical suffixes, unknown extension attributes, non-DNS
entries, duplicates, and exact SAN set drift. All three shipped producer
flavors must pass maintained test/build gates and OCI acceptance, plus
CodeQL and MegaLinter. Following review and merge, PR #260 must incorporate
this change and prove genuine first issuance, independent SeaweedFS readback,
three no-ops, a second Pebble order, seven negative cases, active no-egress
probes, and defensive cleanup. No claim of E2E completion is authorized
before those gates are observed passing.

## Related Decisions

ADR-022 governs portable Certbot state, ADR-024 selected certificate
issuance, ADR-047 the local challenge-validation-bypassed E2E model,
ADR-051 the invocation-private renewal directory fields, and ADR-052 the
exact singleton DNS-01 renewal tuple. ADR-053 adds only the observed
critical SAN text-header spelling to the existing strict reader.
