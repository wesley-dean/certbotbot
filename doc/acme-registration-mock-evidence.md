# Mocked ACME Registration Continuity Evidence

Status: **mock-only acceptance contract for task #59**.  This file
describes the synthetic evidence provided by
[`tests/register-continuity.bats`](../tests/register-continuity.bats).
It is not a report of live ACME, IAM, S3, or Route53 interoperability.

## Test Boundaries and Evidence

The complete ordinary/development/minified producer artifact is invoked as
a process for each test, as required by ADR-009 and ADR-041.  A modified,
**opt-in** `lifecycle-fixture.bash` mock handles the external `aws` and
`certbot` command boundaries.  Its normal issuance/renewal behavior is
unchanged when registration mode is not explicitly selected.

Each registration, issuance, and renewal invocation uses a different private
temporary workspace.  A synthetic local file acts as one persistent S3
object across invocations.  Real GNU tar/gzip create and inspect the exact
published archive; real local OpenSSL creates self-signed test certificates
to exercise the ordinary certificate packaging and verification stages.

The following observable properties are tested:

| Contract | Mock evidence |
| --- | --- |
| Explicit registration | Only `certbotbot register` invokes mocked `certbot register`; the issuer fails when a required seeded account or archive is missing |
| Account identity continuity | The synthetic account identifier is passed to first issuance and unchanged account private-key and registration files survive the independent-runner S3 read/issue/write cycle |
| Existing account and lineage | Second registration reuses the recognized account, preserves published bytes and existing lineage, and performs no PutObject |
| Environment isolation | Production and staging archive account paths are distinct; a foreign CA account and ordinary production issuer reject staging state |
| Existing accountless object | Registration preserves allowed existing content and requires the matching observed ETag on the update |
| Concurrency and uncertainty | New-object writes require `If-None-Match`; existing-object updates require `If-Match`; conflicts fail, and a lost response is never reported as success |
| Fail-closed behavior | Duplicate accounts, corrupt archives, contact mismatch, denied/ambiguous reads, and partial/failed registration cannot authorize publication |
| Secret minimization | Synthetic private-key markers, mocked cloud error tokens, and contact email do not appear in user-facing failure output |

The tests deliberately assert *both* positive state and the absence of
forbidden Certbot calls, S3 writes, private-data echoes and success claims.
They also reuse the public lifecycle mock for unchanged issue/renew contracts
instead of creating a second independent implementation of certificate
issuance behavior.

## Limits

These tests do not create a real Let's Encrypt registration.  Synthetic
`private_key.json`, `regr.json`, `meta.json`, account IDs and self-signed
certificates prove structural persistence, local tool orchestration and
identity-byte continuity only.  The Certbot account-recognition response
is mocked, so it does **not** prove that an actual Certbot installation
will recognize a registered account in a new runner or that Let's Encrypt
will accept subsequent authenticated ACME requests.

Similarly, the simulated ETag and conditional writes prove expected
argument construction and local failure handling, not actual AWS S3
concurrency or IAM behavior.  No live credentials, actual Route53
changes, registration emails, or ACME requests belong in untrusted PR CI.

The accepted production-only issuer still cannot issue staging
certificates.  A separate CA-bound issuer decision is needed before
milestone #4 staging issuance can be represented as supported behavior.
Milestone #4 owns authorized real staging evidence and must explicitly
differentiate remote outcomes from these synthetic tests.

See [ADR-041](adr/ADR-041-explicit-acme-account-registration-and-state-initialization.md),
[the registration contract](acme-account-registration-contract.md),
and [the public lifecycle](mvp-public-lifecycle.md).
