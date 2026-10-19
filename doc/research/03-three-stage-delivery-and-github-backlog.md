# certbotbot: Three-Stage Delivery Process and GitHub Issues Contract

**Status:** Draft process agreement  
**Objective:** Prevent a repeat of the original rebuild's uncontrolled growth of technical work ahead of a working product  
**Repository:** To be chosen before issues are created  
**Roles:** User is Technical Architect; assistant is Project Manager in Stage 1, planning collaborator in Stage 2, and implementing engineer in Stage 3.

## 1. Central principle

> The backlog, rather than the conversation transcript or a catalog of implementation ideas, must communicate what certbotbot will deliver, why it matters, how completion is proven, how work is ordered, and who may approve a change of scope.

Three separate conversations and two review gates divide **what**, **how**, and **execution**. The resulting GitHub Issues and repository documentation are the durable handoff; no future assistant should need the history of the original chats to understand the currently approved work.

## 2. Stage 1 — Product / Project Planning (this conversation)

**Lead:** Project Manager.  
**Decision authority:** Technical Architect approves product intent, scope, priority, and non-goals.  
**Question:** *What does the user need, why is it valuable, and how will we know it works?*

### Responsibilities

1. Record the small Phase 1 product charter and the exact definition of done.
2. Identify user-visible stories in “As a [role], I want [capability], so that [value]” syntax.
3. Express story acceptance criteria in observable terms, without dictating specific shell functions, testing frameworks, module boundaries, or optional implementation tooling.
4. Distinguish current product promises from historical implementation choices and tentative feature seeds.
5. Establish explicit Phase 1 exclusions and label later features as backlog candidates.
6. Order stories by product value and dependency at a high level; flag conceptual risk or unresolved product behavior.
7. Choose the future repository **before** filing stories, so the authoritative backlog is in the correct place.
8. Create approved Phase 1 tracking and user story GitHub Issues **only after the Technical Architect approves the complete product backlog**. Future phase stories may be filed when their value and scope are sufficiently clear, even if technical tasks are deferred.
9. Place this research archive in an opt-in reference location, not a mandatory implementation context.
10. Provide the issue number for the Phase 1 parent and a directly reusable Stage 2 prompt.

### Prohibited Stage 1 activities

- No application code.
- No implementation PRs or release tags.
- No engineering task creation masquerading as product stories.
- No AWS, IAM, S3 bucket, or Route53 resource provisioning.
- No automatically launched Certbot, DNS challenges, or credentialed staging workflows.
- No changing the product scope to accommodate interesting existing modules.
- No preemptive reproduction of the historical ADR architecture.

### Exit / approval gate 1

Stage 1 is complete when:

- The repository destination has been agreed.
- Every Phase 1 story has a user role, need, value, acceptance criteria, explicit exclusions, and priority.
- A Phase 1 tracking issue summarizes the full MVP and links all approved stories.
- Deferred feature stories are represented in an ordered product backlog without being treated as Phase 1 work.
- The Technical Architect explicitly approves the requirements set.
- All issue references and the Stage 2 prompt are correct; there is no dependency on this chat's context to understand the product.

**Output:** The product backlog, not a line of implementation code.

## 3. Stage 2 — Technical Planning (new conversation)

**Lead:** Technical Architect, supported by engineering analysis and task planning.  
**Question:** *How can we implement only the approved stories, using the least necessary complexity and preserving minimum safe behavior?*

### Inputs

- The repository's Phase 1 parent GitHub Issue number.
- Linked approved user stories and acceptance criteria.
- The concise product charter and newly adopted repository governance.
- The original and rebuild repositories as **reference only**, to consult selectively.
- This historical archive **only when a specific technical risk or prior decision warrants consulting it**.

### Responsibilities

1. Read the destination repository's README, AGENTS, current governing ADRs, and technical entry points.
2. Verify what is approved, proposed, historical, and excluded; do not assume all previous ADRs were adopted.
3. Choose a baseline: minimal original `entrypoint.sh` derivative, selective reuse from the rebuild, or a small fresh Bash implementation. Make that choice on technical evidence, not sunk cost.
4. Trace the one-domain one-archive lifecycle from input through S3 read, Certbot, archive construction, and S3 write.
5. Identify essential prerequisites and known failure boundaries, without turning every defensive possibility into a separate phase.
6. Reconcile conflicts with existing ADRs if continuing in the old repository. A new repository adopts only explicitly reviewed decisions; maintain a concise first ADR or equivalent governing design when a meaningful choice requires recording.
7. Compare a few viable designs; document the chosen approach, rejected alternatives, and test evidence necessary to make it safe.
8. Create **task issues** that describe technical work and link each task to its parent user story. Use GitHub parent/sub-issue relationships where supported and explicit links otherwise.
9. Order tasks so the first real issuance and publication demonstration happens at the earliest sound point.
10. Specify the minimal automated unit/integration tests and authorized real staging evidence needed for the MVP.
11. Produce concrete implementation sequencing, acceptance verification, and a clean handoff for Stage 3.
12. Estimate reviewable PR units by end-to-end results, not by individual helper count. Fewer coherent PRs are preferred when reviewability and safety remain sound.

### Technical planning principles

- Prefer the established Certbot CLI, AWS CLI, standard shell and tar facilities. No custom ACME client, S3 implementation, IAM generation, or arbitrary plugin loader.
- Choose one S3 object and one complete archive. Do not impose multi-object recovery requirements on a one-object feature.
- Every additional abstraction must be defended by an approved requirement or a demonstrable safety/operability need.
- A requirement such as “state survives a new runner” must be tested as behavior, not solely by inspecting filenames.
- Avoid solving for multiple certificates or future SANs through unnecessary generalized data structures in Phase 1.
- Separate test infrastructure from user-facing product functionality. SeaweedFS need not dictate the production IAM or DNS design.
- Treat account registration that Certbot performs on initial issuance as intrinsic first-run behavior, distinct from the deferred user-facing account-management feature.
- Make the minimum deployment assumptions explicit: Bash, installed Certbot + Route53 plugin, AWS CLI, existing bucket/zone, operator credentials, and externally coordinated writers unless expressly changed.
- Escalate actual architecture conflicts to the Technical Architect before coding; do not silently amend scope.

### Prohibited Stage 2 activities

- No application code or implementation PRs in this planning conversation.
- No credentials or cloud resource mutations.
- No automatic creation of future-feature task backlogs when Phase 1 tasks are still incomplete.
- No silent supersession of existing accepted decisions.
- No expansion of Phase 1 stories without returning a change proposal to the product planning/Technical Architect approval boundary.

### Exit / approval gate 2

Stage 2 is complete when:

- Every Phase 1 story is linked to one or more executable tasks and a demonstration/verification task where necessary.
- Dependencies produce a readable topological execution order.
- Technical assumptions, interface decisions, material risks, ADR changes, and operator prerequisites are recorded and explicitly approved.
- The first working end-to-end issuance task is obvious in the sequence.
- The final task proves a new-runner archive restore and future renewal, not merely successful helper tests.
- Every task has objective completion evidence, a narrow scope, and a link to its parent story.
- The Technical Architect approves the technical plan.
- A Stage 3 handoff prompt can be issued using only the repository and the Phase 1 parent issue number.

**Output:** A technically complete GitHub Issues task graph, not source changes.

## 4. Stage 3 — Technical Execution (new conversation)

**Lead:** Implementing engineer/agent.  
**Decision authority:** Technical Architect reviews and approves architecture changes and PRs.  
**Question:** *Implement the approved tasks in order, and prove the user story works.*

### Responsibilities

1. Read the Phase 1 parent and linked stories/tasks before choosing implementation scope.
2. Review the destination repository's governing documentation, ADRs, and current code before edits.
3. Implement only the next unblocked task(s), preserving the selected command/configuration contract.
4. Integrate the public command early rather than accumulating non-activating helper libraries.
5. Write tests that prove accepted behavior and the important negative cases.
6. Make reviewable, cohesive PRs whose bodies link the task issues and acceptance evidence.
7. Request `wesley-dean` review; enable auto-merge only where requested and permissible; report true CI status, not implied success.
8. Respect signed-commit / protected-main repository policy without assuming that an agent branch can bypass protection.
9. Move a task to complete only after its acceptance evidence and PR state are verified.
10. Update issue status and the parent tracking issue so any new chat can resume unambiguously.
11. When blocked by a new architectural decision, propose a bounded choice; do not spend multiple PRs inventing a workaround.
12. Conclude Phase 1 with the exact product acceptance demonstration and clean user documentation.

### Execution stop conditions

Pause and escalate an actual conflict with an accepted ADR, a proposed cloud privilege expansion, a new product-facing capability, a destructive migration of old S3 state, unsafe archive extraction, or a claim of live issuance unsupported by evidence. A reasonable automated safety test failure is a reason to repair the task, not to relax the contract casually.

## 5. GitHub Issues hierarchy

The proposed structure is deliberately simple:

```
Phase 1 tracking issue
  |-- User story: One-domain issue or renewal and S3 persistence
       |-- Task: [technical decomposition performed in Chat 2]
       |-- Task: [technical decomposition performed in Chat 2]
       |-- Task: [fresh-runner acceptance demonstration]

Future-phase tracking issue(s)
  |-- User story: Additional SANs
  |-- User story: Multiple certificate lineages
  |-- User story: Encryption
  |-- User story: User-facing ACME account administration
  |-- ...
```

The initial parent may contain a single substantive Phase 1 story. **Do not invent additional stories simply to produce a more impressive hierarchy.** One honest story with well-bounded tasks is acceptable.

### Naming conventions (proposal)

- `[Phase 1] Single-domain S3 certificate lifecycle` — parent tracking issue.
- `[Story] Persist and reuse one certificate's state from S3` — user story issue.
- `[Task] ...` — implementation task created in technical planning.
- `[Research] ...` — reference research, where justified, separate from the execution backlog.
- `[Future] ...` — explicitly deferred user story; no speculative subtasks yet.

Names are illustrative; do not reserve or invent issue numbers.

### Labels (proposal)

Use a minimal consistent vocabulary, for example `type:story`, `type:task`, `type:phase`, `phase:1`, `phase:future`, `status:blocked`, `needs:architect`. Avoid elaborate label taxonomies unless the repository already has one in place.

### Traceability invariant

A PR links at least one technical task; each task links exactly one primary parent user story (it may mention secondary dependencies); each story links a product phase; phase acceptance depends on completed stories and real observed evidence. Product-level changes originate in stories, not in untracked technical tasks.

## 6. GitHub Issue templates (planning only)

### Product story template

**Title:** `[Story] <user-visible capability>`

**Story:** As a **[specific role]**, I want **[capability]**, so that **[user value]**.

**Context and motivation:** A short statement of the actual user problem, not its implementation.

**Scope:** Explicit user-visible behavior included.

**Out of scope:** Capabilities this story does not promise, especially future-phase features.

**Acceptance criteria:** Numbered GIVEN/WHEN/THEN behavior; failures when those are product-observable.

**Priority / phase:** Phase 1 or named future phase.

**Dependencies:** Other approved product stories, if any; not helper-function prerequisites.

**Open product decisions:** Only questions that materially change user experience.

**Task linkage:** Filled by the technical planning conversation.

**Definition of ready:** Story can be understood and evaluated without the previous chats.

### Technical task template

**Title:** `[Task] <concrete engineering outcome>`

**Parent story:** Link to specific user story issue.

**Objective / deliverable:** One testable component of the accepted outcome.

**Existing implementation:** Reference exact files or prior research worth reusing, without requiring an engineer to reconstruct all previous PRs.

**Approach:** Bounded “how,” including command/library interfaces as needed.

**Dependencies:** Previous task issue numbers or specific required external approvals.

**Acceptance tests / evidence:** Commands, tests, and observable runtime outputs needed to close this task.

**Failure/rollback:** What must remain unchanged when this task fails.

**Non-goals:** Adjacent enhancements that are explicitly excluded.

**ADR references:** Existing normative decisions, proposed supersession, or a clearly recorded new decision.

**Review notes:** Important assumptions and compatibility or security implications.

**Definition of ready:** Another engineer can begin without re-planning the project.

## 7. How to judge progress

Do **not** use the number of merged PRs, number of ADRs, source lines, or the percentage of isolated helper tests as a proxy for product completion.

Report instead:

- Which approved stories are demonstrably complete?
- What user-visible part of the one-archive lifecycle has been proven through the public command?
- What remaining task or external dependency blocks the acceptance demonstration?
- What is the next unblocked task, and why is it next?
- Has the product scope changed, and if so, where is the approval recorded?

There should be an early, visible milestone for **first successful issuance and S3 publication**. A separate milestone confirms **fresh-runner restore and no-op renewal**. The final release milestone adds negative-case evidence and operability documentation.

## 8. Change control and backlog hygiene

1. Identify the source story before agreeing to a new implementation feature.
2. If a proposed change alters the user's required behavior, propose a product story amendment for Technical Architect review; do not hide it in an engineering PR.
3. If the change is necessary for correctness (e.g., a failed S3 read must not be mistaken for absence), show the negative acceptance case and link it to the core story.
4. If the change is valuable but not required for Phase 1 (GPG, distributed locks, multiple lineages, fancy reporting), create or update a **future** user story, not a Phase 1 implementation task.
5. If an old ADR conflicts with the approved MVP, propose an explicit supersession or use the new repository's fresh governance boundary.
6. If an implementation task is blocked, mark the issue blocked and explain what approval/evidence clears the block; do not invent a new series of preparatory PRs.
7. Issue close-out requires observable acceptance evidence and PR link, not a narrative assertion that a module is finished.

## 9. Source of truth and context budget

For an active implementation task, the **mandatory reading set should fit on one concise list**:

1. Destination repository's current `README.md` and `AGENTS.md`.
2. Phase 1 parent tracking issue and specific user story acceptance criteria.
3. The current task and its direct dependencies.
4. Accepted **current-repository** ADRs relevant to that task.
5. Specific source files, tests, and external API docs actually touched by that work.

The long retrospective is **optional, indexed reference**. It should be consulted for particular problems, not loaded wholesale at the start of every task. The original and rebuild repositories can remain accessible links without being the active codebase.

A brand-new GitHub repository alone does not guarantee that an assistant will reason without old assumptions. The task prompts, required-reading list, and governance decide which assumptions enter context. Fresh tasks must say **do not automatically port the old architecture**.

## 10. Suggested Stage 2 launch prompt

> In `[APPROVED_REPOSITORY]`, begin **technical planning only** for Phase 1 as defined by issue `#[ACTUAL_PHASE_1_ISSUE_NUMBER]` and its linked user stories. You are assisting the Technical Architect. Read the project's current governing documents and accepted product scope. Compare the smallest credible Bash one-domain/one-S3-archive implementation with selective reuse of `kdaweb/certbotbot` and `wesley-dean/certbotbot`, without importing historical abstractions automatically. Propose an implementation approach, minimum safety boundaries, a real fresh-runner acceptance test, and an explicitly ordered set of GitHub engineering task issues linked to each approved story. Record material architectural decisions and unresolved choices. **Do not write application code or open implementation PRs in this chat.** When the technical task backlog is ready, present it for the Technical Architect's approval and provide a Stage 3 handoff prompt.

## 11. Suggested Stage 3 launch prompt

> In `[APPROVED_REPOSITORY]`, begin implementing Phase 1 defined by issue `#[ACTUAL_PHASE_1_ISSUE_NUMBER]` and its approved, linked technical tasks. Review repository governance, story acceptance criteria, and task dependencies. Implement tasks in the documented order and prioritize the first functional end-to-end issuing and S3-persistence path. Use only the approved Phase 1 scope: one DNS identity/certificate and one complete tarball stored in one existing S3 location. Do not introduce split archives, multi-domain logic, extra SANs, encryption, arbitrary plugins, infrastructure provisioning, or other future stories. Produce cohesive reviewable PRs, request `wesley-dean` review, and report test evidence accurately. If a material architectural conflict arises, stop that specific change and raise the decision rather than silently broadening scope.

---

**Key guardrail:** Project planning defines what; technical planning decides how; technical execution builds the approved how. **The authoritative handoff consists of GitHub Issues and current repository governance, not conversation memory.**
