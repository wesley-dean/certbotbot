# ADR-034: Network-Guarded Certbot No-Op Renewal Compatibility Test

Date: 2026-10-16

## Status

Accepted

## Decision

Extend the disposable real-Certbot portability integration harness from
ADR-033 to exercise a **certificate-not-due renewal decision** after
restoring account and lineage files under an independent workspace root.
This remains a **test-only exception** to ADR-032's non-activation boundary.
It does not authorize the product to install staged renewal metadata,
initiate production renewals, register accounts, or publish archives.

Use pinned Certbot 5.8.0 with a locally generated, approximately 90-day
CA-signed leaf certificate and a structurally valid fullchain, plus a
synthetic common-account archive.  The certificate lifetime is deliberately
longer than Certbot's normal renewal threshold.  A previous independent
workspace must be deleted before attempting the no-op renewal.

Inside the test harness only, copy the accepted common-account files and
the rebased lineage preview into a fresh private Certbot configuration
root, retaining the same account-key bytes and X.509/private-key material.
Run the real `certbot renew --cert-name example.com --non-interactive`
command with that root, without `--dry-run` or forced renewal.  Explicitly
disable directory hooks and renewal random sleep.

To prevent successful external ACME requests, the harness installs a local
`sitecustomize.py` in Certbot's Python interpreter environment which
overrides the normal socket connection and name-resolution APIs to raise,
and records attempted connections.  Test the guard itself first.
A successful test requires all of the following:

- Certbot exits successfully and explicitly reports that the requested
  lineage is not due for renewal or that no renewals were attempted.
- No outbound socket connection is allowed to succeed.  A blocked
  `socket.getaddrinfo` lookup may occur: Certbot 5.8.0 requests ACME Renewal
  Information (ARI) even when the certificate is not due, and reports the
  resulting lookup error without treating the no-op as a failed renewal.
  Other intercepted socket operations are unexpected and fail the test.
- The certificate and private key are byte-identical before and after
  Certbot's decision.  Critical identity/path settings remain unchanged.
  A blocked ARI lookup can append an `[acme_renewal_info]` section with
  `ari_retry_after`; only this narrowly validated addition is accepted.
- The original producer workspace no longer exists.
- The same behavior is tested for the development, ordinary, and
  minified standalone Bash artifacts.

This is intentionally a compatibility smoke test, not a network isolation
sandbox or proof of ACME account validity.  CI must not provide DNS
credentials, AWS credentials, production account metadata, or a production
certificate.  No output is published to object storage.

## Context and constraints

The producer's defining requirement is that one invocation may execute
under Jenkins and another under GitHub Actions or EC2, reconstructing all
needed persistent state from shared archives without machine-local state.
ADR-033 established that Certbot 5.8.0 can inspect a relocated lineage,
but read-only listing alone does not exercise Certbot's renewal decision.
Certbot's documented `renew` exit code is zero both when renewal succeeds
and when no renewal was necessary, so the exit code by itself is
insufficient evidence of a no-op.

As of Certbot 4.0.0, normal renewal eligibility is based on the remaining
fraction of a certificate's validity period.  A locally generated
90-day certificate therefore provides an intentionally not-due fixture
immediately after generation.  The test checks for an explicit no-op diagnostic rather than assuming success
implies non-renewal.  The first CI exercise established that Certbot 5.8.0
may still attempt an ARI DNS lookup even after detecting a non-due lineage;
the network guard blocks that lookup, and Certbot continues with a normal
no-renewal decision.  Certbot may also record an `ari_retry_after` value
in renewal metadata.  No certificate reissuance does not imply that
all persistent producer state remains unchanged.

References:

- https://eff-certbot.readthedocs.io/en/stable/using.html
- ADR-025, ADR-032, and ADR-033

## Security assumptions and limitations

The socket interceptor applies to Python code using the patched APIs
within Certbot's interpreter.  It is **not** operating-system network
namespace isolation, and it cannot prevent network access by arbitrary
child processes or native code bypassing the Python socket hooks.
The fixture includes no executable hooks and uses
`--no-directory-hooks`.  Absence of the network marker is additional
test evidence, not a general-purpose guarantee that no possible network
operation could occur.  An environment-protected dedicated integration
test with actual staging credentials remains separately necessary.

The copied `private_key.json`, `meta.json`, and `regr.json` are
synthetic and not legitimate ACME account records.  Successful no-op
selection does not prove account validation or registration with a CA.
Only generated, disposable private keys are used, and test logs may
not include sensitive real account material.

## Alternatives considered

Issuing or renewing a real Let's Encrypt production certificate in
ordinary PR CI was rejected because it introduces unnecessary DNS
authority, public CA quotas, secrets, and external side effects.
`certbot renew --dry-run` was rejected here because it can initiate
real DNS-01 challenges even when the certificate is otherwise not due.
Skipping the real renewal command and inferring no-op behavior from
expiry timestamps was rejected because it cannot validate upstream
Certbot's decision logic and restored configuration loading.
Adding a persistent shared Certbot volume was rejected because it
contradicts cross-node portability.
An OS-level isolated container may provide a stronger future network
boundary, but is not required for the current credential-free smoke test.

## Compatibility, verification, and consequences

The new test depends on Certbot 5.8.0, Python's supported
`sitecustomize` mechanism, OpenSSL, GNU tar/coreutils, and the
already reviewed Bash archive/preview modules.  It is a CI-only
consumer of the existing public-artifact build and does not change
product CLI or archive formats.  The synthetic certificate lifetime is increased from ADR-033's initial
seven days to 90 days for a stable no-op decision.

The test must fail if Certbot cannot read the relocated lineage,
reports an issuance attempt, makes an unexpected socket operation beyond
its tolerated blocked ARI DNS lookup, changes certificate/key bytes or
core renewal settings, or returns an unrecognized result.  The test
must verify that an accepted ARI addition survives domain archive repackaging.  Build, Bash 4.3, source checks, CodeQL, and
MegaLinter remain required in addition to the new real-Certbot job.

## State-only durable archive implications

Because Certbot can update ARI scheduling metadata without renewing a
certificate, a later producer cannot equate a no-op renewal result with
an absence of persistent state changes.  The future issuer must inspect,
validate, and account for recognized renewal metadata updates before
disposing of an ephemeral workspace.  Whether ARI-only changes warrant
immediate S3 publication, and how they are serialized and recovered
without corrupting the last known good archive, require a separate
reviewed implementation decision.  This test only confirms that such
metadata survives a local archive repack; it does not publish to S3.

## Further release gates

The tested no-op decision is not a demonstration of successful renewal.
Before activating the producer, use real Certbot-issued Let's Encrypt
**staging** artifacts to verify valid account registration and reuse,
due renewal, changed SANs, preserved lineage identity, test CA
trust, and durable S3 publication with rollback/failure behavior.
Independent Jenkins, Actions, and EC2 workspaces must be supported
without local state; writers must remain serialized until a genuine
distributed lease/fencing design exists.  Production certificates and
ACME requests remain disabled in the public issuer during this phase.

## Related decisions

ADR-019 establishes split-state archives.  ADR-022 governs publication.
ADR-025 governs issuance-state portability.  ADR-027/028 govern staged
restoration, ADR-030/031 govern CA and account identity, ADR-032
governs non-activating path previews, and ADR-033 established the
read-only real-Certbot CI baseline.
