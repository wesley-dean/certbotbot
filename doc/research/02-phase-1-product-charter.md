# certbotbot Phase 1: Product Charter and MVP Requirements

**Status:** Draft product requirements, to be reviewed and approved by the Technical Architect  
**Role owner:** Project Manager owns product requirements; Technical Architect owns technical architecture and its approval  
**Phase:** 1 — first usable certificate lifecycle  
**Implementation:** Deliberately not authorized by this document  
**Primary principle:** One domain, one archive, one complete working result, as early as safely possible.

## 1. Product purpose

certbotbot is a small shell-based companion to Certbot. It enables a certificate administrator to run Certbot on an ephemeral or newly provisioned machine, retain the state required for a later run in S3, and renew the same certificate without keeping a persistent Certbot installation directory on the original machine.

certbotbot coordinates existing tools. It does not implement ACME, replace Certbot, become a DNS service, become an S3 service, or provision cloud infrastructure.

**One-sentence Phase 1 objective:**

> Given one operator-selected DNS name, certbotbot retrieves an existing S3 archive if present, invokes Certbot to issue or renew the corresponding certificate, packages the necessary persistent Certbot state into **one tarball**, and uploads that archive to the configured S3 location.

This is the agreed product-level contract. It is deliberately narrower than the previously explored full-featured rebuild.

## 2. Roles and responsibility boundary

**Certificate administrator / operator:** Provides an existing bucket, appropriate S3 and Route53 permissions, a DNS name they control, normal AWS credentials/role access, Certbot account contact information and terms acceptance where required, and serialized execution of simultaneous invocations against the same archive.

**certbotbot:** Validates the specific invocation, obtains and restores the archive if one exists, invokes Certbot with suitable single-certificate DNS-01 options, confirms a usable result, produces a complete archive, and publishes it to the selected existing S3 object.

**Certbot and Route53 plugin:** Own ACME registration when necessary, DNS-01 challenge execution, issuance, renewal decisions, and the managed certificate/renewal state.

**S3 / AWS CLI:** Own object storage access, credentials, transfer behavior, and object API semantics. certbotbot does not create or manage the bucket or IAM policy.

**TLS-consuming server:** Owns extraction, installation, reloads, and deployment lifecycle. A deploy-to-server operation is not Phase 1.

## 3. Approved Phase 1 boundaries

The following reflect explicit direction in this conversation:

1. **Exactly one domain/certificate** is addressed in one operation.
2. **Exactly one persistent tar archive** holds the necessary Certbot state and is stored at one S3 object location.
3. **If an archive already exists, retrieve it and use its state** for the next operation.
4. **If no archive exists, make the first certificate possible**, using the normal behavior of Certbot rather than a separate account-management subsystem.
5. **Issue or renew through Certbot**, using Route53 DNS validation.
6. **Create a tar archive and publish it to S3** after successful work.
7. **Do not implement bells and whistles** in Phase 1, even when previously developed components are available.
8. **No infrastructure provisioning.** Users configure buckets, IAM, Route53, and storage resources.
9. **No implementation work in product-planning or technical-planning discussions.** The output of planning is a GitHub Issues backlog and a separately approved technical task plan.

**Interpretation requiring explicit architectural confirmation:** The simplest reading of “one domain, additional SANs in the backlog” is one DNS identity (one leaf certificate) with **no automatically added wildcard**. The earlier rebuild mandated an apex+wildcard pair. Do not silently let that historical rule overrule the new MVP. The Technical Architect should confirm the exact one-name contract at the technical planning gate.

## 4. Phase 1 core user story

### US-P1-001 — Persist and reuse one certificate's state

> **As a certificate administrator, I want to issue or renew a certificate for one domain using a single S3-stored state archive, so that I can operate from a temporary or new machine without relying on state left behind by an earlier run.**

**Business value:** One reliable certificate lifecycle with no operator-maintained permanent producer host and no duplicated certificate state outside the chosen durable S3 object.

**Acceptance criteria (product-observable):**

1. Given a valid controlled domain and required external configuration, a first successful invocation with a confirmed missing archive issues a usable certificate and places one complete archive into the configured S3 location.
2. The uploaded archive contains sufficient certificate, key, account, and renewal information for another new workspace to continue management of that exact certificate.
3. A second invocation from a clean workspace downloads the archive, restores the necessary state, and invokes Certbot without losing the original account/lineage identity.
4. When Certbot determines the certificate is not due for renewal, the invocation succeeds without forcing an unnecessary issuance.
5. When an authorized renewal is necessary, the tool can obtain the renewed certificate and preserve the updated state in the same S3 archive location.
6. A failed Certbot operation, invalid archive, failed S3 read for reasons other than absence, or failed local packaging does not replace the existing remote archive with unvalidated local data.
7. The operator is not required to ask certbotbot to create a bucket, create an IAM role, create a Route53 zone, or perform a consumer-side service reload.
8. The observed functionality exists through the **publicly invocable command**, not only through a test helper or disabled internal module.

Acceptance criteria 1-4 should be demonstrated as soon as possible in execution. Criteria 5-8 complete the story's minimum failure and renewal contract; the technical plan determines safe execution sequencing.

**Non-goals:** Multi-certificate batches, extra SAN inputs, custom account-management commands, encryption, distributed locking, producer-managed backups, multiple providers, deployment hooks, infrastructure management, and user-configurable ACME protocols.

**What this story does not prescribe:** Tar implementation, exact flags, shell function count, backend module decomposition, mock framework, choice of a local lock, object key spelling, release artifact construction, or use of any old module. These are tasks/decisions owned by technical planning.

## 5. Minimal acceptance walkthrough

### Scenario A: First-run issuance

**Given:** A freshly prepared operator-authorized environment; a controlled DNS name; normal Certbot/Route53/AWS CLI dependencies; an existing writable S3 bucket; a selected key that is **confirmed absent**; and no prior local certificate state.

**When:** The certificate administrator invokes certbotbot for the chosen name.

**Then:** Certbot obtains the certificate; the result is usable for that name; certbotbot uploads one archive that can restore the relevant account and certificate management state; the command exits successfully and reports the object it updated without revealing secrets.

**Failure cases:** If the bucket is inaccessible or the absence could not be established, the operation does **not** presume this is a first run. If issuance fails, no new corrupt archive is published.

### Scenario B: Fresh-workspace reuse and no-op renewal

**Given:** Scenario A succeeded, its working directory has been destroyed, and the archive remains in S3.

**When:** A second process in a newly created directory or independent runner invokes certbotbot for the same name.

**Then:** The archive is downloaded and restored; Certbot recognizes the existing account and certificate lineage; if the certificate is not due, no forced renewal occurs; and the next run remains possible from the S3-held state alone.

**Failure cases:** The second runner cannot silently create a new account when an expected archive is unreadable or its retrieval failed.

### Scenario C: Renewal / updated state

**Given:** A previously issued certificate is actually due for renewal, or a controlled staging experiment proves a permitted renewal path, with an intact archive from the prior run.

**When:** The authorized run executes from a clean workspace.

**Then:** Certbot follows its documented renewal behavior, and updated private key/certificate/account/renewal state is retained in the one archive.

**Evidence note:** A synthetic no-op test cannot substitute for proof that the real Certbot/ACME account continuity works when that is asserted. Rate-limit-aware staging tests should use operator-authorized DNS and must not be automatically dispatched by an untrusted pull request.

### Scenario D: No remote data loss on failure

**Given:** A known-good S3 object already exists.

**When:** One of the bounded failure modes happens: denied S3 read, damaged archive, failed Certbot, missing output, failed local tar creation, or interrupted preparation.

**Then:** The known-good remote archive is not knowingly overwritten by incomplete state; the command exits nonzero with a nonsecret diagnostic; the failure is not reported as a successfully issued certificate.

**Operational limitation:** Two concurrent independent writers can overwrite one another in MVP unless the operator serializes them. Do not claim a distributed lock or cross-cloud atomic transaction.

## 6. Definition of done for Phase 1

Phase 1 is complete **only when all are true**:

- The **public command** completes the one-domain one-archive cycle.
- Initial issuance succeeds against an authorized staging environment, or another agreed, genuinely representative live issuer path, using operator-controlled credentials and DNS.
- The persisted tarball is sufficient to restore Certbot's account and lineage in a **different fresh workspace**, with no access to previous disk state.
- A subsequent successful no-op check does not spuriously rotate or duplicate the certificate.
- An appropriate real renewal scenario is exercised or its exact unsupported evidence is clearly recorded as a release blocker (the Technical Architect determines which proof is required for v0.1 release).
- The S3 object is not knowingly replaced after failed reads, failed Certbot work, invalid results, or failed local archive construction.
- The certificate material is valid for the requested identity and the stored files necessary for future Certbot operation are present.
- The tool relies on **existing** operator-managed S3/IAM/Route53 resources.
- Installation, required environment configuration, failure behavior, and concurrency limitation are documented with an example that does not include real credentials.
- The selected distribution is tested, not just its internal functions.
- No out-of-scope future feature was slipped into Phase 1 without an approved scope change.

**Release gating discipline:** A task is not “almost done” merely because many helpers are implemented or PRs merged. The acceptance walkthrough must pass for the integrated executable.

## 7. Minimum correctness and safety: not optional embellishments

Simplicity is a constraint on implementation and optional capability. It does **not** mean accepting outcomes that corrupt the only durable archive or expose private material:

- Validate the one requested DNS name and the absence/uniqueness of ambiguous command input.
- Preserve literal argument boundaries when invoking Certbot/AWS CLI; no `eval` or shell-source generation from user input.
- Distinguish confirmed `NoSuchKey` (or equivalent supported absent result) from `AccessDenied`, TLS/transport failure, or service errors.
- Use a private owned workspace, conservative `umask`, no secret echoing, and cleanup on regular/signal exit as practicable.
- Never extract an arbitrary tarball into an untrusted or system-wide directory without a reviewed minimal scope/path policy.
- Retain the remote object's last known good state until a complete locally verified candidate exists.
- Prefer Certbot's normal renewal logic over wrapper-defined expiry thresholds or `--force-renewal`.
- Treat plaintext stored private keys as sensitive: user-controlled bucket ACLs, IAM, object encryption-at-rest policy, and retention are externally managed.
- Explicitly document that independent writers must be externally serialized. A local process lock is not a distributed lock.

Each protection should have a concrete failing example and acceptance criterion; do not create frameworks to handle hypothetical extension points.

## 8. Explicitly deferred features and seed user stories

These are **backlog seeds**, not yet approved final issue content. Story formulations intentionally describe value, not code.

| Seed | Future user story | Tentative disposition |
| --- | --- | --- |
| US-F-001 | As a certificate administrator, I want to manage multiple independent certificate names, so that I can renew different services through one tool. | Later phase |
| US-F-002 | As a certificate administrator, I want to specify additional DNS identities on a certificate, so that one certificate can serve related hostnames. | Later phase |
| US-F-003 | As a certificate administrator, I want wildcard and apex coverage, so that I can secure a domain and its subdomains with one managed certificate. | Later phase; clarify exact MVP single-name interpretation |
| US-F-004 | As a certificate administrator, I want separate common-account and per-certificate archives, so that I can distribute individual lineages independently of shared account material. | Later phase; requires migration story |
| US-F-005 | As a security-conscious operator, I want an optional encrypted archive, so that remote persisted private key material can be protected independently of bucket encryption. | Later phase |
| US-F-006 | As a certificate administrator, I want to manage ACME account identity and registration options explicitly, so that I can control account selection, email, and permitted changes. | Later phase; normal initial Certbot registration is inherent to MVP |
| US-F-007 | As an operator, I want writers on different runner platforms to coordinate safely, so that simultaneous runs cannot silently replace each other's updates. | Later phase; external serialization applies meanwhile |
| US-F-008 | As an operator, I want recoverable historical archive versions and a supported rollback procedure, so that I can recover from accidental or interrupted publications. | Later phase |
| US-F-009 | As a TLS platform administrator, I want independently installable per-certificate deployment archives, so that servers receive only the material they require. | Later phase unless essential Phase 1 consumer contract approved |
| US-F-010 | As a TLS platform administrator, I want combined PEM output, so that I can install issued certificate material in software that expects one fullchain-plus-key file. | Later phase if not required by MVP |
| US-F-011 | As a certificate administrator, I want an explicitly separated staging environment, so that I can rehearse changes without using production-issued certificates. | Later phase as a user-facing feature; controlled testing may require it earlier |
| US-F-012 | As a platform engineer, I want a supported container distribution, so that I can run the tool in a repeatable ephemeral container. | Later phase |
| US-F-013 | As a CI maintainer, I want approved Jenkins and GitHub Actions examples, so that teams can run certbotbot on their own schedules. | Later phase |
| US-F-014 | As an operator, I want supported S3-compatible endpoints, so that I can use an S3 API implementation I already administer. | Later phase; SeaweedFS may remain a test fixture first |
| US-F-015 | As an existing certbotbot user, I want a migration procedure for legacy archives, so that I can adopt the new release without losing certificate and account continuity. | Later phase |
| US-F-016 | As an operator, I want an intentional certificate deletion/revocation workflow, so that I can retire unneeded lineages without editing persistent storage by hand. | Later phase |

**Not promised future features:** Automatic AWS bucket creation, IAM provisioning, hosted-zone creation, arbitrary runtime third-party plugins, homegrown ACME challenge handling, or server deployment hooks. They are excluded from current product ownership unless deliberately revisited.

## 9. Issue boundaries and traceability

This document describes the product. When the Phase 1 product scope is approved, **Chat 1** creates an overarching Phase 1 tracking issue and approved **user story issues**. User stories use “As a ..., I want ..., so that ...”, clear acceptance criteria, exclusions, and priority.

**Chat 2** performs technical planning: ADR reconciliation, source-baseline selection, concrete tasks, risk decisions, implementation order, test evidence, and actual parent/sub-issue links to those user stories. The technical plan is not allowed to add Phase 1 product scope unilaterally.

**Chat 3** implements the accepted technical tasks and closes stories only after accepted evidence. PRs link to tasks; tasks link to stories; stories link to the Phase 1 tracking issue.

The existence of this draft does **not** imply these issues have been created. Issue numbers are unknown until GitHub assigns them.

## 10. Product questions intentionally left for architectural review

**Confirm before implementation:**

- Does “one domain” mean exactly one DNS SAN, without automatic wildcard? Proposed: **yes**.
- Is the Phase 1 archive a whole Certbot configuration tree rooted at a stable relative path? Proposed: one self-contained tarball sufficient for both issuance and renewed use.
- Is the archive key fixed, configurable within a narrow grammar, or derived from the single DNS name? No assumption yet; choose one clear contract.
- Is combined PEM output required to claim the MVP usable, or is normal Certbot `live/` state sufficient? No assumption yet.
- Must Phase 1 ship only as a Bash executable, or do existing release flavors remain required? Favor minimum distribution compatible with the product.
- Which real staging lifecycle test is necessary before the first production release? Choose one domain / one archive, not the old two-lineage six-runner gate by default.
- When there is no renewed certificate, should the tool always republish the tarball or avoid writing unchanged state? Accept either behavior if documented and no continuity is lost; choose in technical planning.

None of these questions justifies building a subsystem before making the decision.

---

**Interpretation rule for future agents:** Approved user stories and their acceptance criteria define the product. This draft's proposed technical assumptions do not bind implementation until the Technical Architect approves them. Historical research, test fixtures, and previous ADRs may inform decisions but must not silently enlarge the Phase 1 scope.
