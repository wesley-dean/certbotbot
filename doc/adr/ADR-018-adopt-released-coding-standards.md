# ADR-018: Adopt a Verified Released Coding Standards Snapshot

Date: 2026-10-19

## Status

Accepted

## Decision

Adopt the latest stable upstream `wesley-dean/coding_standards` release,
resolved on October 19, 2026 as **`coding_standards@v2.1.0`**. Materialize
the exact release's `standards/` contents into this repository's
`doc/standards/` tree. Record the canonical upstream, concrete release,
published archive SHA-256 digest, and destination in `.codingstandardrc`.

Files in `doc/standards/` are externally managed. Do not edit them locally,
copy from upstream `main`, or install permanent standards-download/update
machinery. An update must select a verified concrete GitHub Release and
replace the entire managed tree, proposing it through a reviewable PR.

**Applicability:** General and cross-cutting standards apply wherever
relevant. Language-specific standards govern maintained content in the
corresponding language. Presence of a standard does not make it universally
applicable. Content under `doc/standards/examples/` is illustrative and
non-normative except where a governing standard explicitly states otherwise.

**Precedence:** Applicable shared standards are governing repository
requirements. Accepted repository-specific ADRs and explicit local policy
may deliberately refine or supersede an applicable standard. Conflicts
must be identified and resolved visibly; imported standards must never
be modified locally to encode a repository exception.

The independently prepared drafts under `doc/research/` preserve what
was learned from the previous, larger certbotbot rebuild. They are
**historical or proposed material, not current implementation mandates**.
Project planning will convert accepted Phase 1 requirements into GitHub
Issues, technical planning into linked tasks, and implementation into
reviewed code. Those future user stories must not silently inherit
design choices from `certbotbot-research`.

## Context and Drivers

The `certbotbot` repository was freshly created from `template-bash`
after the exploratory implementation was renamed `certbotbot-research`.
The reset explicitly separates product management, technical planning,
and execution to avoid building an extensive framework before a
one-domain, one-archive Certbot/S3 lifecycle works.

Applying independently reviewed coding standards provides consistent
engineering expectations without duplicating their text in project
documentation. The standards are a versioned artifact and should
not quietly track changing upstream `main`.

The user requested both preservation of the prior research documents
and adoption of the current released standards as repository content.
Neither action authorizes a new issuer implementation or changes the
product backlog.

## Assumptions and Boundaries

- The upstream is `https://github.com/wesley-dean/coding_standards.git`.
- The selected tag `v2.1.0` identifies upstream commit
  `b780b378c438570f7222700acce4a34000ad9647`.
- GitHub release metadata publishes archive SHA-256
  `ee04401441a3206d5cdc2bdc2e6d5130ff278ddc1ecd641f1c01843aa0666020`.
- The separately published checksum companion metadata is consistent
  with the precisely reconstructed conventional `sha256sum` record
  for that archive. The tag's entire 46-file `standards/` tree has been
  materialized through GitHub connector reads, with exact blob identity.
- The build remains governed by relevant inherited Accepted ADRs until
  the Technical Architect expressly adopts or supersedes them for Phase 1.
- This decision does not require unrelated standards for languages the
  project does not maintain.

## Alternatives Considered

**Copy only selected standards:** rejected because it would break
reproducible snapshot identity and make local omissions hard to audit.
Applicability can be evaluated without mutating the upstream release.

**Track the upstream main branch:** rejected because source behavior
could change without an explicit reviewed version bump.

**Duplicate governing text in AGENTS.md:** rejected because summaries
drift and conceal release provenance. Reference the committed snapshot.

**Import the old research repository's entire implementation and
governance:** rejected because its split archive and multi-lineage design
was deliberately deferred. Preserve knowledge without inheriting scope.

**Add a standards auto-updater:** rejected. Adoption remains an explicit
reviewable process, not a hidden network/build dependency.

## Consequences and Verification

The managed tree must match the selected release exactly, including
all 46 maintained and example files. The target's `.codingstandardrc`
pin records the published archive hash, not a hash of the extracted tree.

Repository-facing instructions in `AGENTS.md`, `README.md`, and
`CONTRIBUTING.md` must describe the standards' authority, relevance,
local ADR precedence, and prohibition on editing the imported snapshot.
Future agents should read those instructions and the applicable standards,
not load the entire research archive by default.

No implementation code, cloud resource, user story, or GitHub issue is
authorized by this decision. A later technical-planning ADR may refine
inherited starter conventions where the accepted Phase 1 product scope
requires it.

## Related Decisions

ADR-001 defines the documentation hierarchy, ADR-004 and ADR-014
distinguish template plugin examples from necessary product design,
ADR-008 governs documentation-before-implementation, ADR-013 maintains
repository-facing documentation, ADR-015 governs dependencies, and
ADR-017 governs generated ADR navigation.
