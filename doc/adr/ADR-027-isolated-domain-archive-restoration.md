# ADR-027: Isolated Restoration of Validated Certificate Lineages

Date: 2026-10-16

## Status

Accepted

## Decision

The producer must treat a downloaded certificate archive as untrusted until
both its declared member layout and the actual restored filesystem have
passed separate checks.  Restoration begins by copying the supplied archive
bytes into a private producer workspace.  It then validates that local copy
using the domain-only manifest policy established in ADR-026.

Only after a successful manifest preflight may GNU tar extract into a fresh,
empty, owned mode-0700 staging directory, separate from the producer's active
Certbot configuration tree.  Extraction does not restore arbitrary file owners
or archive-specified permissive modes.  After extraction, enumerate every
actual filesystem entry without following symlinks and reject anything outside
the one requested lineage's fixed allowlist.  Check the four expected
relative live symlinks again against the real versioned files, confirm both
combined PEMs and renewal metadata exist, and enforce restrictive modes for
all private-key-bearing regular files.  Any failure destroys only the newly
created staging tree.  A successful result remains isolated: a caller must
explicitly discard it after any later processing.

A normal certificate-management request will not call this helper until
renewal configuration portability, shared account restoration, cryptographic
key-to-certificate verification, and end-to-end publication sequencing have
been reviewed and tested.  No archive extraction may occur directly inside
an active or consumer TLS tree under this decision.

## Context and drivers

ADR-019 requires domain archives to be directly composable; ADR-025 warns
that Certbot renewal files can contain absolute, workspace-specific paths;
ADR-026 establishes a narrow manifest allowlist but explicitly does not
prove that extracted data match the listing or that extraction is harmless.
Tar supports filesystem objects and metadata that are dangerous when applied
to a preexisting tree.  The implementation must preserve useful Certbot
symlinks while declining unrelated or dangerous entries.

The first version uses the existing Bash 4.3 baseline and installed GNU tar,
GNU find, GNU coreutils, and the built-in private workspace helper.  It does
not add a runtime Python service or external plugin mechanism.

## Security assumptions

The issuer process and its operating-system identity are trusted.  The
private workspace is inaccessible to unrelated users, but another process
already acting as the same operating-system user is within the trust
boundary.  The copied archive must remain private between inspection and
extraction.  The narrow manifest allowlist contains only regular files,
expected directories, and four terminal symlink leaves; none of the
allowed symlinks is a parent of another admitted entry.  The helper must
not trust the original archive pathname again after taking a private copy.

## Promises

- Restoration never targets the active Certbot configuration directory.
- Failed validation or extraction does not overwrite existing producer state.
- A successful restore has one explicitly owned private staging path.
- The resulting tree is independently checked for unexpected members.
- Expected symlink targets and private key file permissions are checked
  on the real extracted filesystem, not only in tar metadata.
- No S3, Certbot, GPG, or ACME operation is performed by the helper.

## Non-promises and residual risk

A metadata allowlist and isolated GNU tar extraction are not proofs against
all compressed-input denial-of-service risks, tar implementation flaws,
same-user workspace tampering, or malicious configuration contents.
Post-extraction checks do not establish that PEM data are cryptographically
valid, that certificate and private key match, or that the renewal metadata
contains safe portable paths.  Filesystem deletion is not secure erasure.

This is not a general untrusted tar extraction library and is deliberately
restricted to the domain archive shape accepted by ADR-026.  Common ACME
account state requires its own policy and trust review before restoration.

## Considered alternatives

Extracting directly into /etc/letsencrypt was rejected because unexpected
writes can damage live state before any check.  Inspecting only tar metadata
was rejected because the resulting filesystem must independently satisfy
the contract.  Treating successful extraction as proof of a valid Certbot
lineage was rejected because renewal configuration and key/certificate
matching are separate semantic requirements.  A broad archive parser and
third-party extension API were deferred as unnecessary for the known format.

## Consequences and verification

The producer must allocate and clean up an additional staging directory per
restored certificate lineage.  Bats tests shall exercise valid restoration,
private permissions, malicious or unrelated lineages, symlink abuse,
corrupted inputs, cleanup, and no modification of active workspace paths,
across all shipped script flavors.  A later PR must explicitly reconcile
validated staging contents with the active Certbot workspace and document
how renewal configuration paths remain valid across invocations.

## Related decisions

ADR-019 governs composable archive format, ADR-022 governs publisher
serialization, ADR-025 controls issuance/renewal portability, and ADR-026
controls the required pre-extraction manifest inspection.
