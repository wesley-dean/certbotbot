# ADR-024: Govern Maintained Content by a Verified Released Coding Standards Snapshot

Date: 2026-10-15

## Status

Accepted

## Context

certbotbot is derived from template-bash and inherits project-local ADRs and documentation conventions.  The author maintains a separate released coding standards repository, intended to give projects shared baseline requirements without requiring runtime update machinery.  A committed snapshot makes the exact standards visible to reviewers and reproducible across contributor environments.

## Decision Drivers

- Apply the latest stable released standards, never mutable main-branch content.
- Preserve local accepted ADR governance while making deviations visible.
- Avoid automated standards fetching in runtime, build, or CI.
- Keep source provenance auditable through a concrete version and archive digest.

## Decision

Adopt `coding_standards@v2.1.0` from `https://github.com/wesley-dean/coding_standards.git`, materialized under `doc/standards/`.  Record source, concrete version, artifact SHA-256, and managed destination in `.codingstandardrc`.  The release contains `coding_standards.tar.gz` and `coding_standards.tar.gz.sha256`; the selected release digest is `ee04401441a3206d5cdc2bdc2e6d5130ff278ddc1ecd641f1c01843aa0666020`.  Applicable standards in the committed snapshot are mandatory.  General and cross-cutting standards apply as relevant, language-specific standards apply to maintained content in those languages, and `examples/` is illustrative unless a governing document explicitly elevates it.

Accepted project-specific ADRs or explicit local policy may refine or supersede imported standards.  Deviations MUST be recorded in local governance, never inserted by editing managed upstream snapshot files.  Changes to the upstream standards require a reviewed refresh/upgrade operation with a new concrete release, checksum verification, and a full snapshot replacement through a PR.

## Promises

- Reviewers can inspect exact adopted standards locally without a network request.
- The declared release and digest are stable, inspectable provenance.
- No runtime standards downloader or ongoing update job is installed.

## Non-Promises

- Importing standards does not prove the implementation follows every applicable rule.
- Standards adoption does not supersede already accepted local ADRs without an explicit reconciliation.
- Presence of standards for another language does not make them applicable to this Bash project.

## Adversary and Failure Model

Unpinned latest tags, mutable source branches, unverified archives, local edits to managed files, and silent governance conflicts could create divergence across contributors.  The resolved version and digest must be recorded; imported files must match the selected release tag; future changes must be reviewed for drift.

## Operational Constraints

- Standards MUST come from one concrete stable GitHub Release.
- `doc/standards/` MUST remain a complete managed snapshot, not a mixed local overlay.
- Applicable standards MUST be obeyed unless an accepted local ADR or explicit policy refines them.
- No independent standards downloader MAY be installed in this repository.

## Considered Alternatives

Referencing upstream main dynamically was rejected because it is mutable.  Placing standards in `dependencies.txt` was rejected because the standards protocol explicitly forbids adding updater machinery to consuming repositories.  Editing imported files to make local exceptions was rejected because it destroys provenance.

## Consequences

Maintainers must review standards updates explicitly.  New contributors gain an inspectable normative baseline alongside the existing project-specific ADRs.

## Related Decisions

Inherited ADR-001 and ADR-013 govern documentation hierarchy and repository hygiene.  ADR-023 governs separate build dependencies.
