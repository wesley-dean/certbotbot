# ADR-014: Modularity as Maintenance and Assembly Architecture

Date: 2026-08-30

## Status

Accepted

## Intent and Documentation Posture

This ADR refines how derived projects should interpret the modular/plugin example
established by ADR-004.

The starter's runtime plugin registry and noop plugin remain useful executable
teaching material for command-oriented projects.  Experience deriving bashlog
showed, however, that the more broadly reusable architectural lesson is not
"every Bash project should have runtime plugins."  It is that maintainers benefit
from responsibility-focused source modules, explicit dependency order,
deterministic additive assembly, and standalone consumer artifacts.

This distinction should be visible in the starter so derived projects do not
preserve runtime indirection merely because it was inherited.

## Context

ADR-004 established:

- explicit core source order;
- deterministic discovery of `lib/plugins/*.bash`;
- a runtime plugin registry;
- a noop reference plugin; and
- standalone generated artifacts.

That combination is appropriate for the starter's example CLI because the
example needs concrete executable behavior and demonstrates additive dispatch.

bashlog inherited this design and intentionally retained the build-time modularity
while removing the runtime registry and noop behavior.  Its public API consists of
directly callable Bash functions.  Registry lookup would have added state,
indirection, documentation, and failure modes without solving an actual runtime
problem.

The experience exposed a general template lesson: build-time modularity and
runtime extensibility are separate decisions.

## Decision Drivers

- Preserve small, responsibility-focused maintained source files.
- Keep semantically important source ordering visible.
- Produce deterministic standalone artifacts.
- Avoid teaching derived projects that runtime registration is required for
  modularity.
- Preserve the starter plugin example for projects that genuinely need command or
  implementation dispatch.
- Encourage derived projects to delete or reinterpret starter behavior that does
  not fit their domain.
- Avoid runtime indirection, registries, reflection, or dynamic loading unless a
  concrete product requirement justifies them.

## Decision

The template SHALL distinguish **modular maintained source and deterministic
assembly** from **runtime plugin architecture**.

The following principles are broadly reusable and SHOULD normally survive into
derived projects:

1. maintain implementation in responsibility-focused Bash files;
2. keep core dependency order explicit;
3. use deterministic discovery only for genuinely additive leaf modules;
4. avoid encoding semantic dependencies through incidental lexical filenames;
5. assemble consumer-facing standalone artifacts at build time; and
6. ensure generated artifacts do not depend on the maintainer source tree or
   `vendor/` at runtime unless the derived project explicitly chooses otherwise.

The template MAY continue to ship the runtime registry and noop plugin as concrete
starter behavior.

Derived projects SHALL treat that runtime plugin model as an example to evaluate,
not as a mandatory inherited architecture.  A derived project MAY:

- retain the registry when runtime name-to-implementation dispatch is useful;
- remove the registry and call assembled functions directly;
- reinterpret `lib/plugins/` as build-time additive modules without runtime
  registration;
- enumerate all modules explicitly when their order or dependency graph is
  semantically important; or
- remove plugin discovery entirely when the project is small enough that explicit
  source assembly is clearer.

A derived project SHOULD record a consequential departure from ADR-004 when the
change affects its runtime extension model, public API, trust boundary, or build
architecture.

Runtime directory scanning, dynamic sourcing, hot-loading, or third-party plugin
installation are separate architectural capabilities.  They MUST NOT be inferred
merely from the existence of modular source files or the starter's
`lib/plugins/` directory.

## Promises

1. The starter will continue to demonstrate modular maintained source and
   standalone build assembly.
2. Core source ordering will remain visible rather than inferred from filesystem
   order.
3. Derived projects are explicitly free to remove the runtime registry/noop model
   when it adds no product value.
4. The term "plugin" in starter source will not be treated as proof that a derived
   project has or needs a stable third-party plugin API.
5. Deterministic build-time discovery will remain distinct from runtime dynamic
   loading.

## Non-Promises

1. template-bash does not promise that every derived project should retain
   `lib/plugins/`.
2. The starter registry is not a universal Bash extension architecture.
3. Lexical discovery does not promise that peer modules may depend on one another
   through filename order.
4. Modular maintained source does not imply multiple runtime files.
5. The presence of a noop reference implementation does not mean a derived
   project should preserve starter-only behavior after it has real domain logic.
6. This ADR does not define a secure third-party plugin sandbox or trust model.

## Adversary and Failure Model

This decision addresses architecture drift and accidental complexity such as:

- retaining a registry because it came from the template even when direct
  functions are clearer;
- treating a build-time module directory as if it were a runtime plugin system;
- hidden semantic dependencies encoded in lexical filenames;
- a monolithic maintained source file becoming difficult to review;
- generated artifacts accidentally depending on repository filesystem layout;
- runtime scanning or dynamic sourcing appearing without a deliberate trust
  decision; and
- starter demonstration behavior surviving into a product after its teaching
  purpose has ended.

The decision assumes maintained source committed to the derived repository is
trusted project code.  Third-party runtime extension is outside this decision.

## Operational Constraints

- Core dependency order MUST remain explicit.
- Automatically discovered modules MUST be deterministic.
- Semantic dependencies MUST NOT rely solely on incidental lexical peer order.
- Derived projects MUST NOT assume runtime plugin registration is required for
  modular source assembly.
- The starter registry/noop behavior SHOULD be removed or adapted when it does not
  fit the derived project's domain.
- Runtime dynamic loading or directory scanning MUST require a separate explicit
  project decision.
- Consumer artifacts SHOULD remain standalone unless the derived project
  intentionally documents a multi-file runtime contract.

## Considered Alternatives

### Make the Runtime Registry Mandatory for All Derived Projects

This would keep projects structurally uniform.  It was rejected because uniform
indirection is not a benefit when a project exposes direct functions or has no
runtime extension requirement.

### Remove Plugins From the Starter Entirely

This would make the template more neutral.  It was rejected because the current
registry/noop implementation remains a useful concrete example of additive
extension, testing, and modular source assembly for projects that need it.

### Treat Every Module as Explicit Core

This is maximally transparent and remains a good option for many derived projects.
The template retains deterministic additive discovery because it demonstrates a
useful pattern, while this ADR makes clear that projects may choose explicit
enumeration instead.

## Consequences

The starter keeps its executable plugin example but documents it more honestly as
one runtime pattern rather than the definition of modularity.

Derived projects gain permission, and explicit encouragement, to simplify
inherited architecture when their public model does not need runtime dispatch.
That reduces the chance that template code becomes cargo-cult infrastructure.

Reviewers must distinguish between a change to source assembly and a change to the
runtime extension model, since those concerns no longer travel together by
default.

## Source Lineage

This decision is directly informed by bashlog ADR-016, which retained explicit
core ordering, deterministic assembly, whitespace-free maintained source paths,
and standalone artifacts while rejecting the inherited runtime registry and noop
plugin for a sourceable function library.

It refines, rather than replaces, the starter behavior established by ADR-004.

## Superseded Decisions

This ADR does not remove ADR-004 from the template itself.  It supersedes only an
implicit interpretation that ADR-004's runtime registry/noop requirements should
be carried unchanged into every derived project.

## Open Questions and Follow-Ups

- Future template revisions may rename `lib/plugins/` if accumulated derived
  projects show that a more neutral `lib/modules/` convention teaches the pattern
  better without weakening the executable starter example.
- Additional derived projects should be used as evidence before changing the
  starter's runtime source layout itself.

## Related Decisions

- ADR-004: Modular Source Assembly and Automatically Discovered Plugins
- ADR-006: Three Release Artifact Flavors, Metadata, and Checksums
- ADR-013: Repository-Facing Documentation and Template Hygiene
