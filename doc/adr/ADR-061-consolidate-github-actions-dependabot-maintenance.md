# ADR-061: Consolidate GitHub Actions Dependabot Version Updates

Date: 2026-11-12

## Status

Accepted

## Decision

Keep the current `github-actions` Dependabot ecosystem, repository-root
directory, weekly version-update schedule, seven-day cooldown, and
commit-message conventions. Replace its `minor-and-patch` group with
`actions-version-updates` configured with
`applies-to: version-updates` and `patterns: ["*"]`, without an
`update-types` restriction. Eligible major, minor, and patch routine
version updates may be proposed together within this ecosystem.

Security updates remain independent of the routine version-update group,
weekly schedule, and cooldown. Preserve the existing
`dependabot/fetch-metadata` guard that excludes updates whose highest
semantic version change is `version-update:semver-major` from auto-merge.
A grouped PR containing any major upgrade must receive targeted human
review before merging.

Do not close existing Dependabot PRs without evidence that their upgrades
have been covered and verified by successor PRs. Do not import the example
`test-gate` workflow, change existing required check identities, modify
workflow permissions, or adjust GitHub rulesets or branch protections.

## Context and Drivers

The existing weekly configuration groups only minor and patch GitHub
Actions releases, allowing separate major PRs to increase review overhead.
The adopted `coding_standards@v3.2.0` maintenance standard recommends a
per-ecosystem wildcard group for routine version updates, retaining a
seven-day cooldown, independent security response, and major-upgrade
scrutiny. This is a portfolio maintenance optimization, not a promise of
exactly one PR per week.

Certbotbot's CI exercises the producer's three distribution flavors,
the read-only client, local Pebble/SeaweedFS protocol E2E, OCI runtime,
and release/attestation/publication gates. Some Actions execute with
write-capable tokens or access to Docker Hub, GHCR, signing, and other
publication authority. Combining updates in a PR does not remove those
trust boundaries or justify relaxing their existing controls.

Closed, unmerged PR #305 experimented with a Marketplace regex
`test-gate`. Its logs demonstrated that the gate can succeed after
one discovered matching check completes, before a later E2E failure.
Its proposed ADR-060 was never adopted. This decision uses ADR-061 to
avoid reusing that experiment's abandoned identifier; no test-gate or
CI enforcement change is part of this task.

## Assumptions and Constraints

- GitHub Actions is the only currently configured Dependabot ecosystem.
  No docker, pip, or other ecosystem is implicitly enabled here.
- The existing weekly schedule, seven-day cooldown, and commit convention
  remain unchanged; only the routine version-update group changes.
- GitHub-side dependency graph, security alerts, security updates,
  CODEOWNERS requirements, required checks, and branch protections
  require independent verification. The integration received 403 when
  reading branch protection; YAML is not proof of effective settings.
- Privileged Actions (including registry authentication, release
  publication, attestations, and issue/PR management) require explicit
  review of migration guidance, permissions, attack surface, and CI
  evidence appropriate to their authority.
- Preserve full-SHA pinning and existing provenance controls; grouped
  updates do not grant permission to replace pins with floating tags.
- Existing branch-push Test, OCI, and local E2E checks, PR lint and
  security checks, release gates, and check names remain authoritative.
- ADR-018 governs the released shared standards and ADR-019 governs the
  authoritative `approved` issue-label boundary. Task #308 is approved
  specifically for this scoped change.
- No certificate selection, ACME, Route53, S3, encryption, archive,
  standalone client, Docker build, provider credential, or publication
  behavior is altered.

## Alternatives Considered

1. **Retain minor/patch-only grouping.** Rejected as the portfolio
   default: separate major PRs increase maintenance fragmentation
   without automatically imposing stronger substantive review.
2. **Group all eligible major/minor/patch routine updates.** Chosen,
   retaining manual scrutiny and the non-major auto-merge exclusion.
3. **Move to monthly updates or lengthen cooldown.** Rejected without
   evidence that slower visibility serves this active security-sensitive
   repository.
4. **Auto-merge major-containing groups.** Rejected because breaking
   changes or new Action privileges may affect credentials, CI
   integrity, and release authority.
5. **Group or delay security updates with routine versions.** Rejected:
   security remediation must remain a separate process.
6. **Close existing PRs as soon as the new configuration merges.**
   Rejected: changed grouping does not prove supersession or testing.
7. **Install the optional regex test gate.** Rejected from this task:
   PR #305 demonstrated that discovered checks alone cannot prove
   all expected checks have registered and completed.

## Tradeoffs, Risks, and Consequences

Routine update PR volume may decrease, but resolver constraints,
incompatible major versions, and action-specific failures may produce
multiple PRs or an unsatisfiable group. Failure diagnosis can become
harder within a grouped PR. A justified, narrowly scoped exception
may isolate a high-risk dependency; do not hide its updates with an
`ignore` entry merely to make the broad group pass.

Every grouped PR must be reviewed dependency by dependency, including
release notes, upgrade migration, affected permissions, third-party
supply-chain and transitive execution, compatibility, and evidence from
the CI/release path actually exercised. The highest-risk member sets
review depth. A green linter or CI check that never exercises a changed
publisher does not prove the release workflow remains safe.

Existing Dependabot PRs #303, #215, #214, and #213 remain open unless
an actual grouped successor covers their specific updates with
appropriate verification. Existing auto-merge requests remain subject
to GitHub's enforced checks and review protections; the workflow
request alone cannot prove merge readiness or review approval.

This is a maintenance-policy and documentation change only. It has no
product migration, runtime compatibility, artifact schema, or release
permission implications.

## Expected Outcomes and Verification

After merge, inspect subsequent weekly Dependabot proposals for
the new group, eligible SemVer coverage, major-update metadata, and
security-update separation. Verify major-containing groups cannot
enter non-major auto-merge, and verify required checks, CODEOWNERS,
branch protections, dependency alerts, and security-update enablement
through a sufficiently privileged settings view when available.

Compare actual update coverage, PR count, failures, and review burden
over multiple cycles rather than claiming an immediate reduction.

## Related Decisions

ADR-018 and ADR-019 govern imported standards and approval labels.
ADR-036 and ADR-048 govern producer validation, stable check names,
and workflow event triggers. ADR-038 through ADR-040 govern trusted
OCI builds and release-gated registry publication. ADR-046 and
ADR-047 govern isolated protocol E2E verification. None is
superseded by this decision.
