# Local E2E negative-case parallelism benchmark

**Task:** #276; parent story #274; milestone 18.  
**Decision:** Serial full acceptance remains mandatory under ADR-057.
No parallel-mode speedup has yet been measured.

## Observed baseline

| Successful GitHub Actions run | Seven-negative phase |
| --- | ---: |
| [41782087486](https://github.com/wesley-dean/certbotbot/actions/runs/41782087486) | About 132 seconds, from log timestamps |
| [41825667769](https://github.com/wesley-dean/certbotbot/actions/runs/41825667769) | About 142 seconds, from log timestamps |
| [41875100822](https://github.com/wesley-dean/certbotbot/actions/runs/41875100822) | 128 seconds, explicit bounded phase receipt |

Run 41875100822 also measured preparation 21 seconds, private project
startup 24 seconds, pre-isolation proof 41 seconds, positive lifecycle
171 seconds, and post-isolation proof 41 seconds. The sum of these
six measured stages, including the 128-second negative phase, is
**426 seconds**. This is **not** the complete CI job wall-clock time;
host orchestration, teardown and GitHub runner setup are excluded.
Old runs and the newer run used different source snapshots and
potentially different runner conditions.

Seven negatives cost about 30% of the **measured phases**, not an
independently measured total job runtime.

## Per-case baseline from this PR

The new receipt includes the **actual fault operation** and an
**independent unchanged SeaweedFS object readback**, not merely
the first failed command. The final-head push-triggered Docker E2E
run must demonstrate exactly one bounded success timing for each of:

| Required negative scenario | Final-head observed elapsed seconds |
| --- | --- |
| `ca-production` | Pending successful final-head CI |
| `s3-unavailable` | Pending successful final-head CI |
| `corrupt-archive` | Pending successful final-head CI |
| `acme-order-rejected` | Pending successful final-head CI |
| `route53-unavailable` | Pending successful final-head CI |
| `s3-put-reject` | Pending successful final-head CI |
| `acme-unavailable` (Pebble paused and restored) | Pending successful final-head CI |

The aggregate includes one initial remote baseline setup outside
the individual case timings. No individual time, end-to-end A/B
comparison, or speedup is invented.

## Evaluated concurrency alternatives

**Concurrent use of the current shared Compose project is unsafe.**
The `acme-unavailable` case pauses the same Pebble instance
other workers could need, and all faults currently share one
authoritative current S3 archive and metadata. The checked
ACME order and S3 identity receipts depend on that ownership.

**A naive, sequentially prepared, independent Compose project
per worker is unlikely to help.** A complete positive lifecycle
cost 171 seconds and private service startup cost 24 seconds in
run 41875100822, greater than the entire 128-second negative
stage. This is an illustrative cost model **only when those
operations must be repeated after the main positive lifecycle**.
Concurrent seed preparation overlapping the main lifecycle
could reduce that cost, but would introduce resource contention
and additional isolation/cleanup risks and has not been measured.

Even perfect negative-stage parallelism could save at most 128
seconds in that baseline, **before** any worker preparation or
cleanup. The actual gain would be smaller because the longest
case remains on the critical path. A future proposal must measure
the actual full-suite wall-clock time of fully isolated workers,
not extrapolate from this upper bound.

For now, approved task #275 already provides partial developer
targeting through `--debug-negative=NAME`. That is the lower-risk
way to rerun a single failing scenario without another full
seven-case cycle; its partial result cannot satisfy full CI.

## Required safety and acceptance

Every default full run still requires all seven negative cases,
independent real SeaweedFS object readbacks, the selected CA
and real second ACME order, before/after no-egress evidence,
and project teardown. Timings are **additional** evidence:
one missing, duplicate, malformed, oversize or failed timing
must cause the gate to fail, never silently skip a scenario.

Only fixed scenario names and bounded seconds reach CI output.
Private provider logs, paths, credentials, account material,
and certificate data remain in disposable local scratch. No
performance timing establishes real DNS-01 validation, public
Route53/AWS S3, or Let's Encrypt interoperability.

See [ADR-057](adr/ADR-057-measured-serial-negative-e2e.md)
and the [local E2E harness guide](local-protocol-e2e-harness.md).
