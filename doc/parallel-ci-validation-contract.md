# Parallel Producer CI Validation Contract

Status: **Accepted design for approved task #170; not yet implemented.**
Implementation is divided among [tasks #171-#174](https://github.com/wesley-dean/certbotbot/issues/169).
Governing decision: [ADR-036](adr/ADR-036-parallel-producer-verification-and-handoff.md).

## Current baseline

At the start of task #170, `Makefile` runs `make test` and
`make test-report` serially for the three producer flavors.  In
`.github/workflows/test.yml` the primary Bats/JUnit tests run as a
single serial step, and Bash 4.3 and authenticated encryption also
loop serially inside separately scheduled jobs.  The release workflow
`.github/workflows/semver.yml` serializes both `make test` and its
Bash 4.3 checks inside one credential-bearing job.

The plan replaces serial **flavor scheduling**, not the tests
themselves.  Three producer variants are:

| Flavor | Exact release executable | Full-suite JUnit |
| --- | --- | --- |
| development | `dist/certbotbot.dev.bash` | `bats-development.xml` |
| ordinary | `dist/certbotbot.bash` | `bats-ordinary.xml` |
| minified | `dist/certbotbot.min.bash` | `bats-minified.xml` |

The future `dist/certbotbot-client.bash` is a separate product with
its own test contract, not a fourth entry in this matrix.  The
release inventory must respect whatever client deliverables exist
on main **at the time task #174 is implemented**.

## Chosen job topology

### Ordinary PR and push tests

`prepare` (Ubuntu 24.04, no publishing credentials) verifies all
pre-existing build/source/documentation/TAP/standalone gates,
generates and verifies the complete explicit producer artifact
inventory, and uploads the checked bytes as one same-run/attempt
**one-day retained** handoff with a verified identity manifest.

Three groups of independently scheduled flavor jobs consume and
verify the same handoff:

- `bats[development|ordinary|minified]`: all Bats cases for that
  artifact, each with a distinct JUnit report.
- `bash43[development|ordinary|minified]`: the existing representative
  compatibility script in an actual Bash 4.3 container.
- `encryption[development|ordinary|minified]`: the filtered authenticated
  archive cases on a runner that supports GnuPG 2.4.7+ AES-256/OCB.

All groups use `fail-fast: false` so sibling evidence is retained.
A stable aggregate check succeeds only when preparation and every
required matrix job is `success`.  Reporter annotations are
supplemental, never a substitute for the real Bats exit code.

**This is a logical dependency graph.** Tasks #172/#173 may distribute
shared setup between existing jobs and new jobs provided every
listed gate and result survives unchanged.

### Release workflow

`version` calculates exactly one SemVer candidate via the existing
pinned action with `create_tag: false`.  `release-prepare` validates
maintained source, prepared dependencies, builds the single exact
versioned artifact inventory, verifies it, and produces one immutable
same-run/attempt handoff.  Release Bats and Bash 4.3 matrices use
that verified handoff.  A strict aggregate gate verifies all required
jobs.  The final least-privileged **publication-only** job verifies
the exact same bytes again, attests them, and then creates the
release/tag last.

Only the final job receives write permissions for contents,
attestations, and OIDC.  All untrusted PR executions are excluded
from privileged publication.  The existing semantic-version and
concurrency policies remain unchanged.

## Handoff integrity and reproducibility

The manifest is prepared from the checked-out workflow commit and
one effective build version, never from a path supplied by a PR or a
previous workflow.  Minimum identity fields are `github.sha`,
`github.run_id`, `github.run_attempt`, effective version,
build commit/date and an explicit expected list of executable
basenames/digests.  Preparation publishes those expected identity
fields as job outputs; downstream validation compares the downloaded
manifest to those outputs and the local workflow context.

Each downloader checks exact expected names, counts, executable
shape and matching `.sha256` sidecars before running anything.
A missing, stale, mismatched or changed file fails the job; retries
must not accept artifacts from a different run attempt.  Do not
use `actions/cache`, mutable tags, or an external release URL as an
authoritative handoff.  Review and pin any newly introduced Actions
by full commit SHA.

The test-only Make target introduced by #171 must **not** call the
ordinary `make build`/`FORCE` target on a downloaded artifact.
The existing local `make test` and `make test-report` behavior
is unaffected, including all three local JUnit files.  Selected
flavors are strict literals, not arbitrary paths or shell commands.

## Gate preservation map

| Current requirement / evidence | New owner | Failure behavior |
| --- | --- | --- |
| Build fails offline without prepared mktext | Ordinary `prepare` | Abort before matrix |
| Docs fails offline without prepared adrctl | Ordinary `prepare` | Abort before matrix |
| `make check` and source lint/syntax | Preparation in both workflows | Abort before matrix |
| `make deps`, `make deps-check` and pin verification | Preparation in both workflows | Abort before matrix |
| `make all` after fresh generated state | Ordinary `prepare` | Abort before matrix |
| Three executable shapes and each current `.sha256` | Preparation + each consuming runner | Reject missing/extra/mismatch |
| No stale `.256` companions and deterministic rebuild | Ordinary `prepare` | Abort before matrix |
| `make docs`/generated ADR index/ignored clean state | Ordinary `prepare` | Abort before matrix |
| Filename template TAP smoke | Ordinary `prepare` | Abort before matrix |
| Dated-backup publication TAP smoke | Ordinary `prepare` | Abort before matrix |
| Read-only dated recovery / fault TAP smoke | Ordinary `prepare` | Abort before matrix |
| Guarded retention TAP smoke | Ordinary `prepare` | Abort before matrix |
| Full Bats all flavors | Three Bats matrix legs | Each complete and independent |
| Distinct JUnit XML and test report publication | Each Bats matrix leg | Real Bats exit failure authoritative |
| No-vendor standalone help/version/negative public checks | Ordinary `prepare`, after built bytes verified | Reject broken artifact |
| Bash 4.3 compatibility across all three | Three Bash 4.3 matrix legs | Each must succeed |
| Authenticated AES-256/OCB actual GnuPG tests | Three encryption legs on supported runner | No skipped or incomplete suite |
| GnuPG TAP filtered case inventory (`>=20` per flavor) | Each encryption leg | Must meet original threshold |
| Release SemVer calculated once, no early tag | Release `version` | No publication |
| Release syntax/inventory/checksums | Release preparation + consumer + publisher | Reject mismatch |
| Exact tested release bytes, attestations | Release publisher after aggregate success | No tag until attestation passes |
| Release tag and all assets | Final privileged release-only stage | Must be last |
| All required statuses including skipped/cancelled | Stable aggregate check | Not green on partial success |

This map describes **existing obligations**, even when tasks
redistribute them between jobs.  No row may be removed because
it seems slow.  Task #54 under the separate-client story may
extend the inventory and require client-specific tests independently.

## Result and failure-injection matrix

| Injected condition | Expected required workflow result |
| --- | --- |
| Bats failure only in development / ordinary / minified | Overall failure; other two reports available |
| Missing/empty JUnit for one selected variant | Overall failure, not silent success |
| Reporter action fails / annotations unavailable | No green aggregate without required evidence |
| One test matrix leg skipped or cancelled | Aggregate failure or cancelled workflow |
| One Bash 4.3 variant fails or never starts | Aggregate failure or cancelled workflow |
| Missing GnuPG feature on crypto runner | Crypto leg failure |
| One encrypted test skipped, or positive count below current inventory | Crypto leg failure |
| Wrong-run/attempt handoff or missing artifact | Consumer failure before executing script |
| Wrong digest, missing sidecar, extra file, mismatched version/commit | Consumer and publisher failure |
| Failure of offline dependency/docs negative check | Preparation fails, no green aggregate |
| Release suite fails after valid build | No tag or release |
| Attestation fails after passing tests | No tag or release |
| Publication job lacks or misuses required credentials | Publication fails; no false success |
| Client executable appears during milestone #6 | Product inventory updated explicitly; client not tested as producer flavor |

Failure tests should be implemented as disposable, controlled
workflows/faults without pushing malicious production tags or
rewriting existing released assets.  The changed GitHub Actions
job graph should not require weakening branch-protection rules.

**Required-check administration limitation:** the integration used
during design cannot read branch protection (HTTP 403).  Review
required-check identities with a repository administrator before
renaming or replacing an existing required job.  A reported
aggregate success has value only if it is actually required by
the intended protected-branch policy.

## Timing, resource and storage measurement

Task #174 owns the measured before/after evidence.  For comparable
successful runs (prefer repeated runs of similar source/tests on
the same trigger and GitHub runner families), record:

- Workflow trigger, source SHA, run and attempt, elapsed wall time,
  time to visible green, and critical-path stage durations.
- Preparation, Bats, Bash 4.3, encryption, aggregation and
  release/publisher job start/finish timestamps.
- Sum of actual job runner durations as an **estimate** of runner
  usage, and real billable minutes if billing data is available.
- Compressed upload bytes, number of downloads, retention in days,
  approximate `bytes * retention_days`, and billable storage data
  where available; exclude JUnit display reports if not retained.
- Re-runs, cancellations, failure behavior, and percentage of
  total wall time consumed by setup/handoff versus test execution.

Record absolute observations and differences, not a guessed
threefold acceleration.  Compare no fewer than three complete
successful runs per configuration when feasible; label weaker
samples honestly.  A slow runner allocation or unrelated network
failure is not proof that a topology is intrinsically slower.

If measured median elapsed time does not improve or total
runner-minutes/storage costs rise disproportionately, revisit
the shared-build choice through a focused follow-up, including
the independent-build alternative.  Do not weaken correctness
requirements to meet a performance target.

## Scope boundaries and implementation order

1. #170: ADR-036, this contract and current decision map only.
2. #171: exact single-flavor Make interface without rebuilding a
   verified cross-job handoff.
3. #172: three full Bats CI jobs and stable strict aggregate gate.
4. #173: Bash 4.3 and encryption flavor matrices with real crypto checks.
5. #174: release verification/publishing matrix and measured results.

One issue, one focused PR; the story is accepted only after
independent evidence of all its acceptance criteria.  No client
runtime functionality, cloud accounts, DNS, archive format,
test reductions or live-service invocation belongs to this story.

