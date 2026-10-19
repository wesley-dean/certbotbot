# certbotbot: Project History, Engineering Findings, and Lessons Learned

**Status:** Draft retrospective and research archive for architectural review  
**Prepared:** 2026-10-17  
**Scope:** The original `kdaweb/certbotbot`, the October 15-17, 2026 rebuild in `wesley-dean/certbotbot`, and the product-scope reset discussed in the conversations titled *Certbotbot rebuild*, *PR 20 merged update*, and *PR 39 Approval Status*.  
**Purpose:** Preserve knowledge, evidence, successful discoveries, errors, rejected approaches, and unresolved questions for the next project. This document is **historical reference, not a specification or permission to implement everything described here**.

> **Reading rule:** Historical decisions are not automatically requirements for a new implementation. Read the Phase 1 product charter first. This archive explains how we learned what we know; it does not expand Phase 1.

## 1. Epistemic status and sources

This is a reconstruction from the current and original public repositories, their GitHub pull-request/issue records, governing ADRs, and the three project conversations. The GitHub repository state was inspected on October 17, 2026. User statements and subsequent explicit corrections take precedence over older assistant-proposed designs. Some details of individual discussions are represented by retained conversation summaries rather than full transcripts. Those points are described conservatively, and inferences are distinguished from verified repository facts.

**Evidence classes:**

- **User-approved current direction:** Statements explicitly accepted in the latest project-planning conversation, especially one domain, one archive, no extras, separation of roles, and GitHub Issues as the planning deliverable.
- **Historical user requirement:** A genuine requirement at the time that may have been superseded by the MVP reset. Keep the history without silently elevating it back into v1.
- **Repository-confirmed implementation:** Files, merged PRs, tests, and ADRs present in `wesley-dean/certbotbot` or source behavior in `kdaweb/certbotbot`.
- **Tested in a bounded setting:** Synthetic state, fake CLI, locally generated X.509, or a disposable S3-compatible service. Such evidence must not be represented as live Let's Encrypt or AWS production compatibility.
- **Outstanding / proposed:** An assumption, unresolved contract, future user story, or recommendation. No code or release readiness should be inferred from it.

Authoritative source entry points:

- Original repository: <https://github.com/kdaweb/certbotbot>
- Original executable: <https://github.com/kdaweb/certbotbot/blob/main/entrypoint.sh>
- Original README: <https://github.com/kdaweb/certbotbot/blob/main/README.md>
- Rebuild repository: <https://github.com/wesley-dean/certbotbot>
- Rebuild README: <https://github.com/wesley-dean/certbotbot/blob/main/README.md>
- Rebuild decisions index: <https://github.com/wesley-dean/certbotbot/blob/main/doc/decisions.md>
- Rebuild implementation plan: <https://github.com/wesley-dean/certbotbot/blob/main/doc/development-plan.md>
- Rebuild handoff: <https://github.com/wesley-dean/certbotbot/blob/main/doc/handoff.md>
- Rebuild product specification: <https://github.com/wesley-dean/certbotbot/blob/main/doc/specification.md>
- Existing real-staging operator gate: <https://github.com/wesley-dean/certbotbot/issues/46>

Repository inventory as observed on October 17, 2026: the original Git tree contains `entrypoint.sh` and a small set of Docker, CI, testing, and policy files; the rebuild `main` tree has approximately 219 tracked files, 56 numbered ADR source documents, about 29 entries under `lib/`, and about 29 files under `tests/` (including test integration scripts). The pull-request API returned 41 merged PRs for the rebuild at that point, one open Dependabot PR, and one deliberately closed, unmerged IAM-generator PR #47. These are **snapshots, not progress percentages**.

## 2. What the original tool actually was

The original README calls certbotbot a **thin, fast wrapper around Certbot** and describes five actions:

1. Pull a gzipped tar archive from S3.
2. Unpack the archive into the Certbot working state.
3. Use Certbot to issue or renew certificates.
4. Repackage the updated certificate state.
5. Upload the archive to S3.

The original `entrypoint.sh` uses shell functions, Certbot's CLI, the AWS CLI, `tar`, and conventional filesystem operations. The Technical Architect characterized its functional body as approximately **431 lines with comments removed**. The currently published source is substantially longer because of documentation and supporting branches of behavior; its GitHub source displayed approximately 965 physical lines at inspection. These measurements answer different questions and should not be conflated.

Original features that actually appear in `entrypoint.sh` include:

- Defaults such as `WORKDIR=/etc/letsencrypt`, `FILEBASE=live`, and `.tar.gz` archives.
- Configuration through environment variables, including an S3 bucket and contact email.
- A domain-based Certbot Route53 DNS-01 request that supplies both the base name and its leading wildcard.
- A no-arguments path that calls `certbot renew` for existing lineages.
- A `--delete-domain` operation, including lineage cleanup.
- Certbot registration when local registration appears absent.
- Generation of combined PEM output (`fullchain` plus private key).
- Creation of one tarball and upload of a current object plus a date-suffixed version.
- Optional KMS key/bootstrap-related functionality and an attempt to create a missing S3 bucket.
- Container-oriented packaging and GitHub Actions/supporting material.

These behaviors are useful historical data, **not automatic MVP commitments**. In particular, multi-domain operations, wildcard SAN generation, deletion, infrastructure creation, KMS features, and automatic renewal of all lineages exceed the newly agreed Phase 1 scope.

### Original implementation pitfalls we should not reproduce

A small program can still have important defects. The original script contains two concrete examples:

- `ensure_bucket_exists` checks `aws s3 ls` and may run `aws s3 mb` when the check fails. This crosses the now-explicit boundary that **the end user provisions buckets, IAM roles/policies, Route53 zones, and other infrastructure**. It also risks treating access errors as evidence the bucket must be created.
- `restore_archive_if_present` treats a failed `aws s3 cp` generically as "File doesn't exist." Failure might instead mean authentication denial, wrong endpoint, TLS failure, network outage, or another error. Replacing known-good remote state after such a failure is dangerous. **Only a reliably classified absent object permits initial issuance.**

Other historical behaviors warrant re-evaluation, rather than blind transplantation: archive extraction without an explicit trust boundary; arbitrary no-argument renew-all behavior; broad deletion and filesystem cleanup; account-presence heuristics; date-stamped copies; and dynamically unquoted debug flags in a Certbot command. A new implementation may reuse the fundamental sequence or carefully selected code while refusing these inherited behaviors.

Both original and rebuild repositories identify their license as **CC0-1.0** in the inspected GitHub metadata, which reduces licensing friction in reusing source. Even so, retain provenance links and verify the exact source/version that gets copied.

## 3. Original rebuild vision, as it expanded

The rebuild started October 15, 2026 as a new, standalone Bash-oriented version influenced by the original. The early proof-of-concept vision was close to the original five-step cycle: S3-held Certbot state, Route53 DNS-01, normal AWS credentials, automatic initial state creation, and no mandatory encryption.

During initial discussions the scope expanded in ways that were legitimate for a future product:

- **Explicit certificate selection.** Support positional domain inputs, one quoted string, environment-supplied lines, or an input file. Never silently interpret empty input as renew-everything. Each selected group addresses a stable, named lineage.
- **Certificate identity.** Base plus `*.base` names were made mandatory for each logical group; additional SANs could be provided literally. Certbot's own renewal decision, rather than a hard-coded day count, controlled unchanged lineages.
- **Consumer-facing archives.** Consumers should extract domain archives directly into `/etc/letsencrypt` and use `fullchain.pem`, `privkey.pem`, or combined PEMs without installing Certbot, possessing ACME account secrets, or running the producer. The consumer owns deployment hooks and service reloads.
- **Split archives.** Separate an authoritative shared ACME account archive from individually addressable certificate-lineage archives so distinct lineages can coexist and be installed independently.
- **True independent-runner portability.** The shared state in S3 must be sufficient to run one hour on a Jenkins worker, later on GitHub Actions in Azure, and later on EC2, without needing any state left on the previous runner. S3 is the producer's durable source of truth, not a backup of some privileged permanent host.
- **Bundled provider modules.** Route53 and S3 only for the initial version; the project used build-time discovery/assembly of first-party provider modules as in `bootstrap`. Third-party runtime plugins and arbitrary consumer extensions were expressly excluded.
- **Optional encryption.** GPG symmetric encryption of stored archives, with explicit plaintext/encrypted modes and manual migration concerns, was considered and later implemented in preparatory modules.
- **Staging/production separation.** Explicit Let's Encrypt staging selection and nonoverlapping S3 object namespaces, with separately validated staging trust roots.
- **Build and distribution.** A Bash 4.3-or-newer baseline, direct executable artifacts (`.dev.bash`, `.bash`, `.min.bash`), checksum companions, tests across artifact flavors, dependency pins, MegaLinter/CodeQL, documentation generation, and optional Docker/Jenkins/GitHub Actions examples.
- **Locking.** Local host coordination and CI-specific concurrency where possible; distributed locking was acknowledged as absent and deliberately deferred.

These were valuable capabilities to explore, but *they ceased to be a useful Phase 1 requirement set once the objective became early delivery of one certificate in one S3 archive*.

## 4. Source and build conventions actually established

The rebuild used `wesley-dean/template-bash` as the general build/repository posture, subject to local ADRs, and adopted released coding standards v2.1.0 at the beginning of the effort. Among its practices:

- `make` is the build/test/dependency/documentation interface.
- `make deps` is a network-capable dependency convergence boundary; `make deps-check` is offline verify-only; `make build` consumes prepared dependencies without fetching them.
- Make bootstraps a pinned released `vendor/bashdeps.bash`, verifies the committed SHA-256 before execution, and keeps that bootstrap script out of the ordinary `dependencies.txt` dependency graph.
- Bundled runtime and build support included bashlog, mktext, Bash-Minifier, bash-doxygen, and adrctl, with roles distinguished by stage.
- Source comments use verbose Doxygen conventions; the development artifact preserves those comments and the other release variants strip/minify them.
- Generated reference documentation and the ADR index are ephemeral output; maintained source is the authority.
- Build integrity and third-party dependency *trust* are distinct concerns.
- The tested baseline includes Bash 4.3 and relevant generated release flavors.

**Positive lesson:** these standards improved inspectability, reproducibility, evidence, and consistency. **Negative lesson:** conventions should not determine product size or create an independent backlog. The value of every runtime module and tool should still be judged by whether it is necessary to the selected user story.

In a new repository, governance may deliberately choose a smaller subset of this tooling. That is an architectural decision for technical planning, not a license to ignore accepted ADRs in an existing repository.

## 5. Rebuild chronology: what the PRs actually achieved

The following is a thematic map of the **41 merged PRs**, derived from GitHub PR titles and repository documents. It is not a claim that the public product worked. PR numbers are non-contiguous because issue numbers share the numbering sequence.

### 5.1 Foundation, CLI, and working state (PRs #2-#10)

| PR | Confirmed focus | Useful outcome / lesson |
| --- | --- | --- |
| #2 | Architecture, coding standards v2.1.0 | Strong recorded intent; the design scope grew before a working vertical slice. |
| #3 | Release artifacts and pinned runtime libraries | Reproducible deliverables, but build infrastructure was completed before issuance. |
| #4 | Certificate input normalization and provider registry | Better input handling; provider extension became a focus ahead of the one backend pair. |
| #5 | Host-local locks and command wrappers | Command arguments could be tested without credentials; a local lock is not a cross-platform distributed lock. |
| #6 | Route53/Cerbot command seam, portability ADR | Typed Certbot invocation through validated argv; not connected to public issuance. |
| #7 | Private workspaces and combined PEM assembly | Protected key handling and expected consumer outputs. |
| #8 | Strict per-domain archive manifest validation | Lessons about tar members, traversal, types, modes, and symlinks. |
| #9 | Isolated per-domain archive restoration | Untrusted archived data should not be extracted directly into active state. |
| #10 | Separate shared-account archive staging | Recognized that ACME account state must persist independently of certificate files. |

### 5.2 Certificate and state validity (PRs #13-#26)

| PR | Confirmed focus | Useful outcome / lesson |
| --- | --- | --- |
| #13 | Pre-publication OpenSSL validation | Certbot returning zero alone does not prove certificate/key/trust correctness. |
| #14 | Separate staging environment | Prevent test certificates or staging accounts from contaminating production. |
| #15 | ACME account and renewal-server identity | Restored account and lineage must refer to the intended CA/environment. |
| #16 | Non-activating renewal-path rebase preview | Certbot renewal metadata can contain absolute paths tied to a destroyed workspace. |
| #17 | Real Certbot **read-only** relocated-state inspection | A concrete compatibility check beyond ad hoc tar inspection. |
| #18 | Real Certbot **offline no-op renewal** | Verified a bounded restored no-op path; not genuine ACME account reauthorization. |
| #19 | Three-run ACME Renewal Information continuation | Useful independent-workspace evidence under test conditions. |
| #20 | Exact leaf certificate DNS SAN set comparison | Do not infer identity coverage from chain/key validity or CN alone. |
| #21 | Duplicate ADR identifier correction | Governance artifacts can conflict just like code. |
| #22 | ADR-037 active import release gate | Explicitly documented why synthetic validation is not sufficient to activate restored state. |
| #23-#25 | Non-activating import assessment of archive pairs/batches | All selected lineages need coherent common-account and renewal state before mutation. |
| #26 | Restored renewal-option allow policy | Archived renewal configs may contain hooks, executable paths, or unsupported directives. |

### 5.3 S3, security, publication, and recovery (PRs #27-#41)

| PR | Confirmed focus | Useful outcome / lesson |
| --- | --- | --- |
| #27 | Typed S3 retrieval and private staging | Absent objects must be distinguishable from denial, interruption, or corruption. |
| #28 | Assessment of complete downloaded collection | Download success does not imply a safe Certbot state candidate. |
| #29 | GPG AES-256 symmetric archive path | Explicit encryption/plaintext modes matter; encryption is deferred from the new MVP. |
| #30 | Frozen, verified candidate archives | Publish validated bytes, not a mutable working directory whose contents may drift. |
| #31 | Verified previous S3 object checkpoints | Preserve known-good remote bytes before risky replacement. |
| #32 | Operator-authorized real staging workflow *example* | The difference between documentation and an executable workflow matters. |
| #33 | Failure-atomic inactive multi-lineage candidate assembly | Avoid partial imports when more than one archive is selected. |
| #34-#35 | Recovery plan and write-once recovery generations | Multi-object replacement creates substantial recovery complexity. |
| #36-#37 | Remote drift and ETag-bound preconditions | A freshness check by itself is vulnerable to state changes before write. |
| #38 | Conditional latest-object publication and rollback | Guarded S3 publication was tested internally while active issuance remained disconnected. |
| #39 | Exclude Certbot-generated README files in staging archive export | Real Certbot output contains files a strict hypothetical archive schema may miss. |
| #40 | Disposable S3 service, fresh-runner recovery tests | Valuable proof of transport/protocol behavior, not of genuine AWS + Let's Encrypt issuance. |
| #41 | Digest-pinned S3 interoperability CI | Repeatable local integration evidence, without needing the operator's real cloud credentials. |

### 5.4 Real-staging preparation and the remaining gap (PRs #43-#45)

| PR | Confirmed focus | Useful outcome / lesson |
| --- | --- | --- |
| #43 | Inactive six-runner, two-lineage staging test plan | Detailed plan to prove genuine shared ACME account continuity and separate lineage portability. |
| #44 | S3 retrieval to a fully verified **inactive** import candidate | Components could be composed while keeping the public issuer disabled. |
| #45 | Fix second staging lineage SAN mismatch | Automated tests can encode contradictory requirements and fail even when real services work. |

**As of the reviewed `main` branch:** `src/main.bash` supports validation/preflight and refuses ordinary issuance with status **69**. This is an intentional fail-closed behavior under the existing governance, not evidence of a released end-to-end issuer. `README.md` explicitly states certificate issuance and S3 persistence are not yet implemented through the public CLI. The release workflow is separately gated by `CERTBOTBOT_RELEASE_ENABLED=true`.

### 5.5 Closed scope-drift proposal (PR #47)

An assistant created PR #47, `feat: generate least-privilege real-staging IAM policies offline (ADR-056)`, intending to reduce operator setup for the live staging gate. The Technical Architect correctly pointed out that consumers are responsible for provisioning their S3 buckets, IAM policies/roles, Route53 zones, and storage infrastructure. An IAM policy generator was unnecessary for SeaweedFS testing and outside the product's remit. PR #47 was **closed without merge**. The generated draft ADR-056 and script on that unmerged branch **are not part of `main`** and must not be treated as Accepted governance for production work.

This is a clear process lesson: a task can seem to help unblock testing and still be a feature we should not build. The PM must surface the responsibility boundary before allowing scope to expand.

## 6. What has actually been demonstrated, and what has not

| Capability | Evidence | Proper interpretation |
| --- | --- | --- |
| Input normalization, backend selection | Bats across built artifacts | Preflight works; issuer does not. |
| Argument-safe Certbot and AWS wrappers | Fake executables and negative tests | Command construction can be verified without live cloud calls. |
| Locally generated X.509 chain/key/SAN checks | OpenSSL/Bats test fixtures | Crypto validation paths are real but use local test certificates. |
| Strict archive-path and renewal-option rejection | Bats, synthetic fixtures | Validates known archive formats and rejection contracts; real data can reveal additional members. |
| Real Certbot read-only restored lineage inspection | Pinned Certbot smoke tests | Verifies a bounded loader path without exercising ACME. |
| Real Certbot no-op renewal from restored synthetic state | Network-guarded compatibility tests | Verifies some renewal continuity without live registration or DNS-01 issuance. |
| Three independent workspaces and ARI-related metadata | Test fixtures/integration | Supports state portability assumptions for those cases, not a full live-account guarantee. |
| S3 recovery via disposable SeaweedFS | Local end-to-end service tests | Tests S3-compatible protocol flows and recovery behavior; does not test AWS IAM/Route53 or Let's Encrypt. |
| Six-runner staging evidence *workflow* | Example under `examples/github-actions/` | A prepared, inactive test design; not an executed verified staging result. |
| Genuine Let's Encrypt staging issuance + account reuse across fresh machines | **Not demonstrated in the inspected project record** | External operator-controlled test remains an open release gate under the old ADR-037. |
| Normal public CLI issuance and persistence | **Not implemented in the inspected `main`** | This is the fundamental outstanding product capability. |
| New one-archive Phase 1 lifecycle | **Planning agreement only** | Requires its own acceptance demonstration. |

This is a central finding: **many independently useful correctness tests can coexist with an absent basic user-facing capability**. Validation coverage is not a substitute for an end-to-end user outcome.

## 7. Technical discoveries worth retaining

### 7.1 Certbot owns ACME; the wrapper owns persistence

Do not reimplement ACME, DNS challenges, certificate renewal eligibility, or Certbot account management. The wrapper should supply configuration, invoke the supported Certbot CLI with quoted, validated arguments, preserve state, package it, and store it. Certbot's choice not to renew a still-valid certificate is a success, not a reason to force an unnecessary reissue.

### 7.2 An empty workspace is the ultimate portability test

If a runner needs files retained by a prior runner, the S3-backed producer state is incomplete. An ordinary process restarting on the same host is insufficient evidence. The test should destroy the first workspace and reconstruct a fully usable Certbot account and lineage from S3 on another clean workspace.

### 7.3 Certbot's state includes more than the leaf certificate

The account key/registration and renewal metadata are necessary for preserving account identity and renewal behavior. Renewal config may include absolute filesystem paths to `live/`, `archive/`, and config directories. Successful PEM extraction is not proof that Certbot will renew from a different location.

**Phase 1 simplification:** one archive may contain the full portable Certbot configuration tree and all relevant account/lineage state. This postpones the common/domain split and greatly reduces multi-object coordination; it does **not** eliminate the need to verify restoration.

### 7.4 A server may need directly usable files, but deployment is separate

The rebuild explicitly preserved combined PEM output for compatibility with consumers such as HAProxy. Consumer-side extraction and service reloads are not the producer's responsibility. For the strictly minimal MVP, identify which files the user needs inside the one tarball, and allow later independent stories to define combined PEM and selective per-lineage consumer packaging if they are not necessary to the first usable release.

### 7.5 Absence is not failure

An S3 object's confirmed nonexistence can signal first-run issuance. It is never safe to treat `AccessDenied`, a stale credential, a broken S3 endpoint, an interrupted response, or corrupted download as proof the object is absent. The original wrapper conflated these. The rebuild spent meaningful effort correcting the classification; the MVP needs a small, correct implementation of this distinction, not an elaborate general S3 state-management framework.

### 7.6 Local validation precedes remote publication

At minimum, the selected Certbot process must succeed, expected certificate/key files must be present and valid for the requested name, and a readable complete archive must be produced **before** replacing remote state. A partially written local archive, failed Certbot command, or malformed restored archive must not cause an overwrite.

### 7.7 One S3 object is materially easier than many

The old split-common/domain design implied ordering of multiple writes, read-back verification of each, recovery generations, ETag comparisons, and cross-object rollback. A single-archive MVP has one durable key to update and no multi-object consistency protocol. S3's object-level semantics do not resolve simultaneous independent writers; that remains an external operational constraint unless a future story implements coordination.

### 7.8 Concurrency must be a stated operating constraint

A per-host `flock` and a GitHub Actions concurrency group do not coordinate with Jenkins, a second self-hosted runner, or EC2. The project correctly identified the need for a future distributed lock, but that capability does not automatically belong in Phase 1. State explicitly that users must serialize writes for the same archive during MVP operation. Decide in technical planning whether a cheap local lock is essential within one host or deferred.

### 7.9 Archive inputs cross a trust boundary

Archived tar members, paths, file types, modes, and symlinks can change what extraction writes. More robust validation is necessary when consuming archives from an untrusted or compromised store. The MVP needs a bounded, documented safety contract; it must not repeat raw extraction into arbitrary host paths, but neither should it automatically copy the entire multi-lineage manifest validation apparatus.

### 7.10 Independent certificate checks protect against stale or wrong output

A successful `certbot` process does not, by itself, prove that the selected certificate covers the intended name, its key matches, or the chain is usable. The old project developed chain/key and exact-SAN validators. A one-name MVP can perform an appropriately narrow check and retain deeper verification as a known future hardening option. Be explicit about how production vs Let's Encrypt staging chains differ.

### 7.11 AWS infrastructure is external

Users provide an existing bucket, authorization, a Route53 hosted zone, and AWS credentials or an AWS-supported credential mechanism. The script must not create an S3 bucket, IAM role, policy, KMS key, or hosted zone. SeaweedFS was used only as disposable S3-compatible local test infrastructure; it requires neither AWS IAM nor Route53. Prefer established AWS credential resolution over custom key-management interfaces.

### 7.12 Encryption is optional future work

The rebuild explored strict GPG mode selection, AES-256 symmetric encryption, and format migration. Those are real future concerns, especially because archives contain private keys and ACME account material. For Phase 1, accept explicit **plaintext S3 storage with documented operator responsibility for bucket security** unless the Technical Architect revises the requirement. Do not accidentally introduce encryption, KMS, or a migration protocol into MVP.

### 7.13 Backend modularity does not imply extensibility

The rebuild used first-party build-discovered backend modules inspired by `bootstrap`. It intentionally did not permit arbitrary runtime plugins. With exactly one DNS backend and one storage backend, a direct call path is a legitimate simplification. Do not create registry infrastructure merely because it is reusable in some other project.

### 7.14 Test infrastructure is not production functionality

Pinned Certbot compatibility tests, generated fixtures, and SeaweedFS integration are useful evidence but should not be sold as a working certificate producer. The original `examples/github-actions/real-staging-evidence.yml` was moved out of active `.github/workflows/` after a question about why an example was being invoked automatically. Inactive examples must stay inert until authorized; live staging requires control of DNS and appropriate credential boundaries.

### 7.15 Configuration should support a fresh runner, not an installed host

A useful operational invocation is not allowed to assume state in `/etc/letsencrypt` of an earlier run. The user supplies configuration and normal external credentials; the archive supplies preserved Certbot state; the run uses a temporary private working directory. Inherent runtime system dependencies (Bash, Certbot, AWS CLI, tar) are acceptable for a thin wrapper; the original requirement for optional Docker should not turn into a mandatory distribution system.

## 8. Process and project-management lessons

### 8.1 The central failure was an absent controlling delivery plan

The project had detailed ADRs, tests, tooling, and reviewed PRs, but not an enforceable, short sequence ending in the first working issuer. Many commits individually improved future capabilities without producing the primary outcome. The real failure was **sequencing and requirement control**, not the mere existence of documentation or tests.

### 8.2 A PR can be correct and still be premature

Each layer (manifest validation, staged candidate, recovery snapshot, drift detection, conditional publication) can be appropriate for a feature-rich product. Implementing them before a one-certificate end-to-end success made the plan longer and added compatibility decisions that compounded the time to delivery.

### 8.3 Review approval does not substitute for product acceptance

The Technical Architect regularly reviewed and approved PRs. This was healthy oversight, yet no single PR approval answered whether the complete MVP user story was demonstrably satisfied. Reviews should approve tasks **in the context of accepted user stories**; a feature is complete only when its user-observable acceptance criteria pass.

### 8.4 Many small PRs created overhead

The Technical Architect explicitly requested fewer, larger, cohesive PRs and repeatedly asked to expedite completion. A reasonable implementation unit is a vertical slice with a reviewable result, rather than every preparatory helper. The objective is neither arbitrarily large PRs nor maximizing PR count; it is predictable delivery and clarity of review.

### 8.5 Checklists and governance can become a self-reinforcing loop

ADRs led to new validators, which led to more specialized tests, which revealed edge cases and required further ADRs. That cycle improved local correctness but was no longer governed by an achievable Phase 1 milestone. New ADRs should resolve material architectural decisions **necessary to an approved story**, not promote potential future edge cases into mandatory current features.

### 8.6 Defer optional complexity without discarding the research

Splitting account from domain archives, supported encryption, cross-runner locking, advanced recovery, test optimization, compatibility expansions, and templated workflows all can be backlog stories. They need not be deleted from knowledge history, nor copied verbatim into the v1 implementation.

### 8.7 One visible canonical plan

Without a single authoritative issue graph, an engineering conversation can continue inventing a roadmap. The agreed resolution is separate project planning, technical planning, and technical execution stages, with a GitHub Issues product backlog and later engineering tasks linked to their parent stories.

### 8.8 Clarify responsibilities before writing convenience tooling

PR #47 is the canonical example: an IAM policy generator seemed helpful for testing but crossed from product execution into infrastructure provisioning support that the customer owns. The PM must evaluate every proposed feature against user value, scope, and ownership before making engineering tasks.

### 8.9 Explicit early demonstration

The first real certificate issued to S3, then restored on a fresh runner, must be scheduled at the earliest safe point. Secondary features cannot block that demonstration without a stated, reviewed correctness dependency. Requirements and acceptance evidence determine progress; percentage-complete estimates based on PR counts are misleading.

### 8.10 Context management is a design concern

A long chat, a large repository, and an extensive ADR corpus can bias subsequent work toward perpetuating inherited architecture. However, a repository does not inherently consume model context: **the material placed into a conversation or retrieved/read by an agent does**. A new repository can help keep working documents short and authoritative; a new chat and issue-scoped instructions can also achieve much of the context isolation without copying code. The solution is to control **what becomes normative**, what remains **reference**, and what an agent is required to read.

## 9. Specific divergences between the old plan and the new MVP

| Historical rebuild contract | New Phase 1 contract | Disposition |
| --- | --- | --- |
| Automatically request base + wildcard, then extra SANs | One specified DNS identity / certificate; extra SANs later | **Requires explicit product/architecture reconciliation.** |
| One shared account archive plus independent per-domain archives | **One complete archive / one durable object** | Old ADR-019 design is historical/future, not Phase 1. |
| Multi-certificate, line-oriented groups | One certificate lineage per invocation | Later story. |
| Optional GPG modes and format migration | No encryption feature in MVP | Later story and security disclosure. |
| Deep multi-object checkpointing and recovery | One object, minimum fail-closed publication | Future hardening stories. |
| Bundled plugin registry | Fixed Route53 and S3 behavior | Prefer direct orchestration unless justified. |
| Six-runner, two-lineage live-staging release gate | Prove the **one-lineage** fresh-runner lifecycle | Do not misrepresent or silently override the old repo's Accepted ADRs. |
| Extensive `--validate` and release variants | One actually working user-facing command first | Later packaging choices may be retained if cheap. |
| Current `src/main.bash` returns 69 on issuance | A working issuer is the central deliverable | Requires controlled governance change in old repo, or new repository with deliberately adopted requirements. |
| Infrastructure-convenience scripts | Customer provisions cloud resources | Excluded. |

## 10. Governance dilemma: continuing in the old repository

The old repository's Accepted ADR-037 explicitly forbids activating restored Certbot state and calling Certbot on that active imported state until genuine staging evidence and an additional Accepted activation ADR establish import and rollback. ADR-018 requires apex and wildcard identities; ADR-019 requires split archives. These are **binding in the existing repository** until they are explicitly superseded, not optional suggestions.

Returning to one archive and one DNS identity in **that same repository** therefore requires a coherent ADR supersession/compatibility plan and a decision about the release gate. Simply bypassing the old functions or documenting the old ADRs as irrelevant would contradict governance.

A new repository, by contrast, may define its initial architecture independently while retaining the old ADRs as explicitly non-normative research references. The new repo still needs its own product safety contract. A clean history is not a waiver of essential validation, credential isolation, or evidence.

## 11. Open risks and questions for the Technical Architect

1. **Repository identity:** Continue `wesley-dean/certbotbot` after amending many ADRs, or build in a fresh repository and promote the completed tool later? Recommendation: fresh repository for the new MVP, but this is not yet an approved repository change.
2. **Meaning of one domain:** Exactly one DNS SAN (proposed, consistent with additional SANs being deferred) or the original base/wildcard pair? Do not infer both silently.
3. **Object key and tar layout:** Historic `live.tar.gz` / early proposed `latest.tar.gz` / split `common-latest.tar.gz` are different contracts. Choose one fixed key and one stable archive structure in technical planning; document compatibility and migration separately.
4. **Certbot registration:** An empty archive must still yield a functioning account. Allow Certbot's normal first-run registration as intrinsic behavior; postpone a custom account-management interface.
5. **Path portability:** What Certbot config/work paths must remain stable or be relocated between fresh workspaces? Demonstrate with real Certbot and restored state before calling Phase 1 complete.
6. **Certificate trust:** What minimum validity checks are required for a single issued DNS identity? How does the test use staging without putting staging trust into a production certificate decision?
7. **Storage failure boundary:** How is "missing" distinguished from denial and transient errors using the AWS CLI? How are partial downloads and partial local archives handled?
8. **Write serialization:** Confirm externally serialized independent writers for Phase 1, without introducing a distributed lock.
9. **Secret handling:** Decide minimum local file permissions, work directory cleanup, AWS credential inheritance, and plaintext S3 protection documentation.
10. **Release shape:** Decide what "installable" means for Phase 1 (direct Bash script, standalone assembled artifact, and optional helpers). Avoid building packaging ahead of issuance.
11. **Reference reuse:** Which original `entrypoint.sh` operations can be reused with small corrections? Which existing rebuild helpers earn their complexity for a one-archive flow? Decide after comparing a minimal baseline, not from sunk-cost pressure.
12. **Test authorization:** The official staging test needs controlled DNS names and credentials. The prior six-runner test is research; choose the minimum live evidence for one certificate across fresh workspaces without bypassing safety.
13. **Recovery:** Does the MVP publish one replacement `latest` object only? Are S3 bucket versioning and historical backups exclusively operator-managed/future stories?
14. **Consumer output:** Is raw Certbot state in the tarball sufficient initially, or is `combined.pem` part of the first user value? The previous design supports it, but the new MVP statement did not explicitly require it.
15. **Environment management:** Is a bare-host CLI sufficient? Docker/Jenkins/GitHub Actions can come later unless an installer or runner is necessary to prove the MVP.

These questions are inputs to **technical planning**, not authorization to implement solutions in project planning.

## 12. Research backlog: preserved, deliberately not MVP

The following are possible **future product stories**, not task assignments. They need individual user value, acceptance criteria, a parent phase, priority, and a Technical Architect review before engineering decomposition:

- Multiple independent domains/lineages in one invocation.
- Additional explicit DNS SANs or changes to SAN sets.
- Wildcard coverage and automatic apex/wildcard requests.
- Separate shared account and per-lineage archive storage.
- Separate user-facing ACME account creation/selection/rotation controls.
- Symmetric GPG encrypted S3 archives and explicit plaintext/encrypted migration.
- Distributed lock/lease or robust conditional concurrent-writer coordination.
- Remote write checkpoints, recovery generations, restore/rollback interfaces, and replays.
- Direct consumer-oriented packaging, selective extraction, and combined PEM generation if not MVP.
- Optional Docker packaging and runnable CI/Jenkins examples.
- Staging/production controls exposed as an operator-facing product feature.
- Support for additional bundled DNS or storage backends, if a concrete user requests them.
- S3-compatible alternate endpoints such as SeaweedFS or MinIO as a formal product contract (tests may use them earlier).
- Rich observability, scheduling, notification, and renew-on-interval policy customization.
- Bulk import, legacy archive migration, and safe transition from the original project.
- Automatic storage lifecycle/retention, bucket setup, IAM configuration, and Route53 provisioning are **excluded product responsibilities**, not merely low-priority enhancements, unless product scope is explicitly renegotiated.

## 13. Direct conclusions

- The original problem remains a **small, valuable workflow** around mature external tools.
- The prior rebuild produced real research, validators, tests, useful documentation, and explicit safety boundaries.
- The prior rebuild did **not** deliver a working public issuer in the inspected code.
- Our error was **requirements and delivery sequencing**, not exclusively Bash, excessive comments, or insufficient review effort.
- The reset to **one certificate + one self-contained S3 archive** removes much of the unnecessary coordination burden.
- Nothing in this retrospective itself creates a new requirement; only approved product stories do.
- The next implementation should demonstrate the one-archive lifecycle early and should neither import an entire old architecture nor bypass obvious input, state, and credential safety.
- The knowledge archive should remain searchable but not mandatory reading for every future engineering task.

## 14. Reference register

These links capture the most relevant concrete artifacts, without requiring every future conversation to consume their entire contents:

- Original flow and known failure classifications: <https://github.com/kdaweb/certbotbot/blob/main/entrypoint.sh>
- Rebuild public CLI issuance-disabled state: <https://github.com/wesley-dean/certbotbot/blob/main/src/main.bash>
- Rebuild statement of unimplemented issuer: <https://github.com/wesley-dean/certbotbot/blob/main/README.md>
- ADR-018 DNS identity: <https://github.com/wesley-dean/certbotbot/blob/main/doc/adr/ADR-018-certificate-identity-and-dns-issuance.md>
- ADR-019 split archives: <https://github.com/wesley-dean/certbotbot/blob/main/doc/adr/ADR-019-composable-state-archives-and-consumer-boundary.md>
- ADR-022 serialization and publication: <https://github.com/wesley-dean/certbotbot/blob/main/doc/adr/ADR-022-execution-serialization-and-publishing.md>
- ADR-025 Certbot state portability: <https://github.com/wesley-dean/certbotbot/blob/main/doc/adr/ADR-025-certbot-state-portability-and-issuance-boundary.md>
- ADR-030 staging separation: <https://github.com/wesley-dean/certbotbot/blob/main/doc/adr/ADR-030-isolated-letsencrypt-environments.md>
- ADR-037 active state import prohibition: <https://github.com/wesley-dean/certbotbot/blob/main/doc/adr/ADR-037-gated-active-certbot-import.md>
- ADR-044 staging authorization: <https://github.com/wesley-dean/certbotbot/blob/main/doc/adr/ADR-044-opt-in-real-acme-portability-evidence.md>
- ADR-050 guarded conditional publication: <https://github.com/wesley-dean/certbotbot/blob/main/doc/adr/ADR-050-conditional-latest-publication-and-recovery.md>
- ADR-053 two-lineage staging: <https://github.com/wesley-dean/certbotbot/blob/main/doc/adr/ADR-053-two-real-lineage-staging-evidence.md>
- ADR-055 second-lineage SAN fix: <https://github.com/wesley-dean/certbotbot/blob/main/doc/adr/ADR-055-real-staging-second-lineage-sans.md>
- Initial architecture PR #2: <https://github.com/wesley-dean/certbotbot/pull/2>
- DNS command adapter PR #6: <https://github.com/wesley-dean/certbotbot/pull/6>
- Active import gate PR #22: <https://github.com/wesley-dean/certbotbot/pull/22>
- Multi-object publication PR #38: <https://github.com/wesley-dean/certbotbot/pull/38>
- Disposable S3 recovery PR #40: <https://github.com/wesley-dean/certbotbot/pull/40>
- Inactive live staging PR #43: <https://github.com/wesley-dean/certbotbot/pull/43>
- Inactive multi-lineage remote import PR #44: <https://github.com/wesley-dean/certbotbot/pull/44>
- SAN correction PR #45: <https://github.com/wesley-dean/certbotbot/pull/45>
- **Deliberately closed** IAM generator PR #47: <https://github.com/wesley-dean/certbotbot/pull/47>
- Unexecuted real-staging operator gate issue #46: <https://github.com/wesley-dean/certbotbot/issues/46>
- Existing S3 CI-runtime optimization backlog issue #42: <https://github.com/wesley-dean/certbotbot/issues/42>

---

**Maintenance instruction:** When copying this file to a new repository, place it under `doc/research/` or link to it as an external archive. Do not import the former repository's complete `AGENTS.md`, ADR set, README, and implementation plan into a new MVP as mandatory context without an explicit architectural review.
