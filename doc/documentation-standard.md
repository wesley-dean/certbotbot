# Bash Documentation Standard

This document defines the normative source-documentation standard for Bash files
in projects created from this template.  The standard deliberately prefers
verbose, explanatory documentation.  Source brevity is not a goal when brevity
would force a future maintainer to infer intent, contracts, assumptions, failure
semantics, or architectural relationships from executable code alone.

The distribution pipeline separates maintenance representation from consumer
representation.  The `.dev.bash` artifact retains documentation.  Full-line
comments are removed from the ordinary `.bash` artifact, and Bash-Minifier
produces the `.min.bash` artifact.  Maintainers therefore should not reduce
source documentation merely to optimize release size.

## Comment Syntax

Doxygen documentation lines begin with two hash characters:

```bash
## @file lib/example.bash
## @brief Provides an example capability.
## @details
## This module exists to preserve a specific contract.  The details explain why
## the capability belongs here, how callers should use it, and what assumptions
## future changes must preserve.
```

Use ordinary single-hash comments for narrow implementation annotations that are
not intended to become part of generated reference documentation.  Prefer
Doxygen comments whenever the material helps explain an interface, invariant,
module responsibility, non-obvious decision, or maintenance constraint.

## File Blocks

Every maintained Bash source file should begin with:

- `# shellcheck shell=bash` when the file is a sourced/assembled fragment without
  its own shebang;
- `## @file <path>`;
- `## @brief <one-sentence purpose>`; and
- `## @details` followed by substantive prose.

The details should explain the module's responsibility, its relationship to
neighboring modules, important state it owns, and assumptions that affect safe
modification.  A useful file block answers "why does this module exist?" as well
as "what functions are in it?"

## Function Blocks

Significant functions should use the following vocabulary as applicable:

```bash
## @fn example_lookup()
## @brief Looks up a named example.
## @details
## Explain the contract, assumptions, side effects, and why the function exists.
## Describe non-obvious behavior and interactions with other modules.
##
## @param name Logical name to look up.
## @par Standard Output
## The matching value when one exists.
## @retval 0 A matching value was found.
## @retval 64 The caller supplied invalid input.
## @retval 69 No matching value exists.
## @par Examples
## @code
## value="$(example_lookup demo)"
## @endcode
example_lookup() {
  # implementation
}
```

Document parameters in call order.  Document standard output and standard error
when callers depend on them.  Document return values semantically rather than
merely saying "success" or "failure" when distinct failures matter.

Examples are strongly preferred for public, plugin, parsing, transformation, or
otherwise non-trivial interfaces.  Examples should demonstrate intended use,
not manufacture a second test suite inside comments.

## Variables and Constants

Document exported variables, configuration knobs, registry structures, and
constants whose meaning is not self-evident.  Explain units, allowed values,
mutability, ownership, and lifecycle when those details matter.

Do not document every local loop variable.  Documentation volume should preserve
reasoning, not create noise that obscures it.

## Private Helpers

Private helpers may use shorter Doxygen blocks when their contract is narrow and
obvious from the surrounding module.  They still require fuller documentation
when they encode a tricky shell behavior, quoting assumption, error translation,
security boundary, portability workaround, or ordering dependency.

## Document Intent, Not Syntax

Avoid comments such as "increment the counter" immediately above
`((counter++))`.  Prefer comments that explain why the counter exists, why an
operation occurs at that point, or why a seemingly unusual implementation is
necessary.

If code and documentation disagree, treat the disagreement as a defect to
investigate.  Do not automatically rewrite the comment to match current code;
the code may be the part that drifted from the intended contract.

## Relationship to ADRs

Doxygen documentation owns implementation-level intent.  ADRs own durable
architectural reasoning and rejected alternatives.  Source comments may link to
an ADR when a local implementation exists specifically to satisfy an
architectural constraint.

Do not copy an entire ADR into source comments.  Do not invent historical
rationale when no source supports it.  State uncertainty or add an ADR when a
new consequential decision is required.

## Review Standard

Review documentation with the same seriousness as executable code.  Ask whether
a maintainer unfamiliar with the current implementation could understand:

- the responsibility of each module;
- the contract of each significant function;
- important inputs, outputs, and return semantics;
- invariants and ordering requirements;
- meaningful edge cases and failure modes;
- why non-obvious implementation choices exist; and
- which architectural decisions constrain future changes.

There is no target comment-to-code ratio.  The desired amount is "enough to
preserve the reasoning."  In this project family that will often be more prose
than teams accustomed to sparse Bash comments expect, and that is intentional.
