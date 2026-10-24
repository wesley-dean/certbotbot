# ADR-036: Parallel Producer Validation with Verified CI Artifact Handoff

Date: 2026-10-24

## Status

Accepted

## Intent and Documentation Posture

This decision establishes the trust, scheduling, build-identity and failure
contract for approved story #169 and design task #170 before any workflow
implementation.  It is a project-specific refinement of the existing
three-flavor testing and late-tagging architecture, not permission to remove
tests or change the issuer.  Tasks #171-#174 implement and verify this design
in separate reviewable pull requests.

## Context

The project distributes three distinct representations of one producer:
`certbotbot.dev.bash`, `certbotbot.bash` and `certbotbot.min.bash`,
each with an adjacent `.sha256` file.  Every representation must pass the
same Bats public behavior tests.  ADR-035 separately authorizes one future
`certbotbot-client.bash` executable, which is **not** a fourth producer flavor
and requires a separate client-specific test contract.

As of this design decision, `Makefile` implements `make test` and
`make test-report` by iterating over the three producer variants in
serial.  `.github/workflows/test.yml` has three already independent jobs,
but its primary Bats/JUnit step runs all three flavors sequentially,
as do the Bash 4.3 and authenticated-encryption flavor loops inside
their respective jobs.  The release `semver.yml` workflow similarly
runs serial `make test` and Bash 4.3 loops in one privileged job.

This is a latency cost, especially while reviewing a sequence of focused
pull requests.  It is not evidence that one variant may be skipped.
The existing workflows also perform negative dependency/bootstrap checks,
generated documentation and ADR navigation, deterministic build validation,
checksum checks, independent-runner behavior checks, targeted TAP diagnostics,
authenticated GnuPG AES-256/OCB acceptance, and late release publication.
Their value must not be traded away for a faster green check.

The repository has previously experienced high GitHub Actions storage
utilization.  A matrix that builds and transfers binaries without bounded
retention could repeat that problem; a matrix that rebuilds everything on
every runner could instead multiply network traffic, setup overhead and
runner-minutes.  The cost decision must cover both dimensions.

## Decision Drivers

1. Shorten elapsed time to reliable PR and release feedback.
2. Preserve complete observable behavior and crypto/runtime coverage.
3. Validate **actual assembled executable bytes**, not only source.
4. Preserve one authoritative release version and exact tested/published bytes.
5. Keep credential-bearing tag/attestation operations downstream of all tests.
6. Produce independent per-flavor diagnostics even when another flavor fails.
7. Limit cross-job state, artifact storage, permissions and new dependencies.
8. Preserve stable Make interfaces used locally and in CI.
9. Make measurable improvements and regressions visible rather than guessed.

## Decision

### Shared verified build; independently scheduled flavor validations

For each workflow invocation, a **single, read-only preparation job** SHALL
perform the existing prerequisite checks and assemble the three producer
artifacts, plus all checksum companions, once.  The preparation job SHALL
verify the complete expected release-file inventory, checksums,
deterministic-build behavior, and that generated executables are standalone.
It SHALL expose a small verified handoff containing the intended executable
files and matching sidecars for the current run.

Downstream per-flavor GitHub Actions **matrix jobs** SHALL download only that
same-run handoff and independently verify its artifact identities and
checksums *before execution*.  Each job SHALL execute its precise assigned
flavor against the relevant unchanged test contract.  The full Bats matrix
has exactly these three producer flavor identifiers:

| Flavor identifier | Executable | Report basename |
| --- | --- | --- |
| `development` | `certbotbot.dev.bash` | `bats-development.xml` |
| `ordinary` | `certbotbot.bash` | `bats-ordinary.xml` |
| `minified` | `certbotbot.min.bash` | `bats-minified.xml` |

The flavor selector SHALL use an explicit validated enumeration rather than
a glob, free-form pathname, shell evaluation, or index into an unrelated file
list.  The future client is not included in this producer matrix.

The ordinary test workflow SHOULD use one shared preparation job plus
independently scheduled **full Bats**, **Bash 4.3** and **authenticated
encryption** matrix jobs, with environments and prerequisite tools specific
to each suite.  GitHub may schedule matrix entries subject to runner
availability; the architecture requires concurrency eligibility, not a
guarantee of instantaneous start.  Each matrix uses `fail-fast: false`
so one failed member does not cancel sibling evidence.

### Build handoff identity and lifetime

Every handoff SHALL be scoped to the **same workflow run and attempt**, not
a reusable cache, a different workflow, a previous run attempt, a release
download, or the mutable contents of another PR.  The preparation job
SHALL emit and upload an explicit manifest containing at least:

- exact source commit SHA (`github.sha`) and GitHub run ID/attempt;
- effective version and build provenance inputs;
- the expected artifact names and digests (one checked sidecar per script);
- the number of files expected for this product generation; and
- an explicit distinction between producer and separate-client deliverables.

The selected handoff shall contain **only** verified `dist/` executable
release files and checksum companions plus any minimal manifest needed by
the downstream tests.  It shall not upload `vendor/`, credentials,
certificate fixture secrets, test workspaces, compiled documentation, the
Git checkout, or entire runner directories.

Use a short-lived **one-day** GitHub Actions artifact retention window and
a unique same-run/same-attempt artifact identity.  Verify manifest identity
against trusted workflow-context values and outputs from the preparation
job, then verify **all** expected file checksums on each consuming runner.
Do not rely on a manifest supplied solely by the downloaded artifact to
authorize itself: its expected source/version/run identity originates in
the prior preparation-job outputs and workflow context.  Check unexpected
files, missing sidecars, duplicate names, and digest mismatches.  The
actions that perform artifact upload/download SHALL be pinned to reviewed
full commit SHAs in keeping with existing workflow practices.

The contents originate from the checkout associated with the workflow
run, not an arbitrary caller-provided artifact identifier.  The handoff
is integrity transport **within the trusted workflow execution**, not a
claim that a SHA-256 sidecar proves a remote publisher's identity.
A pull-request workflow MUST NOT elevate privilege by accepting untrusted
artifact data into an unrelated trusted `workflow_run` publisher.

If measured artifact overhead or storage costs outweigh benefits,
a later focused decision MAY switch ordinary PR checks to identical
independent verified builds per runner.  Such a change still must keep
checksums, flavor identity, all gates, and release-byte fidelity.  The
initial approved topology is one shared, verified build.

### Make as the stable local interface

Preserve `make test` and `make test-report` as all-producer-flavor local
interfaces, with their existing broad behavior and JUnit filenames.
Task #171 SHALL introduce narrow single-producer-flavor test/report
targets or an equivalent explicit Make interface.  Exactly one selected
flavor is tested for a matrix entry, and a failed Bats invocation must
remain nonzero.  The new interface must work with **already built**,
checksum-verified handoff files; invoking it in a test matrix must not
quietly regenerate bytes and then claim the downloaded handoff was tested.

Because the current `make test` target depends on `build` and the
development artifact uses `FORCE`, task #171 MUST distinguish ordinary
local build-then-test behavior from verified-artifact test-only mode,
rather than relying on Make's timestamp logic to avoid reconstruction.
Do not replace source validation or dependency preparation with
an untrusted runner-local cache.

### Workflow-specific validation and reporter semantics

In `test.yml`, retain the present offline-build and offline-doc failure
assertions, `make check`, pinned `make deps` and `make deps-check`,
`make all` from a fresh state, expected shape of the three producer
flavors, checksum companions and stale-`.256` rejection, deterministic
rebuild comparison, `make docs`/ADR index assertions and clean Git
state, the focused filename/dated-backup/recovery/retention TAP checks,
and negative standalone-without-vendor checks.

The full Bats matrix SHALL run the complete test inventory once per
producer flavor with a distinct JUnit report.  A reporter step MAY use
`if: always()` and `continue-on-error` only to preserve diagnostic
upload or annotations; it must not determine the authoritative test
outcome or hide missing/empty reports.  Failure to execute a required
test, a missing report, invalid test XML or a reporter failure that
prevents required evidence from being available is a failed quality
gate, not a green test.

The Bash 4.3 matrix SHALL execute the existing
`tests/compat-bash43.bash` contract against each checked artifact in
the minimum supported Bash image.  Its environmental isolation and
runtime version must be demonstrable.

The encryption matrix SHALL retain the environment with proven
GnuPG >=2.4.7 AES-256/OCB support, existing TAP filters, the requirement
for at least the currently enforced positive case inventory (20 passed
filtered cases per artifact at design time), and **zero skipped** gated
encryption cases.  Any mismatch, missing GnuPG capability or unchecked
filter is a failure.  No matrix may silently substitute Ubuntu 24.04's
older GnuPG for the supported crypto environment.

### Fail-closed aggregate and required check identities

GitHub Actions' `needs` DAG SHALL separate shared preparation from the
independent validation jobs and a **stable final aggregate gate**.
The gate SHALL run with an `always()`-style result inspection after its
dependencies complete, and succeed only when **every explicitly
required predecessor is `success`**.  Any `failure`, `cancelled`,
`skipped` or missing expected result SHALL fail the gate.  The gate
must never use a permissive `contains(..., 'success')` expression
which could treat partial success as global success.

The aggregate checks shall preserve or deliberately migrate repository
required-check identities.  Current job names include
`Check, build, and test`, `Bash 4.3 compatibility`, and
`Authenticated archive interoperability`.  GitHub branch-protection
settings were **not readable with the available integration** at design
time (403).  Task #172 must verify required-check configuration with
repository administration before changing job names, or preserve an
equivalent stable check identity and document any necessary manual
settings update.  Never claim branch protection has been verified when
it has not.

Cancellation of an entire workflow is not success.  If a workflow-wide
cancellation prevents a downstream aggregate job from starting, the
overall workflow remains cancelled and must not be treated as green
by review or release automation.

### Release pipeline, privilege separation and late tagging

For `semver.yml`, calculate the semantic version **once** from the
intended source history with the existing pinned SemVer action and
`create_tag: false`.  Build and checksum **one immutable artifact
set** at that version/commit in an unprivileged preparation job.
Every release Bats/Bash 4.3 flavor matrix member SHALL test that
set, not an independently rebuilt variant with a changed version,
dirty provenance or different bytes.

Release acceptance SHALL require source checks, dependency checks,
exact expected build inventory, Bats against each producer flavor,
Bash 4.3 against each, checksums, provenance identity, and every
other governing release requirement.  The preparation and matrix
jobs SHALL have read-only repository access and no publication or
attestation authority.  A final **publication** job, after a
strict success-only gate, SHALL download the same run's validated
bytes, verify the original source/version/attempt manifest and all
sidecars again, attest those **exact bytes**, then create the tag and
release as the last operation.  The final job alone receives the
minimum required `contents: write`, `id-token: write`,
`attestations: write` and related release permissions.  All pinned
actions and credential exposure require task-specific review.

The publication gate shall reject a missing or cancelled test job,
invalid or missing handoff, mismatch between version and source
commit, checksum change, or unexpected extra release file.
Attestation success is a prerequisite, never a cosmetic side
effect after tagging.  The workflow keeps its existing versioning
and concurrency protections; new races between version calculation
and tag creation are not silently introduced as part of this story.

ADR-035 has already established that a future successful build will
contain eight release files, including the one separate client and
its companion.  Task #174 SHALL preserve the **current** expected
inventory and adjust to the actual state of main at implementation
time, so it does not hard-code an obsolete six-file total or
accidentally put `certbotbot-client.bash` through the producer
three-flavor test matrix.  All released executables must still be
tested according to their respective contract before publication.

### Performance and resource accounting

The initial objective is an independently measured reduction in elapsed
time-to-green while preserving evidence, rather than a guaranteed
threefold overall speedup.  Task #174 SHALL compare representative
successful workflow runs before and after implementation, with a
defined warm/cold-run and source-size context.  Record:

1. workflow creation-to-completion wall time and critical-path jobs;
2. start/finish times for each preparation, matrix and publication job;
3. aggregated billable runner-minutes (including setup and reruns);
4. handoff archive compressed size, number of uploads/downloads,
   retention in days and approximate byte-days of storage;
5. failed/cancelled rerun behavior and diagnostic visibility; and
6. whether extra setup/network/handoff time displaced serial test time.

Use job-run metadata and published billing data when accessible.
Do not describe rough sum-of-job-duration estimates as exact billed
usage, or infer storage pricing without billing evidence.  A
regression in overall wall time or disproportionate storage cost
triggers a review of the selected topology, not automatic removal
of required tests.

## Promises

- Every existing producer flavor receives its complete intended tests.
- A failed flavor, missing test or bad handoff cannot satisfy the
  workflow-wide success gate.
- The producer's local three-flavor Make commands remain available.
- Tests execute the exact same source/version artifact set intended
  for the eventual release.
- No publication authority is needed by the build or test matrix jobs.
- Release tagging remains conditional on all validation and attestation.
- Workflow artifacts are short-lived, scoped and explicitly verified.

## Non-Promises

- Matrices do not guarantee that GitHub provisions three runners
  simultaneously, nor do they guarantee reduced total runner-minutes.
- A checksum companion is not an independent signature or provenance
  service; it detects mismatches against the trusted build manifest.
- One-day retention still consumes storage and may incur upload,
  download and billing overhead.
- This decision does not change the number of producer artifacts,
  the content of tests, or the implementation of the separate client.
- It does not assume GitHub branch protection can be inspected by
  the existing limited-permission integration.
- This ADR alone does not create working matrix jobs or verify a
  performance improvement.

## Adversary and Failure Model

| Boundary | Threat / failure | Required mitigation | Residual risk |
| --- | --- | --- | --- |
| Repository checkout -> build | Wrong ref, dirty state or untrusted build input | Pin intended source SHA, dependency digests and provenance | Trusted tools can be compromised |
| Build -> Actions artifact | Truncated, wrong-run or replaced bytes | Same-run/attempt identity, exact explicit manifest, digest validation | GitHub Actions storage remains trusted infrastructure |
| Artifact -> test runner | Flavor confusion, stale files, unverified sidecar | Whitelist selection; verify all expected files/checksums | External runtime dependencies can differ |
| Matrix -> aggregate | Skipped/failed/cancelled result counted as green | `fail-fast: false` and all-required-success aggregate | A cancelled workflow may not run aggregation |
| Bats -> JUnit reporter | Reporter green when tests failed, absent XML | Test status authoritative; require expected report | Reporter errors can delay diagnosis |
| Crypto runner -> acceptance | Wrong GnuPG, filtered-away or skipped cases | Version/feature proof, no skips, minimum case inventory | Tests are bounded, not full crypto proof |
| Release test -> publisher | Rebuild different bytes or early tag | Immutable same-run validated handoff; final checksum/attestation | Concurrent main pushes still require workflow serialization |
| CI -> credentials | PR code obtains release authority | No credentials in PR validation; release-only privileged final job | Privileged release actions remain trusted dependencies |
| CI optimization -> account billing | Excess artifact retention or runner cost | One-day handoff, measure byte-days and runner-minutes | Cost varies with GitHub plan and execution load |

## Operational Constraints

- MUST use an explicit three-entry producer matrix; the client is separate.
- MUST retain the same Bats assertions and documented local Make behavior.
- MUST prove all necessary original gates are present in the new DAG.
- MUST verify the exact built bytes and sidecars on each consuming runner.
- MUST use no cross-run, cross-PR or persistent cache as artifact authority.
- MUST set short-lived handoff retention and review action pins.
- MUST keep matrix failures visible and gate all required results strictly.
- MUST retain Bash 4.3 and true authenticated-GnuPG acceptance checks.
- MUST calculate release version once and tag only after verification,
  attestations and final inventory checks.
- MUST withhold release credentials/permissions from test matrix jobs.
- MUST measure elapsed time and Actions cost without unsupported claims.
- MUST coordinate independently approved tasks and narrow PR boundaries.

## Considered Alternatives

### One independent full build on every matrix runner

This eliminates Actions artifact storage and handoff trust, and each
runner can verify its own local dependencies.  It was not selected for
the initial design because every full Bats, Bash 4.3 and encryption
matrix leg would repeat network-dependent preparation and assembling
all artifacts, potentially increasing runner-minutes, download load
and latency.  It remains a legitimate alternative if measurements
show the small verified handoff costs more.

### Keep one runner and launch three concurrent local Bats processes

This avoids persistent artifact transfer and some setup costs.  It
was rejected as the initial architecture because processes share
CPU, memory and filesystem resource contention on one runner,
complicate test-report isolation, and fail to provide three
independently scheduled/inspectable GitHub job results.  It remains
a possible local-only optimization outside this story.

### Run producer tests only on the ordinary artifact

Rejected under ADR-009.  Comment stripping and minification are
part of the shipped behavior and can introduce representation-specific
defects, so coverage cannot be exchanged for speed.

### Use a shared cache as authoritative test input

Rejected.  Mutable or cross-run cache identities can be stale,
tampered with, or incorrectly reused.  Caches may accelerate
dependency setup under their own reviewed trust rules but cannot
replace the exactly built release handoff.

### Permit the first failing matrix member to cancel siblings

Rejected.  `fail-fast: true` discards useful independent evidence and
can obscure whether the same defect affects all representations.

### Let the release publisher rebuild after tests succeed

Rejected.  A rebuilt script can differ from tested bytes due to
metadata, dependencies, environment or source changes.  The
publisher must attest/publish the tested handoff itself.

### Give the whole release workflow write permissions

Rejected as unnecessarily broad.  Running tests does not require
tag, release, or attestation authority; the privileged operation
belongs in the final success-gated job.

### Parallelize by adding a fourth "producer" job for the separate client

Rejected.  ADR-035 makes that command a distinct consumer executable
with different dependencies and behavior.  Client tests should form
their own explicit acceptance matrix when the client exists.

## Consequences and Compatibility

Workflow structure will gain preparation, matrix and aggregation
jobs, along with a verified one-day handoff that consumes finite
Actions storage.  Cross-job environment setup and transfer add some
overhead.  CI failures become easier to attribute to a particular
flavor, but required-check names and reporter permissions need care
to avoid making a red check disappear behind a renamed job.

Local developers keep the existing serial full-suite Make commands,
so no local invocation changes are forced by GitHub's schedule.
The release workflow gains a sharper privilege separation while
retaining the original SemVer calculation and late-tag rule.

The task sequence is deliberate: #171 defines the Make interface,
#172 updates the ordinary Bats matrix, #173 updates Bash 4.3/crypto,
and #174 updates release gating and records measured outcomes.
The story is complete only after its actual acceptance criteria,
not because these proposals were written.

## Source Lineage

Approved story #169 and task #170 authorize this specific design.
ADR-003 governs Make orchestration, ADR-006/012 govern producer
artifacts and checksums, ADR-009 requires complete behavior tests,
ADR-011 requires exact verified files and late tags, ADR-015/016
govern supply-chain trust and threat review, ADR-019 governs live
issue approval labels, and ADR-035 defines the separate client.

## Superseded Decisions

No existing Accepted ADR is replaced.  This decision **refines**
ADR-009's serial execution example by allowing identical all-flavor
coverage to be scheduled concurrently, and **refines** ADR-011's
single-job workflow implementation into a preparation/verification/
publication DAG.  Its exact tested-bytes and late-tagging mandates
remain fully binding.

## Open Questions and Follow-Ups

- Branch-protection required-check configuration cannot presently be
  read through the integration; task #172 must confirm the necessary
  stable required-check names with repository administration.
- Task #171 must define a verified-artifact testing mode which never
  triggers the `FORCE` rebuild rule and therefore keeps handoff
  identity meaningful.
- Task #172 must prove no unexpected Actions artifact exposure or
  storage explosion; task #174 will compare actual costs and time.
- Task #174 must reconcile any concurrent milestone #6 client changes
  with the live release inventory, without misclassifying the client.
- GitHub-hosted runner and action behavior may change over time;
  future changes must reverify pinning, permissions and result gates.

## Related Decisions

ADRs 001, 002, 003, 005, 006, 008, 009, 011, 012, 015, 016, 018,
019 and 035.  See [the parallel CI validation contract](../parallel-ci-validation-contract.md).

