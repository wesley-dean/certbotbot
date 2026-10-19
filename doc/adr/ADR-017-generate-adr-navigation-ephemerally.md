# ADR-017: Generate ADR Navigation Ephemerally

Date: 2026-09-09

## Status

Accepted

## Intent and Documentation Posture

This ADR replaces the manually maintained ADR index with generated linked
navigation while preserving the repository's existing documentation hierarchy and
offline documentation-build boundary.

The maintained ADR corpus remains authoritative architectural source.  Human-
authored framing remains maintained source.  `adrctl` derives the linked list from
the actual ADR files, and the assembled `doc/adr/README.md` becomes ephemeral
build input for Doxygen rather than another maintained representation that can
drift from the corpus.

## Context

ADR-001 established a layered documentation hierarchy in which ADRs preserve
durable reasoning, `doc/decisions.md` provides concise architectural discovery,
`AGENTS.md` provides operational guidance, and generated reference documentation
does not replace maintained source.

ADR-005 established explicit dependency and network boundaries.  `make deps` may
acquire or repair repository dependencies, while `make docs` consumes prepared
state offline.

ADR-010 established that Doxygen output under `doc/reference/` is generated,
ignored state and that the ADR directory should be included in reference material
where practical.

The repository currently maintains `doc/adr/README.md` manually.  That page
contains useful introductory prose followed by a hand-maintained ADR list.  The
Doxyfile already uses it as the main page for generated reference documentation.
The page therefore solves the presentation problem, but its ADR list duplicates
information already present in the filenames and titles of the ADR corpus.

Every new, renamed, or retitled ADR creates a synchronization obligation: the ADR
itself, `doc/decisions.md`, and the manual `doc/adr/README.md` list must all be
updated consistently.  The decision map is intentionally maintained because it
adds concise semantic summaries.  The README list adds no comparable authored
meaning; it is mechanical navigation and should be derived mechanically.

The related Bash projects now use the released `adrctl generate toc` capability
to derive linked ADR navigation from the current corpus.  The command can combine
maintained introductory and closing fragments with the generated list, allowing
Doxygen to continue using `doc/adr/README.md` without requiring that assembled
file to be committed.

Adding adrctl also changes the documentation trusted computing base.  ADR-015
requires that this change be reviewed according to execution context, data
exposure, authority, input trust, side effects, supply-chain posture, failure
behavior, and removal cost rather than treated as a neutral manifest edit.

## Decision Drivers

- Preserve `doc/decisions.md` as the concise, authored architectural discovery
  layer.
- Derive mechanical ADR navigation from the actual ADR corpus.
- Avoid committing generated Markdown solely to support Doxygen or GitHub Pages.
- Preserve ADR-005's explicit network boundary: `make docs` remains offline.
- Preserve ADR-010's ephemeral generated-documentation model.
- Reuse the existing bashdeps-managed dependency lifecycle.
- Keep generated publication atomic so failed generation cannot replace a valid
  landing page with partial output.
- Keep routine documentation generation free of ADR relationship graphs.
- Preserve the maintained Mermaid threat-modeling material governed by ADR-016.
- Keep template-bash runtime and release artifacts independent of documentation
  tooling.

## Decision

### Maintain ADR landing-page framing as source

The repository SHALL maintain:

```text
doc/adr/README.intro.md
doc/adr/README.outro.md
```

These files SHALL contain the human-authored framing previously carried by the
manual ADR README, adapted so the ownership boundary is explicit.

The introductory fragment SHOULD explain the documentation hierarchy and the role
of ADRs.  The closing fragment MAY preserve useful notes that belong after the
index, including current refinement relationships or generation guidance.

Neither fragment SHALL maintain the complete ADR list manually.

### Generate the ADR README from the current corpus

The complete landing page SHALL be generated at:

```text
doc/adr/README.md
```

That file SHALL be ignored by Git and SHALL NOT be committed as maintained source.
It is derivative documentation input generated from maintained framing and the
current ADR corpus.

Generation SHALL use the pinned released `adrctl` artifact and its
`generate toc` command with the maintained introduction and conclusion.  The
resulting list SHALL contain Markdown links to the ADR files so the same page is
useful both as Doxygen input and when inspected locally after generation.

Routine documentation generation SHALL NOT invoke `adrctl generate graph` or
compose an ADR relationship graph.  This restriction applies only to automatic
ADR navigation.  It does not prohibit unrelated Mermaid or Graphviz diagrams
whose content and purpose are separately governed, including the maintained
threat-modeling diagram material established by ADR-016.

### Generate the landing page atomically

The Makefile SHALL provide an `adr-index` target.

`adr-index` SHALL require an already-prepared regular `vendor/adrctl.bash` file.
It SHALL NOT invoke `make deps`, synchronize dependencies, or intentionally access
the network.  Missing prepared state SHALL fail with actionable guidance to run
`make deps` or `make all`.

The target SHALL write the generated Markdown to a temporary candidate adjacent
to `doc/adr/README.md` and move that candidate into place only after successful
generation.  Cleanup SHALL remove abandoned adjacent candidates.

### Manage adrctl through the existing dependency manifest

The released adrctl artifact SHALL be declared in `dependencies.txt` alongside the
existing Bash-Minifier and bash-doxygen dependencies.

The artifact SHALL use an immutable released URL and a committed SHA-256 digest.
Acquisition and verification SHALL remain the responsibility of bashdeps according
to ADR-005.

`vendor/adrctl.bash` is documentation tooling only.  It SHALL NOT be sourced,
concatenated, copied, or otherwise incorporated into generated consumer artifacts,
and it SHALL NOT become a runtime dependency of projects derived from the starter
merely because the template uses it for documentation generation.

### Keep documentation generation offline

`make docs` SHALL continue to consume prepared dependency state without
synchronizing or repairing dependencies.

It SHALL require both the prepared Bash Doxygen filter and adrctl artifact,
regenerate the ADR landing page, and then invoke Doxygen.  `make deps` remains the
explicit network-capable convergence path, and `make deps-check` remains the
offline verification path.

This decision therefore refines ADR-005 and ADR-010 without changing their network
or dependency boundaries.

### Use the generated README as the Doxygen main page

The Doxyfile SHALL continue to use:

```text
USE_MDFILE_AS_MAINPAGE = doc/adr/README.md
```

The ADR corpus SHALL remain available in generated reference documentation.
Maintained framing fragments and ADR template/helper material SHALL be excluded
from appearing as independent documentation pages where practical.

The Doxygen source-code reference continues to use the prepared bash-doxygen
filter.  No change to the Bash source documentation standard is introduced.

### Preserve an always-present architectural discovery surface

Because generated `doc/adr/README.md` is absent from a fresh checkout,
`doc/decisions.md` SHALL remain the always-present concise architectural map.

Repository-facing guidance SHALL direct contributors to `doc/decisions.md` and
the relevant ADR files without requiring the generated README to exist before
`make docs` or `make adr-index` has been run.

### Keep generated state removable

`make docs-clean` SHALL remove:

- `doc/reference/`;
- generated `doc/adr/README.md`; and
- abandoned adjacent ADR-index temporary candidates.

`make clean` and `make distclean` SHALL preserve their existing broader lifecycle
semantics.

### Validate the ownership and network boundaries

CI and Pages workflows SHALL prepare dependencies explicitly before invoking
`make docs`.

CI SHOULD verify that:

- `make docs` fails rather than acquiring missing adrctl state;
- the real manifest-managed dependency set synchronizes and verifies;
- `make docs` generates `doc/adr/README.md`;
- the generated README contains the current ADR;
- the generated README is ignored by Git;
- Doxygen produces `doc/reference/index.html`;
- generated reference output remains ignored;
- `make deps-check` succeeds after documentation generation; and
- tracked repository state remains clean after the documentation build.

## Dependency and Trust Review

adrctl executes as a subprocess during documentation generation.  It receives
repository-controlled ADR Markdown and the maintained README framing files, and
its standard output becomes generated Markdown that Doxygen subsequently parses.
It therefore has influence over published documentation and executes with the
filesystem, process, environment, and network authority available to the
invoking documentation job.

The selected artifact is release-pinned and authorized by a committed SHA-256
digest through the existing bashdeps boundary.  This establishes the expected
bytes that execute; consistent with ADR-015, it does not prove those bytes are
behaviorally safe.

The dependency is not used in template-bash runtime behavior, artifact assembly,
checksum creation, or release execution of generated consumer artifacts.  It does
not receive application runtime input merely by being present in the documentation
path.  Its direct input for this feature is maintained repository documentation.

The principal residual risks are therefore documentation/build compromise,
misrepresentation of architectural navigation, misuse of the invoking process's
authority, and future coupling to adrctl behavior.  Pinning, digest verification,
explicit dependency preparation, atomic output publication, and absence from
runtime artifacts bound those risks without claiming to eliminate them.

## Promises

1. ADR navigation is derived from the current ADR corpus rather than maintained as
   a duplicate list.
2. Human-authored landing-page framing remains maintained source.
3. The assembled `doc/adr/README.md` remains generated, ignored state.
4. `make docs` remains offline and non-repairing after dependency preparation.
5. adrctl remains a documentation-only repository dependency.
6. Generated ADR navigation is published atomically.
7. Routine ADR navigation generation does not include a relationship graph.
8. Existing maintained Mermaid threat-modeling material remains unaffected.
9. `doc/decisions.md` remains available in a fresh checkout as the concise
   architectural discovery map.

## Non-Promises

1. Generated navigation does not replace ADRs or `doc/decisions.md` as maintained
   architectural source.
2. Digest verification does not prove adrctl is free of defects or malicious
   behavior.
3. `make docs` does not install Doxygen or other operating-system packages.
4. A fresh checkout is not promised to contain `doc/adr/README.md` before
   generation.
5. This decision does not define or remove adrctl's explicit graph-generation
   capability.
6. This decision does not remove Mermaid or Graphviz from unrelated documentation
   or product features.
7. This decision does not change template-bash runtime behavior, artifact flavors,
   checksum policy, Bash compatibility floor, or release semantics.

## Adversary and Failure Model

This decision accounts for:

- a manual ADR list drifting from added, renamed, or retitled ADRs;
- a committed generated README drifting from its maintained inputs;
- missing or tampered adrctl dependency state;
- partial generated output after a failed adrctl invocation;
- documentation generation unexpectedly acquiring network state;
- a compromised documentation dependency influencing published documentation or
  acting with documentation-job authority;
- contributors assuming the generated README must exist in a fresh checkout;
- framing or template files appearing as unintended standalone Doxygen pages; and
- routine navigation generation accumulating graph-rendering dependencies or
  behavior unrelated to the linked textual index.

The decision does not sandbox adrctl or Doxygen.  They remain trusted tooling
within the authority of the process that invokes them.

## Operational Constraints

- `doc/adr/README.intro.md` and `doc/adr/README.outro.md` MUST be maintained source.
- `doc/adr/README.md` MUST be generated, ignored, and uncommitted.
- `adr-index` MUST consume prepared adrctl state and MUST NOT acquire dependencies.
- ADR-index generation MUST publish atomically after successful generation.
- adrctl MUST be pinned and digest-verified through `dependencies.txt` and
  bashdeps.
- adrctl MUST remain outside generated consumer runtime artifacts.
- `make docs` MUST remain offline and MUST NOT invoke `deps`.
- Doxygen MUST continue to use the generated ADR README as its main page.
- Framing and template/helper Markdown SHOULD NOT appear as independent generated
  reference pages.
- Routine documentation generation MUST NOT generate an ADR relationship graph.
- ADR-016's maintained Mermaid threat-modeling content MUST remain unaffected.
- `doc/decisions.md` MUST remain the always-present concise decision map.
- `make docs-clean` MUST remove generated ADR-index and reference-documentation
  state.

## Considered Alternatives

### Keep the Manual ADR README

The existing page is readable and requires no additional tool.  It was rejected
because its ADR list is purely mechanical duplicated state that must be updated
whenever the corpus changes.  The authored framing remains worth maintaining; the
list does not.

### Commit the Generated ADR README

This would preserve the current GitHub browsing experience in a fresh checkout.
It was rejected because it creates a synchronization contract for derivative
content and duplicates the drift problem ADR-010 already avoids for generated
HTML.

### Make doc/decisions.md Generated Too

The decision map could theoretically be derived from ADR titles.  It was rejected
because `doc/decisions.md` contains authored semantic summaries and refinement
context, not merely navigation.  It remains maintained source by design.

### Have make docs Run make deps

This would make a fresh documentation build more convenient.  It was rejected
because it directly contradicts the explicit network boundary in ADR-005 and the
offline documentation contract in ADR-010.

### Generate a Relationship Graph Alongside the TOC

A relationship graph may be useful in some contexts, but it adds another generated
representation and potentially another rendering/integration dependency.  The
current need is navigational discovery, which linked text satisfies.  Explicit
adrctl graph generation remains available outside the routine docs path.

### Remove Existing Mermaid or Graphviz Material

The repository contains maintained Mermaid threat-modeling guidance and installs
Graphviz in documentation CI.  Those concerns are separately governed and were
rejected as scope for this change.  Removing unrelated diagram capabilities would
violate the requirement for a surgical migration.

## Consequences

The repository gains two maintained framing fragments and one additional pinned
documentation dependency while deleting one manually maintained duplicate ADR
list.

A fresh checkout no longer contains `doc/adr/README.md`.  Contributors use
`doc/decisions.md` and the ADR files directly until `make adr-index` or `make docs`
generates the landing page.

The Pages site retains an ADR-oriented Doxygen landing page, now with linked
navigation derived from the actual corpus.  Adding or renaming an ADR automatically
changes the generated index on the next documentation build.

The documentation trusted computing base expands by adrctl.  That expansion is
accepted because the dependency is pinned, digest-verified, documentation-only,
and replaces a recurring synchronization obligation with deterministic generated
navigation.

No template runtime, generated consumer artifact, release checksum, source
assembly, plugin model, or Bash compatibility behavior changes.

## Superseded Decisions

This ADR does not supersede ADR-005 or ADR-010; it refines their established
offline and ephemeral documentation model by extending ephemeral state to the ADR
landing-page Markdown.

This ADR refines ADR-001 and ADR-013 where prior repository guidance could be read
as assuming that `doc/adr/README.md` is always-present maintained source.  The
maintained architectural discovery surface is `doc/decisions.md`, while the ADR
README is now generated navigation.

## Related Decisions

- ADR-001: Documentation and Decision Hierarchy
- ADR-003: Make as the Canonical Orchestration Interface
- ADR-005: Dependency Management and Explicit Network Boundaries
- ADR-007: Doxygen-Based Verbose Source Documentation Standard
- ADR-008: Documentation-Driven, Test-Second Development
- ADR-010: Generated Reference Documentation Is Ephemeral
- ADR-013: Repository-Facing Documentation and Template Hygiene
- ADR-015: Dependencies as Explicit Attack Surface
- ADR-016: Explicit Threat Modeling for Security-Relevant Changes
