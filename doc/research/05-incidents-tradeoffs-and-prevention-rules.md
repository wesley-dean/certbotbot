# certbotbot: Specific Incidents, Tradeoffs, and Prevention Rules

**Status:** Draft retrospective appendix — historical reference only  
**Purpose:** Make the negative lessons as reusable as the positive discoveries. This is not a blame assignment, a bug tracker for the new implementation, or an automatic list of Phase 1 features.

## 1. Recurring failure pattern

The common pattern across the original rebuild was **local optimization without end-to-end delivery control**:

1. A technically credible concern appeared.
2. A narrowly scoped PR was proposed to reduce that concern.
3. The PR was documented, validated, reviewed, and approved.
4. Its implementation introduced more internal contracts requiring additional verification.
5. The user-facing command still did not perform the central operation.
6. More PRs were needed to justify activating the new layers.

No individual step was necessarily irrational. The missing control was a visible product story with a short critical path to the first real issuance.

The corrective rule is not "avoid tests" or "avoid ADRs." It is **require traceability to an approved user outcome and choose the lowest-complexity proof that matters now**.

## 2. Incident: From a five-step workflow to split multi-object persistence

**Original user need:** Retrieve certificate state, issue/renew one certificate, upload updated state. Durable S3 archives allow independent ephemeral runners.

**Expanded design:** Separately archived common ACME account state and individually selectable certificate lineages, with each certificate directly installable by consumers. This was a legitimate eventual requirement for multiple independently managed certificates.

**Consequences:** Multi-object publication order, partial updates, recovery manifests, ETag drift detection, write-once generations, verified checkpoints, batch import candidate assessment, and shared-account identity checks. Implemented by a broad sequence of PRs, notably #10, #23-#25, #30-#38, and #44.

**What was learned:** Multi-object recovery is not cosmetic complexity. When common state and multiple independent domain archives are separately persisted, the writer must account for partial publication and readers observing different generations. The implementation rightly explored these problems.

**What should change:** The single-certificate MVP does not require separate common/account and lineage objects. Persist one self-contained archive and defer the migration to split state until a user story justifies it.

**Prevention:** Before implementing a persistence mechanism, ask: *How many independently observable remote objects does the approved story require?* If the answer is one, do not design a distributed multi-object commit protocol.

## 3. Incident: Tests and gates became a substitute for an operational issuer

**Historical behavior:** The rebuild steadily added synthetic archive fixtures, real Certbot read-only inspection, no-op renewal, ARI tests, OpenSSL validation, inactive import candidates, and an operator-controlled six-runner staging example. Yet `src/main.bash` still returned exit code 69 for normal issuance.

**What was learned:** These tests found real limitations, particularly renewal metadata path portability, cryptographic identity, Certbot-generated README files, and independent runner state assumptions. A true ACME account cannot be fully modeled by a synthetic one.

**Failure in process:** We treated successful supporting checks as project progress without demanding an early public-command acceptance test. The release gate therefore became an expanding checklist without a finished critical path.

**Prevention:** Every phase must have an **earliest working vertical slice** scheduled explicitly, with one end-to-end acceptance demonstration. A helper that passes its unit tests is not the product milestone. The number of synthetic checks is not a release-readiness score.

## 4. Incident: The active import gate became an architectural dependency

**Observed governance:** ADR-037 prohibits importing staged Certbot state into an active environment, calling Certbot on it, or activating public issuance until real staging evidence plus a further Accepted activation ADR exists.

**Reason:** Account references, renewal paths, hooks, and synthetic certificates can be self-consistent yet unsafe or inoperable under real Certbot and real ACME. This is a valid technical concern.

**Tradeoff:** The gate was defined for the larger split-archive, multi-lineage architecture, and a later six-runner staging example was designed to satisfy it. That gate became difficult to complete without operator-specific cloud authorization.

**Phase 1 answer:** Keep the **need for a real portability demonstration**, but do not mechanically import the six-runner/two-lineage requirement into the new one-archive product. If continuing in the old repository, the Technical Architect must explicitly supersede the conflicting ADR requirements. If using a new repository, the architecture and appropriate one-certificate release gate must be adopted independently.

**Prevention:** Every release gate must state which approved product failure it prevents, who can satisfy it, what exact minimum evidence is sufficient, and how to avoid turning the gate into a general future-feature acceptance suite.

## 5. Incident: Real staging GitHub Actions example in an active workflow directory

**Observed sequence:** A real-staging portability workflow was initially prepared in an executable GitHub Actions workflow location, and MegaLinter/Checkov policy objected to certain dispatch behaviors (the conversation referenced Checkov `CKV_GHA_7`). The Technical Architect asked why a merely illustrative workflow was stored somewhere GitHub could actually invoke it. The workflow example was kept inactive under `examples/github-actions/` with explicit human installation/authorization and separate staging credentials.

**Root issue:** Mistaking a runnable *example* for authorized *automation*. A file path changes what code can execute; documentation and operational CI are different trust boundaries.

**Positive lesson:** Keep credentialed demonstrations inert until an authorized operator chooses the controlled environment and grants necessary identity. This holds even if the workflow's steps are themselves valid.

**Prevention:** Before adding a CI file, state explicitly: Is this active automation, opt-in example, or test fixture? Never infer approval to run a credentialed external workflow merely from approval of source code containing that workflow.

## 6. Incident: Stage-two lineage SAN mismatch (#45)

**Observed bug:** The planned six-runner staging test tried to issue and verify the second independent lineage with one bare DNS SAN. The accepted product contract at that point, ADR-018/036, required the base **and its wildcard** as distinct SANs. Even a successful live staging run would therefore fail the end-state validator.

**Correction:** PR #45 corrected both issuance and exact validation to require the apex+wildcard pair and documented the limited supersession of ADR-053 via ADR-055. Additional locally signed certificate tests enforced that intended identity.

**Positive lesson:** End-to-end test plans must be checked **against the authoritative product contract**, including their requested inputs, not just syntax or CI execution.

**Prevention:** A product acceptance example must describe a case the real product would accept. If test behavior and the acceptance story disagree, resolve the contract first; do not add a narrow exception just to make the test green.

## 7. Incident: Certbot-generated README files caused strict archive rejection (#39)

**Observed bug:** Strict archive validation rejected legitimate Certbot-generated README members exported with the staging archive. PR #39 adjusted the export behavior to omit those extras where the archive contract intentionally allowed only specific members.

**Positive lesson:** Real upstream software state can include benign members absent from synthetic fixtures. Strict validation is valuable, but the allowed set should be informed by actual supported Certbot output and should minimize unnecessarily special-cased transformations.

**Prevention:** Before hardening an archive schema, record at least one real supported Certbot state tree. Distinguish malicious/unsupported members from harmless generator metadata. In a single-archive MVP, choose the simplest compatible tar contract rather than presupposing the future multi-lineage one.

## 8. Incident: Fake S3 tests did not replace AWS or live ACME evidence

**Observed work:** A disposable S3-compatible service and fresh-runner recovery test suite exercised internal S3 operations, conditional publication, object recovery, and transport through the storage adapter. This was valuable and repeatable; it did not require cloud credentials.

**Scope limit:** SeaweedFS supplies an S3-like API, not Route53 hosted zones, GitHub AWS OIDC configuration, IAM policy enforcement, or the ACME challenge itself. It is not evidence that the tool can obtain a real certificate from Let's Encrypt or that a particular AWS principal has production permissions.

**Prevention:** Put the service name and tested boundary in the test report. Keep three claims distinct: (a) local S3 protocol exercise, (b) real Certbot compatibility with local state, and (c) genuine cloud/DNS/ACME portability. No single test implies all three.

## 9. Incident: Optional features were implemented before v1 viability

**Examples:** GPG symmetric encrypted archives, arbitrary additional SANs, split lineage archives, multi-lineage inactive import candidates, drift detection, conditional multi-object publishing, and staged recovery generations.

**Tradeoff:** These are individually useful for a fully featured certificate management system. They were expensive, introduced contracts to maintain, and made the release gate more demanding.

**Prevention:** A new Phase 1 feature must (1) directly satisfy the current approved story, (2) prevent a demonstrated unacceptable failure of that story, or (3) be explicitly approved as a critical prerequisite. Otherwise it becomes a future story with **no Phase 1 task dependencies**.

## 10. Incident: Automated IAM policy generation (#47)

**Observed decision:** An offline IAM policy generator was added in an unmerged PR to reduce the manual burden of six-runner staging authorization. The Technical Architect corrected the responsibility boundary: end users own AWS infrastructure and permissions; certbotbot consumes configured services. The proposal did not help SeaweedFS and was outside the product. PR #47 was closed unmerged.

**What was learned:** Operational convenience is not automatically product scope. A helper that feels like it accelerates a release gate can introduce a new surface area, testing obligations, IAM assumptions, and documentation that the product has no authority to manage.

**Prevention:** For any proposed infrastructure setup helper, ask: *Whose responsibility is provisioning?* If it is the operator's, documentation of prerequisites can be sufficient; provisioning scripts are out of scope absent an explicit user story.

## 11. Incident: Technical quality versus user-perceived progress

**Conversation evidence:** The Technical Architect repeatedly approved PRs, requested status, asked for fewer and larger PRs, and urged completion. The agent responded with continued preparatory development. A question about the original thin 431-line program crystallized the concern: after extensive engineering, the rebuilt public entrypoint still could not perform issuance.

**Interpretation:** This is jointly owned process learning, not criticism of any one review. The Technical Architect approved the work; the engineering agent failed to consistently distinguish local engineering correctness from overall product delivery. The product plan never made a visible, authoritative minimal acceptance path.

**Prevention:** The Project Manager must own a single Phase 1 parent issue with ordered stories and definitions of done; the Technical Architect must approve the product contract before task decomposition; the engineer must link PRs to exact tasks and show user-facing acceptance evidence.

## 12. Incident: New Python vs Bash debate

**Observation:** Python could offer structured exceptions, context-managed filesystem operations, `tarfile`, easier test fixtures, and boto3 S3 APIs. Bash offers a very small wrapper around already mature Certbot and AWS CLI tools, simple runtime distribution, and a proven original five-step model. Both languages still require correct ACME account/renewal state and failure-safe persistence.

**Current disposition:** The exploration concluded by **retaining Bash for the MVP** and revisiting planning instead of rewriting into Python. Choosing Python was a considered alternative, not the approved path for Phase 1.

**Prevention:** Do not treat a language migration as a substitute for a product contract and a delivery plan. Reconsider language only on evidence that the approved scope cannot be delivered cleanly within its chosen runtime.

## 13. A minimal decision test for every future proposal

Before creating a story, task, ADR, or PR, answer each question:

1. What **approved user story** requires this work?
2. Is this behavior needed **now**, or is it a future capability?
3. What observable acceptance case will prove the work is complete?
4. What is the least complex implementation consistent with that case?
5. What existing tool (Certbot/AWS CLI/tar/Bash) already owns this responsibility?
6. Does the proposed solution cross an operator-versus-product boundary?
7. Which real failure does the added safety work prevent?
8. Does this change alter the public contract, artifact format, or persistent state?
9. Is a new ADR or explicit supersession required by the **current** repository's governance?
10. Can this be tested without invoking real external credentials, and if not, who authorizes that test?
11. Does the implementation move the first certificate lifecycle demonstration closer?
12. If the implementation fails, can the user still recover the last known good archive?

If answers 1, 3, or 11 are missing, defer the proposed work and return to planning.

## 14. Counterfactual alternative: what a better first two days might have looked like

This is a retrospective *proposal*, not a claim about events that actually occurred:

- Agree one story: one domain, one tarball, one existing bucket, one S3 key, Certbot Route53 DNS-01.
- Begin with the original thin wrapper and remove out-of-scope bucket creation, deletion, KMS, implicit renew-all, extra domains, and auto-wildcard if not accepted.
- Repair critical handling of a confirmed missing archive vs denied/failed download.
- Construct a private Certbot workspace and package all persistent state.
- Show a first live authorized staging certificate and an S3 object at the earliest safe point.
- Destroy the workspace and prove account/lineage continuity on a fresh runner.
- Add targeted failure tests and basic documentation; release the minimal utility.
- Plan multiple domains, encryption, archive splitting, advanced recovery, and distributed locking as future user stories rather than prerequisites.

The lesson is sequencing, not hindsight certainty: testing the real path early would likely have surfaced the hard Certbot portability questions sooner, giving the team better evidence on which to decide whether each additional layer was warranted.

## 15. Positive assets to preserve

The original rebuild is not a failed investigation. It produced:

- Written architecture decisions that explain the *reasoning* behind candidate approaches and explicit alternatives.
- A reliable inventory of Certbot managed files and the risk of absolute renewal paths.
- Synthetic and real-Certbot compatibility test fixtures for restored account/lineage state.
- Practical OpenSSL certificate/key/chain/SAN verification knowledge.
- A typed understanding of S3 missing/error behavior, conditional uploads, and recovery risks.
- Awareness of locally reproducible S3-compatible tests and the limits of that evidence.
- A model for separately authorized real staging tests, rather than assuming normal CI may issue certificates against operator resources.
- Portable producer-state requirements across Jenkins, GitHub Actions, EC2, and new hosts.
- Maintained build/test conventions, signed-commit/review protections, and documentation practices.
- A clear cautionary example showing why a reviewed PR is not the same as a delivered user story.

Preserve these assets as **research inputs** and selectively reuse the subset that advances the Phase 1 story.

## 16. Explicit organizational lessons

- Engineers must feel free to challenge technical assumptions, including requirements that are technically impractical or premature.
- The PM must prevent the appearance of momentum from replacing actual accepted product results.
- The Technical Architect approves architectural deviations; product scope changes are visible and traceable.
- A backlog is a dependency graph ending in an observable result, not a list of ideas or a count of available helpers.
- Questions and design choices should be handled during technical planning, but real discoveries during implementation can trigger an explicit controlled amendment.
- User stories state **what and why**; engineering tasks state **how**; PRs record **what changed and what proves it**.
- Better documentation makes decisions easier to recover; excessive *mandatory* documentation may burden future context and encourage unnecessary preservation of old plans.
- A new GitHub repository offers useful separation of authoritative scope and history, but it cannot replace discipline about required reading or issue-focused execution.

---

**Classification:** Append this to the historical research corpus, not the short mandatory Phase 1 implementation reading list.
