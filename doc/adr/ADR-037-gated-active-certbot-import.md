# ADR-037: Gate Active Certbot State Import on Verified Portability

Date: 2026-10-16

## Status

Accepted

## Decision

A producer must **not** install staged common-account or certificate-lineage archives into Certbot's active configuration merely because their tar manifests, extracted filesystem trees, account references, and path-rebase previews pass their individual validators.

Phase 4I is divided into two explicit boundaries:

1. **Preparation and assessment (permitted now):** restore the common archive and selected lineage archives into isolated, private staging trees; reject malformed archive content, incompatible ACME environments, wrong account references, mismatched lineage identities, unsafe renewal options, and nonportable paths.  Inspect and report an intended import without mutating active Certbot state, invoking Certbot, or publishing S3 objects.
2. **Activation (withheld):** install verified data into a fresh active Certbot configuration only after the evidence below is reviewed and an additional Accepted ADR authorizes the exact import and rollback mechanism.  ADR-032's preview must remain non-activating until that decision.

All requested lineages for one invocation must be assessed before active-state mutation.  Common account state must be present and consistent whenever an existing lineage is restored.  No fallback registration is permitted for a missing or corrupt common archive that belongs to an existing lineage.  A completely empty collection may be initialized only by a separately reviewed issuer path.

## Required evidence before activation

- A supported, pinned Certbot release must create genuine Let's Encrypt **staging** account state and a real DNS-01-issued lineage using narrowly scoped credentials.
- After destroying the first runner's workspace, a second independent workspace must restore the same account and lineage and demonstrate genuine account reuse and no-op renewal behavior.
- After destroying the second workspace, a third must demonstrate due renewal or an intentional SAN addition/removal, retaining the expected ACME account and writing independently restorable archives.
- The importer must reject renewal hooks, arbitrary path overrides, unexpected credential/plugin paths, ambiguous account selection, and unsupported Certbot configuration fields.  No archived code or foreign executable hooks are accepted.
- Two selected domain archives must coexist with disjoint lineage member paths and no accidental shared-state overwrite.
- The resulting active configuration must pass file ownership, path, private-key mode, chain/key/combined-PEM, and exact requested SAN checks before any subsequent publication.
- Tests must establish failure atomicity before activation: a failed or conflicting import must leave the intended active configuration untouched.  No S3 mutation, DNS operation, or account registration may occur on that failure.
- Acceptance must use staging/production-specific namespaces and preserve the separation required by ADR-030.  Staging trust roots must be explicit when validating staging chains.
- The existing release gate and public status-69 issuance failure remain enabled throughout preparatory work.

## Context and constraints

ADR-027 and ADR-028 authorize *isolated* extraction only; ADR-031 validates selected account references, not account JSON authenticity; ADR-032 allows only a non-activating renewal-path preview.  ADR-033 through ADR-035 add valuable synthetic and locally signed Certbot compatibility tests, including a three-run ARI continuation.  They do not demonstrate real ACME registration, authenticated account reuse, DNS challenge issuance, changed SANs, or remote persistence.

The durable-state requirement is that Jenkins, GitHub Actions, and EC2 can run serially against the same common and selected lineage archives without using prior local state.  That requirement must not be relaxed to make import work on one host.

## Assumptions

- Bash 4.3 remains the minimum native runtime; the reviewed standalone artifacts embed the same internal modules.
- The first-release provider set is the bundled Route53 and S3 implementations, with no consumer-installed plugins.
- The producer has exclusive control of an owner-private, new workspace, but no guarantee against another process under the same operating-system user.
- Independent writers are externally serialized; storage-backed fencing is outside v1.
- The private workspace may be destroyed at the end of each run; object storage alone must carry durable ACME state.
- The account-only common archive format may require reviewed amendment if real Certbot needs additional durable shared state.

## Alternatives considered

**Copy staged trees directly into config/** was rejected: validators do not yet authenticate an ACME account or prove all renewal settings safe, and sequential copying can leave partially activated state.

**Use the ADR-032 path preview as the active renewal file now** was rejected: it directly contradicts that ADR's explicit prohibition and lacks genuine staging account-reuse and changed-SAN evidence.

**Rely on the synthetic three-workspace test** was rejected as the sole gate: it deliberately blocks real network operations and uses synthetic account registration.

**Use a persistent filesystem across runners** was rejected because it violates the project requirement that object storage is the sole durable producer state.

**Enable issuer publication along with import** was rejected: S3 absence/error classification, multi-object publication and rollback, optional encryption, and pre-publication verification must receive separate review.

## Consequences, failure behavior, and compatibility

Preparatory work may add internal, test-only orchestration and negative tests, but it must not change the public CLI, release-artifact naming, or fail-closed normal invocation.  Failures must not install staged files into active Certbot state, request a certificate, or write to S3.

The later activating ADR must choose a specific strategy for assembling a complete candidate active tree, validating it, and committing or rolling it back without accepting a partially initialized workspace.  It must also address security semantics of account JSON, cross-lineage conflicts, renewal option grammar, backup/recovery, and the lifecycle of temporary private data.

This decision neither supersedes nor weakens ADR-025 or ADR-032; it documents the required transition between internal staging and public issuer integration.  The public issuer remains disabled, and automatic releases remain gated.

## Related decisions

ADR-018 defines requested certificate identity; ADR-019 durable split archives; ADR-022 serialized publication; ADR-025 Certbot portability; ADR-027 and ADR-028 archive staging; ADR-029 and ADR-036 certificate verification; ADR-030 and ADR-031 environment/account identity; ADR-032 preview restrictions; ADR-033 through ADR-035 compatibility tests.
