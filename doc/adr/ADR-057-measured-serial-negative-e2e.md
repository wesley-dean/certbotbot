# ADR-057: Measure Real Negative-Case Costs Before Isolated Parallel E2E Workers

Date: 2026-11-04

## Status

Accepted

By repository convention, this decision becomes operative upon review and
merge of technical task #276's pull request, not by publication of the
draft alone.

## Decision

Retain **serial** execution for all seven required negative scenarios in the
default, final-head, push-triggered isolated Pebble/SeaweedFS acceptance
harness. Add independently checked, bounded elapsed-seconds receipts for
each of those existing serial negative cases, including the real fault
operation and the **independent authoritative SeaweedFS object readback**.
Measure the fault and verification work, not just an isolated command.
Keep the existing total `seven-negatives` timing and full gate receipts.

For each fixed scenario, the private host runner emits one literal
`negative_timing=NAME; elapsed_seconds=N; status=pass` line **only after**
the original expected-refusal and independent readback tests have
succeeded. The host CI runner must validate **exactly one** matching
receipt per required scenario with a 0–2100-second bounded integer before
reporting a sanitized fixed-name `timing_negative` result. Missing,
malformed, duplicate, failed, oversized or unknown timing records fail
closed rather than silently passing. Focused developer runs may report
one named scenario, but remain explicitly partial and cannot emit the
full-acceptance receipt. No provider logs, private account data, S3
object names or paths cross the host log boundary.

Do **not** introduce concurrent negative runner processes, shared
Pebble outage locks, object-key multiplexing, or additional Compose
projects in this task. Such a design is conditional on demonstrated
per-case timings **and** an independently costed isolation architecture;
the cost of obtaining independent, valid ACME account and SeaweedFS
certificate seed state must be included. A favorable single-stage
benchmark cannot authorize unsafe parallelism by itself.

## Context, Data and Assumptions

Approved story #274 sought faster feedback than the former serial
8–12-minute local E2E cycle. Technical task #275 implemented explicitly
partial developer targeting and bounded whole-stage timing. Approved
technical task #276 asks for a measured cost/benefit decision before
isolating and parallelizing negative scenarios.

A successful, fully required, push-triggered [run 41875100822]
(https://github.com/wesley-dean/certbotbot/actions/runs/41875100822)
for the #280 implementation recorded these **observed**, rounded
wall-clock times:

| Existing stage | Elapsed seconds |
| --- | ---: |
| Dependency preparation and verified build | 21 |
| Private project startup | 24 |
| Pre-isolation probe | 41 |
| Positive lifecycle, including real second order | 171 |
| All seven serial negative cases | 128 |
| Post-isolation probe | 41 |

The six reported stage durations sum to **426 seconds**; they exclude
some host/CI setup and final teardown, and are not a wall-clock CI
duration guarantee. Older successful runs 41782087486 and 41825667769
showed a 132–142-second seven-negative phase from observed log
timestamps, but did not expose individually bounded case timings.
These are historical reference observations, not paired A/B
measurements with identical infrastructure. First-hand case-by-case
timings from this task's final E2E run must be recorded separately in
the maintained benchmark report.

The negative-run host currently seeds one genuine CA account, verified
selected certificate and current SeaweedFS object, then exercises six
faults with separate fresh runner invocations and independent object
readback. The seventh, `acme-unavailable`, pauses the **same** owned
Pebble container and must explicitly unpause it before confirming the
unchanged object. Other negative cases may rely on that Pebble instance
and on exactly the same current-object digest and metadata. The
positive lifecycle and second real ACME order are stateful and must
remain serial under ADRs 047, 049 and 054.

## Security and Trust Boundary

Assets: one authoritative synthetic SeaweedFS certificate archive, the
native Pebble account/order history, canonical staging TLS root,
independent readback evidence, no-egress isolation, and private runner
logs and account material.

The trusted computing base includes the checked-in host runner,
bounded receipt validator, literal Compose manifest, private Docker
engine, pinned images, and verification performed inside disposable
runner containers. An untrusted or malformed provider log is input to
the timing parser; it is never forwarded verbatim to CI. The parser
accepts only the seven known scenario names and bounded unsigned
seconds, and **cannot** convert timing evidence into an issuance,
object-integrity, isolation or cleanup success receipt.

A concurrent worker sharing the Pebble instance would be disabled by
another worker's `docker pause`; shared current S3 object keys,
nonunique paths, order counts and Compose cleanup could invalidate
failure isolation or allow a race to fabricate apparent success.
Run cancellation or timeouts could strand paused Pebble or partially
updated object state. Separate workers would therefore require unique
Compose project names, internal subnets, independent CA and SeaweedFS
state, separate object identity, independently authenticated seed
state and scoped recovery, with no reference to host/public AWS
credentials. These protections are **not** established by the
current harness.

The existing no-egress, AWS credential refusal, private container
filesystem boundaries, fake Route53, real native Certbot/Pebble
transactions and SeaweedFS readbacks remain mandatory. No DNS-01
challenge validation or actual live AWS/Let's Encrypt behavior is
claimed. Compromise of the host Docker engine is outside the proof.

## Alternatives and Cost/Benefit

1. **Parallelize the seven existing cases on the shared fixture.**
   Rejected as unsafe: the Pebble-outage case can break other requests
   and the remaining cases can contend on remote object identity.
2. **Fan out all seven to fully independent Compose projects.**
   Deferred pending measured benefit. If each worker must repeat the
   measured 171-second positive lifecycle **serially after** the main
   positive stage, setup alone exceeds the currently 128-second
   negative phase, before additional startup (24 seconds on the
   reference run), image caching and teardown. Concurrent fixture
   preparation overlapping the main lifecycle could reduce that
   setup penalty, but would risk resource contention and has not
   been measured. This is an **illustrative conditional cost model**,
   not a measurement of a working seven-project implementation.
3. **Clone only the current S3 archive into separate object keys on
   one shared project.** Rejected because it does not isolate the
   Pebble outage, CA order state, network topology or Compose cleanup.
4. **Run six failures concurrently, then pause Pebble for the seventh.**
   Deferred because the six still share mutable service and archive
   state and the specific inter-worker isolation proof is absent.
   A mutex on `docker pause` alone would not fix shared S3 state.
5. **Retain serial execution, add per-case benchmarking, and use the
   existing partial debug selector for repeated hot-spot investigation.**
   Accepted as an inspectable, low-complexity choice that does not
   diminish test coverage.

The maximum possible suite-level saving from parallelizing only the
seven-negative stage is strictly **less than the entire observed
128-second stage**, before any extra fixture overhead. The actual
potential saving depends on the longest individual case and on
validated isolation; neither may be invented. Measurements must
guide any future approved proposal.

## Consequences, Verification, and Reconsideration

No production CLI, certificate lifecycle, artifact, S3 backend, GPG
behavior, AWS/ACME authority, or public released Docker image changes.
The full CI stage continues to run all seven cases in the same order,
require each original remote-unchanged receipt, one full-suite receipt,
post-isolation no-egress proof and complete project teardown. The only
new output is nonsecret, fixed-name bounded performance evidence.

Unit/Bats tests must prove correct timing reporting, absent/malformed/
duplicated/failed/oversized receipt refusal, a strict known-name list,
and that no partial run can satisfy full acceptance. A real final-head
Docker E2E CI run must pass before claiming engine-backed validation.
The benchmark report must cite exact run IDs and distinguish observed
full-stage and individual durations from hypothetical concurrency
estimates; it must never claim an unmeasured speedup.

Reconsider parallel execution only if subsequent timing observations
show a sufficiently dominant subset and a separately approved design
proves independent Pebble, network, SeaweedFS state, object keys,
cancellation recovery, no-egress, all seven negative receipts and
meaningfully lower **measured full-suite** wall-clock time than the
serial final-head baseline. Preserve a mandatory serial fallback.
If no demonstrated benefit exists, do not expand the test runtime's
trusted computing base solely for apparent concurrency.

## Related Decisions

ADR-015 and ADR-016 on dependencies and threat boundaries;
ADR-043 on separately authorized real-provider tests;
ADR-046/047 on the sealed local E2E trust boundary and DNS-01
validation bypass; ADR-048 on push-triggered CI;
ADR-049 on one real second ACME order;
ADR-054 on native metadata stabilization;
ADR-055 on fixed synthetic Route53 selection.
