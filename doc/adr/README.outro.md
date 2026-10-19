ADR-014 refines how derived projects should interpret ADR-004: modular maintained
source and deterministic assembly are reusable architectural lessons, while the
starter's runtime registry and noop plugin remain an example to evaluate rather
than a universal requirement.

## Generation

The linked ADR list above is generated with the pinned `adrctl` release during
`make adr-index` and `make docs`.  Routine documentation generation intentionally
produces textual navigation only; it does not generate an ADR relationship graph.
The maintained Mermaid threat-modeling material remains a separate documentation
concern governed by ADR-016.
