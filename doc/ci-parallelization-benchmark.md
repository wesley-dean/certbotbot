# Parallel CI Validation: Baseline, Resource Cost, and Evaluation

Date: 2026-10-24. Owner: approved story #169, task #174.
Architecture: [ADR-036](adr/ADR-036-parallel-producer-verification-and-handoff.md).

## How to interpret this evidence

These measurements use **completed GitHub Actions runs retrieved from the
repository**, not estimates from the number of matrix jobs. A run's
`created_at` to `updated_at` interval is a practical approximation of
workflow wall time. Summing `started_at` to `completed_at` for its individual
jobs is a **raw runner-duration estimate**, not GitHub's actual billed
minutes: hosted-runner rounding, runner class/pricing, queue time,
retries, cancellation, allowances and billing adjustments may differ.

The observations below are real, but source commits, suite contents,
runner queues and simultaneous workflows differed. Two observations
per ordinary test configuration are **insufficient** to support a
stable causal or percent-speedup claim. The release change defined in
task #174 is a proposal until its PR is merged and the newly
structured release workflow completes. No post-#174 release result
is fabricated here.

## Serial release-workflow baseline (before #174)

All three sampled runs are successful `push`-triggered `Versioning`
workflows. Each had one `versioning` job, running version calculation,
build, three Bats variants in series, Bash 4.3 variants in series,
checksum verification, attestation and publication.

| Workflow run | Source | Workflow wall seconds | Job seconds (raw) |
| --- | --- | ---: | ---: |
| [40143181971](https://github.com/wesley-dean/certbotbot/actions/runs/40143181971) | `daa018c6` | 1,009 (16:49) | 988 |
| [40145247345](https://github.com/wesley-dean/certbotbot/actions/runs/40145247345) | `c9270b41` | 991 (16:31) | 987 |
| [40147536198](https://github.com/wesley-dean/certbotbot/actions/runs/40147536198) | `ee2aca16` | 1,009 (16:49) | 1,004 |

Median sampled serial release wall time: **1,009 seconds (16:49)**.
Median summed job time: **988 seconds (16:28)**. Those
medians apply only to the three runs listed.

### After #174 (required follow-up evidence)

**Pending until a successful run of the merged parallel release workflow.**
The release PR itself does not trigger `semver.yml`, which publishes
only from `main`. Do not create test tags or bypass its protected
publication gate merely to obtain a benchmark.

After the PR is merged, collect at least three comparable successful
main-branch release runs (or state clearly if fewer exist). Record:

- workflow run ID, commit SHA, attempt, trigger and result;
- candidate calculation, preparation/build, all six flavor checks,
  unprivileged gate, attestation/publication and final `versioning`
  status, with individual job durations;
- elapsed wall time, critical-path segments and raw summed job time;
- exact release artifact names, file hashes and attestation/release
  asset evidence;
- handoff compressed archive size, upload count and one-day retention;
- actual billed minutes/storage **only if authenticated billing
  evidence is available**, otherwise label calculations as estimates.

The baseline values above are not post-change measurements. The story
must remain open if verification remains outstanding.

## Intermediate ordinary test-workflow comparison

Task #172 moved full Bats from a serial three-flavor step into
independent jobs. The Bash 4.3 and encryption loops remained serial
at that stage. These results illustrate the tradeoff before #173's
separate crypto/compatibility matrix becomes effective.

| Configuration and run | Source | Wall seconds | Sum of job seconds |
| --- | --- | ---: | ---: |
| Serial Bats: [40143346282](https://github.com/wesley-dean/certbotbot/actions/runs/40143346282) | `daa018c6` | 705 (11:45) | 1,206 (20:06) |
| Serial Bats: [40145453982](https://github.com/wesley-dean/certbotbot/actions/runs/40145453982) | `c9270b41` | 998 (16:38) | 1,499 (24:59) |
| Parallel Bats: [40147536208](https://github.com/wesley-dean/certbotbot/actions/runs/40147536208) | `ee2aca16` | 545 (9:05) | 1,565 (26:05) |
| Parallel Bats: [40147638911](https://github.com/wesley-dean/certbotbot/actions/runs/40147638911) | `ee2aca16` | 551 (9:11) | 1,454 (24:14) |

The two intermediate parallel-Bats runs completed faster than the
two serial-Bats samples, while their **raw runner-second sum did not
consistently decrease**. They are not workload-matched repetitions,
and their samples are too small to infer a reliable improvement
distribution. The test workflow additionally runs separate
authenticated-encryption checks (which can dominate the critical
path) and may be queued concurrently with release and other checks.

### Observed critical-path details

- `40143346282`: serial `Check, build, and test` job **702 seconds**;
  authenticated-encryption job **483 seconds**; Bash 4.3 job
  **21 seconds**.
- `40145453982`: serial `Check, build, and test` job **995 seconds**;
  encryption **479 seconds**; Bash 4.3 **25 seconds**.
- `40147536208`: preparation **75 seconds**, Bats development
  **327 seconds**, ordinary **274 seconds**, minified **332 seconds**;
  encryption **535 seconds**, Bash 4.3 **19 seconds**, aggregate
  **3 seconds**.
- `40147638911`: preparation **65 seconds**, Bats development
  **333 seconds**, ordinary **237 seconds**, minified **251 seconds**;
  encryption **540 seconds**, Bash 4.3 **24 seconds**, aggregate
  **4 seconds**.

The Bats matrix in the intermediate version could finish before
serial encryption, limiting improvements to total Test wall time.
Task #173 seeks to reduce that bottleneck without dropping its tests.

### Actions artifact storage actually observed

The intermediate Bats matrix generated **one** handoff per workflow
run, with **one-day retention**. GitHub's artifact inventory
reported:

| Workflow run | Artifact | Reported compressed size | Retention |
| --- | --- | ---: | --- |
| `40147536208` | `producer-40147536208-1` | 88,527 bytes | 1 day |
| `40147638911` | `producer-40147638911-1` | 88,527 bytes | 1 day |

These sizes correspond to the same-source six producer files and
their small manifest, not the larger checkout/vendor tree. A
one-day-retained 88,527-byte upload is roughly **0.0844 MiB-day**
per run if retained for a full day. This is a storage-occupancy
estimate, **not a billing charge**. Upload/download traffic,
runner time and provider storage accounting are separate costs.

The proposed release workflow adds **one** separately scoped,
one-day retained handoff per successful preparation, not six
independent copies. The compressed size of an actual release
handoff and its billed cost must be measured **after** #174
merges; they cannot be assumed equal to the dev-version
workflow artifact.

## Reproducible collection and evaluation

For each comparable successful GitHub Actions run, collect the run
metadata and its jobs using GitHub Actions run/job APIs. Compare
workflow trigger type, source revision, runner OS, test inventory,
version output, and rerun attempt. Record the start/end time
of each meaningful job and calculate:

`wall_seconds = updated_at - created_at`

`raw_runner_seconds = sum(job.completed_at - job.started_at)`

`estimated_byte_days = artifact_size_bytes * retention_days`

Use actual billed usage reports if available. Do not call the
summed runner durations "billed minutes" in their absence.
For median comparison, prefer **at least three full successful
runs per configuration**; report sample sizes and min/max.
Keep cancellation/retry counts separate. Distinguish a
slow provider runner or a changing test suite from a reproducible
workflow regression.

Investigate the independent-build option if measured elapsed time
does not improve or the increment in aggregate runner-minutes,
storage/transfer and maintenance overhead is disproportionate.
That alternative requires review against ADR-036; it must
preserve verified bytes, complete coverage and late-tagging.

## Negative-release acceptance evidence

The new design includes executable, workflow-derived gate tests
in `tests/ci-release-matrix.bats`. They inject `failure`,
`skipped`, `cancelled` and empty results into each prerequisite,
including publisher outcome, without creating real tags. Existing
`tests/ci-producer-handoff.bats` independently covers malformed
manifest identity, wrong run/attempt, changed script bytes,
missing/mismatched checksum companions and invalid artifact
inventory. These are reproducible local **negative tests**;
they do not substitute for actual successful and failed GitHub
Actions integration evidence.

A passing Bats static topology check and the reviewable merged
workflow do not prove post-merge release success. A human
reviewer must confirm the real matrix results, exact published
bytes, attestation, and final release state before #174 and
the parent story can be marked complete.
