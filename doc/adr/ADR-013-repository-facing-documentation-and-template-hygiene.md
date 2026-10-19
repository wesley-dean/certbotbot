# ADR-013: Repository-Facing Documentation and Template Hygiene

Date: 2026-08-30

## Status

Accepted

## Intent and Documentation Posture

This Architecture Decision Record defines repository-facing documentation and
GitHub templates as maintained starter behavior rather than incidental boilerplate.
It incorporates lessons learned while adapting template-bash into bashlog, where
the core architecture and README could be current while inherited support,
contribution, security, and issue-reporting files still described an unrelated
project.

A template amplifies both good defaults and stale assumptions.  A copied mistake
is therefore more costly in a starter repository than in a single derived
project.

## Context

template-bash intentionally supplies more than Bash source.  Derived projects
inherit README structure, contributor guidance, support and vulnerability
reporting policy, issue and pull-request templates, ADR machinery, test guidance,
and release documentation.

During bashlog development, several reusable gaps became visible:

- inherited `SUPPORT.md` content referred to an unrelated GitHub Action and issue
  tracker;
- `CONTRIBUTING.md` linked to a nonexistent `LICENSE.md` and did not explain the
  project's documentation-first workflow;
- `SECURITY.md` suggested public issue disclosure after a fixed period rather than
  continued coordinated disclosure;
- generic web-application issue templates asked users to click and scroll instead
  of requesting Bash version, artifact/version, shell state, and a minimal
  reproducer;
- testing documentation captured a fixed test-count snapshot and stale behavior
  descriptions that later became incorrect as the contract evolved;
- the ADR corpus benefited from a concise `doc/decisions.md` map between the full
  records and `AGENTS.md`; and
- consequential ADRs benefited from explicit Promises, Non-Promises, and Adversary
  and Failure Model sections in addition to Operational Constraints.

None of these defects required a runtime redesign.  They were documentation
lifecycle failures.  The template should encode the stronger lifecycle so derived
projects begin with better defaults.

## Decision Drivers

- Treat all repository-facing documentation as part of the starter's quality
  surface.
- Prevent unrelated project names, links, and assumptions from propagating into
  derived repositories.
- Make contributor and issue-reporting guidance appropriate for Bash projects.
- Keep vulnerability reporting private until disclosure is intentionally
  coordinated.
- Avoid documentation that becomes stale merely because test counts or specific
  implementation details change.
- Provide a concise architectural discovery layer without turning `AGENTS.md`
  into a second ADR corpus.
- Improve ADR templates for security, trust, compatibility, failure, and public
  API decisions while allowing irrelevant optional sections to be removed.
- Preserve the template's adaptability rather than forcing every derived project
  into one product-specific workflow.

## Decision

Repository-facing Markdown files and GitHub issue/pull-request templates SHALL be
maintained as first-class starter assets.

They SHALL be internally consistent, project-appropriate, free of unrelated
repository links, and written so a derived project can either retain them with
minimal edits or clearly identify where adaptation is required.

### Concise Decision Map

The template SHALL provide `doc/decisions.md` as a concise architectural discovery
map.

The hierarchy SHALL be:

```text
README.md              public orientation
AGENTS.md              concise contributor/automation map
doc/decisions.md       concise ADR summaries and links
doc/adr/*.md           durable architectural reasoning
project specification  normative observable behavior when a project needs one
Doxygen comments       implementation-level contracts
tests / CI             executable evidence
```

`doc/decisions.md` SHALL summarize rather than duplicate ADR reasoning.  When the
summary and an ADR appear to conflict, readers must consult the ADR and surface
the inconsistency.

### ADR Template

The starter ADR template SHALL retain the existing detailed posture and add
optional sections for:

- Promises;
- Non-Promises;
- Adversary and Failure Model; and
- Superseded Decisions.

These sections SHOULD be used for consequential security, compatibility, public
API, data-loss, destructive-behavior, trust, or complex failure-semantics
decisions.  They MAY be removed when they genuinely do not clarify a narrower
decision.

Promises should be bounded and observable where practical.  Non-promises should
prevent reasonable over-interpretation rather than excuse missing requirements.
The adversary/failure model may include malformed input, unavailable dependencies,
partial execution, stale state, operator error, hostile data, an actual attacker,
or a future maintainer misunderstanding an assumption.

### Support and Contribution Guidance

`SUPPORT.md` SHALL describe a Bash-oriented problem report rather than a GitHub
Action or web application.  It SHALL point to the current repository issue tracker
without hard-coding another project's URL.

`CONTRIBUTING.md` SHALL point contributors to the repository's actual license,
README, ADRs, documentation standard, testing guidance, and release guidance.  It
SHALL explain that generated artifacts are not maintained source and that public
behavior/architecture changes require corresponding documentation and tests.

### Vulnerability Disclosure

`SECURITY.md` SHALL instruct reporters not to publish suspected vulnerabilities in
ordinary public issues before coordinated disclosure.  A fixed response window
MAY be stated as an operational goal, but expiration of that window SHALL NOT by
itself instruct a reporter to publish sensitive technical details.

Derived projects SHOULD replace template contact information when their security
reporting process differs.

### Issue and Pull-Request Templates

Bug-report templates SHALL ask for Bash-oriented reproduction information such as
project version/commit, Bash version, operating system, minimal reproducer,
expected behavior, actual behavior, exit status, stdout/stderr distinction, and
relevant shell state when applicable.

Feature-request templates SHOULD emphasize the concrete problem/use case,
proposed behavior, alternatives, and compatibility or contract impact rather than
only asking for an idea.

Pull-request templates SHOULD remind contributors to keep ADRs, specifications,
Doxygen contracts, tests, README/decision summaries, and implementation aligned
when those surfaces are affected.

### Documentation Freshness

Documentation SHALL prefer durable invariants over snapshots that predictably
rot.  For example, testing documentation should state that every shipped artifact
receives the complete suite rather than recording a fixed number of tests unless
the exact count itself is a maintained contract.

When public behavior or architecture changes, review SHALL include repository-
facing documentation that may encode the old behavior, not only source and tests.

## Promises

1. Starter documentation will not intentionally point users to unrelated project
   support or issue trackers.
2. The template will provide a concise ADR decision map in addition to full ADRs
   and `AGENTS.md`.
3. The ADR template will make promises, boundaries, and failure models easier to
   preserve for consequential decisions.
4. Security guidance will favor coordinated disclosure over automatic public
   escalation after a timer expires.
5. Bash bug-report guidance will request information useful for reproducing Bash
   behavior.
6. Documentation will prefer durable contract descriptions over needless mutable
   snapshots such as test counts.

## Non-Promises

1. Derived projects are not promised complete documentation merely because they
   started from this template; project-specific behavior still requires
   project-specific documentation.
2. The template does not require every derived repository to retain every starter
   document or GitHub template.
3. A concise decision map does not replace ADR review for consequential work.
4. The expanded ADR template does not require every ADR to contain every optional
   section.
5. Generic security guidance does not create a service-level agreement or promise
   a particular remediation time.
6. The template cannot prevent maintainers from introducing stale links or copied
   assumptions later; review discipline remains necessary.

## Adversary and Failure Model

This decision accounts for:

- starter content copied into many repositories before anyone notices it is stale;
- a user following an inherited support link to the wrong project;
- a contributor following generic instructions that omit the repository's real
  architecture and validation workflow;
- a vulnerability reporter being encouraged to disclose publicly before a safe
  disclosure plan exists;
- issue templates collecting irrelevant UI screenshots while omitting Bash
  version, shell state, or stdout/stderr behavior;
- a fixed test-count statement becoming false as the suite grows;
- `AGENTS.md` expanding until it duplicates and drifts from ADR reasoning; and
- future maintainers inferring guarantees that an ADR never intended to make.

The decision does not attempt to make documentation self-updating.  Human and
automated review must still compare changed behavior with maintained documentation.

## Operational Constraints

- `doc/decisions.md` MUST exist as a concise ADR summary map.
- `AGENTS.md` MUST point to `doc/decisions.md` and governing ADRs rather than
  becoming the sole architectural record.
- Starter repository-facing documentation MUST NOT intentionally contain links or
  terminology belonging to an unrelated project.
- `CONTRIBUTING.md` MUST link to the actual repository license path.
- `SUPPORT.md` MUST direct ordinary reports to the current repository.
- `SECURITY.md` MUST NOT instruct automatic public disclosure merely because a
  response window elapsed.
- Bug-report templates MUST request Bash-oriented reproduction details.
- Pull-request guidance SHOULD surface documentation/ADR/spec/test alignment.
- Documentation SHOULD avoid fixed test counts unless the count itself is a
  maintained contract.
- The ADR template MUST include optional Promises, Non-Promises, Adversary and
  Failure Model, and Superseded Decisions sections.
- Derived projects SHOULD review and adapt repository-facing starter files before
  their first release.

## Considered Alternatives

### Treat GitHub Templates as Unimportant Boilerplate

This minimizes template maintenance, but it was rejected because derived projects
inherit those files verbatim and users encounter them as part of the project.
Incorrect support or security guidance can be more damaging than a cosmetic README
problem.

### Put Every ADR Summary in AGENTS.md

This would reduce the number of files contributors need to discover.  It was
rejected because `AGENTS.md` would grow into a parallel architecture manual and
increase drift risk.  `doc/decisions.md` provides a better intermediate layer.

### Keep the Smaller ADR Template

The original template was sufficient for many ordinary decisions.  It was not
selected because bashlog demonstrated concrete value from explicitly documenting
promises, non-promises, failure models, and exact supersession for security and
public-contract work.

### Record Exact Test Counts

Exact counts can communicate test-suite size at a point in time.  They were
rejected as routine documentation because they become stale without adding a
useful compatibility promise.  CI already reports exact current counts when that
information matters operationally.

## Consequences

The starter carries somewhat richer documentation and repository templates.  A
new project receives better contributor, support, security, and architecture
navigation defaults, but project maintainers must still adapt product-specific
language before release.

The decision adds a small maintenance obligation: repository-facing documents
must be included in release-readiness reviews when architecture or public
behavior evolves.  That cost is accepted because a starter repository is intended
to encode reusable engineering discipline, not only reusable shell code.

## Source Lineage

This decision backports lessons learned while deriving and polishing
`wesley-dean/bashlog` from template-bash.  In particular, bashlog established:

- a concise `doc/decisions.md` layer;
- a richer ADR template with promises, non-promises, and failure models;
- Bash-specific support and issue-reporting guidance;
- coordinated vulnerability-disclosure wording; and
- documentation freshness rules that avoid mutable test-count snapshots.

## Open Questions and Follow-Ups

- Future template-derived projects may identify additional repository-facing files
  that deserve starter-level hygiene rules.
- A future validation tool could check internal Markdown links or known template
  placeholders, but automated link validation is not required by this ADR.

## Related Decisions

- ADR-001: Documentation and Decision Hierarchy
- ADR-007: Doxygen-Based Verbose Source Documentation Standard
- ADR-008: Documentation-Driven, Test-Second Development
- ADR-009: Observable Behavior Testing Across Shipped Artifacts
