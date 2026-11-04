# ADR-054: Independently Verify Native Metadata Stabilization Before Strict Local No-Ops

Date: 2026-11-04

## Status

Accepted

**Implementation convention:** The status is the repository's standard for
an ADR submitted with work intended for review and merge. The decision
becomes operative when its associated approved task PR is accepted.

## Decision

For milestone 16's isolated Pebble/SeaweedFS E2E acceptance, one native
non-due Certbot invocation immediately after a genuinely issued certificate
may create a single **durable selected renewal-metadata update** and
republish the current S3 object. That invocation is explicitly classified
as post-issuance *metadata stabilization*, not as a passing no-op.

The harness must first prove real initial issuance and independent initial
S3 archive, account, selected lineage, certificate and private-key
validation. It then executes the unchanged checksum-verified public producer
in a separate credential-free, isolated runner, without a force flag or a
mocked Certbot. If native Certbot writes updated renewal metadata, the
unchanged public producer must publish it under ADR-025. Before treating
the stabilization as valid, the runner must independently establish:

1. The command succeeded with `checked` status and a single
   `published=true` receipt, with `UPLOAD_NO_RENEWAL=false`.
2. The replacement SeaweedFS object differs from the initial object in
   both exact archive digest and independently observed S3 identity.
3. The selected renewal configuration bytes genuinely changed. The
   harness must never forge, redact, regenerate, or suppress these
   native configuration values.
4. The account identity and account private-key bytes, selected lineage,
   certificate DER, and matching certificate/private key are unchanged;
   no unrelated lineage is introduced, and no force-renewal switch is
   persisted.
5. Pebble's independently observed new-order count has not increased.
6. A *different* disposable verifier runner fetches the exact replacement
   object and verifies the original issued certificate DER independently.

Only **after** these conditions pass may the stabilized archive digest
become the reference input for the three mandatory fresh-runner normal
non-due checks. The development, ordinary, and minified producer flavors
must *each* report `checked; published=false`, leave the SeaweedFS current
object's exact bytes and ETag/LastModified/size unchanged, preserve
certificate/account state, and add **no** new Pebble ACME order. The
stabilization cannot count as any of those no-op successes.

The harness must then still establish a deliberate second actual Pebble
ACME order using ADR-049's single-use *test-only* forced-renewal adapter,
a different leaf DER hash, preserved account identity, a genuinely changed
S3 object independently validated by a fresh runner, and a final ordinary
post-renewal check. The seven negative cases, before/after isolation
probes, staged TLS integrity and full cleanup are unaffected.

This is a **narrow supersession of ADR-047**: its no-object-rewrite proof
is applied to the three stable no-op runs *after* the single observed
native metadata stabilization, rather than requiring the first-ever
post-issuance check to meet the no-rewrite property. The existing ADR-025
durable-change publication contract is expressly preserved.

## Evidence and Motivation

Draft [PR #260](https://github.com/wesley-dean/certbotbot/pull/260) failed
at the first fresh-runner development-flavor no-op. After the previously
accepted critical SAN and renewal-format compatibility corrections,
real [run 41780291675](https://github.com/wesley-dean/certbotbot/actions/runs/41780291675)
reported the following *bounded and independently checked* categories:

- `lifecycle stage=noop-development`
- `status-checked; published-true`
- `object-changed; renewal-changed; orders-unchanged`

The readback proves that an actual S3 object changed and the selected
renewal configuration changed, while Pebble did not create another order.
This is real metadata-only behavior, not merely unexpected logging.

With approval under issue #272, a disposable test-only replay using
the **same unchanged producer** ran immediately after that first
metadata-only publication, with no raw provider output exposed.
[Run 41781308764](https://github.com/wesley-dean/certbotbot/actions/runs/41781308764)
reported the closed categories
`status-checked; published-false; object-unchanged; renewal-unchanged`.
That supports **one-time convergence** for the pinned native Certbot
version and current local fixture. It does not prove that arbitrary
future Certbot versions or external providers have the same behavior.

ADR-025 anticipated this condition: real `certbot renew` may return
success without issuing a certificate while legitimately updating
durable account or renewal metadata. Its durable-change flag must trigger
publication even when the user has not enabled
`UPLOAD_NO_RENEWAL`. ADR-047's strict no-rewrite local acceptance had
inadvertently counted this first native metadata transition as a no-op.
This decision preserves both contracts by separating a bounded setup
transition from subsequent truly stable no-op acceptance.

## Assumptions and Security Constraints

- The experiment and acceptance use only pinned, real Certbot with the
  local Pebble server, real SeaweedFS and synthetic Route53 API. Pebble
  deliberately bypasses DNS authorization under ADR-047.
- No real Let's Encrypt staging, Amazon S3, AWS Route53, production
  credential, external DNS propagation or network egress is authorized.
- The public producer, archive format, stable certificate selection,
  account identity checks, key/chain checks, and conditional-write
  security properties remain unchanged.
- All metadata, private keys, certificate identities, actual SANs,
  provider output, cloud responses, private runner logs and workspace
  paths remain inside sealed transient runner storage. Only fixed
  status classifications and opaque SHA-256 identity receipts may cross
  the host/CI reporting boundary.
- Failure to demonstrate **every** stabilization condition fails closed.
  A second metadata rewrite in any of the three following strict no-op
  checks also fails closed; no blanket publish override or unlimited
  normalization loop is permitted.
- The invocation's `checked` status does not alone prove absence of
  a new order; the host must verify the separate Pebble counter.
- A mutation of certificate identity, key, account, lineage, unrelated
  state, or persistent forced-renewal setting is never acceptable
  merely because the issuer did not make a new order.

## Alternatives Considered

1. **Suppress metadata-only publication in the public producer.**
   Rejected: doing so violates ADR-025, risks silently losing legitimate
   Certbot updates, and would mask rather than fix the integration gap.
2. **Change `UPLOAD_NO_RENEWAL` to suppress all non-due writes.**
   Rejected: that option governs *unchanged* state; it is not an
   authorization to discard actual durable mutations.
3. **Weaken all no-op tests to accept S3 rewrites.** Rejected: without
   stable-object assertions the test can no longer prove proper no-op
   and idempotence behavior across the three release artifacts.
4. **Mock the first Certbot check or edit archived renewal files.**
   Rejected: simulation hides native compatibility and can undermine
   account/lineage integrity.
5. **Force another ACME order to escape the metadata transition.**
   Rejected: it violates ADR-025 normal renewal and would hide a
   product/state integration problem.
6. **Treat any number of metadata publications as stabilization.**
   Rejected: an unbounded loop could conceal chronic recurring state
   drift, repeated S3 writes or a product bug.
7. **Move all no-op checks after the forced second order.** Rejected:
   it skips evidence for the ordinary post-initial-issuance state.
8. **Refuse any initial metadata-only update as a defect.** Rejected:
   the native replay demonstrates one-time convergence for this
   fixture, and the current accepted product contract permits
   these durable updates.

## Consequences, Compatibility, and Verification

The sole intended change is within the isolated milestone-16 test
harness and its acceptance sequence. There is no public CLI,
application permission, certificate storage, S3 publication,
renewal-timing or archive migration change. A real native
post-issuance update adds one verified S3 publication and one
additional independent readback. The three strict no-op flavors remain
mandatory and unmodified.

CI and Bats must require the explicit stabilization phase and reject
missing/duplicate evidence, false certificate/account continuity, a
new Pebble order, unchanged claimed replacement bytes, failed
independent readback, and any subsequent normal no-op that republishes.
Real sealed E2E must also pass the genuine second order, seven negatives,
before/after no-egress probes and complete cleanup. A passing static
Bats suite alone is insufficient proof of real-protocol completion.
Any further recurring native metadata rewrite would require separate
diagnosis, not automatic acceptance.

## Related Decisions

ADR-025 governs selected normal renewal and durable-change publication.
ADR-047 defines the challenge-validation-bypassed local Pebble/SeaweedFS
scope and remains in force except for the explicitly superseded
first-no-op timing rule. ADR-046 retains all independent readback and
no-external-egress boundaries not superseded by ADR-047. ADR-049
governs the genuine second ACME order and test-only force marker.
ADR-022 governs portable canonical archive state; ADR-051 and ADR-052
govern native renewal metadata interoperability; ADR-053 governs the
exact critical SAN header; ADR-048 governs CI trigger separation.
