# ADR-043: Manually Authorized Staging-Only Live E2E Workflow

Date: 2026-10-27

## Status

Accepted

## Decision

Milestone 4's live acceptance uses a **separate, manually dispatched** GitHub Actions workflow, on the trusted `main` branch of `wesley-dean/certbotbot`. Its trigger is solely `workflow_dispatch`. It has no push, pull-request, pull-request-target, reusable-workflow, release, or schedule trigger. The manual dispatch accepts **zero inputs** (Checkov CKV_GHA_7, parameterless build integrity); staging is a literal, non-overridable value in the trusted workflow and is also passed explicitly to the public producer. The operator's act of dispatching this single-purpose named workflow is the affirmative action, restricted to the repository owner `wesley-dean`. The original `github.actor` and retry-time `github.triggering_actor` must both be that owner, including on re-runs. Both the workflow's admission guard and each credentialed job independently enforce repository, manual event, trusted main ref, immutable source SHA, owner identity, and literal staging **before** network-capable checkout, credential injection, or cloud operation. The owner must separately verify test-only resources and authorize the precise run; the manual click alone cannot prove the external resources' isolation.

The workflow uses three jobs in dependency order: a **credential-free** checked-source build/verification job; a first private runner for a selected genuine staging issuance against an **existing** staging-account S3 archive; and a second independent private runner for restoration and the normal selected renewal/no-op decision. The first job builds the public producer artifacts from pinned dependencies and supplies one same-run, same-attempt checksum-verified artifact handoff using the existing ADR-036 manifest. The two credentialed jobs reverify all artifact identities before injecting AWS secrets. Both call the same shipped ordinary producer `certbotbot.bash`, not internal library functions. Each job independently verifies the trusted event/ref, explicit staging selection, expected scoped resource parameters, and the isolated S3 seed before a provider invocation.

The public issuer is always invoked with the literal `--acme-environment staging`, alongside `--config` pointing to an empty private literal configuration, one controlled DNS domain, an existing S3 bucket and **dedicated staging key**, `--archive-encryption none`, `--include-subdomains true`, `--upload-no-renewal false`, disabled dated backups, zero retention, and no archive migration. No EFF signup, ToS assent, `register`, production CA, global renew, forced renewal, arbitrary SANs, or provider fallback is authorized inside the workflow. Production remains the ordinary producer compatibility default outside the workflow as decided by ADR-042.

All supplied GitHub Actions configuration values are repository **secrets** referenced with `secrets.*`, not repository variables. Only the credentialed stage injects the required AWS key pair, region, test domain, public Route53 zone ID, S3 bucket and key. The stored contact email is deliberately **not injected** because issuance must reuse a previously seeded staging account; `GPG_SYMMETRIC_KEY` and registry secrets are also excluded. Never run unreviewed pull-request code in a secret-bearing job.

First issuance must result in actual `issued` and `published=true`, followed by an independently verified readable S3 object. The first job records its SHA-256 object digest as nonsecret inter-job comparison metadata. The second job obtains the same object from S3 on a different ephemeral runner, verifies the digest before running, requires a legitimate `published=false` selected no-op, and verifies the object bytes remain unchanged afterward. Missing seed, expired credentials, wrong zone, changed archive, preflight mismatch, unsupported input, unexpected renewal, or uncertain remote write causes a failed job. A due-renewal demonstration is **not** synthesized; it requires a separately authorized future natural-due run or recorded acceptance limitation.

The emitted log/evidence is deliberately **bounded**: source commit and checked public artifact digest, job/run identity, named scenario, whether a staging call reached the public producer, real AWS/Route53/ACME boundaries, and pass/fail results. The workflow captures and deletes raw producer/provider output privately; it does not print secret values, zone IDs, domains, ACME account material, AWS identities, challenge responses, raw certificates, archives, or private paths, and does not upload credentialed artifacts. S3 operation failures may leave uncertain remote state even if this run exits nonzero. An externally provisioned bucket recovery/versioning path and **serialization of all writers**, including nonworkflow actors, remain the operator's responsibility.

## Context and constraints

- Accepted ADR-041 permits explicit staging registration, but registration is a separate privilege and requires positive consent.
- Accepted ADR-042 now allows explicitly selected staging issuance and requires an independent pre-network staging-only workflow gate.
- ADR-020 through ADR-030 preserve archive privacy, selected-lineage behavior, native Certbot state, fail-closed restoration, and no unintended publication. ADR-036 requires independently verifiable immutable public artifacts.
- Approved task #225 belongs to milestone 4's live acceptance story #16 and staging-resource story #91. Existing tasks #104, #47, #48, #49 and #219 contain preflight, mock, and release evidence, **not** live interoperability.
- Staging certificates are intentionally untrusted by browsers. Genuine Let's Encrypt staging, Route53 DNS-01, and real Amazon S3 are required for live acceptance; local Bats mocks and Certbot dry-run do not qualify.
- A GitHub repository secret's existence proves neither its value, permissions, domain scope nor consent to operate it. The operator must explicitly authorize the exact test-only domain, zone and bucket/key and confirm a recovery mechanism outside the workflow.
- The workflow cannot guarantee that unrelated external writers honor its GitHub concurrency group; that is a residual operational risk.

## Considered alternatives

1. **Add real credentials to ordinary Test or Versioning:** rejected. Those workflows process changes automatically and, in some configurations, untrusted PR content. Privilege separation is mandatory.
2. **Test on production Let's Encrypt:** rejected under the absolute milestone staging-only constraint.
3. **Run Certbot `--dry-run` alone:** rejected because it does not prove the selected public producer's persistence and independent restored no-op.
4. **Infer the environment from an archive or default:** rejected; production is the normal default, and untrusted persisted state cannot choose a CA.
5. **Seed accounts automatically in the issuer:** rejected; registration has separate explicit consent and publication governance under ADR-041.
6. **Use one runner with cleared paths:** rejected for required independently allocated runner identity and avoidance of accidental host state reuse.
7. **Keep user-controlled workflow_dispatch parameters for a second typed confirmation:** rejected by CKV_GHA_7's parameterless build-integrity requirement. Owner-only dispatch with constant staging and separately reviewed resource scope avoids user-supplied build parameters; the missing typed prompt is an explicitly acknowledged tradeoff.
8. **Build independently on both credentialed runners:** rejected: increases bytes/provenance ambiguity and network exposure with credentials. One verified same-run artifact handoff is the established ADR-036 model.
9. **Download latest mutable release artifacts or reuse PR artifacts:** rejected: mismatched source and unreviewed artifacts can smuggle code into a privileged run.
10. **Publish private archive or raw Certbot logs as evidence:** rejected: they may contain reusable account keys, private certificate keys, and identifying or secret values.
11. **Force early renewal for a fully green first run:** rejected: would not demonstrate normal due/no-op behavior and may incur CA rate limits.

## Consequences and verification

This creates a deliberately separate, manually initiated trust boundary. The earlier typed-confirmation workflow inputs were removed to satisfy Checkov CKV_GHA_7 without a policy exemption. The only admitted dispatcher and retrying actor are the owner, and staging selection is constant. This trades away a second typed confirmation prompt; the owner must still affirm test scope and recovery privately before dispatch. A protected GitHub environment with required reviewers may add defense in depth when explicitly configured, but none is presumed or required by this implementation. A first run against an archive that already contains a valid, unchanged lineage will **fail** the first-issuance assertion; operators must use a new dedicated staging seed/key for a genuine first-issuance acceptance. A second run on a different job obtains continuity from S3 alone. Both producers remain production-default outside this workflow, and ordinary release automation is unchanged.

Tests must verify the guard's negative event/ref/repository/CA/actor cases locally with **no network**, prove the workflow has no automatic triggers or secret-bearing PR jobs, and preserve existing CI and release gates. After review and merge, a separate operator-authorized dispatch can provide real evidence. A green mocked PR workflow, code review, or creation of this workflow **does not** close parent story #16 or #91. The actual live run and its redacted evidence require independent review.

## Related decisions

ADR-009 (observable public tests), ADR-016 (threat modeling), ADR-019 (approval governance), ADR-020–030 (selected S3 lifecycle), ADR-036 (verified artifact handoff), ADR-041 (separate registration and consent), and ADR-042 (explicit CA identity). This ADR specializes ADR-042's staging-only workflow policy without modifying the production issuer default or superseding existing production contracts.
