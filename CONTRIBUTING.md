# Contributing

Contributions are welcome.  template-bash is intended to encode reusable Bash
engineering practices rather than force every derived project into one product
shape, so changes should distinguish between starter-wide lessons and behavior
that belongs only in one derived project.

Before consequential work, please read:

- `README.md` for the starter's purpose and build lifecycle;
- `doc/engineering-philosophy.md` for reusable engineering posture;
- `doc/decisions.md` and the governing ADRs under `doc/adr/`;
- `AGENTS.md` for the concise repository map;
- `doc/documentation-standard.md` before editing maintained Bash comments;
- `doc/testing.md` before changing tests or generated artifacts; and
- `doc/release-verification.md` before changing release behavior.

## Development Expectations

Prefer focused changes with a clear contract.  Consequential architectural work
should update or add an ADR.  When a change is broadly reusable across derived
projects, document the reusable principle rather than only the implementation that
happened to expose it.

The canonical validation surfaces are:

```text
make check
make test
make test-report
make docs
make deps-check
```

Generated files under `dist/`, `doc/reference/`, `test-results/`, and `vendor/`
are not maintained source and should not be edited directly.

Public APIs, Make targets, artifact names, environment variables, output formats,
and return statuses can become compatibility commitments in derived projects.
Avoid exposing implementation details merely because they are convenient to
access.

## Adapting the Starter

Derived projects are expected to remove or reinterpret starter behavior that does
not fit their domain.  In particular, the runtime plugin registry and noop plugin
are teaching examples, not universal requirements for modular Bash source.

Before a derived project's first release, review repository-facing files such as
README, `SUPPORT.md`, `SECURITY.md`, issue templates, and pull-request guidance for
stale template names, links, assumptions, or policies.

## Reporting Problems

Use `SUPPORT.md` for ordinary support and bug-report guidance.  Suspected
vulnerabilities should be reported according to `SECURITY.md` rather than in a
public issue.

## Collaboration Policy

Contributors are expected to follow `CODE_OF_CONDUCT.md`.

## Public Domain

This project is dedicated to the public domain within the United States, and
copyright and related rights in the work worldwide are waived through the
[CC0 1.0 Universal public domain dedication](https://creativecommons.org/publicdomain/zero/1.0/).

See [`LICENSE`](LICENSE) for the repository's license text.  By contributing, you
agree that your contribution will be released under the same CC0 dedication.
