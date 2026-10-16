# ADR-026: Strict Pre-Extraction Validation of Domain Archive Manifests

Date: 2026-10-16

## Status

Accepted

## Intent and Documentation Posture

Introduce a bounded, auditable check of a downloaded certificate-lineage
archive's declared members before the producer considers restoring it.  This
decision establishes a necessary validation gate, not a claim that a tar
archive is safe to extract or that a lineage is renewal-ready.

## Context

ADR-019 promises directly composable domain archives containing Certbot's
versioned certificate and key files, its `live/` relative symlinks, one
renewal configuration, and two combined PEM files.  ADR-025 requires the
producer to prove that restored renewal metadata remains portable between
transient workspaces before enabling live issuance or publishing.

Tar files are a hostile-input boundary even when retrieved from an
authenticated object store.  Archive members can contain absolute paths,
parent traversal, duplicate entries, symlinks, hard links, special devices,
unexpected ownership/mode metadata, and unexpectedly large contents.  GNU
tar makes some extraction-time transformations that must not be treated as
a substitute for project-specific scope validation.

## Decision Drivers

- Reject unrelated lineages and unexpected filesystem types.
- Admit only expected Certbot lineage and deployment paths.
- Preserve the standard relative `live/` symlink structure.
- Detect hidden aliasing through duplicate tar member names.
- Check that private-key-bearing files will not acquire permissive modes.
- Establish a testable gate before attempting any extraction.
- Preserve the standalone Bash artifact and avoid Python as a runtime requirement.

## Decision

An internal `certbotbot_archive_validate_domain` routine will inspect a
local owned readable compressed domain archive with GNU tar's numeric-owner,
full-time, escape-quoted verbose listing.  The parser rejects any listing
line outside that documented format.  It accepts only regular files,
directories, and the exact four expected lineage symlinks; any hard link,
device, FIFO, unknown member, traversal name, absolute path, duplicate
member, or unexpected symlink destination fails.

Permitted directory names are the relative `archive/`, `live/`,
`renewal/`, and `combined/` parents, plus the specific
`archive/<name>/` and `live/<name>/` directories.  File members are
limited to `archive/<name>/{cert,chain,fullchain,privkey}<N>.pem` for
positive decimal N, `renewal/<name>.conf`,
`live/<name>/combined.pem`, and `combined/<name>.pem`.
The four `live/<name>/{cert,chain,fullchain,privkey}.pem` symlinks
must point to literal `../../archive/<name>/<kind><N>.pem`
targets that are also members of the archive.  Private-key and combined
regular file mode metadata must not grant group/other permissions.

The first implementation limits regular-file sizes, aggregate declared
content, and member counts to bounded values.  These are conservative
resource limits, not a proof that compressed-input or GNU tar parser DoS
is impossible.  The future consumer and producer extractor must also
enforce compressed size, decompression budgets, extraction target
ownership, directory graph integrity, post-extraction file types and
modes, and no untrusted filesystem writes.  The archive validator
performs **no extraction** and does not invoke Certbot, GPG, or S3.

The initial validator supports domain archives only.  A separate policy
must govern the `common-latest.tar.gz` ACME account archive, whose
paths and secrets differ materially from the domain archive.

## Promises

- No archive member is extracted by the validation routine.
- Unknown lineage paths and unsupported tar entry types are rejected.
- Expected live links must have in-archive versioned targets.
- Required live links, renewal configuration, and both combined PEM
  files must be present.
- Validation failures return nonzero before any producer publication.

## Non-Promises

- Successful metadata validation does not authenticate archive contents.
- A tar archive can change after validation unless the producer stages a
  private immutable copy and controls its lifecycle.
- A valid listing does not prove an actual extraction implementation
  resists all symlink pivoting, tar extensions, or filesystem races.
- Metadata alone cannot prove PEM/key cryptographic matching, ACME
  account correctness, or portable renewal configuration.
- Resource limits alone do not prevent all archive decompression attacks.

## Adversary and Failure Model

An attacker or damaged producer could supply a tarball with duplicate
member names, deceptively quoted newline-containing filenames, links
outside the intended lineage, hard links to sensitive files, private-key
files with unsafe modes, unexpected special entries, or oversized
declared members.  A compressed bomb may exhaust resources during listing
even without extraction.  Tests must demonstrate rejection, no
workspace mutation, and consistent behavior across the three release
artifact flavors.  A later phase must add staged extraction and
independent filesystem validation before any archive is trusted.

## Operational Constraints

- Domain archive validation MUST occur before extraction or publication.
- Validation MUST use only canonical paths for the requested lineage.
- All live symlinks MUST match the expected relative target pattern and
  resolve to archived regular-file entries.
- Non-domain or common archives MUST NOT be passed off as valid domain state.
- Archive validation MUST remain unreachable from normal issuance until
  a complete safe restore and issuance workflow is implemented.

## Considered Alternatives

Unrestricted `tar -xf` followed by inspecting the extracted tree was
rejected because writes may escape before post-extraction validation.
Trusting S3 object keys or TLS alone was rejected because credentials,
uploaders, or stored bytes can be compromised.  A general-purpose
tar extraction framework or an embedded Python dependency was deferred
because the first need is a narrow Bash preflight for a fixed archive
shape.  The existing local PEM-link checker was not reused for raw
tar input because it inspects already-existing filesystem objects.

## Consequences

The first archive interface will reject atypical Certbot data until an
explicit reviewed extension describes its path and security contracts.
Archive validation becomes an inspectable, testable prerequisite.
Extraction, renewal-configuration path portability, and cryptographic
validation remain mandatory future stages and cannot be bypassed by
treating a green tar manifest as sufficient evidence.

## Related Decisions

ADR-019 defines the domain archive format.  ADR-022 governs failure-safe
publication.  ADR-025 governs renewal-state portability.  ADR-020
requires bundled implementations without arbitrary runtime plugins.
