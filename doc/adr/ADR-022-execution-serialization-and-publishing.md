# ADR-022: Serialized Runs, Explicit Storage Limitations, and Failure-Safe Publication

Date: 2026-10-15

## Status

Accepted

## Intent and Documentation Posture

Provide deterministic sequential certificate processing and conservative publication while recording the deliberate absence of a cross-platform distributed lock in the first release.

## Context

Jenkins, GitHub Actions, native Bash, and optionally Docker can independently initiate the same certificate-management workflow.  All could read a shared common archive or overwrite a domain object.  Jenkins concurrency controls and GitHub Actions concurrency groups do not coordinate with each other.  S3 objects also have no native multi-object atomic commit.

## Decision Drivers

- Avoid overlapping work within one execution environment.
- Prevent failed issuance from replacing the last known good archive.
- Do not present CI-level serialization as a distributed lock.
- Keep storage backend interfaces able to acquire a future lock.
- Make first-run common account publication and partial failures recoverable.

## Decision

A single certbotbot invocation processes the requested certificate groups sequentially in an isolated private workspace and restores shared account state only once.  The first release uses a local host lock for native processes configured against the same archive collection, Jenkins `disableConcurrentBuilds()` for its example, and GitHub Actions `concurrency` controls for its example.  Operators MUST ensure only one independent writer is active for a given shared account/archive namespace; running both CI platforms against the same collection simultaneously is unsupported until a storage-backed lock is implemented.

The storage interface SHALL reserve a capability for future lock acquisition, renewal, and release.  Add a backlog item to design and test lease-based locking on the storage backend, including stale lock recovery, ownership tokens, expiry, and cross-provider semantics.  Do not implement a deceptively weak "lockfile exists" check as a guarantee.

Local generation and validation of all affected objects MUST complete before remote mutation.  No upload shall occur on invalid inputs, failed renewal, missing decryption credentials, or corrupted archives.  Publish in an order compatible with account references (shared state before newly dependent lineage state), and retain/recover previous published versions where possible.  There is still no claim of transactionality: any upload may fail after an earlier object succeeded.  A precise recovery/retry procedure is therefore required.

If missing storage state is confirmed via a not-found result, initialize a first-run archive; transport, authorization, and endpoint errors are fatal, not evidence of first run.  Destination object names must be stable and never derived from unsanitized shell tokens.

## Promises

- One process does not process multiple certificate groups concurrently.
- CI examples prevent overlapping jobs within their own defined concurrency scope.
- Local failure before publication does not overwrite an existing remote archive.
- Remote writes do not start until all selected certificate processing succeeds.

## Non-Promises

- There is no cross-platform or cross-host mutual exclusion in v1.
- S3 and compatible stores do not provide atomic multi-object transactions.
- A successful individual upload does not prove that every related object has the same generation.
- Local lockfiles alone cannot fence stale or compromised independent writers.

## Adversary and Failure Model

Duplicate jobs, delayed retries, crashed workers, stale state, API throttling, partial uploads, lost responses, object overwrite races, and accidental cross-environment credential use must be documented and tested where practical.  The storage implementation must distinguish missing, denied, and indeterminate results and never silently replace valid state after an indeterminate read.

## Operational Constraints

- Execution MUST be sequential within one invocation.
- Native and CI examples MUST prevent local concurrency where supported.
- Independent writers to one archive collection MUST be serialized operationally.
- Failed certificate validation MUST prevent remote publication.
- Storage locking MUST be a tracked backlog item and NOT claimed as implemented.
- The backend MUST preserve a seam for real storage-level leases.

## Considered Alternatives

Sole reliance on CI locks was rejected as insufficient across platforms.  Immediate per-domain upload was rejected because a later domain failure could produce avoidably partial published state.  A distributed lock now was deferred to keep the first release focused; a naive S3 key-existence lock was rejected because it does not solve leases, fencing, or crashed writers.

## Consequences

Operators must coordinate runs across platforms.  Multi-object write failure can require manual recovery.  Storage-level locking, version references, and transactional manifests are possible future enhancements, but are not silently assumed by the initial protocol.

## Related Decisions

ADR-019 defines shared and domain objects.  ADR-020 defines storage adapters.  ADR-021 defines encryption failures.
