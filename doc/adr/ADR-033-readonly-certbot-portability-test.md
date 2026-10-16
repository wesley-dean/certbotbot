# ADR-033: Read-Only Certbot Portability Compatibility Test

Date: 2026-10-16

## Status

Accepted

## Decision

Authorize a narrowly scoped **test-only** compatibility exercise using a
real, version-pinned Certbot binary to inspect certificate state reconstructed
under a different absolute producer workspace root.  This refines ADR-032
only for disposable, locally generated test fixtures; it does **not**
authorize the production issuer to install or consume a rebased renewal file.

The test runs in a dedicated GitHub Actions job with Certbot 5.8.0 installed
into an ephemeral Python virtual environment.  A source workspace holds an
OpenSSL-generated, short-lived locally CA-signed X.509 certificate and a synthetic
Certbot-shaped renewal configuration.  The test uses the same domain archive
format and common-account structure as the producer and runs the actual
certificate-archive validation and isolated restore helpers.  The shared
account JSON triplet is fixture data, not a live ACME registration.

The internal ADR-031 identity check and ADR-032 relocation preview produce
the updated renewal path values.  **Only inside this disposable test**, the
harness installs a copy of the preview and the staged lineage files into a
separate private Certbot configuration directory.  The actual Certbot
`certificates` subcommand then inspects this local, read-only lineage
without requesting certificates, contacting ACME, registering an account,
running DNS challenges, or uploading state.

Before the second inspection, the original source workspace is deleted.
The test must find the named lineage under the relocated configuration
directory with the same private-key fingerprint, and the installed renewal
file must contain no reference to the deleted old root.  Exercise all
three standalone Bash artifact flavors.

## Relationship to ADR-025 and ADR-032

ADR-025 remains the governing requirement for actual renewal portability.
ADR-032 prohibited installing or passing a rebased renewal preview to
Certbot before supported integration evidence.  **This decision introduces
one explicit exception for a real Certbot read-only inspection in an
isolated CI fixture**, because otherwise no direct upstream loader test
could be conducted.  The exception is confined to the test harness, not
the public producer, its backends, or general-purpose staging helpers.

No existing producer function installs the preview, and ordinary
certificate requests continue to fail closed.  A subsequent ADR and
end-to-end tests must still justify active import and renewal, including
actual Certbot-issued artifacts, real ACME account restoration,
no-op renewal, changed SANs, correct staging/production selection,
cryptographic verification, and fail-closed storage publication.

## Context and decision drivers

Certbot persists absolute paths in renewal configurations, even when
the initial invocation uses a custom configuration root.  An apparently
correct text preview is insufficient evidence that the supported
Certbot release can actually load an imported lineage.  The project's
Twelve-Factor-style requirement is that successive Jenkins, GitHub
Actions, and EC2 invocations work without shared local files, using
portable common and per-domain archives in external object storage.

A local inspection test can falsify broken path rewriting, unexpected
archive paths, and some version-specific Certbot loader assumptions.
It does not require Route53 authority or real ACME credentials.
The pinned CI version is a reproducible first compatibility target,
not a promise that every future Certbot version behaves the same.

## Alternatives considered

Running issuance against Let's Encrypt production for each PR was
rejected because tests must not consume real authorization credentials,
production CA rate limits, or valid public certificates.  Running
`certbot renew --dry-run` was deferred because it performs network
challenges and can depend on DNS credentials.  Trusting synthetic
Bash-only fixtures without running Certbot was rejected because that
does not test upstream state loading.  A shared persistent Certbot
volume was rejected because it defeats cross-node portability.

## Promises and verification

- The test uses an actual pinned Certbot binary, not a fake executable.
- The test does not execute a Certbot issuance, renewal, or ACME operation.
- All fixture archives and workspaces are created locally and disposed.
- The source root is deleted before final Certbot inspection.
- A successful inspection requires the original named lineage under
  its new config root with the same private-key bytes.
- Both source and relocated state remain private to the test identity.
- The test is exercised for the development, stripped, and minified scripts.

## Non-promises and failure modes

A green test is not evidence that the account JSON is accepted by Let's
Encrypt, that the cert was originally issued by Certbot, that
`certbot certonly` can renew it, or that a SAN change works.
Self-signed test material cannot prove trusted chain publication, and the
read-only certificate listing may use fewer of Certbot's internal
configuration paths than real renewal.  The test still depends on the
upstream Python installation and transitively resolved packages; a pinned
Certbot version alone does not lock every transitive dependency.
The workflow does not read production secrets or access S3.

## Follow-up and migration

Before enabling active renewal, perform a separate integration test using
real Certbot-generated account and lineage data with a supported staging
ACME server and approved DNS challenge credentials in a controlled
environment.  Confirm no-op renewal, SAN replacement, account identity,
restoration in a new workspace, cryptographic checks, and publication
rollback behavior.  Keep automated release publication disabled until
those security and operational gates are satisfied.

## Related decisions

ADR-019 specifies portable split archives.  ADR-022 specifies
single-writer publication.  ADR-025 requires renewal portability
evidence.  ADR-027 and ADR-028 govern isolated restores.  ADR-029
governs cryptographic verification.  ADR-031 requires account/ACME
identity agreement.  ADR-032 defines the non-activating path preview.
