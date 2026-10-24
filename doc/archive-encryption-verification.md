# Client-Side Encryption Verification Evidence

Status: **approved task #43 verification candidate**, not yet accepted
until the final PR revision passes CI and is reviewed/merged.

Governing decisions:
[ADR-031](adr/ADR-031-opt-in-authenticated-gpg-archive-encryption.md),
[ADR-030](adr/ADR-030-shared-archive-multiple-lineages.md), and
[ADR-028](adr/ADR-028-single-key-s3-publication.md).
The [archive encryption contract](archive-encryption-contract.md)
defines the expected public behavior and operator safeguards.

## Test boundaries and independent evidence

`tests/public-lifecycle.bats` drives **actual generated standalone
executables** with mocked AWS CLI/Certbot and real local GNU tar/gzip,
OpenSSL and, where available, GnuPG AES256/OCB. A fixture S3 object
on local disk mimics one existing remote object; the mock copies a
candidate only on successful PutObject (or deliberately simulates
acceptance followed by a lost response).

The ordinary `.github/workflows/test.yml` matrix stays on Ubuntu
24.04, building and exercising development, stripped and minified
artifacts. Its packaged GnuPG 2.4.4 is **below ADR-031's 2.4.7
minimum**, so genuine authenticated encryption cases are not
verified by that matrix even when the overall Bats suite is green.

The **new required `Authenticated archive interoperability` CI
job** uses the officially supported Ubuntu 26.04 GitHub runner and
distribution-supplied GnuPG 2.4.8. It builds all three artifacts
from the maintained source and dependencies, verifies their SHA256
companions and executes the matching public-command encryption
cases for each separately. The job **fails on any Bats skip** or
fewer than 20 matching tests; unsupported GnuPG can no longer
be represented as passing encryption acceptance.

The CI runner's GnuPG version comes from the supported Ubuntu
distribution rather than an unreviewed third-party PPA or downloaded
binary. An external tool remains within the trusted computing base:
the suite is not a penetration test of GnuPG, the runner image,
the host, or hardware key storage.

## Acceptance matrix

| Approved requirement | Executable test evidence |
| --- | --- |
| Plaintext default stays supported | `plaintext mode remains unchanged when no key is configured`; existing MVP suite |
| Configuration precedence | `encryption setting honors literal file, environment, and CLI precedence` |
| Reject secrets in `.env` or CLI | `encryption secret is forbidden in CLI and literal config file` |
| Reject unknown modes, missing migration confirmation, and malformed secrets | `encryption rejects unknown mode, migration direction, and invalid backup flag`; `encryption secret with newline or carriage return is rejected before AWS` |
| Fail without supported GnuPG | `encryption unsupported GnuPG version fails before S3 and Certbot` |
| Initial opt-in encrypt and local authenticated decrypt | `authenticated migration publishes ciphertext then cleanly decrypts on rerun`; `encryption migration of unchanged plaintext requires and makes one write` |
| Four fresh runners and unrelated lineages | `encryption clean runners preserve complete tar account and two lineages` |
| Selected-only renewed state retains other lineage | Same four-runner test; compare private key, renewal config and account material in real decrypted tar |
| Exact one bucket/key and ciphertext-only publication | `encryption_assert_remote_ciphertext`; public AWS mock's key assertions |
| Missing/wrong key fail with no overwrite | `encryption missing key refuses encrypted object without cloud overwrite`; `encryption wrong key fails closed without logging secret or publishing` |
| No downgrade or second migration | `encryption mode downgrade rejects ciphertext before cloud or provider`; `encryption migration cannot run twice or reinterpret encrypted input` |
| Tampered AEAD and unsupported version rejected | `encryption tampered authentication tag blocks provider and PutObject`; `encryption unknown version never triggers plaintext migration fallback` |
| Reject legacy nonauthenticated OpenPGP | `encryption legacy non-AEAD GnuPG packet cannot impersonate OCB envelope` |
| Normal no-op, forced encrypted upload | Existing encrypted no-op test; `encryption forced unchanged republish remains ciphertext on exact S3 key` |
| Failed PutObject keeps prior mocked object | `encryption failed PutObject retains previous ciphertext without rollback claim` |
| Lost PutObject response does not falsely claim rollback | `encryption lost PutObject acknowledgement reports uncertain remote result` |
| No key exposure in public output or child processes | `encryption_no_secret_exposure`; fixture AWS/Certbot probes that reject inherited secrets |

## Limits and deferred work

These tests validate sequential independent runners, not concurrently
writing runners. They do not establish live S3 API behavior, Route53
DNS authorization, Let's Encrypt account registration, external
encrypted client compatibility, S3 atomic rollback after a lost
response, or recovery from a lost encryption key. A hostile host,
compromised GnuPG or process-memory inspector also remains outside
the scope of shell-based confidentiality.

The plaintext object **must** be backed up independently before the
operator attests to a one-way migration. The test fixtures are
operator-controlled synthetic data, never actual certificate keys.
No automatic key rotation, reverse migration, new object or
production-runbook requirement is added by task #43.

## Closeout

To complete #43, require a fully green final-head CI matrix,
including the **non-skipped Ubuntu 26.04 real-GnuPG job**, all
three release artifact variants, Bash 4.3 compatibility, MegaLinter,
CodeQL and relevant security scanners. Record the final head,
test counts and known limits on issue #43. Only after review and
merge, assess the parent story #14 and Milestone #3 for closure.
