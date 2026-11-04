# ADR-055: Explicit ID-First Synthetic Route53 Zone Selection

Date: 2026-11-04

## Status

Accepted

**Scope:** Approved issue #252, milestone #19, in the local, sealed
Pebble/SeaweedFS test harness only.  No public certbotbot configuration,
certificate issuance behavior, production provider, or real AWS API changes.

## Decision

The test-only Route53 stub shall require a positively selected single
synthetic hosted zone before opening its HTTP listener.  The selection uses
two independent test-only variables:

- `LOCAL_E2E_ROUTE53_HOSTED_ZONE_ID` is authoritative when supplied.
- `LOCAL_E2E_ROUTE53_HOSTED_ZONE_NAME` provides name-only selection
  when no zone ID is supplied.

A valid explicit ID selects the fixed, authorized local zone even if a
different, syntactically valid name is also present; an invalid, empty,
or unknown explicit ID fails closed and never falls back to a name.
Malformed or explicitly empty names are refused rather than ignored.
Name-only selection requires a case-insensitive, terminal-dot-normalized,
exact match against the one allowed synthetic fixture.  Missing both
variables, unknown names, unsupported inputs and ambiguous selections
fail before any HTTP provider request or listener starts.  The pinned
CI Compose service supplies the known synthetic ID explicitly.

The stub also permits the minimum synthetic `ListHostedZonesByName`
read needed to demonstrate the name-based lookup interface, returning
only that one authorized zone.  The existing upstream Certbot plugin
may continue to request `ListHostedZones` independently; the harness
does not alter that plugin or assume it uses the new name-only
selection path.  Record-set mutation remains scoped to the one fixed
authorized synthetic zone and approved TXT names.  A supplied selector
never acts as an arbitrary zone discovery request or external endpoint.

## Context and Constraints

The original Route53 adapter needed Certbot-compatible
`ListHostedZones`, `ChangeResourceRecordSets` and `GetChange`
operations, along with correctly preserved multiple TXT values.  Those
compatibility corrections were merged as part of milestone #16.
Issue #252 separately requested deterministic ID-first selection and
name-based lookup for local harness configuration.

ADR-047 superseded the portion of ADR-046 that would have treated actual
Route53 DNS-01 challenge propagation as local E2E acceptance.  The local
harness uses real Certbot and Pebble ACME transactions, but
`PEBBLE_VA_ALWAYS_VALID=1` bypasses DNS challenge verification and a
minimal Route53 stub answers only synthetic API calls.  No real AWS
credentials, externally accessible services, or host-provider fallback
are permitted.  The existing fixed synthetic zone is intentionally
retained: changing its DNS namespace or deriving it from arbitrary
environment values would require broader test-fixture and security
analysis beyond issue #252.

## Assumptions

- The selected CI fixture remains `ZLOCALONLY123456` /
  `e2e.test.`; unknown zone IDs and names are rejected.
- The official Certbot plugin continues to consume the synthetic
  `ListHostedZones` and record-set APIs regardless of which harness
  selector supplied the authorized zone.
- The new name-lookup API demonstrates selection against that fixed
  fixture. It does not establish real AWS hosted-zone enumeration or IAM
  permissions.
- The Compose manifest, rather than ambient host values, supplies the
  explicit CI zone selector; pre-existing isolated container boundaries
  remain unchanged.

## Security and Failure Boundaries

The trusted boundary includes only the checked repository's Compose
configuration, Python standard-library stub, test-runner verification,
and synthetic credentials.  Explicit ID/name input is untrusted
configuration data.  It is validated before listener startup and cannot
change endpoint addresses, AWS clients, account state, or CA selection.
The API refuses foreign zones, unknown paths, unsupported operations,
invalid synthetic authorization, malicious TXT records, and incompatible
cleanup without mutating existing synthetic state.

Observable test receipts and errors must not include credentials, TXT
contents, private certificate data, or raw request paths.  The stub
does not validate SigV4 cryptography or implement actual DNS resolution;
host or Docker daemon compromise is outside its isolation guarantee.
No successful local run may be advertised as evidence of actual Route53,
DNS-01 propagation, AWS S3, or Let's Encrypt staging interoperability.

## Alternatives Considered

1. **Retain only fixed implicit selection.** Rejected because it leaves
   the approved configuration interface unimplemented and silently
   chooses a zone when configuration is absent.
2. **Select an arbitrary name or ID from the operator environment.**
   Rejected because it would widen the fixture's authority and make
   fail-closed isolation harder to establish.
3. **Fall back from invalid ID to valid name.** Rejected because it
   violates the Product Owner's ID-first precedence contract.
4. **Use real AWS Route53 discovery.** Rejected because external network
   and live credentials are outside the local test's trust boundary.
5. **Use the explicit fixed-fixture ID-first contract.** Accepted:
   test-only configurability with narrow, inspectable failure behavior.

## Consequences and Compatibility

The pinned Compose definition must provide an explicit valid selector
for ordinary full CI.  Local callers omitting both variables will now
receive a bounded, nonzero startup failure.  Focused unit tests exercise
ID-only, name-only, both-present, missing, malformed, unknown and foreign
selections, as well as the bounded synthetic lookup response and
existing mutation isolation.

No released files, producer flags, persistence formats, or native
Certbot options change.  The existing full positive, negative,
no-egress, and teardown CI gates remain mandatory and cannot be
replaced by passing the Python unit tests.  Reconsider this decision
only when the synthetic zone fixture or the relevant plugin API
contract intentionally changes.

## Related Decisions

ADR-015, ADR-016, ADR-019, ADR-024, ADR-042, ADR-046, ADR-047,
ADR-048, ADR-049 and ADR-054.
