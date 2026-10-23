# ADR-025: Selected-Lineage Renewal and Observable No-Op Results

Date: 2026-10-22

## Status

Accepted

## Decision

The existing-lineage provider may invoke Certbot **only for the explicitly
selected existing certificate name** and its verified original ACME account.
For this increment, renewal is permitted only when the requested SAN set
exactly matches the SAN set in the restored leaf certificate. A mismatch,
including a change to INCLUDE_SUBDOMAINS, fails before Certbot runs.

For an exact match, Certbot's `renew --cert-name NAME` performs ordinary
due-renewal behavior without forcing unnecessary ACME issuance. The command
uses the installed Route53 authenticator from the already-restored renewal
state and explicit private `--config-dir`, `--work-dir`, and `--logs-dir`.
The local runtime checks the installed plugin and the exact restored account
before execution; it never registers an account, executes archived hooks,
or invokes global renewal.

The provider owns renewal-path preparation and finalization for this one
selected lineage. It maps canonical paths to private paths before Certbot,
and maps them back before a successful result may be reported. Neither an
issuance failure nor an invalid post-renewal state can lead to publication.
Failure leaves the workspace for the calling lifecycle to destroy and leaves
the existing authoritative S3 object unchanged.

## Why this is necessary

Certbot documents that `certbot renew` returns zero both when certificates
were renewed and when nothing needed renewing. The provider cannot equate
success with changed certificate bytes, and a no-op can still change account
or renewal metadata. The publication decision therefore needs two results:
whether certificate material changed and whether *any durable configuration*
changed.

The local provider computes a private deterministic digest of the restored
configuration's filesystem state before preparation and after finalization.
It compares the selected leaf certificate's bytes and current symlink target
to identify certificate replacement. The results are caller-visible
`CERTBOTBOT_RENEWAL_OCCURRED=true|false` and
`CERTBOTBOT_DURABLE_CHANGED=true|false`. Both are cleared on failure.
Digest outputs, filenames, account identifiers, certificate bytes, and
subprocess diagnostics are not emitted to standard output or standard error.

These results are local observations, **not remote publication status**.
A durable-change result is used later under ADR-020 to decide whether to
publish; UPLOAD_NO_RENEWAL still controls an unchanged no-op. The local
digest includes content, names, link targets, and permissions in a stable
GNU tar representation, but it is not a transactional filesystem snapshot.
The caller serializes execution and keeps the workspace private.

## Assumptions and boundaries

- Prior archive validation and restoration established one private
  mode-0700 configuration tree with one complete selected lineage.
- ADR-023 preflight establishes one production ACME account, matching
  lineage files, and no executable archived hook configuration.
- The leaf certificate has a parseable DNS-only SAN extension. Installed
  OpenSSL exposes it through `openssl x509 -noout -ext subjectAltName`.
  Any unsupported SAN encoding or non-DNS SAN type fails closed.
- Requested SANs are exactly one validated DNS name or its own two-name
  apex/wildcard complement. No unrelated names are added by the provider.
- No force-renewal, duplicate, expand, global renew, or silent account
  registration is authorized. Ordinary Certbot renewal policy decides
  when a matching lineage requires a new certificate.
- The provider revalidates the restored ACME account/lineage and SAN set
  after Certbot. A provider zero exit is necessary but insufficient for
  declaring usable state or a publishable archive.
- Actual Certbot interoperability and real ACME/Route53 operations will
  be exercised in a separate end-to-end milestone; MVP tests use mock
  Certbot/OpenSSL processes and temporary local certificate fixtures.

## SAN drift policy and alternatives

**Automatically use `certonly --cert-name` with new SANs:** deferred to
approved task #23. Certbot can modify an existing named certificate, but
the behavior must be explicitly governed and tested for both adding and
removing wildcards, lineage preservation, and failure rollback.

**Force renewal on every invocation:** rejected. It bypasses Certbot's
normal renewal window, unnecessarily consumes ACME rate limits, and
contradicts unchanged no-op behavior.

**Infer renewal from Certbot exit status or logged prose:** rejected.
Certbot's documented success return does not distinguish no-op and
successfully renewed state; logs may contain sensitive material.

**Rely only on the leaf PEM digest:** rejected. ACME account and renewal
metadata may change without replacing certificate material.

**Run `certbot renew` without `--cert-name`:** rejected because that
may process unrelated lineages and contradicts ADR-020.

## Consequences and follow-up

A matching selected lineage now has an independent renewal/no-op adapter.
SAN-drift changes continue to fail closed until task #23 supplies approved
replacement semantics. Publication also remains disabled until a complete
candidate archive is validated and uploaded to the exact one existing S3
key. The public CLI continues returning its explicit unavailable error.

## Relationships

ADR-020 fixes one archive and selected identity; ADR-022 governs canonical
renewal paths, ADR-023 restored account preflight, and ADR-024 installed
Certbot/Route53 authority. Tasks #26 and #23 govern selected renewal and
SAN drift. ADR-008 requires specification and tests before implementation.

## References

- Certbot user guide (renewal and `--cert-name`):
  https://eff-certbot.readthedocs.io/en/stable/using.html
