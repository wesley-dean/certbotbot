# Milestone 4: Operator-Controlled Live Staging Acceptance Procedure

**Prepared for:** task #48, story #16, milestone #4. **Execution status:** Not run. This is an operator procedure, not authorization to execute or evidence of successful live interoperability.

## Non-negotiable staging boundary

Milestone 4 **must never access Let's Encrypt production**. Its only allowed ACME directory is `https://acme-staging-v02.api.letsencrypt.org/directory`. Never run Certbot `--dry-run` as a substitute for actual staging issuance, or pass a production archive, account or server to the staging test.

As of the procedure's preparation, ADR-041 supports explicit staging *account registration*, but the ordinary producer remains production-only under ADRs 023/024/025. The separately approved task **#219** must deliver a reviewed Accepted CA-bound issuer ADR, code, negative tests and staging-only workflow gate **before any live issuance or renewal**. This document deliberately gives no executable ordinary issuer command while production is its default. Future commands must be taken from reviewed, exact, staging-explicit public CLI documentation, not inferred here.

For credentials, zone/account checks and preservation, complete [the dedicated preflight](milestone-4-staging-preflight.md). Do not confuse a merged preflight document with verified AWS permissions or a real seed archive.

## 1. Operator authorization and resources

Before each credentialed operation, record the operator's explicit authorization for the exact action, resource set and time. A manual operator-controlled `workflow_dispatch` from protected, reviewed `main` is an acceptable mechanism *after* its staging-only guard is validated. No `pull_request`, `pull_request_target`, unreviewed branch checkout, or automatically triggered privileged run.

Use these repository-level Actions **secrets** (not `vars.*`): `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `CERTBOTBOT_AWS_REGION`, `E2E_CONTACT_EMAIL`, `E2E_DOMAIN`, `E2E_ROUTE53_ZONE_ID`, `E2E_S3_BUCKET` and `E2E_S3_KEY`. Confirm their effective presence privately and never emit their values. `GPG_SYMMETRIC_KEY`, Docker Hub and GHCR publishing secrets must **not** enter the initial plaintext staging job. Require `ARCHIVE_ENCRYPTION=none`, `UPLOAD_NO_RENEWAL=false`, `DATED_BACKUP_ENABLED=false`, `BACKUP_RETENTION_COUNT=0`; avoid format migration, unexpected backup deletions and unrelated SAN changes.

Preflight privately verifies the controlled *public* Route53 hosted zone, test DNS delegation, exact requested SANs (including any `INCLUDE_SUBDOMAINS` complement), bucket region/key, AWS execution identity, least-privilege S3/Route53 access, expected external tools and outbound reachability. A successful `HeadObject` or `GetObject` alone is not evidence of all write permissions. A denied/ambiguous read is not permission to bootstrap. If a supplied value is absent, ambiguous, mismatched or outside the staging boundary, **stop before any remote side effect**.

Use only reviewed immutable shipped producer bytes and independently established SHA-256/attestation evidence from [release verification](release-verification.md), not `src/` or a repository-internal helper. Verify Bash 4.3+ compatibility and a private ephemeral owned mode-0700 Certbot workspace. Never load host `/etc/letsencrypt` as fallback. Ensure one serialized writer to the selected S3 key and a reviewed recovery route for remote-write uncertainty.

## 2. Genuine staging account and account-only seed

An existing validated S3 object at the operator's **staging-exclusive** bucket/key must contain one native, reusable Let's Encrypt *staging* ACME account before the first issuer run. For an account-only seed, no selected lineage exists yet. The expected private Certbot account root is `accounts/acme-staging-v02.api.letsencrypt.org/directory/<id>/`, including nonempty `private_key.json`, `regr.json` and `meta.json`. Never publish these contents, raw account IDs or the archive.

Download only to a fresh private directory; validate all archive members and extraction boundaries before activating state. Inspect the validated staging account, reject any unexpected production/competing account, and require Certbot to recognize the account under an *explicit staging* server. A well-formed local directory is **not** proof of a remotely registered account.

If the object is positively absent, stop the main issuer scenario. A separately authorized operator action may invoke the **public registration command** with `register --acme-environment staging`, the specified bucket/key and email, after genuine subscriber-terms consent (`--agree-tos true`). Its EFF email choice must be deliberate (default signup `true`). Registration alone never issues a certificate. Conditional S3 creation and uncertain-write handling follow ADR-041. An existing suitable seed is reused without registration, even if the operator supplies a new email address.

**Checkpoint A:** verified real staging account seed, unchanged known-good storage/recovery boundary, selected lineage absent. Otherwise the issuer remains blocked.

## 3. First issuance: runner A

**Prerequisites:** checkpoint A; merged/reviewed #219 staging issuer and Accepted ADR; independently checked test-workflow staging-only guard; explicit operator authorization.

1. Start runner A with a new private workspace, approved public executable and no inherited host Certbot state. Resolve an explicit staging CA selector from the **approved updated issuer contract**. Confirm the exact SANs, stable certificate name, configured bucket/key and test-only Route53 zone. Verify there is no production fallback.
2. Run the reviewed public producer, not a private helper. Observe the real S3 HEAD/GET of the existing seeded object and safe validated restoration.
3. Require staging-bound Certbot account recognition and real `certonly` with the installed `dns-route53` authenticator. Verify that all DNS-01 changes are restricted to authorized test records; never share challenge values.
4. Verify the returned selected lineage has exact requested DNS SANs, usable leaf/chain, matching private key, portable canonical renewal metadata and the original staging account identity. Observe real ACME and Route53 interactions, not simulated output.
5. Require a successful public result reporting `published=true` for changed state. Independently re-read the **same** S3 key in a private trusted context to confirm the updated archive is durable and valid. Do not infer success only from Certbot's exit code or the producer's status line.
6. Record the observed staging server, exact artifact version/SHA-256, exit code and a redacted object generation/digest when safe. Ordinary browsers not trusting the staging certificate is expected.

**Checkpoint B:** actual first staging issuance, selected lineage validation and successful genuine S3 publication. A dry-run, local fixture or mock cannot satisfy it.

## 4. Fresh-runner restore and legitimate no-op: runner B

**Prerequisite:** checkpoint B.

1. Destroy runner A's invocation-owned Certbot state. Initialize runner B independently, without any copy or shared mount of A's configuration, account, workspace or logs. The only durable input is the selected S3 object.
2. Run the exact same **staging-selected public producer** with the same SAN set, certificate name and plaintext mode. Observe a new S3 read and the restored staging account/lineage. Reject account replacement, surprise SANs, production account paths and unrelated-lineage mutation.
3. Observe actual Certbot `renew --cert-name NAME` semantics on that selected lineage with the staging server. No global renew, forced issuance or implicit registration.
4. A truly unchanged successful no-op with `UPLOAD_NO_RENEWAL=false` normally yields `published=false`. If Certbot changed any legitimate durable metadata, a changed-state upload may be correct despite no new certificate; record what actually changed rather than falsely asserting no-op.
5. Independently compare state/lineage continuity and S3 object generation. Evidence must show B did not rely on A's local files.

**Checkpoint C:** genuine fresh-runner continuity and an observed ordinary selected renewal decision, with accurate distinction between unchanged no-op and metadata-only publication.

## 5. Due renewal or reviewed equivalent

Do **not** force a renewal, switch to production, circumvent rate limits or manufacture an early expiry merely to obtain a green test. When an actual staging lineage becomes due under normal Certbot policy, the operator may authorize a further independent runner, verify real staging renewal, updated selected certificate, unchanged account/lineage identity, valid candidate publication and subsequent clean-runner restoration. Record each observation.

If a real due-renewal window cannot safely be reached during acceptance, distinguish simulated due-renewal tests from live no-op evidence, document the unmet real acceptance element, and obtain the applicable human scope decision. Never claim a due renewal succeeded merely because mocked tests passed.

## 6. Failure and isolation matrix

| Case | Safe test environment | Required observation |
| --- | --- | --- |
| No seeded object/account | Isolated fixture key or mocks; never destroy real seed | Fail closed; no implicit registration, no publication |
| S3 access denied / ambiguous read | Mock or separately scoped isolated permission fixture | Nonzero; no Certbot or upload |
| Corrupt/unsafe archive, mixed CA, production account | Mock or privately validated fixture | Reject before Certbot; no production contact |
| Unsupported issuer/environment or production-selected E2E | Credential-free negative test | Rejected before any network side effect |
| Failed Certbot, wrong SANs or incomplete lineage | Mock/fault injection | Nonzero, candidate rejected, no publication |
| Failed packaging | Local mock/fault injection | No remote write |
| Failed or ambiguous S3 PutObject | Mock or independently approved isolated object | Report remote state *uncertain*, inspect independently, no assumption of rollback |
| Unexpected changes to other lineages | Deterministic multi-lineage fixtures | Rejected or preserved per accepted lineage contracts |
| Authenticated archive crypto (optional) | Separate approved staging scenario with compatible GnuPG | No plaintext fallback, no secret leakage; not part of initial plaintext run |

Do not corrupt/delete the only good staging archive for a negative case. A controlled mock proves failure wiring, not real AWS/ACME interoperability.

## 7. Public-artifact parity and evidence handling

Run `make test` and `make test-report` in credential-free CI against the shipped development, ordinary and minified producer executable flavors, with expected checksum companions, Bash 4.3 checks and independent standalone-client checks where applicable. Report each as **mocked** unless external services truly ran. Privileged staging tests are separate, manual and outside untrusted PR checks.

The execution record must include: operator signoff; reviewed branch/tag and public executable SHA-256; scenario; runner separation; expected and observed exit status; selected non-production ACME proof; actual vs mocked S3/Route53/Certbot classification; redacted S3 generation/digest where appropriate; expected and observed `published` result; acceptance decision, limits and redacted run reference.

Never disclose AWS credentials, email/domain values from repository secrets without operator permission, account IDs, private JSON, private keys, raw private tarballs, GPG keys, raw Certbot logs or shell trace. Limit CI artifact uploads to reviewed redacted evidence. A test command's exit-zero status does not prove the remote state is committed and usable.

### Operator evidence form

| Scenario | Real ACME | Real Route53 | Real S3 | Public artifact/hash checked | Result | Limitations |
| --- | --- | --- | --- | --- | --- | --- |
| Preflight and seed | Not run | Not run | Not run | Not run | Pending | Credentials and seed unverified |
| Initial staging issuance | Not run | Not run | Not run | Not run | Blocked until CA gate | #219 implementation |
| Fresh-runner restore/no-op | Not run | Not run | Not run | Not run | Blocked | Requires initial issue |
| Due renewal or equivalent | Not run | Not run | Not run | Not run | Pending | Must distinguish mocks |
| Failure preservation | Mocked tests may run separately | Mocked tests may run separately | Mocked tests may run separately | Pending | Not run | Do not sacrifice real seed |
| Artifact flavor parity | Not applicable | Not applicable | Mocked | Pending | Not run | CI is not live evidence |

Do not mark task #16 or story #91 accepted solely because this procedure is merged. Link actual independently observed results and limitations to the operator's acceptance decision.

## Governance and references

[Preflight](milestone-4-staging-preflight.md), [release verification](release-verification.md), [testing](testing.md), [the public lifecycle](mvp-public-lifecycle.md), [explicit registration contract](acme-account-registration-contract.md), [ADR-020](adr/ADR-020-one-selected-certificate-and-one-durable-archive.md), [ADR-021](adr/ADR-021-fail-closed-seeded-s3-read.md), [ADR-022](adr/ADR-022-portable-certbot-state-archives.md), [ADR-023](adr/ADR-023-fail-closed-restored-acme-preflight.md), [ADR-024](adr/ADR-024-selected-only-certbot-route53-provider.md), [ADR-025](adr/ADR-025-selected-renewal-noop-contract.md), [ADR-041](adr/ADR-041-explicit-acme-account-registration-and-state-initialization.md), and approved tasks #48/#219. The future issuer ADR, not this runbook, authorizes any change to the certificate issuance contract.
