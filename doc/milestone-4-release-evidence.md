# Milestone 4: E2E Fixture and Release Verification Evidence

**Technical task:** #49 (approved), under story #16 and the staging resource
story #91.  This document records which checks actually passed and which
requirements remain unverified.  It is **not** authorization to use AWS
secrets or to contact Let's Encrypt production.

## Evidence classifications

- **Mocked public E2E:** The real, built certbotbot executable calls synthetic
  AWS/Certbot executables and handles local gzip/tar/openssl fixtures.  The
  fake ACME account and locally self-signed leaf prove only wiring and
  observable failure handling.  They do **not** establish real Route53,
  genuine Let's Encrypt registration/issuance, or Amazon S3 persistence.
- **Artifact and release gates:** Checks bind exact files to source SHA,
  build/run/attempt metadata and each adjacent SHA-256 digest; they execute
  the same Bats suite against all three producer representations and enforce
  Bash 4.3 compatibility.  Passing these gates does **not** mean an external
  staging certificate has been issued or installed.
- **Live staging:** Only a separately operator-authorized, staging-only
  invocation with actual Certbot/Route53/ACME/S3 evidence can satisfy the
  remote-service portions of story #16.  No such result is established by
  the CI evidence below.  An actual due renewal needs an observed normal
  renewal event, not a forced renewal or mock.

The only allowed CA endpoint for this milestone is
`https://acme-staging-v02.api.letsencrypt.org/directory`.
No production ACME requests, automatic account registration, or privileged
staging tests on pull requests are authorized.  See the
[staging runbook](milestone-4-staging-acceptance.md) and
[operator preflight](milestone-4-staging-preflight.md).

## Verified pre-#49 baseline

The exact test baseline is [PR #223](https://github.com/wesley-dean/certbotbot/pull/223),
which was merged into `main` as
`82cd80eed473fa3b13192a0be32be249e48f9133` on 2026-10-27.
Its last verified PR head was
`2b4ecd086e9fefb4745a974b880161e134cdb417`.

[GitHub Actions Test run 40557276094](https://github.com/wesley-dean/certbotbot/actions/runs/40557276094)
completed successfully on that PR head.  The observed completed-success
jobs included the producer artifact preparation, `Bats (development)`,
`Bats (ordinary)`, `Bats (minified)`, all three corresponding
`Bash 4.3` checks, the combined `Bash 4.3 compatibility` check,
all three authenticated-encryption legs, the authenticated standalone
client, and the `Check, build, and test` aggregate.  This is CI
evidence, not a claim of a local invocation of `make test` or
`make test-report`.

The associated
[MegaLinter run 40557276035](https://github.com/wesley-dean/certbotbot/actions/runs/40557276035),
[CodeQL run 40557276037](https://github.com/wesley-dean/certbotbot/actions/runs/40557276037),
and [OCI runtime acceptance run 40557276063](https://github.com/wesley-dean/certbotbot/actions/runs/40557276063)
also completed successfully.  These jobs do not prove real ACME operation.

## Current task #49 integration contract

`Makefile` discovers every `tests/*.bats` file, including
`tests/milestone-4-public-e2e.bats`, for both `make test` and
`make test-report`; the verified-handoff `test-one` and
`test-report-one` targets use the **same** full inventory.  The
pre-existing Test CI runs `test-report-one` independently on each
development, ordinary and minified executable.  Versioning CI runs
`test-one` independently on those same three exact candidate bytes
before release/tag publication.  It does not reuse the PR's artifact.

Task #49 adds `make verify-m4-e2e-inventory` as a non-networking
precondition of all four Make testing targets and as an explicit
preparation-stage gate in both `test.yml` and `semver.yml`.  The
guard requires a regular, non-symlink staging E2E Bats file, confirms
it belongs to the full Make Bats inventory, and asks Bats to count
a positive number of executable test cases.  It has **no AWS or ACME
secrets** and does not run a duplicate full test suite.  If the suite
disappears or becomes non-runnable, the matrix/release fails rather
than reporting green on a reduced inventory.  Additional test cases
can be added without updating a hardcoded count.

The ordinary and release workflows retain their shared verified
eight-file producer/client handoff, one-day artifact retention, exact
SHA-256 companions, per-flavor Bats/Bash 4.3 gates and strict
aggregators.  No credentialed staging steps, production ACME endpoint,
additional release products, or publication privileges are added.

## Acceptance and evidence matrix

| Required scenario / gate | Instrumentation | Verified result at PR #223 baseline | Live staging result |
| --- | --- | --- | --- |
| Seeded first staging issuance | Public executable, synthetic staging account + AWS/Certbot mocks, local gzip/tar/OpenSSL | Bats suite passed in all three flavors; specific case transcript not published separately | Not run or verified |
| Second independent runner and no-op | Separate fixture TMPDIRs; exact original account/lineage and no-put traces | Bats suite passed in all three flavors | Not run or verified |
| Simulated due-renewal and publication | Mock changed leaf, selected `renew` and one current-key PUT | Bats suite passed in all three flavors | Not run or verified |
| Missing/unsafe archive; Certbot and packaging failures | Mock fault stages, no downstream PUT and prior-object preservation | Bats suite passed in all three flavors | Not run or verified |
| Failed or uncertain S3 PUT | Pre-acceptance denial versus lost-response simulated separately | Bats suite passed in all three flavors | Not run or verified |
| Exact shipped producer flavors | Development, ordinary, minified from same verified handoff, Bats and Bash 4.3 | Completed-success jobs for all three flavors | Not run or verified |
| Checksums and release provenance | SHA-256 companions and same-run handoff manifest | PR Test preparation succeeded; actual future release run unverified | Not applicable to CA |
| All-flavor local Make targets | `make test` and `make test-report`, JUnit in `test-results/` | Source wiring verified; local execution not claimed | Not applicable to CA |
| #49 inventory gate and release linkage | New Make precondition + both CI preparation jobs | Pending PR #49 CI and review | Not applicable to CA |
| Genuine staging account / Route53 / S3 | Explicit operator permission and real isolated resources | Not supplied by mock CI | Not run or verified |
| Genuine first staging issue / S3 publish / fresh-runner no-op | Operator-controlled live process, independently re-read archive | Not supplied by mock CI | Not run or verified |
| Real due renewal or accepted equivalent | Actual staging renewal decision under normal Certbot policy | Simulated only | Not run or verified |

Individual green Bats cases do **not** claim a trusted Let's Encrypt
certificate or an independently verified remote object.  A separate
operator-approved action with a redacted run ID, exact public executable
digest, isolated runner evidence, account/lineage continuity and explicit
real/mock classification is required for live acceptance.  Never attach
AWS credentials, domain/contact secrets, ACME private keys, raw archive
bytes or unrestricted Certbot logs to this report.

## Reproducing the fixture/release checks

From an authorized, prepared repository checkout with trusted pinned
dependencies:

```bash
make deps
make deps-check
make build
make verify-m4-e2e-inventory
make check
make test
make test-report
```

`make test` exercises all three producer flavors;
`make test-report` also emits per-flavor JUnit reports.  In a CI
same-run verified handoff, `make test-report-one
TEST_FLAVOR=development` (or `ordinary`/`minified`) does not
rebuild candidate artifacts and checks that flavor's checksum before
running the complete inventory.  Do not expose real AWS credentials
to any of these fixture commands.

Use the separate
[release verification contract](release-verification.md) for
release candidate SHA binding, Bash 4.3, strict quality gates and
late publication.  A merged documentation or test PR alone does
not close stories #16 or #91.  Their remaining real staging
acceptance criteria must be evidenced independently.

## Follow-up and status discipline

Technical task #49 was completed by the merged, verified PR #224. The
mocked fixture/release integration is complete, but story #16 still requires
live first issuance,
a clean independent runner's no-op/selected renewal decision, and safe
handling of any documented remaining due-renewal limitations.  Story
#91 requires the authorized real staging seed, DNS/S3 rights and operator
signoff.  Approved task #225 introduces the separate manual-only
[staging workflow](milestone-4-live-staging-workflow.md) under
[ADR-043](adr/ADR-043-manual-staging-live-e2e-workflow.md). Its
implementation is **not** proof of live staging acceptance. A missing live
test is **not** an automatically accepted waiver.
