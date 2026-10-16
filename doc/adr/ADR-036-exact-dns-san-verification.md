# ADR-036: Exact Requested DNS SAN Set Before Certificate Publication

Date: 2026-10-16

## Status

Accepted

## Decision

The certificate producer MUST verify that each issued leaf certificate's
X.509 DNS Subject Alternative Name (SAN) set exactly equals the authoritative
normalized request for that lineage.  A successful Certbot invocation,
matching private key, valid certificate chain, and structurally valid
archive are individually insufficient to establish that the issued
certificate covers precisely the requested identities.

The first implementation adds an internal, read-only
`certbotbot_crypto_verify_sans` function to the existing OpenSSL
certificate verification module.  Its inputs are a private, validated
Certbot configuration root, one canonical lineage name, and individually
quoted normalized requested SANs.  The request must include both the apex
and leading-wildcard names mandated by ADR-018.  Additional SANs are
taken literally from the parsed request; the helper never infers them.

The validator checks the normal lineage-scoped `live/<name>/cert.pem`
symlink and resolved archived leaf file before invoking OpenSSL.
It queries the actual leaf certificate's SAN extension and requires an
unambiguous OpenSSL DNS-SAN presentation.  It interprets DNS names
case-insensitively and compares the *sets*, rather than their serialized
order.  A missing, duplicated, extra, malformed, or non-DNS SAN entry
causes validation failure.  The certificate's subject Common Name (CN)
does not substitute for an absent SAN, and wildcard coverage never
implies apex coverage.

This is a separate fail-closed boundary from ADR-029's existing
cryptographic validation.  The eventual issuer MUST invoke **both**
the existing chain/private-key/combined-PEM verifier and the SAN set
verifier after issuance/renewal and before any mutation of S3 state.
Failure of either prevents publication.  The present release gate
remains disabled; adding the helper does not activate an issuer.

## Context and drivers

ADR-018 defines an authoritative per-lineage SAN set, including an
explicit apex and wildcard, with additional names preserved literally.
The caller can remove names deliberately to narrow a later certificate.
ADR-029 validates certificate signature, trust chain, key matching,
current validity, and combined PEM integrity but explicitly excludes
correspondence to the requested DNS identities.  Issue #12 requires
runtime certificate testing, so SAN correspondence is a missing
publication-critical validation step.

In a stateless producer, the requested SAN set can differ between
successive Jenkins, Actions, and EC2 runs.  Restored lineage files
must never be published as satisfying a new request merely because
the same archive name still exists.  An extra name is as important
as a missing name because it contradicts the requested authority and
may retain names that the caller deliberately removed.

## Preconditions and assumptions

- The input parser has normalized all requested SANs to lowercase
  ASCII DNS names and deduplicated them.
- The canonical lineage name is a safe, non-wildcard FQDN.
- The leaf certificate has already been obtained in the producer's
  private workspace, and its normal Certbot lineage structure is
  available.
- OpenSSL is an explicit runtime dependency of the producer's
  certificate verification gate.
- Supported leaf certificates use conventional DNS entries in the
  X.509 subjectAltName extension.
- The existing name validation grammar does not accept arbitrary
  internationalized Unicode; IDNs must be presented as punycode.

## Alternatives considered

Using the Common Name or TLS hostname wildcard matching rules was
rejected because certificate identity is an exact requested *set*,
not a client-side hostname-matching assertion.  Trusting Certbot's
successful exit status or inspecting its requested `-d` arguments
was rejected because this does not examine the actual leaf certificate.
Checking only that all requested names appear was rejected because
unwanted extra names could silently survive an intentionally narrowed
request.  Comparing a human-readable SAN string verbatim was rejected
because certificate order and DNS case are semantically irrelevant.
Invoking an external scripting language or ASN.1 library was deferred
to avoid additional runtime dependencies in the standalone Bash tool.

The initial implementation parses a restricted, conventional OpenSSL
SAN presentation and refuses unfamiliar output.  If supported OpenSSL
releases present SANs differently, the parser and its compatibility
tests require review.  It must never silently skip an unknown SAN type
or a malformed entry to produce a false success.

## Promises

- Missing requested SANs prevent success.
- Unrequested or repeated certificate SANs prevent success.
- Non-DNS SAN entries do not silently pass.
- The apex and wildcard are independently mandatory.
- DNS name order and ASCII case do not change set equivalence.
- The check neither invokes Certbot nor mutates the certificate tree.
- The helper is included in the three built standalone artifact flavors.

## Non-promises and residual risks

A matching SAN set does not prove DNS ownership, that an ACME CA
validated a challenge, revocation or CT status, current certificate
validity, issuer chain trust, private-key integrity, or client
compatibility.  ADR-029 covers the separate cryptographic gate.
Parsing the OpenSSL textual extension output depends on its format,
so unsupported presentation fails closed instead of guessing.
The helper does not handle URI, IP, email, or other SAN types, and
the initial product does not support certificate requests for them.

An isolated unit test alone cannot prove that all remote publication
paths invoke the new verifier.  Integration and negative publishing
tests remain mandatory before production release.

## Validation and operational consequences

Use locally generated CA-signed X.509 certificates to verify exact
apex/wildcard success, order independence, DNS case equivalence,
additional requested names, missing names, unexpected names, duplicate
SANs, absent extensions, unsupported SAN types, incorrect wildcard
levels, and unsafe live certificate links.  Each test runs against
the development, ordinary, and minified standalone artifacts on the
supported Bash baseline, alongside the existing ADR-029 tests.
No AWS, Route53, or ACME credentials are needed.

Before enabling production publication, verify that the actual
normalized request passed to Certbot is passed unchanged to this
gate and that its failure blocks every object-store write, including
state-only ARI metadata updates.  A reissued certificate after a SAN
change must be validated against the *new* request, not the old
renewal configuration.

## Compatibility and relationships

No archive name, S3 key, CLI switch, provider interface, or consumer
installation procedure changes.  OpenSSL was already required for
ADR-029, so no new native runtime dependency is introduced.  The
decision refines ADR-018 identity and ADR-029 validation without
superseding either.

Related: ADR-018 certificate identity; ADR-019 archive contents;
ADR-022 failure-safe publication; ADR-025 portable renewal; ADR-029
cryptographic verification; ADR-034 ARI state-only updates.
