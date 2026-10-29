# certbotbot

**certbotbot** is a noninteractive certificate-management producer for
existing Let's Encrypt/Certbot accounts. It uses **Route53 DNS-01** to
issue or renew a selected certificate, persists the complete validated
Certbot account and certificate state in an **existing Amazon S3 object**,
and can resume on a fresh Linux runner without relying on that runner's
previous `/etc/letsencrypt` directory.

An explicitly invoked `certbotbot register` operation can now provision and
persist a Let's Encrypt account without requesting a certificate.  Ordinary
issuance and renewal never register an account implicitly.  This new path
has only mocked acceptance coverage pending milestone #4 live staging checks.

It is designed for scheduled or manually initiated, **one-shot Bash**
execution. Docker and rootless Podman are optional ways to run the same
producer; neither is required.

**[Releases](https://github.com/wesley-dean/certbotbot/releases) ·
[Complete lifecycle](doc/how-it-works.md) ·
[Configuration and CLI](doc/configuration-reference.md) ·
[Operator examples](#operator-examples) ·
[Architectural decisions](doc/decisions.md) ·
[Issues](https://github.com/wesley-dean/certbotbot/issues)**

## Why use certbotbot?

- **Ephemeral runners:** A new trusted machine can restore the existing
  registered account and certificate lineages from one configured S3 object.
  Only the S3 archive, not the runner's local workspace, is durable.
- **Explicit, bounded certificate selection:** One invocation targets **one
  named certificate lineage** with a validated set of DNS Subject Alternative
  Names (SANs), including unrelated domains. The same archive may preserve
  multiple independent lineages, but other lineages are not implicitly
  renewed or removed.
- **Verification before publication:** Downloaded archives, restored account
  state, selected certificate material, canonical renewal metadata, and
  candidate output pass separate checks. A verified unchanged no-op does
  **not** rewrite S3 by default.
- **Optional confidentiality and recovery copies:** Authenticated
  GnuPG AES-256/OCB encryption, a deliberately authorized
  plaintext-to-encrypted migration, dated recovery copies, and
  narrowly scoped backup retention are available as opt-ins. Backup
  publication defaults **off**; retention defaults to **zero deletes**.
- **Separation of concerns:** The producer owns certificate maintenance.
  A separately shipped **read-only client** can retrieve and validate the
  current archive; the operator owns installation and service reloads.
  A certificate-serving host does **not** need Certbot merely to consume
  validated certificate files.

### Supported boundaries

The current producer supports **S3 storage**, **gzip-compressed GNU tar**
state archives (optionally inside an authenticated GPG envelope), and
**Certbot with Route53 DNS-01**. It relies on a **previously registered
Let's Encrypt account for the **selected CA** (production by default, or
explicit staging) and an **already seeded S3 archive**. Never mix staging
and production account state within one archive or S3 object key.

The ordinary certificate lifecycle does **not** create Let's Encrypt accounts,
S3 buckets, IAM roles, hosted zones, or an initial archive.  The separate,
explicit `register` command is the only path permitted to create a native
account-only archive at a positively missing S3 key.  The tool does not
provision a web server, install or reload target certificates, automatically
renew all stored
lineages; delete orphaned lineages; provide distributed locking; or
implicitly migrate encrypted/plaintext formats. Other storage backends,
DNS providers and archive formats are not supported by the current
producer. A container image is a distribution choice, not additional
account-provisioning or certificate-serving functionality.

See [How certbotbot works](doc/how-it-works.md) for the complete lifecycle
and [the threat model](doc/mvp-certificate-state-threat-model.md) for
specific trust boundaries and failure assumptions.

## How the pieces fit

```mermaid
flowchart LR
    operator[Operator-managed scheduler, AWS IAM and secrets]

    subgraph runner[Trusted ephemeral Linux, Docker or Podman runner]
        cli[certbotbot Bash producer]
        private[Private temporary Certbot config, work and logs]
        verify[Archive, lineage, SAN, key and candidate verification]
        cli --> private
        private --> verify
        verify --> cli
    end

    subgraph aws[Operator-provisioned AWS resources]
        current[(Existing S3 current archive)]
        backups[(Optional dated S3 recovery copies)]
        route53[Existing Route53 hosted zones]
    end

    acme[Existing Let's Encrypt account and ACME service]
    consumer[Separate read-only client or operator download]
    service[Operator-managed certificate installation and TLS reload]

    operator --> cli
    current -->|Restore existing account and lineages| cli
    cli -->|Selected DNS-01 challenge| route53
    route53 <--> acme
    cli -->|Verified, conditional current publication| current
    cli -.->|Opt-in dated backup and retention| backups
    current -->|Independent read| consumer
    consumer -->|Operator-controlled installation| service
```

An archive is the **contents of the Certbot configuration root**
(`/etc/letsencrypt`) using validated relative members and canonical
renewal metadata. The exact configured **current S3 bucket/key**
(default `latest.tar.gz`) is authoritative. A successful certificate
run does not imply downstream deployment. A failed or interrupted
S3 PutObject may have changed the remote object even if the
producer returns nonzero: the operation is **not** a transaction.

## Explicit account registration

The account-provisioning command is separate from certificate issuance.
It requires a contact email, an existing S3 bucket, and affirmative consent
to the Let's Encrypt subscriber terms.  EFF email signup defaults to
`true` and may be disabled explicitly.  Production is the default CA;
select `--acme-environment staging` when testing, with a **different S3
key** to keep account contexts separate.  For example, after reviewing
the terms and configuring AWS credentials:

```bash
./certbotbot.bash register \
  --email operator@example.org \
  --agree-tos true \
  --eff-email-signup false \
  --s3-bucket my-existing-certificates \
  --s3-key latest.tar.gz
```

The address and bucket are illustrative.  The command uses isolated
Certbot state, a verified account-only tar archive and conditional S3
publication.  No certificate is issued.  A confirmed missing S3 key is
permitted only for explicit registration; access errors and ambiguous state
are fatal.  The ordinary issuer accepts a *separate*, explicitly selected staging
CA and archive under ADR-042. Registration never implicitly starts issuance;
any milestone 4 live test must explicitly use staging and must never reach
Let's Encrypt production.
See [the registration contract](doc/acme-account-registration-contract.md)
and [ADR-041](doc/adr/ADR-041-explicit-acme-account-registration-and-state-initialization.md).

## Quick start: existing account and seeded archive

This is a **production-adjacent example, not an unattended setup
script or evidence of a live service test**. Prepare the prerequisites
before executing any credentialed command:

1. **Account and archive:** Register a suitable production
   Let's Encrypt account **outside certbotbot**. Populate an existing
   S3 bucket and current object with a valid full Certbot-state
   `tar.gz` containing that account, including its registration
   metadata and private key. An account-only archive is allowed
   for the initial certificate issuance; a missing archive or
   missing account is **not**.
2. **DNS and AWS identity:** Provision a Route53 hosted zone for
   the requested DNS-01 challenges and a trusted AWS CLI identity
   with narrowly scoped S3 reads/writes and necessary Route53
   TXT-change and status-check permissions. Configure AWS region,
   network access and credential delivery separately. If dated
   backups or retention are enabled, review their additional
   conditional-write/list/delete permissions first.
3. **Trusted Linux toolchain:** Install Bash **4.3+**, AWS CLI
   **v2**, Certbot with the `dns-route53` plugin,
   OpenSSL, GNU tar/gzip and standard file/hash utilities.
   GnuPG **2.4.7+ with working AES-256/OCB support** is
   additionally required for encrypted archives. The runner
   must keep its temporary Certbot workspace private.
4. **Reviewed release artifact:** Choose an immutable reviewed
   release tag, verify the [release checks and provenance](doc/release-verification.md),
   and obtain an **independently verified** SHA-256 for the
   ordinary `certbotbot.bash` executable. Never treat the
   downloaded executable and its same-origin checksum alone as
   sufficient proof of release trust.
5. **Only one writer per current key:** Schedule and coordinate
   certificate jobs so that two producers cannot concurrently
   modify the same authoritative bucket/key, even across
   Jenkins, GitHub Actions, containers and other hosts.

With the GitHub CLI, a trusted `sha256sum` implementation and
the expected digest obtained **out-of-band from your review**,
the following shell example fails closed until its placeholders
are replaced:

```bash
set -euo pipefail
umask 077

RELEASE_TAG='vREPLACE_WITH_REVIEWED_TAG'
EXPECTED_SHA256='REPLACE_WITH_INDEPENDENTLY_REVIEWED_64_HEX_DIGEST'

[[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]]

mkdir -m 0700 ./certbotbot-release
cd ./certbotbot-release
gh release download "$RELEASE_TAG" \
  --repo wesley-dean/certbotbot \
  --pattern certbotbot.bash \
  --pattern certbotbot.bash.sha256

sha256sum --check certbotbot.bash.sha256
actual="$(sha256sum certbotbot.bash | awk '{print $1}')"
[[ "$actual" == "$EXPECTED_SHA256" ]]
gh attestation verify certbotbot.bash \
  --repo wesley-dean/certbotbot >/dev/null
gh attestation verify certbotbot.bash.sha256 \
  --repo wesley-dean/certbotbot >/dev/null

bash -n certbotbot.bash
chmod 0700 certbotbot.bash
./certbotbot.bash --help
./certbotbot.bash --version
```

For the **standalone Bash tools**, rather than the container image,
the ordinary producer and separate read-only client are available from
[GitHub Releases](https://github.com/wesley-dean/certbotbot/releases).
You can also use [`vet`](https://github.com/vet-run/vet) to download,
inspect, lint (when ShellCheck is available), and explicitly approve
a remote release script **before executing it**, for example:

~~~bash
vet https://github.com/wesley-dean/certbotbot/releases/latest/download/certbotbot.bash --help
vet https://github.com/wesley-dean/certbotbot/releases/latest/download/certbotbot-client.bash --help
~~~

`vet` runs the fetched script for this invocation; it does not install
a permanent copy or replace independent release and attestation checks.
Use the release assets above when you need locally installed executables.

The download commands intentionally do **not** contact S3, Route53
or ACME. Once the real account, archive, permissions and selected
domain have been **independently prepared**, an ordinary invocation
from that private directory looks like:

```bash
./certbotbot.bash \
  --s3-bucket my-existing-certificates \
  --s3-key latest.tar.gz \
  example.com
```

Here `my-existing-certificates` and `example.com` are **illustrative
values**, not provisioned resources. The default
`INCLUDE_SUBDOMAINS=true` also requests the complementary wildcard
SAN, so `example.com` normally requests both `example.com`
and `*.example.com`. Use `--include-subdomains false`
when only the literal name is desired. For a stable lineage
across SAN changes, use an explicit `--cert-name`.

A successful run prints a nonsecret selected-lineage and
`s3://bucket/key` status containing `published=true`
or `published=false`. An unchanged, validated no-op is still
success and normally skips the remote write. A failed provider,
unsafe archive, mismatched certificate/key or incomplete candidate
must not authorize publication; after an attempted remote write,
the remote state can be **uncertain**. Inspect the current object
independently rather than blindly retrying a failed or partial
publication. See [failure and recovery details](doc/how-it-works.md).

## Common configuration

Settings resolve **CLI > explicitly exported environment >
literal selected `.env` > built-in defaults**. Without an
explicit `--config FILE`, the optional `./.env` file is read
as strict **data**, never sourced as shell code. Unknown or
duplicate entries and shell expansion are rejected. The
[full configuration reference](doc/configuration-reference.md)
is authoritative for values, edge cases, precedence and all
public flags.

| CLI | Environment / literal `.env` | Default or purpose |
| --- | --- | --- |
| `--acme-environment` | `ACME_ENVIRONMENT` | `production` by default; opt into `staging` for a matching test archive |
| `DNS_NAME` or `--domain` | `DOMAIN` | **Required** primary DNS name |
| `--san` (repeatable) | `ADDITIONAL_SANS` | Optional additional names; CLI replaces lower-tier SAN collection |
| `--include-subdomains` | `INCLUDE_SUBDOMAINS` | `true`; add complementary apex/wildcard for each name |
| `--cert-name` | `CERT_NAME` | Derive shortest valid SAN name unless explicitly set |
| `--s3-bucket` | `S3_BUCKET` | **Required** existing bucket |
| `--s3-key` or `--s3-key-template` | `S3_KEY` or `S3_KEY_TEMPLATE` | Current object; default literal `latest.tar.gz` |
| `--upload-no-renewal` | `UPLOAD_NO_RENEWAL` | `false`; do not republish an unchanged verified no-op |
| `--dated-backup-enabled` | `DATED_BACKUP_ENABLED` | `false`; opt in to an additional dated recovery object |
| `--backup-key-template` | `BACKUP_KEY_TEMPLATE` | `archive-{YEAR}{MONTH}{DOM}.tar.gz`; naming alone does not enable publishing |
| `--backup-retention-count` | `BACKUP_RETENTION_COUNT` | `0`; **no deletion** unless positive and dated backups enabled |
| `--archive-encryption` | `ARCHIVE_ENCRYPTION` | `auto`: plaintext without key, GPG OCB with exported key |
| `--archive-migration` | `ARCHIVE_MIGRATION` | `none`; explicit one-way migration only |
| `--archive-migration-backup-confirmed` | `ARCHIVE_MIGRATION_BACKUP_CONFIRMED` | `false`; independent recoverable-backup acknowledgment |

The **secret** `GPG_SYMMETRIC_KEY` is accepted **only as an
exported process-environment variable**, never as a CLI option
or literal `.env` key. Use a trusted secret manager and ensure
it is absent from command arguments, build inputs, files and
logs. Selecting `ARCHIVE_ENCRYPTION=none` while supplying a
nonempty key fails closed; migration requires explicit mode,
key and independently confirmed backup.

The current key and a separately selected date-derived
current-key template conflict **only when both are set at the
winning precedence tier**. Templates use a frozen UTC date
and the supported `{YEAR}`, `{MONTH}`, `{DOM}` tokens.
Positive retention additionally requires stricter managed
date-shaped backup keys and can delete eligible older
objects. No option automatically creates a recovery backup
or restores it on failure.

Run `./certbotbot.bash --help` or
`./certbotbot.bash --version` without cloud access.
The full reference covers exact Boolean syntax, SAN limits,
status codes, invalid combinations and encryption migration
safety.

## Standalone read-only client

The separate `certbotbot-client.bash` release artifact retrieves
**one current** selected S3 object, validates it, and extracts
the complete supported Certbot state into a **new, absent
operator-selected destination**. It does not issue or renew
certificates, write to S3, delete backups, install certificate
files into a service or reload that service. A target system
does not need Certbot to use previously issued material.

Download its matching `.sha256` companion, independently
verify the release and attestations as above, then invoke
the client with an existing read-only AWS identity and
a fresh private destination:

```bash
./certbotbot-client.bash \
  --s3-bucket my-existing-certificates \
  --s3-key latest.tar.gz \
  --destination "$HOME/certificate-states/current"
```

The destination **must not already exist**, and its parent
must satisfy the client's private-directory requirements.
For encrypted objects, the client also needs compatible GnuPG
and a matching exported secret. See
[client settings](doc/client-settings.md),
[client examples](doc/examples/certbotbot-client.md) and
[the separate-client contract](doc/separate-client-contract.md)
before adoption. The client is shipped **separately** and
is not embedded in the producer's OCI image.

## Containers and operator examples

The optional [Alpine OCI producer](Dockerfile) executes the
same one-shot CLI in Docker or rootless Podman. Its reviewed
scope is **linux/amd64**, nonroot UID/GID **65532**, a private
ephemeral state directory, a read-only root filesystem and
no baked credentials or ACME material. The image does **not**
schedule itself or automatically deploy certificates. AWS
workload identity or securely injected runtime credentials
must be provided by the operator.

After a successfully verified release, the publisher targets GHCR and
Docker Hub. To pull and inspect the current image from either registry:

~~~bash
docker pull --platform linux/amd64 ghcr.io/wesley-dean/certbotbot:latest
docker image inspect ghcr.io/wesley-dean/certbotbot:latest \
  --format '{{.Os}}/{{.Architecture}} {{.Config.User}}'

podman pull --arch amd64 --os linux docker.io/wesleydean/certbotbot:latest
podman image inspect docker.io/wesleydean/certbotbot:latest \
  --format '{{.Os}}/{{.Architecture}} {{.Config.User}}'
~~~

`latest` follows the most recently accepted release and can change.
For reproducible deployments, pinning a particular release or an
independently verified image digest is encouraged. See the deployment
guide for those options and for secure runtime examples. These commands
do not establish that a release image has already been published or
accepted in either registry.

The [Docker/rootless Podman published-image quick start](doc/examples/docker-podman.md#use-an-independently-verified-published-image)
includes direct `docker`/`podman` pull, label inspection, nonroot
read-only run examples, and the additional prerequisites for real
issuance. See the [full container deployment guide](doc/container-deployment.md),
[OCI publication and operator guide](doc/oci-image-publication.md), and
[publication contract](doc/oci-publication-contract.md) for
trust, credentials, registry recovery, upgrades, and release boundaries.
Local image build/runtime tests do **not** prove live registry
publication or certificate issuance in your environment.

### Operator examples

Examples under `doc/examples/` are **references, not active
production automation**:

- [Jenkins Pipeline and adoption guide](doc/examples/jenkins.md)
  with an [example-only Jenkinsfile](doc/examples/Jenkinsfile)
- [GitHub Actions workflow and OIDC guide](doc/examples/github-actions.md)
  with an [inert workflow example](doc/examples/certbotbot.yml)
- [Docker and rootless Podman runtime](doc/examples/docker-podman.md)
- [Standalone certificate client](doc/examples/certbotbot-client.md)

In particular, the GitHub Actions example is deliberately
**outside `.github/workflows/`**. An operator must separately
review and activate a protected workflow, credentials, IAM
trust policy, release pin and schedule. Examples do not
provision accounts or buckets, run live cloud operations on
PRs, or deploy certificates to consumer servers.

## Manual staging E2E acceptance

Milestone 4's real Let's Encrypt staging acceptance is operator-controlled,
using the separate [manual staging workflow](doc/milestone-4-live-staging-workflow.md)
and governing [ADR-043](doc/adr/ADR-043-manual-staging-live-e2e-workflow.md).
The workflow is never invoked from a pull request. It requires a trusted
`main` dispatch, explicit staging selection, an independently seeded staging
account-only S3 key, and a deliberate operator authorization. It does not
register an account, contact Let's Encrypt production, or provide ordinary
release publication authority. The successful fixture-only Bats suite does
not constitute real staging evidence.

## Building, testing and contributing

The maintained Bash source lives in `src/` and `lib/`.
GNU Make is the canonical build and test entrypoint.
Bash dependencies (including the pinned `mktext`
library used for safe filename templates) are prepared
before building; the resulting standalone scripts have
no runtime dependency on the repository's `vendor/` tree.

```bash
make deps
make deps-check
make build
make check
make test
```

`make deps` can access the network; `make deps-check`
and `make build` are network-free once dependencies
are prepared. `make test-report` writes JUnit output.
`make format` applies the repository's shfmt profile,
`make adr-index` generates temporary ADR navigation,
and `make docs` generates Doxygen reference output
without committing generated files.

The eight release assets comprise the three producer
flavors (`certbotbot.dev.bash`, `certbotbot.bash`,
`certbotbot.min.bash`) plus the distinct
`certbotbot-client.bash`, each with its `.sha256`
companion. Release CI independently verifies the
producer variants, required Bash compatibility and
authenticated standalone client, then attests the
exact files before releasing them. Read
[release verification](doc/release-verification.md)
before pinning executable versions or adopting a
production runner.

For contributor onboarding, start with
[AGENTS.md](AGENTS.md),
[testing guidance](doc/testing.md),
[the engineering philosophy](doc/engineering-philosophy.md),
[the architecture decision map](doc/decisions.md),
[accepted ADRs](doc/adr/README.intro.md),
[the Bash documentation standard](doc/documentation-standard.md),
[CONTRIBUTING.md](CONTRIBUTING.md),
and [the security disclosure policy](SECURITY.md).
The generated ADR index and Doxygen reference output
are not maintained source.

This repository uses an opt-in,
[three-phase approved development workflow](doc/standards/general/three-phase-development-governance.md).
A current issue's `approved` label records its own
authorization, not blanket permission for related
tasks; substantive architecture changes must respect
Accepted ADRs. Issues and PRs are reviewed separately
from CI success.

For support and project status, use
[SUPPORT.md](SUPPORT.md),
[GitHub Issues](https://github.com/wesley-dean/certbotbot/issues),
and [GitHub Actions](https://github.com/wesley-dean/certbotbot/actions).
The historical research record is in
[doc/research/](doc/research/README.md).
The project adopts a pinned released snapshot of
[coding standards](https://github.com/wesley-dean/coding_standards)
through [`.codingstandardrc`](.codingstandardrc).

## License

Dedicated to the public domain under **CC0 1.0 Universal**.
See [LICENSE](LICENSE), [CONTRIBUTING.md](CONTRIBUTING.md),
and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## GitHub issue metadata synchronization

The repository includes a GitHub Actions workflow and two independent Bash
scripts for synchronizing GitHub's native issue relationships and optionally
GitHub Projects v2 Status. This is repository administration tooling, not part
of the certificate producer or its releases.

Prerequisites for local use: `gh`, `jq`, and an exported `GH_TOKEN` with
appropriate permissions. In Actions, native relationships use the built-in
token with `issues: write`; only optional Projects synchronization requires
the repository secret `GH_TOKEN`. The workflow accepts no dispatch inputs; issue events
process the affected issue, and a manual dispatch or weekly scheduled run
processes the entire backlog.

```bash
export GH_REPO=wesley-dean/certbotbot
bash scripts/update_issue_parent_child_relationships.bash --issue 100
bash scripts/update_issue_parent_child_relationships.bash --all

# Projects integration is optional and disabled by default:
export PROJECT_NUMBER=0
bash scripts/update_issue_project_status.bash --issue 100

# To enable Projects v2, set a positive project number and ensure GH_TOKEN
# has permission to update the target Project.
export PROJECT_NUMBER=12
export PROJECT_OWNER=wesley-dean
bash scripts/update_issue_project_status.bash --all
```

Set repository Actions variable `PROJECT_NUMBER` to the appropriate positive
GitHub Projects number to enable project synchronization. Unset, empty, or
`0` skips the Projects job without affecting relationship reconciliation.
An optional `PROJECT_OWNER` variable overrides the repository owner.

Run the isolated mock checks with
`bash tests/issue-metadata-sync.bash`. Existing native parents are not
silently replaced when their Markdown declaration disagrees; failures
must be investigated. Project synchronization mirrors only status and does
not update approvals, issue closure, or milestones. See
[ADR-044](doc/adr/ADR-044-github-issue-metadata-synchronization.md).

### Native issue dependency synchronization

To add native GitHub blocking relationships, write a dedicated level-two `Blocked by` section with one bare issue reference
per line, for example `- #89` followed by `- #90`. References in
`Dependencies and Governing Decisions` are NOT blocking dependencies.
Dependency synchronization is temporarily disabled in Actions pending audit
and cleanup of incorrectly created relationships.
The script adds missing native blockers, verifies them, and preserves existing
relationships; it never removes them or infers dependencies from parentage.

```bash
export GH_REPO=wesley-dean/certbotbot
# GH_TOKEN must be available, as with the other issue scripts.
bash scripts/update_issue_dependencies.bash --issue 100
bash scripts/update_issue_dependencies.bash --all
# Offline mocked checks:
bash tests/issue-dependencies-sync.bash
```

The existing issue metadata workflow invokes this script independently using
its built-in token with `issues: write`, and its dedicated read-only PR test
workflow checks the mocked behavior. See [ADR-045](doc/adr/ADR-045-native-issue-dependency-synchronization.md).
