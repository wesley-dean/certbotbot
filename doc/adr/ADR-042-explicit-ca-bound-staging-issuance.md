# ADR-042: Explicit CA-Bound Staging Selection for Certificate Lifecycle

Date: 2026-10-27

## Status

Accepted

**Implementation status:** This decision is proposed for incorporation in approved task #219. Accepted is the repository's convention for ADRs intended for merge; the decision is not operative until the linked implementation PR is reviewed and merged.

## Decision

The ordinary producer's selected issuance, selected renewal, supported SAN reconciliation, account preflight, canonical renewal metadata checks, and candidate publication shall use **one immutable selected Let's Encrypt ACME environment per invocation**. The only accepted selections are `production` and `staging`; production remains the compatibility default for an ordinary producer invocation and staging is explicit opt-in. Arbitrary user-supplied ACME URLs, alias servers, ambiguous or mixed account contexts, and endpoint fallback are unsupported.

The selector is `--acme-environment production|staging` with corresponding `ACME_ENVIRONMENT`, resolved under the established CLI > exported environment > selected literal `.env` > default precedence. The public `register` command already uses the same spelling and supported values under ADR-041; reuse the bounded CA identity mapping rather than introducing a parallel issuer-only spelling. A malformed or empty explicit higher-priority value is an error, not permission to use the default. Existing invocations that omit CA selection retain their production behavior.

The selected production endpoint is `https://acme-v02.api.letsencrypt.org/directory`; the selected staging endpoint is `https://acme-staging-v02.api.letsencrypt.org/directory`. Certbot's private account root is correspondingly `accounts/acme-v02.api.letsencrypt.org/directory/` or `accounts/acme-staging-v02.api.letsencrypt.org/directory/`. Validation requires exactly one account for the selected CA and rejects accounts for any other CA, competing IDs, or missing required registration files. Certbot `show_account`, `certonly` and selected `renew` must receive the exact selected `--server`, explicit account identity and private paths. The selected server is never inferred from restored untrusted files. Existing renewal metadata must be compatible with the selected account and server; unrecognized server identity, cross-CA renewal provenance and conflicting or unsafe renewal configuration fail before Certbot execution or S3 publication.

A staging selection **never falls back** to production, even when staging is unavailable, a restored account is absent or a Certbot invocation fails. The ordinary issuer still requires a preseeded object with a matching existing account; it never implicitly registers one. Per ADR-041, staging and production account contexts use distinct S3 keys and one CA context per archive. No migration, merging of CA accounts, implicit account replacement, forced renewal, global renewal, host Certbot state fallback or new arbitrary provider behavior is authorized.

Milestone 4's privileged acceptance workflow must enforce a **separate staging-only policy** that fails before any remote action unless staging is explicitly selected, matches the exact allowlisted staging endpoint and account layout, and uses dedicated test-only resources. The producer's compatibility default of production must **not** become the workflow's default; a missing explicit selection is an error in this workflow. Forbidden-production negative evidence must be mocked/local, with no production network access.

## Context and constraints

ADR-041 deliberately permits staging for explicit account registration but defers ordinary issuance/renewal. ADR-023 fixes the ordinary restored-account preflight to production; ADR-024 hardcodes production in selected issuance; ADR-025 does likewise for selected renewal. The orchestration and renewal mapping also assume production. These intentionally fail closed when given staging state and therefore cannot satisfy approved story #16's real staging lifecycle. Task #219 separately authorizes the consequential CA selection decision. ADRs 020–022 and 026–030 govern stable selected lineage, secure restore, renewal, candidate verification and one-key publication and remain in force.

The producer is a standalone Bash 4.3+ program with three built public flavors, installed Certbot/Route53/AWS clients and an operator-supplied existing bucket and zone. Source/test changes must preserve private workspace ownership, strict archive validation, no archived hooks, exact SANs and all prior failure gates. No live service contacts are required by routine pull-request CI. A local account layout and mock Certbot probe are not proof of actual remote registration.

## Alternatives considered

- **Use production for the milestone 4 tests:** rejected by the operator's absolute no-production constraint.
- **Use Certbot `--dry-run` to test staging with production-selected issuer:** rejected; does not demonstrate the public producer's authentic staging-only persisted lifecycle.
- **Change the ordinary default from production to staging:** rejected for backwards compatibility, and it would conceal environment authority in existing scheduled invocations.
- **Infer the endpoint from the restored account files:** rejected because untrusted persisted state must not choose the remote CA.
- **Allow any supplied ACME directory URL:** rejected; enlarges the trust and compatibility boundary beyond the two tested Let's Encrypt environments.
- **Permit one archive to contain both production and staging accounts:** rejected; ambiguous selection and state mixing increase risk and conflict with ADR-041.
- **Implement a hidden staging-only test shim:** rejected; milestone #4 requires testing the same shipped public producer that operators use.
- **Relax only the production account-directory check:** rejected; leaves Certbot issuance, renewal, renewal metadata and final verification inconsistently bound to production.
- **Use an independently distributed staging-only executable:** rejected; creates a second product and release supply chain without need.

## Consequences and tradeoffs

This adds explicit public configuration and refines production-only decisions while preserving their fail-closed principle. Existing production archives and invocations retain the production default. A staging archive must use a distinct dedicated current key and will be refused by production-selected calls; a production archive is refused under staging selection. All Certbot provider probes and mutations must agree on one selected CA. A malformed or ambiguous account/renewal archive results in failure and no intentional publication.

Staging certificates are untrusted by ordinary production TLS clients; this is expected. The change cannot by itself prove Route53/IAM access, real Certbot compatibility, remote staging registration or S3 durability. Those require separately authorized live E2E acceptance and redacted evidence. The trust boundary still includes installed Certbot and plugins, AWS credentials, isolated runner and validated archive. S3 failed writes remain remotely uncertain and external writer serialization remains the operator's responsibility.

## Implementation and verification criteria

1. Resolve the CA selector once from approved configuration precedence; reject unsupported and malformed values without fallback.
2. Carry the selected CA identity through the state validator, selected issuance, selected renewal, SAN reconciliation, renewal canonicalization and post-Certbot candidate checks. Reject cross-CA restored account and renewal metadata before network operations.
3. Verify the exact Certbot `--server` and `--account` in all probes and mutations for each environment; no implicit `register`, host fallback, global `renew` or arbitrary server.
4. Add cross-flavor public-artifact mock tests for staging first issuance and restored renewal/no-op, production-default compatibility, unsupported CA, mixed-account and cross-CA metadata, and negative no-production-fallback assertions. Preserve checksum companions and minimum Bash 4.3 contract.
5. Document the new ordinary selector and retained production default. The manual milestone 4 runbook requires explicit staging and an independent workflow gate before real AWS/Route53/ACME tests.

## Relationship to other ADRs

This decision refines **only the production-only CA identity assumptions** in ADR-023 (account preflight), ADR-024 (Certbot selected issuance), ADR-025 (selected renewal) and associated mapping/orchestration code. It does not supersede their other constraints. ADR-041 remains authoritative for explicit registration, TOS consent, EFF preference, account-only archive initialization and conditional S3 publication. ADR-019 governs separate technical-task approval; ADR-009 and ADR-036 govern public artifact and release-verification evidence. Task #219 is the required independently approved implementation issue.
