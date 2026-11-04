# ADR-047: Mock Route53 and DNS-01 Authorization for Local Lifecycle E2E

Date: 2026-11-02

## Status

Accepted

**Decision scope:** This ADR revises the milestone #16 test acceptance boundary.
It **supersedes the Route53/DNS-01 validation and bridge requirements of
ADR-046**, but does not supersede its isolated ACME gateway, native Certbot
account state, real public certbotbot artifacts, real S3-compatible operations,
fresh-runner isolation, genuine second order, or no-external-egress requirements.
Acceptance of this ADR follows review and merge of the task #243 PR.

**Supersession notice (ADR-054):** The requirement below for a fresh
non-due check with *no S3 object rewrite* applies to the three **stable
no-op acceptance checks after** one separately evidenced, strictly
bounded, native post-issuance metadata-only stabilization.  The initial
stabilization may legitimately rewrite the selected renewal configuration
and SeaweedFS current object only while preserving the verified leaf,
private-key correspondence, account identity, selected lineage, and Pebble
order count.  That stabilization is never counted as one of the three
no-rewrite no-ops.  All other ADR-047 requirements remain operative.

## Decision

Milestone #16 shall verify **certbotbot's actual register, issue, publish,
restore, non-due no-op, and genuinely due-renewal lifecycles** against real
containerized Pebble, real installed Certbot with `dns-route53`, and real
SeaweedFS S3 APIs. Route53 and DNS-01 challenge validation are external
dependencies of certbotbot and will be **test doubles**, not independent
integration targets.

In this isolated test profile, configure Pebble explicitly with
`PEBBLE_VA_ALWAYS_VALID=1` (and optionally `PEBBLE_VA_NOSLEEP=1`).
Pebble's documented setting makes ACME challenges valid without querying
DNS, HTTP, or TLS-ALPN responders. It still supplies actual ACME server-side
registration, order, challenge, finalization, and certificate issuance
transactions. Tests must assert the chosen mode, and must identify any
certificate obtained as **challenge-validation-bypassed Pebble issuance**,
not proof of DNS authorization.

Run a small project-owned **Route53 API stub** on the same sealed internal
container network. Use synthetic, nonfunctional AWS credentials and a single
synthetic zone. The stub needs only enough correctly structured responses for
the installed Certbot `dns-route53` client to proceed through:
`ListHostedZones`, `ChangeResourceRecordSets` (creation/cleanup), and
`GetChange` status polling. Its answers are locally deterministic and need
not create actual DNS TXT responses, communicate with Pebble's challenge
server, or reproduce AWS propagation, IAM, or consistency. A small in-memory
state table may be used to enforce scoped cleanup and fail-closed responses.
It must reject unknown API methods, unapproved zones and record names, invalid
synthetic credentials, malformed values, and unexpected requests. Simulated
write success is **not** evidence of Route53 DNS propagation.

All normal milestone #16 paths must run the **checksum-verified, unchanged
public certbotbot producer**, invoke actual Certbot binaries (not mocks),
preserve the production/staging-only `--acme-environment` selection and
canonical staging account path, and use real SeaweedFS storage operations.
The separate manually authorized milestone #4 staging/AWS workflow remains
the real-provider acceptance gate for DNS-01, Route53, Let's Encrypt and S3.

## Context, Constraints, and Assumptions

ADR-024 binds certbotbot issuance to `certbot certonly --dns-route53
--preferred-challenges dns-01`; the current renewal provider similarly
requires the dns-route53 plugin. Retrofitting HTTP-01 into the public
producer would expand product scope and undermine its wildcard use cases.
ADR-041 requires explicit registration, and ADR-042 fixes the only two
permitted public CA identities. ADR-046 originally required a functioning
Route53-to-Pebble DNS-01 bridge and actual DNS-01 validation as part of
local E2E acceptance. Task #243 / bug #252 demonstrated that implementing
a DNS adapter added complexity unrelated to certbotbot's owned contract.

The Product Owner explicitly directed prioritizing certificate lifecycle
integration and treating Route53/DNS authorization as external behavior.
This ADR deliberately changes **what the local test proves**, not what the
shipped product supports. It does not authorize DNS-provider feature work,
alternate Certbot authenticators, new public flags, arbitrary ACME URLs,
permanent CA trust, or host network changes.

The critical feasibility assumptions are not established by source review:

- The pinned Pebble image honors the documented always-valid flag.
- Real Certbot accepts the TLS-verified local staging-name gateway,
  including its ACME absolute URLs and native account directory.
- The installed Certbot Route53 plugin's botocore client honors the
  test-only `AWS_ENDPOINT_URL_ROUTE53` (or another reviewed sealed
  endpoint override), and never falls back to real Route53.
- The bounded stub's XML responses and behavior satisfy that installed
  plugin's actual requests.
- Real AWS CLI commands reach only SeaweedFS, whose conditional writes,
  ETags, errors, and reads meet certbotbot's required S3 contract.

A green static/unit suite does not establish any of these. If the actual
plugin ignores the endpoint override or a genuine protocol call tries a
public provider, the local test fails. Do not disable TLS, redirect on the
host, or patch the shipped producer to get around the problem.

## Trust Boundaries and Threat Model

The test runner, gateway, Pebble, Route53 stub, and SeaweedFS use an
isolated, disposable internal container network. Image fetching, artifact
building, and tool installation occur **before** entering the sealed
runtime phase. Tests must not expose ports, mount host credentials, use
the Docker socket from the runner, access host Certbot state, or allow
public cloud/CA/DNS or metadata egress. Verify actual network behavior,
not just the Compose declaration.

| Threat or failure | Required control / evidence | Residual limitation |
| --- | --- | --- |
| Public Route53 contacted after stub bypass | Fixed test endpoint, synthetic credentials, no default route, observed blocked egress | Host/engine privileges are outside the container boundary |
| Production ACME accidentally selected | Explicit staging CLI, exact hostname and gateway mapping, private root, TLS verification | Pebble-issued account is not a genuine staging account |
| Fake DNS success presented as interoperability | Always-valid mode explicit in config and reports; never claim challenge validation | No real Route53/DNS-01 coverage in milestone #16 |
| Malformed/foreign Route53 request reaches stub | Bound operations, zone, names, and credentials; fail-closed responses | Stub does not validate AWS SigV4 cryptography or DNS propagation |
| Fake Certbot or forged PEM hides lifecycle faults | Real installed Certbot and original public artifact, native account files, independent DER assertions | Does not prove live external provider correctness |
| Fake object storage success masks publication faults | Direct AWS CLI to real SeaweedFS, conditional writes, independent readback | S3 compatibility is tested only against pinned SeaweedFS |
| No-op mistaken for successful renewal | Second authentic Pebble order, new DER fingerprint, changed independently fetched object | Local renewal trigger needs separate reviewed design |
| Test output leaks keys or archives | Synthetic keys, bounded diagnostics, no raw logs or secret artifacts | Compromised container/host remains outside proof |
| A failed S3 write is treated as rolled back | Fail closed; preserve uncertainty of remote state | S3 does not guarantee rollback after interrupted writes |

## Local Acceptance and Evidence

The milestone #16 positive acceptance sequence remains:

1. Confirm all reviewed pinned images and artifact checksums, isolated
   network, test-only gateway trust, stub endpoint, and **always-valid mode**.
2. Show ordinary issue/renew refuses missing durable account state.
3. Explicitly register a genuine native Certbot account against Pebble;
   create the account-only object in SeaweedFS and independently fetch it.
4. Issue using the unmodified producer and real Certbot/`dns-route53`.
   The stub returns the bounded provider responses; Pebble bypasses
   challenge validation but completes a **real ACME certificate order**.
   Assert exact SANs, PEM/DER certificate identity, selected lineage and
   valid account, and independently read back the published S3 archive.
5. Destroy the first runner, restore in a separate empty runner using
   SeaweedFS only, and demonstrate a non-due no-op without new order or
   object rewrite.
6. Under a separately reviewed, test-only due/renewal condition,
   execute a **second real ACME transaction** with the same plugin and
   dummy provider, proving a different DER fingerprint, stable account
   and lineage, changed current object, and independent readback.
7. Inject ACME, stub, S3, archive, CA-selection and isolation failures;
   verify no false success or unwarranted publication. Actual TXT
   propagation and DNS failure simulation are **out of scope**.
8. Run the entire sequence with bounded timeouts and teardown in a
   distinct credential-free CI gate; maintain all ordinary checks.

Positive evidence must report tested artifact flavor/checksum, Certbot and
plugin versions, Pebble/SeaweedFS/stub image digests, actual network
observations, test mode, ACME order count, certificate fingerprints
(nonsecret), archive digest comparison, and failures. It must **not**
claim tested AWS IAM/Route53, DNS challenge propagation, public Let's
Encrypt, or Amazon S3 interoperability. Milestone #4 retains those
separate real-provider acceptance responsibilities.

## Considered Alternatives

1. **Continue implementing a complete DNS-01 bridge:** rejected for
   milestone #16. It tests the external connector and DNS propagation
   rather than certbotbot's owned lifecycle, and increases attack surface.
2. **Use Nginx with HTTP-01 and change the producer:** rejected.
   ADR-024 intentionally requires Route53 DNS-01, and HTTP-01 cannot
   validate wildcard identities.
3. **Mock the Certbot executable or synthesize certificate files:**
   rejected for local integration acceptance. Such unit tests cannot
   establish genuine ACME account/order/PEM behavior.
4. **Use real AWS and Let's Encrypt in PR CI:** rejected. It conflicts
   with the test's sealed/no-real-credentials design and ADR-043.
5. **Allow generic CA URL and provider test flags in production CLI:**
   rejected. Authority selection belongs outside shipped artifacts.
6. **Use Pebble's always-valid mode plus a minimal provider stub:**
   accepted. It preserves real ACME/certificate and durable state
   validation while explicitly excluding external DNS integration.

## Consequences and Compatibility

This does not change product CLI, issuance authenticator, renewal
authenticator, default CA selection, archive format, storage semantics,
release artifacts, or existing mock unit tests. The local test stack
will drop the need to run a DNS challenge server or manage TXT
propagation; it will require a small bounded Route53 API stub and a
real Certbot runner. Task #243 supplies the stub and harness changes;
#244 handles real registration and first issuance, #245 fresh restore
and no-op, #248 real renewal, #246 scoped failure injection, and #247
CI integration. Maintain **one approved technical task per PR**.

The accepted parts of ADR-046 (CA identity and TLS mediation,
no-egress, real issuer, real S3, native state and genuine renewal)
remain in force. This ADR intentionally supersedes only its DNS/Route53
integration coverage and corresponding DNS negative gates. Any
future reintroduction of real DNS validation as local acceptance
requires another approved decision.

## Related Decisions

ADR-015, ADR-016, ADR-019, ADR-024, ADR-035/036, ADR-041/042/043,
and ADR-046. The suspended native dependency sync under ADR-045
is unrelated and must remain disabled.
