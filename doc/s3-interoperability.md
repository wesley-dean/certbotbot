# S3 interoperability and independent-runner recovery evidence

This runbook describes **opt-in, test-only** evidence against a real
S3-compatible HTTP API instead of the mock executable used by normal Bats
tests. The implementation under test is each **shipped standalone certbotbot
artifact**. It does not enable the public issuer, Certbot import, Route53
changes, Let's Encrypt requests, or production S3 publication.

The suites use **synthetic, non-certificate bytes**. Their results can
establish S3 conditional-write interoperability and recovery behavior but
cannot establish certificate validity or ACME portability. ADRs
[039](adr/ADR-039-typed-s3-state-retrieval.md),
[047](adr/ADR-047-durable-s3-recovery-generations.md), and
[050](adr/ADR-050-conditional-latest-publication-and-recovery.md) govern
the existing implementation. [ADR-037](adr/ADR-037-gated-active-certbot-import.md)
continues to prohibit active import.

## Explicit authorization

These suites **create and delete temporary buckets**, upload synthetic
latest and recovery objects, and intentionally terminate a child with SIGKILL
in one scenario. They belong only against a disposable S3-compatible service
bound to loopback on the same machine. Cloud, LAN, and public endpoints are
refused. As of ADR-051, the installed GitHub Actions
`.github/workflows/s3-end-to-end.yml` provisions an isolated, digest-pinned
SeaweedFS service for pull requests and manual dispatch. No production AWS,
DNS, ACME, or GitHub environment secrets are used.

Conditional `DeleteObject --if-match` support is relatively recent, and
older S3 emulators and AWS CLIs may reject it. An unsupported emulator is
not a reason to weaken fail-closed conditional-write behavior. CI uses an immutable image digest and disposable fixture credentials
rather than a rolling, privileged, or operator-secret-dependent container.

Prerequisites: a prepared repository (`make all`); a supported AWS CLI that
has conditional PUT and DELETE API parameters; an isolated S3 service on
`127.0.0.1`; and **disposable service-only credentials** permitting creation
and deletion of the suite's own test buckets. Never supply live AWS credentials.

Example configuration for an already provisioned local emulator:

```bash
export CERTBOTBOT_S3_INTEROP_CONFIRM=yes
export ACME_ENVIRONMENT=staging
export S3_ENDPOINT_URL=http://127.0.0.1:9000
export AWS_ACCESS_KEY_ID=disposable-local-credential
export AWS_SECRET_ACCESS_KEY=disposable-local-secret
export AWS_DEFAULT_REGION=us-east-1
export AWS_EC2_METADATA_DISABLED=true
unset GPG_PASSPHRASE
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy

make test
make test-s3-interop
```

The local test host should have no unrelated AWS credentials or secrets and
must not send loopback traffic through an external proxy. The harness
refuses all inherited HTTP(S) or SOCKS proxy variables before the first
S3 command. The shell guard
runs before any AWS invocation. The Make target invokes both live API and
cross-runner suites for all three release artifact flavors.

## Evidence captured

The API suite at `tests/integration/s3-backend-interoperability.bash`
checks real create-only PUT, byte-for-byte GET, duplicate
`If-None-Match: *` rejection, ETag-bound replacement, stale ETag rejection,
and conditional deletion. It verifies the CLI operations on which the
internal publisher relies, without invoking issuer logic.

The independent-runner suite at `tests/integration/s3-recovery-evidence.bash`
sources each standalone artifact and exercises its **actual internal**
`certbotbot_latest_conditional_put`, `certbotbot_recovery_s3_put_new`,
`certbotbot_recovery_verify`, and `certbotbot_latest_recover` functions.

- **Full replacement:** exact old bodies are restored from a remotely
  verified previous generation by a new producer process.
- **Partial replacement:** only the common key is changed and subsequently
  recovered, leaving the unchanged domain body intact.
- **New collection:** absent old keys are restored to actual absence using
  ETag-conditional DELETE, not empty placeholders.
- **Unrelated writer:** a conflicting domain body causes the entire
  recovery preflight to refuse modification.
- **Terminated worker:** SIGKILL stops a writer after the first latest
  object. Its private filesystem is discarded before another process
  resumes recovery with the independently recorded generation and checksum.

Completed recovery is retried to confirm idempotence; the remote backup
generation is reverified after latest-key restoration. Each scenario gets
a fresh randomly named `certbotbot-interop-*` bucket, and the harness
attempts cleanup even after test failures.

## Evidence limits and operational follow-up

A successful run demonstrates the exercised API semantics **only for the
tested S3-compatible service version, AWS CLI version, and artifact**.
Record those versions, artifact SHA-256 values, the observed results, and
sanitized logs. Do not retain credentials or private certificate data.

This is **not** proof of AWS production S3 interoperability, registered
Let's Encrypt account reuse, successful real renewals, an active Certbot
import transaction, multi-object atomicity, distributed fencing, or
production release readiness. Separate authorized integration evidence,
external writer serialization, and the ADR-037 activation decision remain
mandatory. The product's normal certificate command continues to exit 69.

A failed bucket removal is an error and must be investigated on the
isolated service. Never reuse the test cleanup procedure on production
storage or on a bucket the harness did not create.
