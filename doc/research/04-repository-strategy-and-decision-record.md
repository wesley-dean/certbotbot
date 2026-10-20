# certbotbot: Repository Strategy for a Clean Phase 1 Implementation

**Status:** Proposed architectural decision; **not approved** and **not applied**  
**Decision authority:** Technical Architect  
**Prepared:** 2026-10-17  
**Recommendation:** Prefer a new minimal implementation repository while retaining `wesley-dean/certbotbot` as a read-only research/history reference. Create neither until the repository and product backlog destination are approved.

## 1. Question presented

Should we continue implementing the one-domain, one-archive MVP inside the existing `wesley-dean/certbotbot` repository, or start from an intentionally small new repository to isolate delivery from the prior architecture, code volume, and accumulated governance?

The decision must account for source/history retention, long-term project identity, GitHub Issues continuity, auditability, engineering labor, and the practical context size presented to future engineering agents.

## 2. Relevant findings

The inspected rebuild repository was created October 15, 2026 and now contains a sizable documentation and test corpus: approximately 219 tracked files, 56 numbered ADRs, and 41 merged PRs. The codebase includes modules for multi-lineage archive assessment, optional GPG state, S3 conditional publication, recovery generations, and a six-runner staging evidence example. Its public `src/main.bash` still intentionally returns 69 for actual certificate issuance. This is a deliberate, governance-based block, not a product-complete executable.

Three existing Accepted decisions specifically conflict with the proposed simpler MVP:

- **ADR-018:** A lineage includes a base identity and mandatory leading wildcard, while additional SANs are individually selectable.
- **ADR-019:** Persistent state is divided into common-account and per-lineage archives; the new MVP wants one complete archive.
- **ADR-037:** Active import of restored Certbot state is forbidden until real staging continuity evidence and an additional accepted activation ADR are in place; the new MVP wants an early complete issuance/restore demonstration.

Other existing ADRs and tests are genuinely informative but should not dictate the new program's feature set merely because they were already built.

The original `kdaweb/certbotbot` directly expresses the now-preferred five-step behavior. Its approach is a promising reference but includes unwanted infrastructure bootstrap and unsafe missing-object classification, and should not be imported wholesale.

## 3. Important clarification about model context

**GitHub repository size and conversation token use are related only indirectly.** A large remote repository is not automatically loaded into the model's context merely because it exists or because the user mentions it. Context is used when its files are attached, read, searched, summarized, pasted, or otherwise injected into a chat. A new chat with a narrowly specified issue and scoped repository reads can already avoid a large proportion of prior-context noise.

**Reasoning contamination is nevertheless a practical workflow risk:** When the default startup instructions require reading a huge old ADR corpus and a development plan, a future assistant may treat past designs as the obvious destination, overfit to existing abstractions, or preserve costly assumptions despite changed requirements.

Starting a fresh repository can help by making the **normative working set small**, but a fresh repository is neither necessary nor sufficient on its own. We also need:

- Concise authoritative `README.md`, `AGENTS.md`, approved Phase 1 product charter, and relevant current ADRs.
- Short issue-scoped task prompts.
- Explicit marking of old code, old ADRs, and the retrospective as **non-normative references**.
- A rule requiring justification before importing any old module, safety framework, or optional feature.
- A clear backlog that tells every contributor which story is in Phase 1.

## 4. Options considered

### Option A — Continue in `wesley-dean/certbotbot`

**Benefits:** Preserves URL, PR history, issue numbers, project setup, tooling, and all discoveries in one repository. Existing test artifacts and recent branch-protection configuration are immediately present. No repo renaming or cross-repo links required.

**Costs:** Must explicitly supersede or amend accepted ADRs conflicting with the MVP; old `README`, `AGENTS`, issue history, build machinery, and many modules are more complex than the Phase 1 requirement. Engineers are likely to encounter partially integrated unused code. Continuing on `main` with a new simple issuer could leave two contradictory source-of-truth concepts in the same project. Pruning code and reconciling governance is a substantial task before or during MVP execution.

**Feasible if:** We are willing to write a formal governing MVP reset, move old architecture to research/archived directories or leave unused, sharply restrict future agent reading, and explicitly reconcile ADR-018/019/037 before any new behavior is implemented.

### Option B — New implementation repository, old repo retained as research (recommended)

**Benefits:** Starts with an authoritative one-page Phase 1 README, minimal governance, one ordered product backlog, and only the tests/source needed for a working Bash issuer. The old investigation remains accessible through links. No requirement to run old optional functions or preserve old API shapes. Easier to define a clean one-archive format, early acceptance demonstration, and a short default context set. The new repository can use the original `entrypoint.sh` as a selective source instead of automatically inheriting both predecessors.

**Costs:** An additional repository, issue/backlog migration decision, new CI/review/configuration setup, need to preserve provenance and link the old work, and eventual product naming/release/discoverability decisions. Some tested code may be re-created unless technical planning evaluates reuse pragmatically. There is a risk of turning “fresh start” into **another exploratory rebuild**; the Phase 1 story and acceptance gates must prevent that.

**Feasible if:** We commit to the strict MVP and avoid “rebuild the previous architecture in a cleaner language/style.” The new repo should be deliberately small, not another template exercise that grows before the first certificate.

### Option C — New branch inside existing repository

**Benefits:** One GitHub project identity and Issue/PR history, while a new default branch can carry minimal source. Avoids a second repository name and some setup.

**Costs:** Branches share the repository's issues, protection/rules, discoverability, and history; rules may need changing. The old code and accepted ADRs remain one checkout or branch switch away and create ambiguity about which branch is authoritative. A major default-branch rewrite may complicate signed commits, audit history, and contributor expectations. This is an acceptable compromise only if repository identity continuity dominates implementation isolation.

## 5. Recommendation and rationale

**Recommend Option B**: keep the existing `wesley-dean/certbotbot` intact as the evidence-rich R&D repository, start a new minimal repository for the product, and make the new repository's GitHub Issues the authoritative backlog for the three-stage process.

This gives us the cleanest match to the Technical Architect's reset without erasing the positive research. The real motivation is **a new normative architecture and controllable delivery scope**, not the raw number of tokens consumed by GitHub.

However, **do not create the new repository yet**. First approve:

1. Whether the new working repository is desired.
2. Its provisional name and where final `certbotbot` branding will live.
3. Whether the old repository should remain actively accessible as research, be archived later, or remain maintained for history (the recommendation is to retain it, then consider archiving after migration).
4. The Phase 1 product charter and one-DNS-name interpretation.
5. The location where the complete planning backlog and linked task issues will be created.

### Naming and promotion

Because `wesley-dean/certbotbot` already exists, the new repository needs a temporary unambiguous name. A working suggestion is `wesley-dean/certbotbot-mvp` (or another Technical Architect-approved name). Do **not** automatically rename or delete the existing repository. When the MVP proves successful and its release/identity strategy is reviewed, decide whether to:

- Keep the new repository's name;
- Rename the old repository to a historical/archive name and promote the new one to `certbotbot`; or
- Retain both repositories with clear roles and links.

Moving or renaming later can affect README links, Actions badges, issue references, GitHub redirects, tags, release automation, and external users. Plan that explicitly; it is not a prerequisite for early functional testing.

## 6. Proposed minimal new-repository structure (concept only)

```text
README.md                        # What the Phase 1 product does and how to run it
AGENTS.md                        # Brief rules: read current stories; do not import old scope
LICENSE                          # CC0-1.0, after Technical Architect review
<small source entrypoint>        # Decided in technical planning, not now
<minimal tests>                  # Prove public lifecycle and required failures
doc/product-charter.md           # Authoritative approved Phase 1 requirements
doc/decisions.md                 # Small map of adopted decisions
...                              # Add only what approved stories require
```

The **research archive** may remain in the old repository, be linked externally, or live in a clearly labeled optional `doc/research/` location. Avoid putting dozens of historical ADRs in the new repository's default `doc/adr/` and then instructing future agents to read all of them.

The initial governance should say in plain language:

> The earlier `wesley-dean/certbotbot` implementation and `kdaweb/certbotbot` are research references, not source-of-truth requirements for this repository. The current approved GitHub Phase 1 issue and its linked user stories define the product. Do not port historical features or architecture without a linked approved story/task.

## 7. Minimal governance decisions a new repository does need

A clean repo still requires explicit choices where they affect correctness:

- Single requested DNS identity and exactly one lineage in Phase 1.
- One complete S3 archive, including account/renewal continuity state.
- Normal first-run Certbot registration rather than custom account administration.
- Existing AWS/Route53 infrastructure and ordinary credentials; no provisioning.
- Fail-closed read classification and no remote overwrite after a failed local result.
- Private workspace, bounded extraction, no logging of private material.
- Externally serialized independent writers; no v1 distributed coordination guarantee.
- Operator-authorized live evidence for fresh-runner reuse, not claims based solely on synthetic tests.
- Explicit decision on object key, packaging/release baseline, and any mandatory consumer output.

These can be recorded concisely in a small governing ADR or product/technical decision document, subject to the new repository's own standards. No need to reproduce 56 ADRs before shipping.

## 8. How to use the accumulated research without importing its design

For each technical task, adopt a **targeted reuse procedure**:

1. Read the current user story acceptance criteria.
2. Identify the single part of the old implementation relevant to that task.
3. Check the associated existing tests and recorded failure conditions.
4. Evaluate whether direct reuse reduces complexity, including any dependencies it brings with it.
5. Copy/rewrite only what is necessary, preserving relevant provenance and attribution.
6. Assert that no deferred feature entered the MVP through reuse.
7. Add the smallest behavior test that proves the accepted outcome.

Examples:

- For S3 reads, consult the previous error classification work, not the entire S3 recovery-generation architecture.
- For renewal portability, consult the real Certbot no-op and path experiments, not a multi-lineage import framework by default.
- For certificate validity, consult the chain and SAN tests, but scope validation to one requested identity.
- For real staging, consult the opt-in workflow lessons without copying the six-runner, two-lineage acceptance plan wholesale.

## 9. Non-goals of repository migration

A new repository is **not** permission to lower product correctness, discard known dangerous failure conditions, overwrite existing production S3 objects without an explicit migration, ignore access controls, evade review/signed-commit policies, or claim issuance works before demonstration. It is also not a commitment to Python: the agreed implementation language for this phase remains Bash unless the Technical Architect separately changes it.

No repo creation, renaming, issue transfer, artifact migration, release publishing, branch protection changes, or code commits are authorized by this draft.

## 10. Decision to record when approved

**Decision:** [To be approved] Establish a new Phase 1 Bash implementation repository as the product backlog and implementation authority; retain `wesley-dean/certbotbot` and `kdaweb/certbotbot` as non-normative historical references. Do not import the prior accepted ADR set into the new repository. Reuse only targeted code or evidence tied to an approved task.

**Reasons:** Product scope was materially reset; old governance and much of the code are structured for a larger multi-lineage, multi-object system; the purpose of the reset is to achieve one complete working certificate lifecycle early with a controlled issue plan.

**Tradeoffs:** Additional repo administration, issue numbering changes, explicit code provenance, and later product name decision in exchange for clearer scope and a smaller authoritative working set.

**Status:** PROPOSED. The current planning conversation remains read-only regarding GitHub until the Technical Architect authorizes the decision and asks for the approved backlog to be created.
