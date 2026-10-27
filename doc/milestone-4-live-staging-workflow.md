# Milestone 4: Manual Staging E2E Workflow Operator Guide

**Work item:** approved technical task #225, under stories #16 and #91.
**Current execution status:** Workflow implementation under review. **No live
staging run is implied by the existence of these files or green PR CI.**

## Prerequisites and operator authorization

Review [ADR-043](adr/ADR-043-manual-staging-live-e2e-workflow.md),
[the safe preflight](milestone-4-staging-preflight.md), and
[the acceptance runbook](milestone-4-staging-acceptance.md). This action
genuinely attempts to issue a Let's Encrypt **staging-only** certificate
using the existing AWS IAM principal and public Route53 zone. It can
modify permitted DNS-01 TXT challenge records and overwrite the selected
**test-only** S3 object after successful issuance. Confirm the selected
test domain, exact staged S3 key, bucket scope, zone and IAM access
privately before authorizing the run.

Do **not** use production AWS/DNS/S3 resources or a production ACME
account. Establish and preserve a separate recoverable staging archive,
with a **real recognized staging account and no selected certificate
lineage**, at the exact authorized S3 key before the *first issuance* run.
The current workflow never registers an account, creates a missing S3
seed, changes subscriber consent, forces renewal, migrates archive
encryption, purges backups, or adds additional arbitrary SANs. It
uses `--include-subdomains true` to request the domain's apex/wildcard
complement. Configure public DNS delegation and IAM for both names.

A missing, unsafe, wrong-CA or ambiguous object fails closed. The
S3 preflight performs a nonextracting member-list sanity check; the
public certbotbot executable performs the authoritative restored state
and renewal-metadata verification. A local path/layout check alone
does **not** prove remote ACME registration. The operator must separately
verify this prerequisite through authorized staging Certbot evidence.

## Secrets: required and deliberately excluded

The GitHub Actions workflow reads only these **repository secrets** in
the credentialed issuance/restoration steps (there are no required
repository `vars`):

| Secret | Purpose |
| --- | --- |
| `AWS_ACCESS_KEY_ID` | Authorized test-only IAM principal |
| `AWS_SECRET_ACCESS_KEY` | Credential paired with the key ID |
| `CERTBOTBOT_AWS_REGION` | Region matching the existing test bucket |
| `E2E_DOMAIN` | Authorized DNS test domain without `*.` |
| `E2E_ROUTE53_ZONE_ID` | Public hosted-zone ID governing that name |
| `E2E_S3_BUCKET` | Existing isolated staging bucket |
| `E2E_S3_KEY` | Dedicated, already seeded staging account object key |

`E2E_CONTACT_EMAIL` is stored but **not injected**, because this
workflow cannot register an account. Likewise,
`GPG_SYMMETRIC_KEY` and all container registry publishing secrets
are excluded. These exclusions are intentional. The initial test
requires a plaintext gzip tar state archive; encrypted scenarios
need separate approval, not a silent configuration change.

The AWS principal requires scoped S3 read/write access and
Route53 list/changes for the selected zone, with any additional
bucket KMS requirements satisfied by the operator. The workflow
cannot discover or restrict a principal's extra AWS permissions; least
privilege must be configured in IAM.

## Starting the controlled run

1. Have the pull request implementing #225 independently reviewed,
   approved and merged into trusted `main`. Green mocked PR CI **does
   not** authorize real AWS/ACME operations.
2. Ensure **no other S3 writer** can mutate the selected key. This
   workflow serializes only its own runs and cannot coordinate an
   external process. Confirm independent archive recovery/versioning
   before the first publication. Never use a production key.
3. Open the repository **Actions** page, select
   **Manual Let's Encrypt staging E2E**, and select **Run workflow**
   against `main`, after independent operator authorization. The
   workflow is restricted to owner-initiated, owner-retried runs;
   collaborators cannot dispatch its privileged stages.
4. Confirm that you are signed in as GitHub account `wesley-dean`.
   The manual workflow has **no dispatch inputs** (Checkov CKV_GHA_7)
   and always selects the staging CA; no user-provided selector can
   switch it to production. Selecting **Run workflow** on `main`
   is the affirmative dispatch action. A rerun by another account
   is also refused. Confirm the exact domain, zone, isolated key,
   and independent recovery plan *before* starting. A typed prompt is
   intentionally absent and is **not** a substitute for that review.
5. Start the run. The first job admits only trusted repository `main`
   and builds a same-run, 8-file verified public artifact handoff
   **without AWS secrets**. Runner A verifies the checksum and
   bundle manifest before secrets are injected, confirms the staging
   bucket/zone/account and runs real public staging issuance.
   Runner B is a distinct ephemeral job that downloads and
   re-verifies the same public bytes and S3 archive, then checks normal
   selected no-op/lineage continuity. All job logs redact the raw
   producer/provider result and do not upload certificate material.

A first run *requires* the account-only seed. Running the workflow
again against a previously issued archive is expected to fail
the **first-issuance** assertion, even if the issuer legitimately
returns an unchanged success. Do not defeat this assertion by forcing
new certs or clearing the known-good archive. A separately reviewed
future restoration-only test can be used if repeatability after the
first issuance becomes necessary.

The known result strings for a first success are `issued` and
`published=true`; the second clean runner must observe a normal
`checked`, `published=false` decision. The second runner verifies
both the initial S3 object digest and the unchanged object after
renewal selection. A real due-renewal event is **not** manufactured;
document its absence as an acceptance limitation until a normal
renewal date and separate authorization.

## Failure handling and reporting

Failure messages intentionally identify only categories, such as
wrong public zone, absent/ambiguous seeded S3 state, invalid artifact,
production-selection rejection, provider failure, unexpected no-op,
or an S3 archive mismatch. Raw AWS identities, domain, bucket/key,
challenge material, account JSON, private keys, archive bytes, and
Certbot logs are not emitted to the shared Actions logs.

**An error after a remote write is potentially uncertain.** Inspect
the current object and any approved safe backup privately; do not
assume atomic rollback, retry blindly, or delete the only valid seed.
Only an independently authorized operator decides recovery. A
GitHub Actions success is evidence of the controlled runner's checks,
not of certificate installation, external TLS trust, or an eventual
natural due-renewal.

The acceptance report should link the *redacted* workflow run, exact
source revision/artifact digest, the observed first-issuance and
clean-runner result categories, independently confirmed test-only
scope, and explicit remaining limitations. Record that the tests
contacted genuine **staging** ACME, Route53, and S3. Do not attach
the raw archive or raw provider logs.

## Current development and progress policy

Task #225 is one technical task and receives exactly **one**
corresponding implementation PR. The six associated milestone 4
technical tasks (#104, #47, #48, #49, #219, #225) are equally
weighted. Prior to task #225 completion, five are closed
(**83.3% task completion; one remaining**). Code completion does
not by itself close stories #16 and #91: those require operator
review of real staging evidence.

## Links

- [Staging acceptance procedure](milestone-4-staging-acceptance.md)
- [Staging resource preflight](milestone-4-staging-preflight.md)
- [Milestone fixture/release evidence](milestone-4-release-evidence.md)
- [ADR-042: CA-bound staging selection](adr/ADR-042-explicit-ca-bound-staging-issuance.md)
- [ADR-043: Manual staging E2E workflow](adr/ADR-043-manual-staging-live-e2e-workflow.md)
