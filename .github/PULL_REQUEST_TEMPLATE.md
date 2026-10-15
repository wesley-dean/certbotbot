<!-- Keep the title brief and useful as a changelog entry. -->
<!-- Link a relevant issue when one exists. -->
<!-- markdownlint-disable -->

Fixes #

<!-- markdownlint-restore -->

## Summary

<!-- What problem does this change address, and what behavior changes? -->

## Architectural impact

<!--
Identify governing ADRs or explain why no architectural decision changes.  If the
change establishes a durable new decision, add or update an ADR and the concise
decision map.
-->

## Security / trust impact

<!--
Does this change dependencies, authority, sensitive-data flow, untrusted-input
handling, network/filesystem access, subprocesses, dynamic loading, build/release
authority, or security claims?  If so, summarize the threat-model impact and
residual risk.
-->

## Validation

<!-- List the checks/tests relevant to this change. -->

- [ ] `make check`
- [ ] `make test`
- [ ] `make docs`
- [ ] `make deps-check` when dependency state or acquisition changed

## Readiness checklist

- [ ] Public behavior, options, outputs, artifacts, or Make targets are documented.
- [ ] Governing ADRs and `doc/decisions.md` are updated when architecture changed.
- [ ] Promises and non-promises are explicit for consequential new behavior.
- [ ] Doxygen comments are updated when maintained Bash contracts changed.
- [ ] Tests exercise each affected shipped artifact flavor.
- [ ] Negative assertions are included when the contract requires forbidden data
      or behavior to remain absent.
- [ ] New dependencies were reviewed as additions to the trusted computing base.
- [ ] Threat-model documentation was reviewed when trust, authority, or sensitive
      data flow changed.
- [ ] Repository-facing documentation/templates contain no stale project names,
      unrelated links, or inherited policies that no longer apply.

### Reviewing maintainer

- [ ] Label as `breaking` if this is a large fundamental change.
- [ ] Label as `automation`, `bug`, `documentation`, `enhancement`,
      `infrastructure`, or `performance` as appropriate.
