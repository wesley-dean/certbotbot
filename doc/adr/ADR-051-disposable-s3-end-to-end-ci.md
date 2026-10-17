# ADR-051: Run Disposable S3 Storage End-to-End Tests in GitHub Actions

Date: 2026-10-17

## Status

Accepted

## Decision

Install a **nonproduction, credential-free-from-GitHub** end-to-end storage
test workflow at `.github/workflows/s3-end-to-end.yml`. The workflow runs
on pull requests and supports manual `workflow_dispatch`, with the smallest
permitted GitHub permission (`contents: read`). It runs the already maintained
`make test-s3-interop` target against all three standalone release artifacts,
using a self-provisioned, digest-pinned **SeaweedFS** container on the
ephemeral GitHub-hosted runner.

This is the **first enabled workflow for synthetic storage interoperability**,
not a change to ADR-044's inactive example for real ACME issuance. No AWS
cloud credentials, OIDC role-assumption grant, GitHub environment secrets,
DNS zone, real Certbot state, or ACME network credentials may be provided to
this workflow. An opaque local, hard-coded test-only S3 username/secret pair
configures only the ephemeral SeaweedFS instance. These are public fixture
values, not protected GitHub secrets.

The image is referenced by a full immutable OCI SHA-256 digest, not
`latest`, a mutable version tag, an installer script, or an unreviewed
container dependency action. Its version/digest change requires an ordinary
reviewed PR and new verification evidence. The image executes only
in the unprivileged, short-lived CI environment with:
- no host filesystem mounts or persistent volumes;
- Linux capabilities dropped except the minimal CHOWN, SETUID, and SETGID
  capabilities needed by the upstream image entrypoint to prepare /data and
  drop to its non-root seaweed user; no-new-privileges and bounded memory/PIDs;
- only TCP port 8333 published, bound to IPv4 loopback;
- deliberately scoped test credentials and no production environment data;
- a startup readiness check against the authenticated S3 API, rather than
  assuming a started container is ready;
- unconditional CI cleanup with an explicit test timeout.

The existing Bash harness `tests/integration/s3-backend-interoperability.bash`
and `tests/integration/s3-recovery-evidence.bash` remain the contract owner.
The workflow calls the Make target rather than duplicating its test logic.
The harness keeps its explicit confirmation gate, `ACME_ENVIRONMENT=staging`
namespace, validated loopback-only `S3_ENDPOINT_URL`, proxy prohibition, and
synthetic archive-body rules. Normal, credential-free Bats guard tests remain
mandatory.

Tests exercise the actual S3 HTTP API and internal ADR-047/050 functions,
including initial absence, conditional replacement, stale writes, conditional
delete, complete/partial writes, a third-party conflict, and recovery from a
worker terminated by SIGKILL. New workers must recover using durable S3
generation bytes and the independently recorded manifest digest, not access to
a previous private workspace. The workflow does **not** authorize product
issuance or active Certbot import.

## Context and drivers

PR #40 introduced an opt-in, operator-provisioned S3 interoperability harness,
but its credential-free CI only tested authorization guards. A developer
could merge unrelated changes while the real-service harness had never run
against an actual S3 API implementation. The current release gate requires
proof of conditional S3 behavior and independently restartable recovery.

The project supports Jenkins, GitHub Actions, and fresh cloud instances sharing
only object state; a first-class end-to-end test must therefore exercise
remote object state across separate producer processes. Deterministic
synthetic storage integration is useful routine CI evidence and does not require
the real AWS account/DNS/ACME authority that ADR-037 and ADR-044 intentionally
withhold. The maintainer explicitly approved integrating this synthetic
service into end-to-end tests.

SeaweedFS publishes an S3-compatible API that documents atomic
`If-Match` and `If-None-Match` operations, including `DeleteObject
If-Match`. Its upstream project documents a single-process `weed mini`
operation with S3 at TCP 8333 and startup credentials derived from
`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. The initial image identity is
recorded in the workflow itself and must be treated as a pinned, reviewed
test dependency. Selecting this backend does not change certbotbot's own
only-supported first-release storage plugin (S3) or backend (Route53).

## Threat model, assumptions, and boundaries

- A pull request may contain untrusted repository code. It executes without
  live cloud or repository deployment credentials, with read-only GitHub
  access and `persist-credentials: false` checkout. The image and scripts can
  still make outgoing requests in a hosted runner; no claim of an OS-enforced
  egress firewall is made.
- Image-origin compromise, image tag substitution, supply-chain drift,
  exposed Docker services, accidental AWS metadata discovery, proxy capture,
  and over-privileged GitHub tokens are the principal new risks. Digest
  pinning, limited container privileges, loopback publishing, fake test
  credentials, metadata disabling, no proxy inheritance into the harness,
  and minimal GitHub permissions reduce their impact. Digest pinning proves
  *which bytes* are used, not that those bytes are inherently trustworthy.
- SeaweedFS itself is a separate implementation from AWS S3. A passing
  result proves only the configured service/CLI/artifact combination, not
  AWS-specific IAM, S3 policy enforcement, real service availability,
  versioning, encryption, or provider interoperability.
- The ephemeral runner and its Docker daemon are trusted for the duration
  of one test. A compromised hosted runner and untrusted runner-to-registry
  supply-chain execution are residual threats outside this CI isolation model.
- The chosen fixed port and short-lived container are acceptable because
  every GitHub-hosted job gets its own isolated runner. On a self-hosted
  runner, this assumption would require separate review.
- GitHub PR and manual runs are permitted; privileged `pull_request_target`,
  automatic real staging issuance, manual production storage targets, and
  ordinary unattended public certificate issuance remain prohibited.
- Failure of the S3 readiness probe, missing conditional AWS CLI support,
  a failed test, or bucket/container cleanup is an error, not a skip, an
  implicit downgrade to the mock, or successful interoperability evidence.
  The unchanged normal Bats suite is still required.

## Alternatives considered

**Require every contributor to provision a local S3 emulator:** rejected
because essential backend evidence would remain optional, difficult to
reproduce, and absent on ordinary PRs.

**Run the test against actual AWS S3 using encrypted repository secrets or
OIDC:** rejected for normal PR CI because it would confer cloud authority
to changeable code, create external cost and cleanup risks, and merge
credentials across trust boundaries. Real AWS validation remains a separate,
explicitly authorized release-readiness activity.

**Install a real Let's Encrypt staging workflow as a required test:** rejected.
Real DNS challenges require narrow Route53 authority and protected
environment approval; ADR-044 deliberately keeps that workflow example
inactive. A synthetic-storage test cannot supersede that restriction.

**Use LocalStack with floating image tags:** rejected because additional
authentication/licensing and supply-chain considerations make unattended,
credential-free reproducibility fragile.

**Use a generic S3 mock or simulated AWS CLI:** retained for unit and
negative tests, but insufficient as the only end-to-end S3 compatibility
evidence. Network service behavior and actual AWS CLI request encoding
must also be exercised.

**Use an unpinned SeaweedFS image, unreviewed third-party Action, or a
self-hosted stateful S3 server:** rejected due to drift, inherited
authority, or a cross-runner state dependency.

**Keep this workflow entirely manual:** rejected as the sole long-term
test mode after explicit maintainer approval for end-to-end CI, because
ordinary PRs could regress storage contracts without any real-service
check. Manual dispatch remains available for investigations.

## Consequences and verification

The first run can reveal real compatibility defects in the unexecuted
integration harness and its assumptions, or missing support in the pinned
emulator or runner AWS CLI. Those are **failures to investigate**, not
grounds to waive safety predicates, forge a green job, or enable the issuer.
Review test logs, compare the operation against the governing ADR, and make
an ordinary fix/upgrade PR with exact reproduction evidence.

The workflow adds container pull/start time and a third-party runtime
dependency to the CI attack surface. The image digest and configuration
must be periodically reviewed for vulnerabilities, upstream maintenance,
and supported conditional S3 semantics. A future move to another emulator
or production credentials is a materially new trust decision.

Verification must include a real, successful PR workflow with all three
artifact flavors completing the conditional API test and five fresh-runner
recovery scenarios; explicit negative tests for missing authorization and
prohibited endpoints; no access to GitHub deployment credentials; and
a checked status on the recorded head commit.

After those results, the product's release still requires separately
authorized real AWS/S3 evidence, external writer serialization procedures,
genuine multi-runner Let's Encrypt staging continuity, and the ADR-037
activation decision. The public issuer remains disabled and must continue
to return status 69.

## Related decisions

ADR-015 reviews dependency trust; ADR-022 establishes operator-managed
serialization and non-atomic multi-object publication; ADR-037 gates active
Certbot import; ADR-039 defines exact missing-object classification;
ADR-044 governs real ACME staging; ADR-047 and ADR-050 define recoverable
generations and conditional latest-key publication; ADR-049 defines
ETag-bound state predicates.
