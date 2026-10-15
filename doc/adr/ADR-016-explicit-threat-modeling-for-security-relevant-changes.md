# ADR-016: Explicit Threat Modeling for Security-Relevant Changes

Date: 2026-08-30

## Status

Accepted

## Intent and Documentation Posture

This ADR establishes threat modeling as an explicit design activity when a Bash
project handles meaningful security boundaries, sensitive data, untrusted input,
privileged operations, destructive behavior, dependencies with substantial
authority, or other changes that materially expand trust.

The goal is not to require ceremony for every script.  The goal is to prevent
security assumptions from remaining implicit until an incident or code review
forces them into view.

## Context

bashlog demonstrated that even a small logging library can have a non-trivial
threat model.  It processes caller-controlled text, can receive credentials or
private data, implements a redaction boundary, emits to downstream consumers, and
becomes a dependency inside other applications.  Writing its explicit threat
model surfaced residual risks that were not obvious from the feature list alone,
including terminal-control/log-forging concerns in human-oriented output and the
supply-chain authority of non-runtime dependencies.

The same lesson applies broadly to Bash projects.  Shell code often runs with the
user's full filesystem, environment, network, repository, or CI authority.  A
small amount of code can therefore have a large trust footprint.

## Decision Drivers

- Make trust boundaries and sensitive data flows visible.
- Treat dependency additions as changes to the trusted computing base.
- Record residual risk and non-promises rather than implying complete protection.
- Connect security claims to evidence in tests, ADRs, and workflows.
- Surface threats created by output interpretation, shell evaluation, filesystem
  authority, network access, and CI/release privileges.
- Keep the exercise lightweight enough that maintainers will actually use it.

## Decision

The template SHALL include `doc/threat-modeling.md` as a reusable threat-modeling
exercise for derived projects.

A derived project SHOULD maintain a project-specific threat model when it includes
one or more of the following:

- credentials, tokens, private keys, or other sensitive data;
- untrusted or attacker-controlled input;
- destructive filesystem or repository operations;
- network access or remote APIs;
- privileged execution or sensitive host state;
- logging/redaction/security controls;
- dynamic code evaluation, templating, or plugin loading;
- dependencies with broad runtime or CI/release authority;
- release credentials, artifact publication, signing, or attestations; or
- explicit security, confidentiality, privacy, integrity, or availability claims.

The threat model SHOULD identify:

1. security objectives;
2. assets;
3. the trusted computing base;
4. trust boundaries;
5. entry points and data flows;
6. threat actors and failure sources;
7. threats, mitigations, evidence, and residual risks;
8. explicit non-goals; and
9. triggers that require the model to be revisited.

For Markdown maintained on GitHub, Mermaid SHOULD be the default diagram format
for trust-boundary/data-flow diagrams because the diagram source remains
reviewable text and renders natively.  DOT/Graphviz MAY be used when its layout or
generation capabilities are materially useful.

A threat model SHALL NOT be treated as proof that the project is secure.  It is a
structured statement of assumptions, boundaries, and evidence.

## Promises

1. The starter provides a concrete, reusable threat-modeling exercise.
2. The exercise includes dependency trust and supply-chain authority rather than
   limiting threats to runtime attackers.
3. Residual risks and non-goals are first-class outputs of the exercise.
4. Threat-model diagrams can remain maintained text through Mermaid.
5. Projects are encouraged to revisit the model when authority, data exposure,
   interpretation, or trust expands.

## Non-Promises

1. Every derived project is not required to maintain a large formal threat model.
2. Threat modeling does not prove absence of vulnerabilities.
3. A listed mitigation is not automatically sufficient evidence of correctness.
4. Mermaid diagrams are not required when a textual model is clearer.
5. The template does not mandate a particular external threat-modeling framework
   such as STRIDE, PASTA, or attack trees.

## Adversary and Failure Model

This decision accounts for security assumptions being missed because:

- a tool appears too small to justify formal security review;
- a dependency's purpose sounds harmless;
- a logging/output path is treated as passive;
- CI/release tooling is assumed irrelevant because it is not in runtime;
- shell evaluation or option parsing introduces interpretation risk;
- the runtime has more authority than the feature seems to require;
- residual risk remains undocumented after a mitigation is added; or
- future maintainers broaden a security claim without revisiting the original
  trust model.

## Operational Constraints

- `doc/threat-modeling.md` MUST remain part of the starter documentation.
- Security-relevant derived projects SHOULD preserve a project-specific threat
  model.
- Threat models SHOULD identify residual risk and explicit non-goals.
- New dependencies MUST be considered in the trusted computing base.
- Changes that expand authority, sensitive-data exposure, network/filesystem
  access, dynamic interpretation, or publication privileges SHOULD trigger threat
  model review.
- Mermaid SHOULD be preferred for maintained GitHub Markdown diagrams unless
  Graphviz or another format offers a concrete advantage.

## Considered Alternatives

### Rely Only on Security ADRs

Security ADRs preserve the reasoning behind individual decisions, but the relevant
assets and trust boundaries may be distributed across many records.  A threat
model provides a system-level view without replacing those ADRs.

### Require a Formal Framework

Mandating STRIDE or another named framework would provide more structure.  It was
rejected as a template-wide requirement because the projects in this family vary
substantially in size and risk.  The starter exercise captures the important
questions without imposing vocabulary that may not fit every project.

### Leave Threat Modeling to Code Review

This was rejected because code review tends to focus on the changed implementation
and may miss system-level authority or dependency boundaries.  Maintained threat
models make those assumptions recoverable across reviews.

## Consequences

Security-relevant projects gain another maintained document and a review
obligation when their trust model changes.  In return, security decisions become
more explicit, residual risks are less likely to be mistaken for guarantees, and
new dependencies or outputs are evaluated as changes to the attack surface.

## Source Lineage

This decision is directly informed by the threat-modeling exercise performed while
polishing bashlog, including its explicit redaction boundary, downstream stderr
boundary, terminal-control residual risk, generated-artifact testing, and
build/release dependency trust model.

## Open Questions and Follow-Ups

Derived projects may adopt more formal methods when their risk profile warrants
it.  Experience from those projects can inform future revisions of the template
exercise.

## Related Decisions

- ADR-000: Capability Scope, Epistemic Honesty, and Separation of Concerns
- ADR-005: Dependency Management and Explicit Network Boundaries
- ADR-013: Repository-Facing Documentation and Template Hygiene
- ADR-015: Dependencies as Explicit Attack Surface
