# ADR-011: Conventional-Commit Semantic Releases and Late Tagging

Date: 2026-08-19

## Status

Accepted

## Context

The repository template already uses Conventional Commits and the
`bitshifted/git-auto-semver` GitHub Action.  The action can calculate semantic
versions from commit history: `feat` increments the minor component,
`BREAKING CHANGE` increments the major component, and supported maintenance
commit types increment the patch component.

A release pipeline should validate the exact bytes it publishes.  Creating a tag
before build and validation makes failure recovery more awkward because an
immutable-looking release marker can exist for artifacts that never passed the
release contract.

## Decision Drivers

- Derive predictable semantic versions from commit history.
- Support major, minor, and patch increments.
- Validate exact release bytes before publication.
- Preserve artifact attestations and checksum verification.
- Avoid creating release tags for failed builds.

## Decision

The release workflow SHALL use `bitshifted/git-auto-semver` with
`create_tag: false` to calculate the next version from Conventional Commits.

The versioning policy SHALL document that `feat` produces a minor increment,
`BREAKING CHANGE` produces a major increment, and supported maintenance commit
types such as `fix`, `docs`, `test`, `refactor`, `perf`, `build`, `ci`, `chore`,
`style`, and `revert` produce a patch increment according to the action's
contract.

The workflow SHALL prepare and verify repository dependencies, run maintained
source validation, build the three artifacts using the calculated version, test
the exact generated artifacts, verify checksums, and attest release files before
creating the GitHub release/tag.

The release action SHALL create the tag only after validation succeeds.  Release
artifacts SHALL include all three executable flavors and all three checksum
companions.

## Operational Constraints

- Version calculation MUST use Conventional Commit semantics.
- The SemVer calculation step MUST NOT create the tag early.
- `feat` MUST be documented as a minor increment.
- `BREAKING CHANGE` MUST be documented as a major increment.
- Exact release artifacts MUST be validated before release/tag creation.
- All executable artifacts and checksum companions MUST be published.

## Considered Alternatives

Patch-only automatic versioning was rejected because the selected action already
supports meaningful major and minor semantics.  Early tag creation was rejected
because validation should precede publication.  Manual version files were
rejected as the starter default because they duplicate information derivable from
release history and commit semantics.

## Consequences

Commit messages become part of the release interface and require discipline.
The workflow is longer because it validates exact release bytes before creating
the release, but failed validation does not leave a premature release tag.

## Source Lineage

adrctl's current semantic release workflow already calculates with
`create_tag: false`, validates exact artifacts, verifies checksums, and attests
before `softprops/action-gh-release` creates the release/tag.  The template's
existing README already documents the major/minor/patch Conventional Commit
mapping.

## Related Decisions

- ADR-006: Three Release Artifact Flavors, Metadata, and Checksums
- ADR-009: Observable Behavior Testing Across Shipped Artifacts
