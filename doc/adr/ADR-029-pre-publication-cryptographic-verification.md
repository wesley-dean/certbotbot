# ADR-029: Pre-Publication Cryptographic Certificate Verification

Date: 2026-10-16

## Status

Accepted

## Decision

certbotbot MUST verify each fully prepared certificate lineage cryptographically
before publishing its archive, regardless of a successful Certbot exit status.
This security gate is implemented as an internal Bash function invoking a
supported OpenSSL binary.  It is included in all release artifact flavors.

The first verifier requires a readable, owner-controlled private Certbot
configuration root and an expected lineage with the normal certificate,
chain, fullchain, and private-key links.  It requires the two generated combined
PEM files.  After structural checks, it must establish that:

1. The leaf X.509 certificate is parseable and valid at the verification time.
2. The private key is parseable and internally consistent.
3. The private key's public component matches the leaf certificate's public
   key, without assuming the key algorithm is RSA.
4. The certificate chain verifies with OpenSSL's TLS server purpose against
   trusted roots.  The default roots come from OpenSSL's host configuration;
   an explicit trusted CA file may be supplied for controlled staging tests.
5. The first certificate in the fullchain is exactly the expected leaf
   certificate.
6. Both combined PEM artifacts contain exactly the fullchain followed by
   one newline and the private key, and are private regular files.

Failures MUST prevent publication.  Only generic diagnostics may be logged;
private keys, full certificate dumps, and passphrases must not be copied into
logs or command arguments beyond the required trusted local filenames.
Temporary intermediate data must be produced inside the private producer
workspace and removed after use.

The initial function remains internally callable for tests, while the
public issuance path still fails closed.  The final producer must invoke
this function, and all other publication gates, after Certbot processing
and PEM assembly but before any object-store mutation.

## Context

Issue #12 requests an explicit shipped certificate-testing layer rather
than assuming Certbot will always produce usable cryptographic material.
Certbot output and archive layout checks are insufficient to detect
a mismatched private key, invalid certificate, incorrect intermediate chain,
or damaged combined PEM artifact.  This gate protects the certificate
producer's outputs and complements ADR-019, ADR-025, and ADR-027.

Issue #11 separately requests switching between Let's Encrypt production
and staging.  Staging CA certificates will not normally verify against
production public trust roots.  An explicit CA bundle allows controlled
tests of cryptographic chain validation without silently disabling it.
Staging and production object namespaces and account selection require
their own reviewed implementation; a valid test certificate must never
replace a production artifact by accident.

## Assumptions and constraints

- OpenSSL is a declared native runtime requirement for certificate testing.
- Certificates and private keys already reside in the producer's private
  workspace and have passed the structural lineage checks.
- Each invocation supplies an appropriate trust environment; arbitrary
  public CA roots and staging roots are not interchangeably trusted.
- Clock accuracy materially affects not-before and expiry validation.
- The caller retains control of archive publication and rollback.

## Alternatives considered

Accepting Certbot's zero exit status alone was rejected because neither
key matching nor final artifact integrity follows from process success.
Comparing RSA modulus strings was rejected for excluding elliptic-curve
and other supported key algorithms.  Comparing private key bytes to a
certificate was rejected because the certificate contains only the public
key.  Disabling CA trust validation for staging was rejected; an explicit
trust anchor is preferable.  Service-level HTTPS handshakes were deferred
because they depend on deployment, routing, and server configuration beyond
the issuer's responsibilities.

## Promises

- A mismatched or invalid private key prevents success.
- Invalid or untrusted certificate chains prevent success.
- Combined artifacts differing from the validated certificate/key material
  prevent success.
- OpenSSL failures propagate as non-success with no silent fallback.
- No remote operation occurs during cryptographic validation.

## Non-promises

This function does not prove DNS ownership, SAN correspondence to a requested
certificate group, correct server configuration, client compatibility, or
successful negotiation with nginx/HAProxy.  Chain validation with trusted
roots is not certificate-transparency auditing or OCSP/CRL revocation checking.
It does not validate future expiry beyond the current validity check.
A green isolated unit test is not evidence that the final producer invokes
this gate before every publication.

## Failure modes and verification

Tests MUST generate real CA-signed certificate/key pairs (including an
elliptic-curve example) and exercise matched and mismatched private keys,
invalid/truncated certificates, wrong trust roots, mismatched first fullchain
certificate, corrupt combined PEM contents, unsafe file modes, and staging
CA bundles.  Run identical tests against development, ordinary, and minified
artifacts.  The final producer must have a failure-path test proving that
verification failure leaves existing S3 objects unchanged.

## Compatibility, migration, and follow-up

Adding OpenSSL as a runtime verification dependency affects native and
container environment prerequisites.  It does not change consumer archive
layout, the GPG policy, or the built-in DNS/storage provider contracts.
Existing deployed certificates remain consumer-owned; no deployment-side
validation process is added by this ADR.  The future staging-API selection
must explicitly provide an appropriate verification trust context and isolate
staging vs production storage keys.

## Related decisions

ADR-019 defines combined PEM contents and deployment boundaries.
ADR-021 governs GPG.  ADR-022 governs publication and failure behavior.
ADR-025 governs Certbot renewal-state portability.  ADR-027 covers safely
restored lineage files.  ADR-028 covers common ACME account state.
