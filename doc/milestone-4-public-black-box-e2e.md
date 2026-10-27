# Milestone 4: Public-Artifact Black-Box E2E Contract

**Task:** [#47](https://github.com/wesley-dean/certbotbot/issues/47), under approved [story #16](https://github.com/wesley-dean/certbotbot/issues/16).

## Purpose, source of truth and evidence boundary

The maintained `tests/milestone-4-public-e2e.bats` suite drives **the built
producer executable**, once for each of its three distributed forms, using the
already-maintained `tests/helpers/lifecycle-fixture.bash` in a private synthetic
environment. It does not source issuer modules, fabricate a certificate result,
or bypass public configuration and archive validation. It observes the full
public boundary: S3 lookup/download, verified account-only archive restore,
Certbot plugin/account checks, selected issuance or renewal, candidate
validation/packaging and conditional same-key S3 publication.

The fixture uses a real local gzip/GNU tar archive, local OpenSSL-generated
**self-signed** PEM material, synthetic account JSON, and executable **mock**
Certbot/AWS processes. The simulated S3 current key is a local file, not
Amazon S3. The mock's `certonly` and `renew` successes are not ACME-issued
certificates and do not prove Route53 DNS challenge operations, authentic
Certbot compatibility, real IAM permissions, or Let's Encrypt registration.
These are **mocked lifecycle observations only**, not live staging
acceptance.

ADR-009 requires behavior tests against the exact producer representations.
ADR-036 requires immutable verified CI handoffs and per-flavor checks. ADR-042
permits explicit staging selection but maintains a production default outside
the live E2E boundary. The staging-only operator runbook and preflight remain
[separate](milestone-4-staging-acceptance.md) and
[operator-controlled](milestone-4-staging-preflight.md). No ordinary pull
request test has AWS credentials or permission to contact a real ACME server.

## Test invariants and instrumentation

The harness reuses the existing fixture's `LIFECYCLE_CALLS` stream, where
the mock AWS CLI and mock Certbot each append fixed, bounded operation names
in process invocation order. The stream is local fixture-only metadata
(verb, mock bucket and key), **not** provider stdout, private keys, or
unredacted credentials. A strict trace assertion detects missing, extra,
reordered or unexpected calls. The fixture's separate private
`LIFECYCLE_CONTEXTS` stream verifies that every provider process uses
the selected staging server, the same selected lineage/account, and
runner-specific private config/work/log roots.

A first selected issuance from an existing account-only object must have:

```text
aws:head-object:fixture-bucket:latest.tar.gz
aws:get-object:fixture-bucket:latest.tar.gz
certbot:plugins
certbot:show_account
certbot:certonly
aws:put-object:fixture-bucket:latest.tar.gz
```

A successful unchanged second invocation from a **different** runner
must replace `certbot:certonly` with `certbot:renew` and have **no**
PutObject. A simulated due-renewal must restore the same state and include
`certbot:renew` followed by exactly one PutObject. Both paths must use
the original staging account, correct canonical renewal metadata,
private temporary roots, and a verified S3 object at the selected
key; no implicit account `register` is allowed.

Failure cases use owned fixture files and never edit production S3:
a confirmed missing seed, corrupted downloaded archive, Certbot error,
local packaging failure, and a rejected PutObject. The observable
required properties are the correct nonzero status, no subsequent
forbidden stage or misleading `published=true`, and preservation of
the last known-good mock S3 bytes when a failure occurs **before**
remote acceptance. A simulated lost PutObject reply is intentionally
different: actual remote state may be uncertain, and no test may
claim that the prior object was preserved in that case.

For independent-runner continuity, the first and second invocations
use separately allocated mode-0700 TMPDIR parents; neither shares
a Certbot configuration, working directory, logs, host state or
filesystem-owned local certificate material. Both invoke the same
public producer with `--acme-environment staging`. Test-visible
config/work/log paths must differ, remain under their correct runner
parents, and be removed after each invocation.

## How the acceptance suite is exercised

`Makefile` currently discovers `tests/*.bats` and feeds the **same**
inventory to the three producer representations. The new suite must be
included through that existing discovery contract; it must not create
a second, weaker or staging-credentialed CI path.

```bash
make deps
make deps-check
make build
make check
make test
make test-report
```

`make test` runs the full matrix. `make test-report` produces
per-flavor JUnit XML in `test-results/`. The existing `test-one` /
`test-report-one` targets accept a verified, previously built
flavor and are also used by the parallel CI and release gates. Tests
should never change those gates to weaken Bash 4.3 compatibility,
hash checking, standalone client coverage, or release provenance.

For focused local development on **already verified built artifacts**
the Bats case file may be run with the required artifact environment
and no cloud credentials, e.g. the development flavor:

```bash
BASH_STARTER_ARTIFACT="$PWD/dist/certbotbot.dev.bash" \
  bats tests/milestone-4-public-e2e.bats
```

The fixture must not run privileged tests or download dependencies.
Generated files under `dist/`, `vendor/` and `test-results/`
remain excluded from maintained source. A test-suite pass requires
all expected checks to execute, not an undisclosed skip.

## Evidence matrix and limitations

| Scenario | Fixtures and boundaries | Required observation | Current evidence |
| --- | --- | --- | --- |
| Seeded staging first issuance | Public script; mock AWS/Certbot; real local tar/OpenSSL | Exact HEAD/GET/provider/PUT sequence and valid published archive | Verified mocked suite in [PR #223 Test CI](https://github.com/wesley-dean/certbotbot/actions/runs/40557276094) |
| Independent second runner | Same public script and simulated remote object, distinct TMPDIR roots | Account/lineage continuity, named renew no-op, no PUT | Verified mocked suite in [PR #223 Test CI](https://github.com/wesley-dean/certbotbot/actions/runs/40557276094) |
| Simulated due renewal | Mock provider emits updated local cert | Named renew followed by verified publication | Verified mocked suite in [PR #223 Test CI](https://github.com/wesley-dean/certbotbot/actions/runs/40557276094) |
| Missing/corrupt seed | Mock S3 and synthetic unsafe bytes | Fail before provider or publication | Verified mocked suite in [PR #223 Test CI](https://github.com/wesley-dean/certbotbot/actions/runs/40557276094) |
| Failed provider/package | Mock Certbot or controlled local tar failure | Fail after allowed stages, no upload, known-good bytes unchanged | Verified mocked suite in [PR #223 Test CI](https://github.com/wesley-dean/certbotbot/actions/runs/40557276094) |
| Failed S3 publication | Mock S3 returns error before acceptance | Nonzero, no false published status, known-good bytes unchanged | Verified mocked suite in [PR #223 Test CI](https://github.com/wesley-dean/certbotbot/actions/runs/40557276094) |
| All producer flavors | Existing verified Make/CI artifact matrix | Same new Bats contract on development, ordinary and minified | Verified mocked suite in [PR #223 Test CI](https://github.com/wesley-dean/certbotbot/actions/runs/40557276094) |
| Authentic ACME/Route53/S3 | **Not exercised by this suite** | Independent operator-authorized staging record | **Not proven** |

This document describes the observable test contract. The mocked suite
has passed in all three producer flavor jobs for merged PR #223, recorded in
[the milestone 4 release-evidence matrix](milestone-4-release-evidence.md).
That evidence does **not** establish any live ACME/Route53/S3 result. Task #49
will connect the documented fixture/live distinction to the final
milestone release evidence and reporting; [story #16](https://github.com/wesley-dean/certbotbot/issues/16)
must remain open until **real staging** requirements have separately
passed or their limitations have been explicitly accepted by the
responsible operator.

## Security considerations

- No AWS, Let's Encrypt or Route53 real credentials are required.
- Never run unreviewed PR code with the operator staging secrets.
- Never turn on live provider fallback when the mocks fail.
- Suppress real provider diagnostics; the fixture prints bounded metadata.
- Preserve the single authoritative key and reject archive path traversal,
  malformed metadata, mixed-CA identity, wrong selected lineage and hooks
  through the existing public preflight.
- Treat failed remote writes as uncertain unless the test explicitly simulates
  rejection **before** remote acceptance.
- The test's synthetic private keys and account JSON are not authentic
  credentials, but should still stay in its private temporary filesystem.

## References

- [ADR-009](adr/ADR-009-observable-behavior-testing.md) and
  [ADR-036](adr/ADR-036-parallel-producer-verification-and-handoff.md)
- [ADR-042](adr/ADR-042-explicit-ca-bound-staging-issuance.md)
- [Public lifecycle](mvp-public-lifecycle.md) and
  [test guidance](testing.md)
- [Staging operator procedure](milestone-4-staging-acceptance.md) and
  [release verification](release-verification.md)
