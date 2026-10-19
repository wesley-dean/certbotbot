# ADR-015: Dependencies as Explicit Attack Surface

Date: 2026-08-30

## Status

Accepted

## Intent and Documentation Posture

This ADR establishes that every dependency added to a project expands the trusted
computing base and should be reviewed as a new attack surface rather than treated
as a neutral implementation convenience.

The principle applies even to dependencies whose purpose appears routine or
low-risk, such as logging, formatting, parsing, documentation, build tooling, or
serialization.  The historical Log4Shell vulnerability in Log4j is a useful
reminder that apparently ordinary infrastructure can become a critical execution
boundary, but this ADR is intentionally broader than any one incident.

## Context

Bash projects often have fewer runtime dependencies than applications written in
larger ecosystems, which can make each additional dependency feel inexpensive.
That intuition is incomplete.

A dependency may:

- execute code in the caller's process or privilege context;
- receive secrets, configuration, paths, command-line arguments, or log data;
- parse attacker-controlled or semi-trusted input;
- access the network or filesystem;
- invoke external programs;
- inherit environment variables, file descriptors, working directory, traps,
  shell options, or credentials;
- introduce transitive dependencies;
- change independently through an upstream release;
- become unavailable or abandoned;
- expose a supply-chain compromise path; or
- broaden the set of code that must be trusted for a security-sensitive action.

Digest pinning and reproducible acquisition reduce some supply-chain risks, but
they do not answer whether the dependency should be trusted with the data,
authority, or execution context the project gives it.

bashlog provided a useful concrete lesson.  A logging library can appear to be a
presentation convenience while actually sitting on a data-egress boundary and
handling values that may include credentials or other sensitive material.
Choosing a logging dependency therefore changes the security model even if the
library never opens a socket itself.

## Decision Drivers

- Minimize unnecessary trusted code.
- Make dependency additions deliberate rather than incidental.
- Separate acquisition integrity from behavioral trust.
- Recognize that mundane infrastructure can process sensitive or attacker-
  influenced data.
- Preserve the UNIX/compositional preference for small tools without assuming
  composition is free of trust consequences.
- Keep runtime dependency surfaces especially small for security-sensitive Bash
  projects.
- Encourage explicit review of transitive and toolchain risk.

## Decision

Every new dependency SHALL be treated as an expansion of the project's attack
surface and trusted computing base.

Before adopting a dependency, maintainers SHOULD evaluate at least:

1. **Execution context.**  Does the dependency run in-process, as a sourced Bash
   library, as a subprocess, in CI, during build, or only during documentation?
2. **Data exposure.**  What arguments, environment variables, files, secrets,
   logs, source code, or generated artifacts can it observe?
3. **Authority.**  What filesystem, network, credential, repository, release, or
   host privileges does it inherit?
4. **Input trust.**  Does it parse attacker-controlled, repository-controlled,
   network-provided, or user-controlled data?
5. **Side effects.**  Can it write files, execute commands, access the network,
   mutate repository state, alter shell state, or publish artifacts?
6. **Transitive surface.**  What additional code or services become trusted as a
   result of this dependency?
7. **Supply-chain posture.**  Can the exact bytes be pinned and verified?  Is the
   upstream maintained, reviewable, and appropriately scoped?
8. **Failure behavior.**  What happens if the dependency is unavailable,
   compromised, malformed, or behaves differently after an update?
9. **Removal cost.**  Does the project become architecturally coupled to the
   dependency's API, data model, or runtime assumptions?
10. **Alternatives.**  Can a Bash builtin, existing dependency, caller-owned
    composition, or smaller mechanism satisfy the requirement with less trusted
    code?

A dependency MUST NOT be considered safe merely because:

- it is popular;
- it is widely used;
- its purpose sounds harmless;
- it is open source;
- its release artifact matches a checksum; or
- it is used only in build or CI rather than production runtime.

The review depth SHOULD scale with the dependency's authority and data exposure.
A documentation formatter that consumes generated comments requires less scrutiny
than a sourced library that receives credentials, but both are still dependencies
with explicit trust consequences.

Runtime dependencies SHOULD be minimized aggressively in small Bash libraries and
tools when builtins or caller-owned composition can satisfy the same contract
without unacceptable complexity.

Build, test, and release dependencies MAY be broader because they do not ship in
the runtime artifact, but their authority over source, generated artifacts,
credentials, tags, attestations, and publication means they remain part of the
software supply chain and MUST NOT be treated as security-irrelevant.

Dependency introduction that materially changes the runtime trust model,
privilege boundary, sensitive-data flow, release authority, or transitive supply
chain SHOULD receive an ADR or equivalent explicit architectural review in the
derived project.

## Promises

1. The starter treats dependency additions as security-relevant design choices,
   not only package-management operations.
2. Digest pinning is treated as integrity evidence for acquired bytes, not proof
   that the dependency is behaviorally trustworthy.
3. Runtime dependencies are expected to justify their authority and data access.
4. Build and CI dependencies remain within the project's supply-chain threat
   model even when they are absent from consumer runtime.
5. Derived projects receive a reusable checklist for evaluating dependency trust.

## Non-Promises

1. This ADR does not promise that dependency review can prove an upstream project
   contains no vulnerabilities.
2. A checksum does not certify source quality, maintenance quality, or absence of
   malicious behavior.
3. Avoiding dependencies does not automatically make custom in-project code safer.
4. The project does not require vendoring or source-auditing every line of every
   development tool before use.
5. Popularity, reputation, signing, attestations, and vulnerability scanning are
   useful signals but are not substitutes for architectural fit and least
   authority.
6. This ADR does not forbid dependencies; it requires that their costs and trust
   implications be considered explicitly.

## Adversary and Failure Model

This decision considers:

- a dependency containing a remotely exploitable parser or evaluation flaw;
- malicious or compromised upstream releases;
- compromised maintainer or CI credentials in an upstream project;
- dependency confusion or substituted download bytes;
- transitive dependencies introducing behavior the direct dependency did not make
  obvious;
- a sourced library observing secrets or shell state it did not strictly need;
- build or release tooling modifying artifacts or publication state;
- a logging, formatting, or serialization component receiving sensitive data;
- an abandoned dependency accumulating known vulnerabilities;
- a dependency update changing side effects without changing the caller's code;
  and
- maintainers assuming "development-only" means "security-irrelevant."

The ADR does not defend against all such failures automatically.  It requires
projects to expose and reason about them rather than treating dependency
introduction as a purely mechanical action.

## Operational Constraints

- New dependencies MUST be treated as additions to the trusted computing base.
- Dependency review MUST distinguish acquisition integrity from behavioral trust.
- Runtime dependency additions SHOULD document data exposure, authority, side
  effects, and failure behavior.
- Build/CI/release dependencies MUST remain in the supply-chain threat model.
- Popularity or checksum verification MUST NOT be treated as sufficient evidence
  of safety.
- Existing Bash facilities or existing reviewed dependencies SHOULD be considered
  before adding new trusted code.
- Security-sensitive derived projects SHOULD prefer the smallest dependency
  surface that remains readable and maintainable.
- Material changes to trust, privilege, sensitive-data flow, or publication
  authority SHOULD receive explicit architectural review.

## Considered Alternatives

### Treat Pinning and Checksums as Sufficient Dependency Security

Pinning and digest verification are valuable because they make acquisition
repeatable and detect substituted bytes.  This was rejected as a complete model
because a perfectly verified vulnerable or malicious dependency is still
vulnerable or malicious.

### Avoid All Dependencies

Eliminating dependencies can reduce supply-chain surface.  It was rejected as an
absolute rule because bespoke replacements can be less reviewed, less portable,
and more error-prone than a well-chosen dependency.  The goal is deliberate trust
minimization, not dependency-count purity.

### Review Only Runtime Dependencies

This was rejected because build and release tooling can modify source, generated
artifacts, tags, attestations, credentials, and published releases.  Their absence
from consumer runtime does not make them irrelevant to software integrity.

## Consequences

Adding dependencies requires more architectural thought than adding a manifest
line.  Some seemingly convenient integrations will be rejected because their
privilege or data access exceeds their value.

The project may retain small amounts of auditable Bash instead of importing a
larger runtime library.  Conversely, review may show that an established,
well-scoped dependency is safer and more maintainable than custom code.  The ADR
requires the comparison rather than predetermining the answer.

Dependency reviews become especially important at data-egress boundaries,
security controls, parsers, templating systems, logging systems, release tooling,
and anything that evaluates or transforms caller-controlled input.

## Source Lineage

This decision is informed by dependency-boundary work in bashdeps, template-bash,
Bootstrap, and bashlog.  bashlog's explicit redaction and pure-Bash runtime design
made the trust implications of logging dependencies particularly visible.

The Log4Shell incident is a historical example of the general principle that a
widely deployed logging dependency can become a critical attack surface.  The
architectural lesson is not specific to Java or Log4j: infrastructure code should
be evaluated according to the authority and data it receives, not according to
how routine its label sounds.

## Open Questions and Follow-Ups

- A future template revision may add a lightweight dependency-review checklist to
  pull-request guidance if derived projects find that useful in practice.
- Automated dependency and vulnerability scanners remain complementary evidence,
  not a replacement for the architectural review described here.

## Related Decisions

- ADR-000: Capability Scope, Epistemic Honesty, and Separation of Concerns
- ADR-005: Dependency Management and Explicit Network Boundaries
- ADR-013: Repository-Facing Documentation and Template Hygiene
- ADR-014: Modularity as Maintenance and Assembly Architecture
