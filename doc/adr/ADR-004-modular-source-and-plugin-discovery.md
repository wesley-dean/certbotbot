# ADR-004: Modular Source Assembly and Automatically Discovered Plugins

Date: 2026-08-19

## Status

Accepted

## Context

Maintainers benefit from small source files organized by responsibility, while
users of Bash tools often benefit from a single inspectable executable.  The
Bootstrap project demonstrates the value of modular source, but portions of its
current backend dispatch still enumerate supported implementations centrally.

For a starter repository, extension should be additive.  Adding a plugin should
not require editing an unrelated central dispatcher merely to make the plugin
exist.  At the same time, build order must be deterministic so generated
artifacts remain reviewable and reproducible.

GNU Make treats whitespace as structural syntax when it expands lists of source
files.  Supporting plugin paths containing whitespace would therefore require a
substantially more complicated source-discovery and assembly mechanism for an
edge case that provides no meaningful benefit to this project family.  The
starter should state that constraint rather than hide it behind fragile quoting.

## Decision Drivers

- Maintainable modular source.
- Single-file consumer artifacts.
- Additive extension without central hard-coded discovery lists.
- Deterministic build order.
- A concrete example that teaches the plugin contract.
- A source-layout contract that remains understandable in ordinary Make.

## Decision

Maintained implementation SHALL be split between an explicit core source order
and plugin files under `lib/plugins/`.

Core files SHALL have an explicit build order because dependencies among core
abstractions are architectural and should remain visible.  Plugin files SHALL be
automatically discovered at build time and appended in lexical pathname order.

Maintained Bash source filenames SHALL use conventional whitespace-free paths.
In particular, plugin filenames under `lib/plugins/` MUST NOT contain spaces,
tabs, or newline characters.  This is an intentional repository convention,
not an attempt to claim that Bash or the underlying filesystem cannot represent
such names.

Plugins SHALL register themselves through a small registry API.  Discovery is
therefore file-based and registration is explicit.  Runtime code MAY dispatch by
registered plugin name without maintaining a hard-coded list of known plugins.

The starter SHALL include a noop plugin.  It is executable starter behavior and
the reference implementation for a minimal plugin, not a mock hidden only in the
test suite.

Generated artifacts SHALL contain all registered plugin implementations and
SHALL NOT depend on the source tree or `vendor/` at runtime.

## Operational Constraints

- Core source order MUST be explicit.
- `lib/plugins/*.bash` MUST be discovered automatically and sorted
  deterministically.
- Maintained Bash source paths MUST be whitespace-free.
- Plugins MUST register through the registry API.
- Adding a plugin MUST NOT require adding its name to a central discovery list.
- The starter MUST include a documented noop plugin.
- Consumer artifacts MUST be standalone after build.

## Considered Alternatives

A monolithic maintained source file was rejected because it scales poorly for
reasoning and review.  Explicitly listing every plugin in the Makefile was
rejected because it turns extension into coordinated edits and invites merge
conflicts.  Runtime sourcing of plugin files was rejected because it weakens the
single-file distribution model and makes deployed behavior depend on filesystem
layout.

A null-delimited or helper-script-based discovery pipeline could support source
filenames containing whitespace.  It was rejected because the additional
machinery would make the starter harder to understand and maintain without
solving a realistic project requirement.  Conventional whitespace-free source
filenames are the simpler and more predictable contract.

## Consequences

Lexical plugin ordering becomes part of the build contract.  Plugins should not
depend on incidental ordering among peers; if a dependency becomes important,
it belongs in the explicit core architecture or needs a documented extension to
the plugin contract.

Contributors must use conventional whitespace-free filenames for maintained Bash
source.  This restriction is intentionally narrow and keeps Makefile source lists
transparent.

## Source Lineage

Bootstrap ADR-010 established modular source assembly into a single distribution
artifact.  Bootstrap's package backends demonstrate the value of separated
implementations.  This ADR intentionally strengthens the starter architecture by
making plugin discovery additive rather than centrally enumerated.

## Related Decisions

- ADR-002: Bash Runtime and Portability Baseline
- ADR-003: Make as the Canonical Orchestration Interface
- ADR-006: Three Release Artifact Flavors, Metadata, and Checksums
