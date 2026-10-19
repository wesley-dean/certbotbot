Architecture Decision Records preserve the reasoning behind consequential
technical and process decisions in this project.  They are intentionally more
verbose than operational summaries because context, alternatives, constraints,
and rejected options are part of the architectural record.

The repository uses a layered documentation model:

- `doc/engineering-philosophy.md` records reusable engineering instincts for areas
  where no more specific Accepted ADR governs.
- ADRs explain why durable decisions exist and what constraints follow from
  them.
- `doc/decisions.md` provides a concise discovery map of Accepted decisions.
- `AGENTS.md` is a concise operational map that points back to the governing
  ADRs rather than repeating their reasoning.
- A project specification, when needed, describes current observable behavior.
- `doc/threat-modeling.md` provides a reusable exercise for exposing assets, trust
  boundaries, dependency risk, mitigations, and residual risk.
- Doxygen comments preserve local implementation contracts and reasoning near
  the code that depends upon them.
- Tests and CI verify observable behavior and selected architectural invariants.

When the engineering philosophy and an Accepted ADR disagree, the ADR governs.
The philosophy document is guidance, not a second source of binding architecture.

The ADR template includes `Promises`, `Non-Promises`, `Adversary and Failure
Model`, and `Operational Constraints` sections so consequential decisions expose
both what they guarantee and what reasonable readers should not infer.  Those
sections do not replace the surrounding rationale.

This landing page is assembled during documentation generation.  The framing in
`README.intro.md` and `README.outro.md` is maintained source, while the linked ADR
list between them is generated from the current corpus by the pinned `adrctl`
dependency.  The assembled `doc/adr/README.md` is generated build input and is not
committed.
