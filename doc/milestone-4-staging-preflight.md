# Milestone 4: Controlled Staging Prerequisites and Preflight

**Scope:** Approved task #104 under story #91. This document is an operator checklist, not evidence that credentials, DNS, S3 state or remote registration have been verified. It does not grant authorization to run live ACME commands. Related acceptance procedure: #48; lifecycle evidence: #47/#49. The operator must keep all sensitive values out of issues, pull requests, CI artifacts and command tracing.

## Non-production boundary and existing blocker

The **only** ACME endpoint permitted for milestone 4 is `https://acme-staging-v02.api.letsencrypt.org/directory`. No Let's Encrypt production registration, issuance, renewal, `--dry-run` substitute or fallback is authorized. ADR-041 supports explicitly selected staging **registration**. ADR-042 and approved task #219 were merged in PR #222 and now support explicitly staging-selected ordinary issuance/renewal. **Do not invoke live staging issuance** until the separate credentialed workflow's staging-only pre-network checks and exact reviewed public artifact are independently verified and the operator authorizes each remote operation. Production remains the ordinary producer default; do not rely on it for E2E. Do not work around any product check in test code.

## GitHub Actions parameter inventory

All names below are currently supplied as **repository-level Actions secrets**, including non-secret configuration values. Use `secrets.*`, not `vars.*`; neither their contents nor effective permissions have been checked. Never echo, print, trace, publish, upload or attach secret values or raw Certbot archives.

| Repository secret | Usage | Verification |
| --- | --- | --- |
| `AWS_ACCESS_KEY_ID` | AWS CLI authentication | Identity/permissions, no value disclosure |
| `AWS_SECRET_ACCESS_KEY` | Credential pair | Masked/absent from output |
| `CERTBOTBOT_AWS_REGION` | AWS region | Match bucket location and CLI region |
| `E2E_CONTACT_EMAIL` | Contact for explicit account registration only | Present; valid syntax; not evidence of TOS consent |
| `E2E_DOMAIN` | Controlled test DNS identity | Domain scope, correct public delegation and chosen SANs |
| `E2E_ROUTE53_ZONE_ID` | Expected public hosted zone | Domain/zone match; Route53 plugin actually selects it |
| `E2E_S3_BUCKET` | Existing staging-only bucket | Bucket exists, correct region, scoped IAM rights |
| `E2E_S3_KEY` | Dedicated staging-only current object key | Never collides with production; existing object/account seed verified |
| `GPG_SYMMETRIC_KEY` | Optional separately approved encrypted scenario | **Do not inject** for the initial plaintext run |

Unrelated `DOCKERHUB_TOKEN`, `DOCKERHUB_USERNAME`, `GHCR_TOKEN` and `GHCR_USERNAME` must not enter the credentialed ACME job. A temporary AWS identity additionally requires a session token; none is listed. The GitHub connector cannot inspect stored secret values.

For the **initial plaintext** scenario, set `ARCHIVE_ENCRYPTION=none` and do not export `GPG_SYMMETRIC_KEY`. Use one staging-exclusive key, `UPLOAD_NO_RENEWAL=false`, `DATED_BACKUP_ENABLED=false` and `BACKUP_RETENTION_COUNT=0` unless independently approved otherwise. Avoid format migration, retention deletion and unrelated SAN changes.

## Read-only operator preflight (no issuer or account registration)

Run this in a trusted, isolated, operator-authorized environment using the intended injected secrets. Commands are **illustrative nonmutating checks**, not an unattended workflow. Disable shell tracing (`set +x`) before using secrets, mask diagnostics, use `umask 077`, and review emitted output privately before sharing any evidence. Do not print the environment. Do not run an arbitrary PR checkout with credentials.

1. **Resource scope:** Confirm `E2E_DOMAIN` is a test-only DNS name controlled by the operator. Confirm `E2E_ROUTE53_ZONE_ID` identifies its authoritative *public* hosted zone, appropriate nameserver delegation exists, and requested `INCLUDE_SUBDOMAINS` determines the exact apex/wildcard SANs. Verify no production DNS name or unrelated Route53 zone will be modified.
2. **Identity and region:** Map `CERTBOTBOT_AWS_REGION` securely to `AWS_DEFAULT_REGION` or `AWS_REGION`. Run `aws sts get-caller-identity` and `aws s3api get-bucket-location --bucket "$E2E_S3_BUCKET"`. Inspect actual identity and location **privately**; publish only a redacted pass/fail. Do not construe one successful call as proof of full permissions.
3. **Bucket and object:** Use `aws s3api head-bucket --bucket "$E2E_S3_BUCKET"` and `aws s3api head-object --bucket "$E2E_S3_BUCKET" --key "$E2E_S3_KEY"`. A missing key is a **bootstrap prerequisite**, not permission for ordinary issuance. A 403, transport error or ambiguous response is **not** proof of absence (ADR-021). Never overwrite a known-good object to run failure cases.
4. **Read and integrity:** After confirming the object exists, use `aws s3api get-object --bucket "$E2E_S3_BUCKET" --key "$E2E_S3_KEY" "$PRIVATE_DIR/current.tar.gz"` into a new mode-0700 temporary directory on a trusted isolated runner. Use the project's approved bounded archive validation and restoration pipeline before extracting or activating anything: **do not blindly run `tar -xzf` on the downloaded archive**. Confirm account-only or supported state and no unsafe members or executable hooks. A successful GetObject alone does not verify archive integrity, Certbot recognition, or staging registration.
5. **Account and CA:** Within the validated private tree, require exactly one supported native `accounts/acme-staging-v02.api.letsencrypt.org/directory/<id>/` with required nonempty account files and no production or competing CA account. Confirm via a staging-bound installed Certbot `show_account` probe **only when the independently approved safe probe procedure is available**; filesystem shape alone does not prove remote registration. If the selected lineage should be absent for first issuance, verify that absence. Do not upload private account files as evidence.
6. **AWS permissions:** Independently verify least-privilege `ListBucket`, `GetObject`, and scoped `PutObject` (including conditional writes required by registration) on the test bucket/key; Route53 `ListHostedZones`, `GetChange` and `ChangeResourceRecordSets` only for the authorized zone. A read-only preflight cannot prove write permissions: record those as **unverified** until an explicitly authorized safe test. Account for bucket KMS permissions, policies and relevant network access without automatically broadening IAM.
7. **Runtime and provenance:** Verify Bash >=4.3, AWS CLI v2, installed Certbot and `certbot-dns-route53`, OpenSSL, GNU tar/gzip, and private runner directories. Select reviewed, immutable public producer release bytes with independent SHA-256/attestation verification; version and checksum are evidence, not mere filename. No raw Certbot or AWS stderr in shared reports.

On failure: stop; record the failed gate and nonsecret diagnostic category. A normal missing archive, corrupt archive, unknown account identity, mixed CA, wrong zone, denied request or unconfirmed authorization must **not** trigger registration/issuance or publication.

## Staging account seed: separate, explicit operator action

Story #91 requires a **real staging account-bearing archive at the selected S3 key before first issuance**. When positively missing, the operator may elect an independently authorized registration/bootstrap action using the existing public `register --acme-environment staging`, after confirming the reviewed release and the precise bucket/key. This is **not** an issuer fallback or part of a read-only preflight. Explicit `AGREE_TOS=true` is required after the operator has accepted the applicable terms; do not infer consent from the email secret. `EFF_EMAIL_SIGNUP=true` is the current default, with an explicit opt-out available. Preserve existing state and registration's conditional first-write behavior (ADR-041). Never switch to the production registration default.

When seeded state already exists, validate and reuse it. Do not attempt account registration merely because issuance fails. Treat any failed/uncertain remote PutObject as **unknown remote state** pending independent inspection, not guaranteed rollback.

## Runner, authorization and preservation gates

Credentialed acceptance must be operator-triggered (for example, protected `workflow_dispatch` on trusted `main`), not `pull_request` or `pull_request_target`. Scope GitHub permissions to the necessary read-only default; inject AWS secrets only into the privileged test job. Before any remote writes, the operator must approve the **specific** staging domain, zone, bucket/key, expected SANs, account bootstrap (if needed), issuer run, external writer serialization, and recovery method. Back up/version the known-good staging archive by an independently approved means if destructive scenarios could affect it; use isolated fixture keys or mocks for negative cases. Never erase the only valid staging seed to prove a failure.

Independent-runner evidence requires a second completely clean private workspace with no access to the first runner's state, restoring the same selected staging account and lineage from S3 and observing a legitimate renewal no-op. This is future acceptance evidence, **not** a result of this checklist. The staging certificate's normal browser distrust is expected.

## Redacted acceptance record template

| Gate | Expected | Evidence type | Status |
| --- | --- | --- | --- |
| Auth, DNS and zone | Test-only identity, correct authority | Private operator preflight; redacted result | Not run |
| S3 bucket/key and permissions | Existing isolated seed; required read/write scope | Read checks / separate authorized write evidence | Not run |
| Archive and staging account | Validated native staging state, no mixed CA | Private approved validator/probe | Not run |
| Producer CA-bound staging support | Reviewed ADR + approved task + negative tests | [ADR-042](adr/ADR-042-explicit-ca-bound-staging-issuance.md), merged PR #222, mocked CI | Implemented; live unverified |
| Public artifact identity | Reviewed version, checked SHA-256, Bash 4.3 | Build/release provenance | Not run |
| First issuance and S3 publication | Genuine staging + Route53 + S3 | Authorized live record | Not run |
| Clean-runner no-op and optional due renewal | Same account/lineage, actual renewal policy | Authorized live record | Not run |
| Failure and archive preservation | Fail closed without known-good corruption | Distinguish mock vs live fixtures | Not run |

Record the exact approved public artifact version/digest, redacted workflow/run reference, test case, expected/observed exit code, whether ACME/Route53/S3 were **real** or **mocked**, current-object generation if safe, limitations and operator signoff. Do not include raw AWS caller IDs, secret values, private keys, account JSON, full diagnostic logs, archives or credential-bearing outputs. Task #104 documentation alone does not prove seeded S3 state or satisfy story #91.

## Governing references

- [ADR-020](adr/ADR-020-one-selected-certificate-and-one-durable-archive.md), [ADR-021](adr/ADR-021-fail-closed-seeded-s3-read.md), [ADR-022](adr/ADR-022-portable-certbot-state-archives.md), [ADR-023](adr/ADR-023-fail-closed-restored-acme-preflight.md), [ADR-024](adr/ADR-024-selected-only-certbot-route53-provider.md), [ADR-025](adr/ADR-025-selected-renewal-noop-contract.md), [ADR-041](adr/ADR-041-explicit-acme-account-registration-and-state-initialization.md)
- [ACME registration contract](acme-account-registration-contract.md), [testing](testing.md), [release verification](release-verification.md), [threat modeling](threat-modeling.md), [configuration reference](configuration-reference.md)
- Approved issues #91/#104, #16/#48; merged staging issuer task #219 / PR #222.
