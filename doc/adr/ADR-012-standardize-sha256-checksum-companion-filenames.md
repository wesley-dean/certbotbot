# ADR-012: Standardize SHA-256 Checksum Companion Filenames

Date: 2026-08-27

## Status

Accepted

## Context

ADR-006 established three executable release flavors and one SHA-256 checksum
companion for each executable.  It selected the suffix `.256`, producing names
such as `<project>.bash.256`.

The checksum tools themselves do not require a particular filename extension, so
`.256` works mechanically.  The name is nevertheless less explicit than
`.sha256`: the latter identifies the digest algorithm directly and now matches
the convention used by the related Bash projects from which this starter derives
its engineering patterns.

A template amplifies naming choices.  Continuing to emit `.256` here would cause
new projects created from the starter to inherit a convention that the source
projects have already replaced.

Historical GitHub releases are published records and should not be rewritten
solely to rename their checksum assets.  Compatibility with older `.256` assets
therefore belongs on the read side rather than in duplicate publication of both
suffixes.

The dependency trust boundary is separate from release checksum naming.  ADR-005
makes committed SHA-256 digests authoritative for the bashdeps bootstrap and
manifest-managed repository dependencies.  A published checksum sidecar is useful
for release verification, but it must not dynamically replace those committed
trust decisions.

## Decision Drivers

- Make the checksum algorithm explicit in the companion filename.
- Keep the starter aligned with the related Bash projects it is intended to
  represent.
- Ensure newly derived projects inherit the current convention automatically.
- Preserve one checksum companion per executable and the six-file release model.
- Preserve conventional `sha256sum` / `shasum -a 256` checksum contents.
- Keep historical releases verifiable without modifying published assets.
- Avoid publishing duplicate `.sha256` and `.256` companions.
- Fail closed rather than treating unrelated retrieval or verification errors as
  evidence that a legacy filename should be tried.
- Preserve committed digests as the authority for repository dependencies.

## Decision

`make build` SHALL produce one `.sha256` checksum companion for each executable
artifact:

```text
<project>.dev.bash.sha256
<project>.bash.sha256
<project>.min.bash.sha256
```

Together with the three executable flavors established by ADR-006, a successful
build SHALL continue to produce six current release files.

Each `.sha256` file SHALL contain the SHA-256 digest and corresponding executable
basename in conventional checksum-tool syntax.  The digest algorithm and file
contents do not change as a consequence of this decision.

New builds and releases SHALL publish only `.sha256` checksum companions.  They
SHALL NOT publish duplicate `.256` companions for transitional compatibility.

A successful build SHALL remove stale `.256` companions for the current generated
executable filenames so output left from the previous convention cannot appear to
be part of the current release contract.

Historical releases that contain `.256` companions SHALL remain unchanged.  A
consumer that retrieves checksum sidecars across both naming eras SHOULD request
`<artifact>.sha256` first and MAY retry `<artifact>.256` only when the preferred
resource is confirmed absent, such as an HTTP 404 for the preferred release
asset.

Fallback SHALL NOT occur because of DNS, connection, timeout, TLS,
authorization, server, malformed-content, or checksum-verification failures.
Those conditions remain failures.

Release checksum sidecars SHALL remain separate from repository dependency trust.
The Makefile SHALL continue to authorize its bashdeps bootstrap with the committed
SHA-256 digest, and `dependencies.txt` SHALL continue to authorize managed
artifacts through committed `digest=sha256:...` values.  Neither Make nor bashdeps
shall dynamically replace those expected digests with values fetched from
`.sha256` or `.256` sidecars as a consequence of this naming change.

Release and CI workflows SHALL verify the generated `.sha256` companions before
publication.  Tests SHALL require the current companions and SHALL reject stale
`.256` companions for current build outputs.

## Operational Constraints

- Every current executable artifact MUST have one adjacent `.sha256` companion.
- New releases MUST NOT publish duplicate `.256` companions.
- Successful builds MUST remove stale `.256` companions for current artifact
  filenames.
- Checksum companions MUST retain conventional SHA-256 checksum-file contents.
- Historical `.256` release assets MUST remain valid for the releases that
  contain them.
- Cross-generation consumers MAY use `.256` only after confirmed absence of the
  preferred `.sha256` companion.
- Retrieval and verification failures MUST NOT trigger legacy fallback.
- Published checksum sidecars MUST NOT replace committed dependency digests.
- The three executable flavors and six-file release model from ADR-006 remain in
  force.

## Considered Alternatives

### Keep `.256`

This would require no migration, but it would preserve a less self-describing
suffix and cause new projects derived from the template to inherit a convention
that related projects have already retired.  It was rejected.

### Publish both `.sha256` and `.256`

Publishing both would support consumers that hard-code the old name without
read-side compatibility logic.  It would also duplicate the same digest data,
expand the release surface beyond six files, and make the old suffix appear
current indefinitely.  It was rejected.

### Fall back to `.256` after any `.sha256` retrieval failure

A generic fallback would conflate confirmed absence with transport, TLS,
authorization, server, or verification failures.  That could hide a real problem,
so fallback is limited to confirmed absence.

### Replace per-artifact companions with an aggregate checksum file

An aggregate `SHA256SUMS` file is a valid convention, but ADR-006 deliberately
established one checksum companion per executable.  This decision changes only
the suffix and does not revisit that relationship.

### Trust published sidecars for repository dependencies

Using live sidecars as dependency authorization would move the trust decision from
reviewed repository source to remote state and contradict ADR-005.  It was
rejected.

## Consequences

The starter and projects derived from it use self-describing `.sha256` checksum
filenames while retaining the same SHA-256 algorithm, artifact flavors, and
release-artifact count.

Historical `.256` releases remain verifiable without alteration.  Consumers that
span both naming eras require a narrow absence-only fallback if they automate
checksum-sidecar discovery.

A rebuild in a working tree containing old `.256` outputs converges to the current
six-file contract rather than leaving obsolete companions behind.

Repository dependency authorization remains unchanged and continues to rely on
committed SHA-256 digests.

## Source Lineage

This decision aligns the starter with the `.sha256` checksum companion convention
adopted by bash-doxygen, bashdeps, mktext, adrctl, and Bootstrap.  The starter
carries the convention forward generically through `PROJECT_NAME` so derived
projects inherit it without project-specific filename edits.

## Superseded Decisions

This ADR supersedes ADR-006 only where ADR-006 names `.256` as the checksum
companion suffix or requires `.256` companions in its operational constraints.
All other ADR-006 decisions remain in force.

## Related Decisions

- ADR-003: Make as the Canonical Orchestration Interface
- ADR-005: Dependency Management and Explicit Network Boundaries
- ADR-006: Three Release Artifact Flavors, Metadata, and Checksums
- ADR-009: Observable Behavior Testing Across Shipped Artifacts
- ADR-011: Conventional-Commit Semantic Releases and Late Tagging
