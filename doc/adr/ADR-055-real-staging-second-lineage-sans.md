# ADR-055: Align Real Staging Second Lineage with Mandatory Apex-and-Wildcard SANs

Date: 2026-10-17

## Status

Accepted

## Decision

Correct the inactive, explicitly installed six-runner ACME staging evidence
example introduced by ADR-053.  The additional independently selected
lineage MUST request and verify the two authoritative identities:

- the concrete canonical `second_name` DNS name;
- its corresponding `*.<second_name>` wildcard DNS name.

A second lineage with only the bare `second_name` MUST NOT be accepted as
successful product portability evidence.  It does not represent the
certificate identity that the actual certbotbot issuer is required to
produce.  The helper used by both second-lineage issuance and the
independent final verification MUST call the existing exact-SAN
validator with the same two names it passes to Certbot.  No new SAN
validator flags or exceptions are permitted.

This decision **supersedes only ADR-053's statements specifying a
single-SAN second certificate**.  All other ADR-053 requirements,
including independent coexisting lineages, separate ciphertext
archives, account-key continuity, strict archive validation, the
inactive workflow location, and separately approved Route53 staging
credentials, remain Accepted and binding.  ADR-018 and ADR-036
continue to govern certificate identity unchanged.

The second identity is still a concrete, lower-case, non-wildcard
name strictly beneath the authorized base staging DNS name and
different from the first lineage's `extra_name`.  Both the concrete
and wildcard names require TXT validation at their appropriate
`_acme-challenge` name.  The operator MUST verify that the narrow
Route53 role can change only the necessary TXT records for this
explicitly approved staging set; the change does not grant general
hosted-zone administration.

The six-stage example remains outside `.github/workflows/` and cannot
run from a pull request, normal CI, schedule, or release.  Production
issuer exit status 69, ADR-037's active-import restriction, the
protected `acme-staging` environment, and real-credential consent
requirements remain unchanged.

## Context

ADR-018 has always required each named certificate lineage to include
both its base name and leading wildcard.  ADR-036's existing
`certbotbot_crypto_verify_sans` explicitly rejects a SAN request
omitting either.  The real staging example originally applied that
rule to the primary lineage and its SAN-change phase.

ADR-053 added a fifth runner issuing an independent second lineage
with only `-d "$second_name"` and checking only that SAN.  The
exact-SAN validator, correctly obeying ADR-036, necessarily returns
64 because the second lineage lacks its mandatory wildcard.  The
same defect is present in the sixth runner, which rechecks the
second certificate.  Thus even with perfect DNS, credentials,
registered ACME account continuity, and successful issuance, the
test could never pass.

This defect is determinable from the source and repository governance,
without spending rate-limited live staging issuance requests.  It
must be corrected before asking an operator to run the real test.

## Assumptions and constraints

- The previously accepted staging DNS scope already includes an
  operator-owned base and additional concrete subdomain; a distinct
  second subdomain is also operator-owned and inside that base.
- DNS-01 for a base-plus-wildcard pair may use the same challenge
  record name and needs no HTTP or TLS-ALPN authority.
- Certbot's pinned version and Route53 authenticator are otherwise
  unchanged; the operator continues to review real ACME evidence
  rather than treating synthetic tests as equivalent.
- The staging private workspace, stored common account, and selected
  lineages remain completely disposable between separate runners.
- Exact-SAN validation must not be weakened merely to make a
  test fixture green.

## Alternatives considered

**Broaden the exact SAN verifier to accept base-only lineages:**
rejected because it violates ADR-018/036 and would accidentally
authorize nonrepresentative producer output.  A new general-purpose
single-SAN certificate product is out of scope.

**Omit exact-SAN validation from the second runner:** rejected because
an unverified certificate identity would undermine the test's
purpose and ADR-036's security requirement.

**Treat the first lineage's SAN-changed certificate as the second
lineage:** rejected for the existing ADR-053 reason: one modified
lineage is not evidence of two coexisting independent archives.

**Create a new authoritative DNS zone for the second lineage:**
rejected because it broadens permissions and produces evidence
unnecessary for the defined portability requirement.  A properly
scoped subdomain in the same authorized test zone suffices.

**Proceed directly to live staging and diagnose the expected failure
there:** rejected to avoid wasting operator effort, DNS changes,
ACME requests, and protected CI access on a known impossible case.

## Consequences, testing, and verification

The fifth runner supplies both `-d <second_name>` and
`-d *.<second_name>` to the already pinned staging Certbot, and the
shared second-lineage verifier passes those same two identities
to the existing exact-SAN function.  The final runner validates both
lineages while remaining read-only with no AWS role or Certbot.

Offline regression tests MUST prove that:
- the complete second-lineage identity pair passes exact-SAN
  validation against a locally signed leaf under an explicitly
  selected test CA;
- a leaf missing the wildcard is rejected without changing its
  private workspace or triggering an external operation;
- the staging example's command includes both identities and
  retains only manual opt-in placement and protected environment
  authorization;
- every standalone artifact flavor continues to pass normal
  issuer-disabled behavior and the existing security tests.

These tests are preparatory evidence only.  Real ACME account reuse,
staging issuance, and recovery remain unproven until a separately
authorized six-runner execution completes.  Production activation,
AWS publication, and external serialization require their own
decisions and proofs.

## Related decisions

ADR-018 governs apex-plus-wildcard identity; ADR-025 constrains
Certbot invocation; ADR-029/036 require certificate and exact SAN
checks; ADR-037 prohibits active state import without evidence;
ADR-044 requires operator-authorized inactive staging;
ADR-053 governs the two-lineage evidence design except for its
superseded single-SAN clause; ADR-054 prepares verified inactive
remote candidates.
