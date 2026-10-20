# certbotbot: Exploratory Project Record and Planning Drafts

> **Repository update (October 19, 2026):** The exploratory rebuild is now [wesley-dean/certbotbot-research](https://github.com/wesley-dean/certbotbot-research), and this new [wesley-dean/certbotbot](https://github.com/wesley-dean/certbotbot) repository is the Phase 1 planning and implementation destination. The documents below were authored before that rename; references to the former repository name or undecided repository choice are historical, **not current decisions**. The product charter, delivery process, and repository strategy remain drafts pending Technical Architect review. This research folder is a reference archive, not governing requirements unless explicitly adopted through approved project governance.


**Prepared:** October 17, 2026  
**Status:** Draft for Technical Architect review. No GitHub repository, issue, PR, resource, or implementation code has been created or modified as part of this documentation exercise.

## Purpose

This package preserves what we learned while rebuilding `certbotbot`, including successful technical findings, mistakes, process failures, historical decisions, and the newly agreed Phase 1 direction. It is designed for a **three-conversation delivery model**: project planning, technical planning, and technical execution.

## Documents

1. **[Project history and lessons](01-project-history-and-lessons.md)** — Exhaustive research archive: the original thin wrapper; requirements evolution; all 41 merged rebuild PRs by category; accepted ADR conflicts; demonstrated versus unproven results; failure incidents; positive and negative engineering lessons; and reference links. **Historical, non-normative.**
2. **[Phase 1 product charter](02-phase-1-product-charter.md)** — Draft current requirements, one-domain/one-archive MVP user story, acceptance scenarios, necessary failure boundaries, explicit exclusions, future-story candidates, and decisions awaiting the Technical Architect. **Intended to become normative only after approval.**
3. **[Three-stage delivery and GitHub backlog](03-three-stage-delivery-and-github-backlog.md)** — Roles, approval gates, issue hierarchy, story/task templates, execution sequencing, definitions of ready/done, and launch prompts for the next two conversations. **Draft governance.**
4. **[Repository strategy and proposed decision](04-repository-strategy-and-decision-record.md)** — Reasoned comparison of preserving the current repo versus creating a minimal new repo; recommended preservation of R&D history without automatic architectural inheritance; no actions authorized. **Proposed, not yet approved.**
5. **[Incidents, tradeoffs, and prevention rules](05-incidents-tradeoffs-and-prevention-rules.md)** — Concrete postmortems of the key failures, source-level and governance lessons, release-gate drift, and a checklist for rejecting unnecessary work. **Historical, non-normative.**

## Confirmed product direction

The first deliverable is an intentionally small Bash tool: accept **one domain**, retrieve **one S3 tar archive if it exists**, use **Certbot with Route53** to issue or renew its certificate, package the resulting durable Certbot state in **one archive**, and upload that archive to the operator's **existing S3 bucket**.

**Not Phase 1:** multiple lineages, extra SANs, encryption, a separate account-management interface, split common/domain archives, third-party plugin systems, infrastructure provisioning, Docker/CI conveniences, and advanced recovery/distributed locking. Certbot's inherent first-run ACME account registration remains necessary; it is distinct from a user-facing account-management feature.

## Explicit non-goal of this package

These drafts **do not authorize implementation** and **are not yet a GitHub Issues backlog**. The agreed end product of the *current planning conversation* is an approved set of product stories and a Phase 1 tracking issue created in the selected repository. The *technical-planning conversation* will then create linked engineering tasks. The *execution conversation* will implement only the approved tasks.

No issue numbers are assumed or fabricated in these documents.

## Repository recommendation

**Prefer starting a new small implementation repository**, while retaining `wesley-dean/certbotbot` as the archived R&D and evidence reference. The older repository contains important lessons but also 56 numbered ADRs and a multi-archive architecture that conflicts with the agreed MVP. Starting fresh is helpful **because it changes the normative working set**, not because GitHub files automatically consume model context. The repository destination, name, and later product-identity strategy still require the Technical Architect's approval.

## How future agents should use this package

For a Phase 1 implementation task, start with the *approved* product charter and the relevant GitHub Issues. Read the current repository's governing documents. Consult the historical research **only for the specific technical question at hand**. Do not treat old PRs or ADRs as requirements automatically. Do not expand scope because an old module or a convenient supporting feature exists.

## Current planning decisions still open

- New repository versus in-place governance reset.
- Precise single-name SAN semantics (recommended MVP reading: one literal DNS identity, without an automatic wildcard).
- Exact single S3 key, tar layout, and minimal shipped artifact.
- Whether combined PEM is needed in Phase 1.
- The minimum authorized live ACME staging evidence required to release safely.

These are visible questions, not invitations to create new implementation features during product planning.
