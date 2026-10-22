# ADR-021: Fail-Closed Read of the Seeded S3 Archive

Date: 2026-10-22

## Status

Accepted

## Decision

The first-party AWS S3 adapter reads exactly the operator-selected bucket and
object key using AWS CLI v2. A successful read stages bytes in a new, private
workspace owned by the caller. The adapter never extracts the archive, runs
Certbot, creates buckets or objects, or performs remote writes. Its return
code distinguishes a confirmed missing object from unavailable state and a
failed/incomplete download.

The adapter makes `s3api head-object` then `s3api get-object` requests. A
404 from HeadObject is not sufficient to prove the selected key is missing,
because access controls and bucket state can affect error responses. A 404
must be corroborated by a successful `s3api head-bucket` call. Only this
combination is reported as a missing seeded object; it is still a fatal
prerequisite failure, not permission to create a new archive. Any other
failure, including 403, expired credentials, missing CLI, bucket uncertainty,
transport errors, or incompatible AWS output, fails closed.

## Context and drivers

MVP #8 requires the entire certificate/account archive to exist in S3
before execution. An account-only archive is valid; an absent object is not.
One configured key defaults to `latest.tar.gz`. The application will
eventually restore the downloaded bytes under an isolated Certbot config
directory and validate them before issue, renewal, or publication.

The selected directory must have restrictive permissions; temporary outputs
and captured AWS error messages must not be printed. AWS CLI receives its
normal credential and region configuration rather than an invented credential
parameter. The externally supplied AWS CLI executable is part of the trusted
computing base and must be installed separately; it is not downloaded during
`make build`.

## Preconditions, results, and non-promises

- AWS CLI v2 is required; its diagnostic formatting is not a structured API.
- Caller has suitable S3 GetObject and ListBucket permissions, and IAM
  credentials are already configured. PutObject will be required by the
  later publication phase, not by this adapter.
- Caller provides a newly created, private workspace. The adapter creates
  a private temporary output within that workspace and only moves it into
  its final staging name after a successful nonempty download.
- Return values: 0 staged, 64 invalid local input, 66 positively missing
  object, 69 unavailable or ambiguous remote state, 74 failed or empty read.
- A zero status means only that bytes were downloaded; it does **not**
  mean the tarball was safe, complete, decryptable, or contained a usable ACME
  account. The archive validator and Certbot integration are independent
  downstream gates.
- The S3 object may be replaced between HeadObject and GetObject; this
  adapter does not provide a distributed lock, immutable snapshot, or
  transaction. The operator externally serializes writers as required by
  ADR-020.

## Alternatives considered

**Treat any HeadObject 404 as definitive absence:** rejected because it
can also describe missing buckets and cannot validate prerequisites.

**Treat 403 as a missing key:** rejected: S3 may return 403 rather than
404 when the caller lacks ListBucket. An access failure must never
authorize fresh issuance.

**Use a high-level recursive S3 copy or prefix discovery:** rejected;
the MVP operates on exactly one selected object and must not infer a key.

**Use stdout as the downloaded archive:** rejected; binary sensitive
material and AWS diagnostics would cross the CLI output boundary.

**Use local `/etc/letsencrypt` as a fallback:** rejected under ADR-020;
the state must be portable across independent runners.

**Introduce a Python runtime or implement tar validation in this adapter:**
rejected; extraction is a distinct security-sensitive gate with its own
approved technical tasks and review surface.

## Failure and threat model

| Stage | Failure | Permitted remote write | Outcome |
| --- | --- | --- | --- |
| Local validation | Invalid workspace/args or missing CLI | None | Nonzero |
| HeadObject | 403, 400, timeout, unknown | None | Unavailable |
| HeadObject | 404 and HeadBucket succeeds | None | Missing object |
| HeadObject | 404 and HeadBucket fails | None | Unavailable |
| GetObject | Failure or zero bytes | None | Read failure |
| Staging | Local move fails | None | Read failure |
| Archive validation (later) | Invalid archive/account | None | Abort |

All error messages issued by the adapter are fixed, non-secret text.
Captured external diagnostics are deleted before return. The local
workspace must be cleaned by its owner after the read/restore sequence;
this adapter does not remove a workspace that it did not create.

## Consequences and follow-up

The S3 read interface is independently testable using an executable AWS
CLI mock without access to cloud services. Its insertion into the public
certificate lifecycle follows after safe archive validation, isolated
workspace setup, and account checks are implemented under #29, #34,
#36, and #37. A successful adapter read is intentionally not interpreted
as successful issuance.

## Related decisions

ADR-020 fixes the one-archive existing-account requirement and rejects
automatic account creation. ADR-015 and ADR-016 govern dependency and
network authority, ADR-008 governs documentation/test sequencing, and
ADR-019 governs technical-task approval.
