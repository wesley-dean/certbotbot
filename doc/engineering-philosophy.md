# Engineering Philosophy

This document captures engineering instincts the starter intends to encourage in
derived Bash projects.  It is guidance rather than a substitute for project-
specific Architecture Decision Records.

When this document and an Accepted ADR disagree, the ADR governs.  When a derived
project has different needs, it should record the intentional divergence rather
than preserving a starter convention merely because it was inherited.

## Respect Developer Agency

Libraries and tools should provide mechanisms without silently taking ownership of
application policy.

Prefer APIs that let the developer make important choices explicitly.  Avoid
inferring sensitivity, control-flow policy, deployment intent, destructive
behavior, or output destinations when the caller is better positioned to decide.

Once a caller explicitly invokes a mechanism with a documented guarantee, the
implementation should honor that guarantee rigorously.  Respect for agency does
not mean weakening a contract after the caller has deliberately selected it.

## Prefer Explicit APIs Over Inference

Important behavior should be visible in function arguments, options, configuration,
or documented process state.

Prefer:

- named options over ambiguous positional conventions;
- explicit option terminators such as `--` when caller-controlled values may begin
  with `-`;
- explicit configuration over environment guessing;
- canonical names over a proliferation of convenience aliases; and
- bounded symbolic values over raw control sequences or mini-languages.

Automatic behavior is appropriate when the observed property is reliable, the
rule is narrow, and the consequences are unsurprising.  Do not turn a convenient
heuristic into hidden policy.

## Follow UNIX Composition Principles Deliberately

The UNIX tradition is a useful design influence for Bash projects, especially the
ideas that tools should do one coherent job, communicate through ordinary text
interfaces, compose with other tools, and avoid taking ownership of concerns that
belong elsewhere in the pipeline.

Apply those ideas concretely rather than ceremonially:

- keep stdout available for application data when diagnostics belong on stderr;
- prefer textual, inspectable interfaces where binary structure is unnecessary;
- let surrounding tools own transport, persistence, scheduling, orchestration, or
  policy when the project does not need to own them;
- expose composable functions and commands rather than forcing one monolithic
  workflow;
- make exit status meaningful and documented;
- avoid hidden global state when explicit arguments or configuration are clearer;
- prefer narrow tools and modules whose responsibilities can be explained in a
  sentence; and
- let callers build higher-level policy through wrappers and composition when the
  library does not need to own that policy.

UNIX philosophy is not an excuse to underspecify behavior or ignore modern
security and correctness requirements.  A project may deliberately retain state,
provide structured output, fail closed, generate standalone artifacts, or expose a
richer API when those choices produce a better contract.  The relevant question
is whether the added mechanism solves a real problem without unnecessarily
capturing responsibilities that could remain composable.

## Treat Every Dependency as New Attack Surface

Composition is valuable, but each dependency also expands the trusted computing
base.

Evaluate dependencies according to the authority and data they receive, not the
harmlessness of their label.  A logger, formatter, parser, documentation filter,
build helper, or release action may still process sensitive input, execute in a
privileged context, mutate artifacts, access the network, or introduce transitive
supply-chain risk.

Before adding a dependency, ask:

- What code will execute, and in which process or privilege context?
- What data, credentials, environment, files, or file descriptors can it see?
- What network, filesystem, repository, or release authority does it inherit?
- What input does it parse, and who controls that input?
- What transitive code becomes trusted?
- Can the exact acquired bytes be pinned and verified?
- What happens when it is compromised, unavailable, abandoned, or updated?
- Can an existing builtin, reviewed dependency, or caller-owned composition solve
  the problem with less trusted code?

Checksums and pinning establish acquisition integrity; they do not prove that the
verified dependency is safe or appropriate.  Popularity and open source status are
signals, not security boundaries.

Runtime dependencies deserve especially careful scrutiny in small Bash tools, but
build, CI, documentation, and release dependencies also remain part of the supply
chain because they can influence source, generated artifacts, credentials, tags,
attestations, or publication.

See ADR-005 for dependency acquisition/network boundaries and ADR-015 for the
explicit dependency trust model.

## Define Contracts Before Mechanisms

Public behavior is a compatibility commitment.  Before optimizing implementation,
identify:

- what the feature promises;
- what it deliberately does not promise;
- how invalid input is handled;
- how failure is reported;
- which side effects are allowed;
- which streams or files are used;
- what ambient state matters; and
- how the new behavior composes with existing behavior.

Implementation may evolve while the contract remains stable.  Tests are evidence
for the contract rather than the source of architectural intent.

## State Promises and Non-Promises

Trust should be an outcome of bounded, inspectable claims.

For consequential decisions, ask both:

- What must remain true?
- What might a reasonable reader incorrectly assume is also guaranteed?

Use explicit non-promises to prevent over-interpretation of portability, security,
privacy, durability, atomicity, availability, or compatibility boundaries.

A non-promise is not permission to omit a genuine requirement.  If documenting a
non-promise reveals that the property is actually necessary, revisit the design.

## Do Not Manufacture Boundaries the Runtime Does Not Provide

Bash does not provide true private memory between sourced functions, strong module
encapsulation, secure memory erasure, or arbitrary transactional semantics.

Do not disguise ordinary state and call it private, encode data and call it
protected, or imply that a convention provides a runtime guarantee it cannot
actually enforce.

Document the boundary that really exists, then design within it.

## Readability and Auditability Are Correctness Properties

Maintained Bash should be understandable by reading it.

Prefer:

- plain names;
- explicit state;
- visible source ordering;
- ordinary control flow;
- responsibility-focused modules;
- narrow helpers;
- bounded algorithms; and
- exact Doxygen contracts beside implementation.

Avoid `eval`, generated source, reversible obscurity, dynamic-variable tricks, or
metaprogramming whose main benefit is cleverness or apparent encapsulation.

When behavior is security-sensitive or operationally risky, a reviewer should not
need to solve a puzzle before they can reason about it.

## Modularity Is Primarily a Maintenance Property

Small maintained source files and standalone consumer artifacts are compatible
goals.

Keep dependency ordering explicit where order is semantically important.  Use
deterministic discovery only for genuinely additive modules.  Do not encode
semantic dependencies through filename tricks merely because lexical discovery
exists.

Modular source does not automatically require a runtime plugin registry, dynamic
loading, filesystem discovery, or third-party extension API.  Add runtime
indirection only when the product's actual extension model requires it.

The template includes plugin discovery and a noop plugin as executable starter
material.  Derived projects should retain, adapt, reinterpret, or remove that
runtime model according to their domain while preserving the more general modular
assembly lessons that remain useful.

## Keep the Public Surface Conservative

Every public function, option, accepted token, output format, environment variable,
file, and return status may become something consumers depend upon.

Expose a capability because callers need it, not because an internal helper already
exists.  Caller-owned wrappers are often preferable when behavior represents
application policy rather than reusable mechanism.

A small coherent API is easier to document, test, and preserve than a broad API
assembled from every available implementation detail.

## Separate Concerns Deliberately

Keep semantic policy, presentation, transport, persistence, dependency acquisition,
building, testing, and release responsibilities distinct when their boundaries
matter.

This does not require many layers for their own sake.  It means avoiding hidden
coupling where changing presentation changes semantics, a build unexpectedly
accesses the network, or a convenience helper silently takes ownership of caller
control flow.

## Fail Closed When a Security Boundary Is Explicitly Invoked

When a project offers an explicit security mechanism and the caller deliberately
invokes it, uncertainty at that boundary should generally fail closed rather than
silently fall back to an unprotected path.

Scope the fail-closed behavior to the mechanism actually selected.  Do not infer
security policy the caller did not request merely because related configuration
exists elsewhere in the process.

Projects whose domain does not contain a security boundary need not manufacture
one to satisfy this principle.

## Prefer Durable Invariants Over Mutable Snapshots

Documentation should describe properties intended to remain true rather than
incidental numbers and implementation snapshots that predictably rot.

For example, "every shipped artifact receives the complete behavior suite" is a
useful invariant.  "the suite contains 137 tests" is usually transient CI output,
not architecture.

Document exact details when they are contractual.  Otherwise document the
invariant that matters.

## Treat Generated Artifacts as Products

If users consume generated files, those files are product surfaces rather than
incidental build intermediates.

Test every shipped artifact flavor.  Do not assume concatenation, comment
stripping, minification, code generation, packaging, or checksum creation cannot
change behavior merely because those operations happen during the build.

## Make External and Network Boundaries Visible

Commands that may access the network or modify dependency state should be
explicitly distinguished from offline build and verification steps.

Runtime external-command use should likewise be an intentional project decision,
not an accidental dependency introduced by a helper that happened to be
available on the developer's workstation.

Visible boundaries improve reproducibility and make failure behavior easier to
understand.

## Preserve Portability Deliberately

A minimum Bash version is a compatibility promise.  Exercise representative
runtime behavior under that floor rather than relying on syntax validation alone.

Adopt newer Bash features when they materially improve correctness, security,
readability, or maintainability enough to justify reconsidering the compatibility
promise.  Avoid fragile compatibility tricks whose only purpose is preserving a
floor that no longer serves the project.

## Documentation Is Part of the Architecture

Use different documents for different jobs:

- README for public orientation;
- this document for reusable engineering posture;
- `doc/decisions.md` for concise architectural discovery;
- ADRs for durable reasoning;
- a project specification for normative observable behavior when warranted;
- Doxygen comments for implementation contracts; and
- tests for executable evidence.

Repository-facing support, contribution, security, issue, and pull-request files
also shape how the project is used and maintained.  They deserve the same release-
readiness review as code-facing documentation.
