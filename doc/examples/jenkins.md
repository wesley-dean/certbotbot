# Jenkins: manually controlled certbotbot producer example

[Example Jenkinsfile](Jenkinsfile) is intentionally located under
`doc/examples/`, **not** the repository root. Merging this file does not
create a Jenkins job, schedule, deploy anything, or issue certificates.
It is the bounded illustration for approved [task #155](https://github.com/wesley-dean/certbotbot/issues/155)
and documentation [story #151](https://github.com/wesley-dean/certbotbot/issues/151).
Adapt it in an operator-controlled Jenkins installation only after review.

## What it does and does not do

The example demonstrates a **manual, one-shot producer run** from an explicitly
reviewed `certbotbot.bash` GitHub release. It verifies the release's matching
`.sha256` sidecar **and** an independently reviewed, Jenkinsfile-pinned
executable SHA-256 before executing it. It then selects one DNS certificate
lineage, downloads and validates a **pre-existing** S3 current archive, runs
Certbot with Route53 DNS-01 when needed, and conditionally republishes that
same current object. Optional dated backups and deletion-based retention
are disabled by default.

It does **not** create a bucket, register a Let's Encrypt account, create the
initial archive, configure Route53/IAM, schedule itself, renew every lineage,
remove orphans, provision a registry image, install a certificate on a
consumer host, or reload that host. There is no automated merge or
deployment. The separate read-only
[certificate client](../separate-client-contract.md) is a different product.

A trusted runner's AWS role or credential provider and the producer have
their normal network privileges. This example is **not a sandbox** and
must never run with secrets on an unreviewed PR's Jenkinsfile, arbitrary
fork/SCM head, or a shared untrusted agent.

## Required operator setup

1. Provision a dedicated, trusted Linux Jenkins agent labeled
   `certbotbot-trusted-linux`, with a private workspace, Bash 4.3+, AWS
   CLI v2, Certbot and its `dns-route53` plugin, OpenSSL, GNU tar/gzip
   and core utilities, `curl`, and SHA-256 tools. Install GnuPG 2.4.7+
   with **verified AES-256/OCB support** only if the selected current
   archive is encrypted. Install packages from reviewed sources.
2. Independently configure an AWS instance/task role or another
   narrowly scoped agent-level **credential provider**. The example
   deliberately does not define raw `AWS_ACCESS_KEY_ID`,
   `AWS_SECRET_ACCESS_KEY`, access tokens, AWS account IDs, or
   `withCredentials` bindings for AWS. If the environment cannot use a
   role, separately adapt the job to Jenkins credential binding with
   secret masking, least privilege, and no Groovy-to-shell interpolation.
   Do **not** commit real credentials or add them as job parameters.
3. Seed an **existing** S3 bucket/key with a complete, validated
   account-only or certificate-containing Certbot archive including an
   **existing registered production Let's Encrypt account**. Provision
   a matching Route53 hosted zone and correct delegation. Test IAM
   read/write/conditional capabilities and Certbot DNS permissions in
   a separately authorized environment.
4. Independently review an immutable GitHub release and its attestation
   and checksums in the [release verification procedure](../release-verification.md).
   Replace `CERTBOTBOT_RELEASE_TAG=REPLACE_WITH_REVIEWED_TAG`
   with the **exact reviewed stable `vMAJOR.MINOR.PATCH` tag**, and
   `CERTBOTBOT_RELEASE_SHA256=REPLACE_WITH_REVIEWED_SHA256`
   with the reviewed ordinary producer's exact 64-character lowercase
   SHA-256 digest. The script **intentionally fails** if these
   placeholders are unchanged. The digest must be confirmed
   independently of the freshly downloaded release and sidecar;
   those two same-origin downloads alone are not a trust anchor.
5. Configure Jenkins to run only the controlled job, from a protected
   and reviewed configuration, on the dedicated agent. An administrator
   must control "Build with Parameters" privileges and any credentials.
   Copy `doc/examples/Jenkinsfile` to an intentionally activated
   job, or point a protected Pipeline configuration directly at that
   specific reviewed revision. **Do not** let a PR Jenkinsfile acquire
   certificate-management authority.
6. Ensure a **single writer across all systems and jobs** for each
   authoritative current S3 bucket/key, including any cron, GitHub
   Actions, Docker/Podman, and direct Bash invocations. Jenkins
   `disableConcurrentBuilds` protects only this job, not all
   independent writers. Use an externally governed lock or an operator
   scheduling policy for cross-job serialization.

No Jenkins `triggers` stanza is present: merging this documentation
cannot activate a timer. Add a separately reviewed scheduled trigger
only if the job owner explicitly accepts the AWS/ACME effects, UTC/time
zone, retries, and cross-run concurrency. Repeated runs might publish
new state or delete older **managed** backup objects when positive
retention is deliberately enabled.

## Parameter reference

Parameters are **not secrets**; people with access to Jenkins build
metadata may see their values.

| Jenkins parameter | Example default | Behavior |
| --- | --- | --- |
| `DOMAIN` | `example.com` | **Placeholder must be replaced** before running; selects one primary DNS identity |
| `S3_BUCKET` | Empty | **Must** be filled with the existing seeded archive bucket |
| `S3_KEY` | `latest.tar.gz` | Literal existing current object key, **not** a recovery backup key |
| `CERT_NAME` | Empty | Optional stable non-wildcard selected Certbot lineage name; omission derives it |
| `INCLUDE_SUBDOMAINS` | `true` | Expand each requested name to its apex/wildcard complement |
| `DATED_BACKUP_ENABLED` | `false` | Explicit additional managed backup publication opt-in |
| `BACKUP_RETENTION_COUNT` | `0` | **No deletion** by default; positive 1–10000 may delete old eligible backups |
| `ARCHIVE_ENCRYPTION` | `none` | Treat existing current archive as plaintext, or deliberately select `gpg-ocb` |

The example does **not** expose migration, variable backup filename
templates, arbitrary `--san` collections, force-no-op upload, or
`UPLOAD_NO_RENEWAL=true` as Jenkins parameters. Add them only
through separate operator review against the
[complete producer configuration reference](../configuration-reference.md).
The standard product's `INCLUDE_SUBDOMAINS=true` expands `example.com`
to include `*.example.com`; disable if your requested certificate should
contain **only** the literal primary name. Use an explicit
`CERT_NAME` when a changed SAN set might otherwise select a
different existing lineage.

The example always uses `--upload-no-renewal false`, meaning an
unchanged validated no-op does not publish; a durable renewal or
account-metadata change still does. Positive backup retention requires
new current-plus-dated publication, complete managed-object inventory,
and ETag-conditional deletion. If unsure, keep retention `0`.

## Credential and secret handling

For plaintext archives, no `GPG_SYMMETRIC_KEY` is bound by the
example. For `ARCHIVE_ENCRYPTION=gpg-ocb`, the script uses Jenkins
Credentials Binding's
`withCredentials([string(credentialsId: 'certbotbot-gpg-symmetric-key',
variable: 'GPG_SYMMETRIC_KEY')])`. Create that exact **Secret text**
credential in the appropriate restricted Jenkins scope before using
encrypted mode. The secret value is not a parameter, `.env` entry,
GitHub file, release argument or Groovy-interpolated string.

The `sh` scripts start with an explicit Bash shebang, disable
xtrace (`set +x`), use single-quoted Groovy multiline script text,
construct a quoted Bash argument array, and avoid `eval`.
The producer itself captures and unexports the key before invoking
ordinary child processes. Jenkins masking and credential binding
limit accidental exposure; they cannot defend against a compromised
agent, administrator, or installed executable. Avoid exporting global
secret environment variables, logging `env`, saving raw core dumps,
or archiving `/etc/letsencrypt` or private run workspaces as Jenkins
artifacts.

The download stage runs **before** any GPG secret binding, retrieves
only the ordinary producer and its sidecar over HTTPS from the
fixed repository's exact release tag, requires the sidecar to validate,
then additionally compares the executable hash to the operator-pinned
digest, checks Bash syntax, and gives it owner-only executable
permission. No floating `latest`, unchecked `curl | bash`,
unreviewed file from a PR, or binary fetched with registry credentials
is accepted. A matching sidecar does **not** replace release attestation
review, signature policies, or the independent SHA pin.

Jenkins `post { always { deleteDir() } }` removes the workspace
download, but this is **cleanup**, not guaranteed secure erasure or
a replacement for private temporary files and a trusted runner.
The producer separately owns and removes its invocation workspace.
No certificate, ACME account, GPG key, or downloaded archive should
be archived as a build artifact.

## IAM and network authority

The role should allow only the selected bucket/key's required reads
and writes (`s3:GetObject`, `s3:PutObject`, appropriate
`s3:ListBucket` for absence classification) and tightly scoped
Route53 TXT challenges and status inspection for the requested zones.
If dated backups are enabled, narrowly scope managed backup
metadata and conditional writes. If retention is enabled, additionally
allow the **specific** list, HEAD and ETag-conditional delete
operations within the accepted template scope, and protect the
authoritative current key from deletion. Actual AWS authorization
may depend on bucket versioning, KMS, policy boundaries, and
conditional API support. This is a capability overview, **not a
ready-to-deploy IAM policy**.

The runner needs outbound access to S3, Route53, AWS role/metadata
endpoints as applicable, the Let's Encrypt production ACME endpoint,
and GitHub release downloads. DNS-01 challenges may cross multiple
hosted zones for multi-SAN certificates. Jenkins does not create
those network paths or zone permissions automatically.

## Failure semantics, monitoring, and recovery

A successful invocation reports the selected lineage and
`published=true|false`; backups/retention add their own nonsecret
status fields when enabled. The pipeline propagates the executable's
status directly. **Do not** replace the producer call with
`|| true`, `returnStatus: true` without a fatal check, or a
console grep that could mask a nonzero status. Jenkins marks the
build failed when validation, renewal, or an archive publication
step fails.

Once an S3 PutObject was attempted, a lost or nonzero CLI response
does **not** prove the previous object survived unchanged. A
confirmed current write followed by uncertain dated backup or
retention is **partial success**: do not blindly retry or assume
automatic rollback. Stop competing writers, inspect the exact
current key and any managed recovery copies independently, validate
the bytes, and coordinate a known-good recovery with downstream
consumers. An S3 backup named by date is **not** a safe producer
read-only retrieval target. The standalone read-only
[client](../separate-client-contract.md) can extract the **current**
object to a new private destination but does not install it into a
service.

See [How it works](../how-it-works.md),
[configuration and flags](../configuration-reference.md),
[container operator guidance](../container-deployment.md),
[trust model](../mvp-certificate-state-threat-model.md),
[archive recovery](../dated-backup-recovery-verification.md),
and [ADR-020](../adr/ADR-020-one-selected-certificate-and-one-durable-archive.md).
No Jenkins, S3, Route53, or ACME live integration was executed when
creating this documentation example.
