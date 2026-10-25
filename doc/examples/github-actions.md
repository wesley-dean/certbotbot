# GitHub Actions: manually authorized certificate producer

The [example workflow](certbotbot.yml) is maintained **only** under
`doc/examples/`, not `.github/workflows/`. It is **inert** in this
repository until a maintainer deliberately copies a reviewed revision
into an enabled workflow path and configures its protected environment.
It implements approved documentation [task #156](https://github.com/wesley-dean/certbotbot/issues/156)
under [story #151](https://github.com/wesley-dean/certbotbot/issues/151).

The workflow runs the **ordinary standalone certificate producer** on
a private GitHub-hosted Ubuntu 24.04 runner for exactly one selected
Certbot lineage. It does not run the separate read-only client or
publish an OCI image. The user initiates it manually through
`workflow_dispatch`; there is **no schedule**, PR, push,
`pull_request_target`, `workflow_run`, or automatic production
certificate-maintenance trigger.

## Trust and authority summary

A manual workflow run can genuinely **issue or renew certificates and
write to S3**, even though the YAML originally lives in the examples
directory. Do not activate it without operator-owned, trusted
infrastructure and security review.

The operator must already have:

1. A suitable **registered production Let's Encrypt account**,
   encoded in a complete account-only or multi-lineage Certbot
   archive at the **existing current S3 key** (default
   `latest.tar.gz`). A missing current object is an error,
   not permission to initialize a new account or empty archive.
2. An existing S3 bucket and Route53 hosted zone(s), including
   correct DNS delegation, IAM policy and network access.
3. A carefully scoped GitHub OIDC IAM role, restricted to
   **this repository, the reviewed main branch/workflow, and the
   protected environment**, and a GitHub environment named
   `certbotbot-certificates`.
4. A separately reviewed and verified
   [GitHub release](../release-verification.md), including the
   exact producer SHA-256 digest and attestation, plus the required
   build tool versions. GitHub Actions permissions and secrets must
   be appropriately restricted.
5. **Global serialization** for every producer writing the same
   bucket/key. Workflow-level `concurrency` only serializes runs
   with matching values inside this workflow. It cannot coordinate
   other workflows, Jenkins, Docker, Podman, or direct calls.

The job requests `contents: read`, `attestations: read`, and
`id-token: write`. The latter is needed for GitHub's OIDC token
exchange; it does **not** by itself grant AWS authorization. The
AWS IAM trust policy and attached permissions ultimately decide
which cloud operations are possible. The workflow has no
`contents: write` or repository release/tag authority and never
executes PR-supplied source or a floating Git checkout.

## Adoption checklist

1. Review the current [producer CLI reference](../configuration-reference.md),
   [lifecycle guide](../how-it-works.md), [archive threat model](../mvp-certificate-state-threat-model.md),
   and all applicable Accepted ADRs. Confirm the existing
   account/seeded archive and the intended certificate name/SAN set
   using an independently controlled environment.
2. Create the GitHub **environment**
   `certbotbot-certificates`, require appropriate **reviewers**
   and restrict its **deployment branches/tags** to the protected
   `main` branch. The example also checks
   `GITHUB_REF=refs/heads/main` before AWS credentials are assumed.
   Protect the source workflow file from unapproved changes.
3. Register the GitHub Actions OIDC provider with AWS for
   `https://token.actions.githubusercontent.com`, audience
   `sts.amazonaws.com`. Create an IAM role with an exact
   `StringEquals` audience and **subject** restriction for the
   reviewed repository/environment. Use the **actual current OIDC
   `sub` value**, including immutable organization/repository IDs
   if GitHub emits them, rather than assuming an outdated legacy
   name-only subject. An environment-based `sub` must still be
   constrained to the intended branch by GitHub environment
   protection. Require independent IAM approval; don't copy an
   unreviewed permissive `StringLike` wildcard.
4. Add these **nonsecret, reviewed environment variables** to the
   protected environment (not the ordinary parsed application
   `.env`): `CERTBOTBOT_RELEASE_TAG` (the exact
   `vMAJOR.MINOR.PATCH` release tag),
   `CERTBOTBOT_PRODUCER_SHA256` (64 lowercase hexadecimal
   characters independently verified against the reviewed
   `certbotbot.bash`), `CERTBOTBOT_AWS_ROLE_ARN`, and
   `CERTBOTBOT_AWS_REGION`. The values are intentionally
   **unset in this example**; no placeholder role/account number
   is treated as a production identity.
5. If encrypted archives are already in use, store
   `CERTBOTBOT_GPG_SYMMETRIC_KEY` as a protected GitHub
   **environment secret**. It is read only by the encrypted
   invocation step and passed to the producer via the required
   exported `GPG_SYMMETRIC_KEY` environment name. The plaintext
   step does **not** bind the secret. Never place it in input
   fields, build args, YAML literals, artifacts, logs, or the
   parsed project `.env`.
6. Review the immutable SHA
   `e1253824e5c10ff9df46874f81ed3ec929e19cfd` of
   [`aws-actions/configure-aws-credentials` v6.3.0](https://github.com/aws-actions/configure-aws-credentials/commit/e1253824e5c10ff9df46874f81ed3ec929e19cfd).
   The example **pins that full commit**, not a mutable tag.
   Check action provenance, implementation, transitive trust and
   runner compatibility before activation and on future upgrades.
7. Deliberately copy the reviewed
   `doc/examples/certbotbot.yml` to
   `.github/workflows/certbotbot.yml` in the *operator-controlled*
   repository and submit it for normal code/permissions review.
   Copying to that path makes `workflow_dispatch` available.
   Do not activate an unreviewed PR head, alternative repository,
   cross-repository dispatch or inherited default token permissions.
8. Choose **Run workflow**, select **main**, supply the mandatory
   primary domain and existing bucket, and leave backup publication
   and retention at their safe disabled defaults for the first
   approved run. The protected environment should require its
   reviewers before any credentialed work executes. Independently
   confirm the selected S3 key and certificate/lineage mapping.
9. Review the exit code and reported
   `published=true|false` outcome, then independently inspect
   the remote certificate/archive before involving downstream
   installation and service reload. Schedule **only through a
   separately approved change**, after global concurrency, retry,
   audit, monitoring and recovery arrangements exist.

The pinned ordinary executable and matching `.sha256` are downloaded
from the exact reviewed GitHub release after input validation. The
workflow checks the companion with `sha256sum --check`, separately
matches the downloaded executable to the independently pinned digest,
verifies both artifacts' GitHub attestations with
`gh attestation verify`, checks Bash syntax, and gives the file
private executable permissions. A checksum downloaded from the
same source as the executable alone is **insufficient** evidence
of trust. No release or PR artifacts are rebuilt during this job.

Only after those checks does the workflow invoke the pinned AWS
OIDC credential action. There is no standing AWS access key checked
into the repository, passed as a workflow input, or written into a
downloaded producer archive. The action assumes a short-lived
operator-provisioned role. This is an **operator-controlled trust
boundary**: the configuration is safe only when the IAM role,
environment and workflow permissions are all correct.

## Runtime and GnuPG constraints

The example uses a dedicated ephemeral `ubuntu-24.04` runner,
installs the distribution's `certbot` and
`python3-certbot-dns-route53` packages, and checks for
Bash 4.3+, AWS CLI **v2**, Certbot Route53 plugin,
OpenSSL, GNU archive tools, `curl`, SHA-256 tools and GitHub CLI.
The runner distribution and installed system packages are **trusted
runtime dependencies**, not part of the producer's pinned artifact.
Package availability and changes must be reviewed separately;
a successful package install is not proof that real ACME/DNS
operations will work.

When `archive_encryption=gpg-ocb`, the runner must separately
provide **GnuPG 2.4.7+ with actual AES-256/OCB support**. The
example checks the available version and intentionally fails
if it is insufficient. The producer performs the mandatory OCB
capability test. A normal Ubuntu 24.04 environment may lack the
required version: an operator must supply a **reviewed compatible
runner/toolchain** before choosing encrypted mode. Do not
silently downgrade to legacy symmetric encryption or reinterpret
the object as plaintext. Neither this example nor certbotbot
implements automatic plaintext-to-encrypted migration.

All downloaded files live under a new private
`$RUNNER_TEMP/certbotbot-example` directory and are removed by
an `always()` cleanup step. The producer itself uses a
mode-0700 private workspace for Certbot state and cleans up its
own invocation-owned files. Ephemeral runner cleanup and
environment masking do **not** defend against a compromised
runner, an administrator with enough access, or secret exposure
in an arbitrary executable.

## Manual input reference

The workflow's inputs are **nonsecret** and can appear in job
metadata or be inspected by authorized collaborators:

| Input | Default | Meaning |
| --- | --- | --- |
| `domain` | Required, no default | Primary selected DNS name; `example.com` is deliberately rejected |
| `additional_sans` | Empty | One comma-separated collection of extra DNS names; forwarded as exported `ADDITIONAL_SANS` |
| `s3_bucket` | Required, no default | Existing bucket with the exact seeded Certbot state |
| `s3_key` | `latest.tar.gz` | Literal current archive key, not a dated recovery key |
| `cert_name` | Empty | Optional stable non-wildcard Certbot lineage identity |
| `include_subdomains` | `true` | Add complementary apex/wildcard SANs per explicit input |
| `archive_encryption` | `none` | Explicit already-stored plaintext vs encrypted format; no implicit migration |
| `dated_backup_enabled` | `false` | Guarded additional dated backup write |
| `backup_retention_count` | `0` | **No deletion** by default; positive N can delete previously managed copies |

The workflow also explicitly passes `--upload-no-renewal false`,
so a verified unchanged no-op does not upload by default.
Additional SANs are deliberately passed as a comma-separated
**exported environment collection**, not inserted into a Bash
command string or parsed through `eval`. The actual Bash
producer enforces validation (up to 99 extras, 100 total
expanded SANs), stable lineage identity and independent
all-lineage preservation.

There are no workflow inputs for arbitrary archive templates,
encryption migration, automatic S3 recovery or broad certificate
renewal/deletion. The
[full public configuration reference](../configuration-reference.md)
documents the supported producer settings and their exact
CLI > exported environment > literal file > defaults precedence.

**Positive retention can delete S3 objects.** It requires
`dated_backup_enabled=true` and the reviewed restrictive
date-shaped backup namespace, complete managed metadata
verification, and conditional exact-key deletion. The current
S3 key is never a retention target. Leave retention at `0`
unless the operator has independently reviewed the
[retention rules](../managed-backup-retention-policy.md),
IAM delete scope, and recovery procedure.

## IAM permissions and audit controls

A narrowly scoped role needs only the supported operations
for the chosen mode: S3 Head/GetObject, current-key PutObject
and required bucket ListBucket checks; Route53 DNS-01 TXT
record changes plus necessary hosted zone and change-status
reads. Dated backups add exact-key conditional PutObject and
metadata checks. Retention adds narrow list/HEAD/ETag-
conditional DeleteObject permissions for a validated namespace.
S3 KMS keys, bucket policy, hosted-zone scope and the role
session's permission boundary may impose further constraints.
This guidance is **not** a deployable IAM JSON policy;
permissions must be reviewed against the actual S3/Route53
calls and account context.

Keep the OIDC trust policy restricted to the exact expected
GitHub audience/subject and the GitHub environment's deployment
branch/reviewer protection. Grant `id-token: write` only to
the particular job that requires it. A workflow with that
permission is not automatically authorized to access S3;
misconfigured role trust, however, can grant it to unintended
branches or environments. Review the selected IAM principal,
GitHub protected environment and AWS CloudTrail identity for
each authorized run.

If operators later add `schedule`, treat the change as
**new live authority**, not a harmless cron example:
first review source ref, protected environment behavior,
timezone, retry concurrency, expiry, certificate renewal
semantics, and destructive retention. Never enable cloud
operations from PR workflow events or arbitrary fork branches.

## Results, failures and recovery

An unchanged validated certificate may produce exit 0 with
`published=false`. A changed certificate or durable state
requires a validated current-key publication. A failed
GetObject, unsafe tar, wrong GPG key, invalid SAN set,
Certbot error or candidate-validation failure prevents
intentional later publication. The job directly executes
the producer and preserves its exit status, so an AWS
publication failure or partial-success backup/retention
failure makes the GitHub job fail.

An S3 PutObject may have been accepted even when the CLI
response is missing or nonzero. A successful current write
followed by a failed dated write or retention operation
is **nonzero partial success**, never an automatic rollback.
Stop competing writers, independently inspect the exact
current key and any managed dated backups, validate candidate
state, and coordinate recovery before retrying. A historical
backup key is **not** a safe producer read-only recovery
target. The [separate client](../separate-client-contract.md)
downloads only the operator-selected *current* key, extracts
safely to a new private destination and does not install or
reload certificates.

The workflow does not call a deployment script on the
target server. Downstream download, certificate installation,
configuration reload and verification remain separate
operator-controlled processes. Successful producer execution
is not evidence that any TLS service has activated a
replacement certificate.

## Verification limits and references

This documentation task did **not** place the example under
an active GitHub workflow directory, assume any AWS IAM role,
read any real secret, connect to S3/Route53/ACME, or
deploy any certificate. Repository CI and static YAML checks
can confirm syntax, structure and linting, but cannot
establish that the operator's actual IAM trust policy,
runner GnuPG capability, network topology or cloud accounts
are correctly provisioned.

Useful references:

- [Producer configuration reference](../configuration-reference.md)
- [Complete certbotbot lifecycle](../how-it-works.md)
- [Release attestations and verification](../release-verification.md)
- [Dated backup publication](../dated-backup-publication-contract.md)
- [Retention safety verification](../retention-safety-verification.md)
- [Repository security decisions](../decisions.md)
- [AWS GitHub OIDC credentials action](https://github.com/aws-actions/configure-aws-credentials)
- [GitHub's AWS OIDC guide](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)
