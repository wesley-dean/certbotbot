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
  multiple independent lineages; unrelated lineages are never modified
  by default. `RENEW_ALL=true` is a separate opt-in to check every
  *existing* complete archived lineage, without implicit issuance or deletion.
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
Let's Encrypt account for the selected CA** (production by default, or
explicit staging) and an **already seeded S3 archive**. Never mix staging
and production account state within one archive or S3 object key.

The ordinary certificate lifecycle does **not** create Let's Encrypt accounts,
S3 buckets, IAM roles, hosted zones, or an initial archive.  The separate,
explicit `register` command is the only path permitted to create a native
account-only archive at a positively missing S3 key.  The tool does not
provision a web server, install or reload target certificates, implicitly
renew every stored lineage, delete orphaned lineages **without an explicitly
complete desired-lineage set and destructive opt-in**, provide distributed
locking, or implicitly migrate encrypted/plaintext formats. Other storage backends,
DNS providers and archive formats are not supported by the current
producer. A container image is a distribution choice, not additional
account-provisioning or certificate-serving functionality.

Opt-in bulk maintenance is deliberately bounded: `--renew-all true` checks
all validated **existing** archived lineages once, using their stored
renewal configurations and a preexisting account. A domainless run is
permitted only with a nonempty complete restored lineage inventory.
Explicit selected issuance remains possible, while unrelated SANs are not
reconciled. Only a fully verified complete result may publish to the existing
current key. See [ADR-058](doc/adr/ADR-058-opt-in-archived-lineage-bulk-renewal.md)
and the [bulk renewal scope matrix](doc/renew-all-contract.md).

Opt-in `--remove-orphans true` reconciles the shared archive against a
**separate, complete, explicitly supplied** set of stable certificate
lineage names. Use repeatable `--desired-cert-name NAME` inputs (or the
literal `DESIRED_CERT_NAMES` collection); selecting a domain or SAN does
not implicitly authorize deletion. An invalid, missing, or partially
specified desired set fails before mutation, and `RENEW_ALL=true`
cannot be combined with removal. Only already validated orphan paths
inside the isolated workspace are pruned after the ordinary selected
operation succeeds. See [ADR-059](doc/adr/ADR-059-explicit-desired-lineage-orphan-removal.md)
and the [orphan removal contract](doc/orphan-removal-contract.md).

See [How certbotbot works](doc/how-it-works.md) for the complete lifecycle
and [the threat model](doc/mvp-certificate-state-threat-model.md) for
specific trust boundaries and failure assumptions.

## How the pieces fit

The one-shot producer restores validated Certbot account and certificate
state from S3, runs the selected Route53 DNS-01 operation, verifies the
candidate state, and conditionally republishes the current archive.
Installation and TLS reloads remain operator responsibilities. See the
[architecture diagram and lifecycle walkthrough](doc/operator-quickstart.md#how-the-pieces-fit)
and [full lifecycle contract](doc/how-it-works.md).

## Explicit account registration

Use the separate `certbotbot register` command to initialize native
account-only state in an existing S3 bucket. It requires an email address,
affirmative subscriber-terms consent, and a selected CA; it does not request
a certificate. Keep staging and production account state in different keys.
See the [registration walkthrough](doc/operator-quickstart.md#explicit-account-registration)
and [registration contract](doc/acme-account-registration-contract.md).

## Quick start: existing account and seeded archive

Ordinary issuance requires an existing compatible Let's Encrypt account,
a seeded S3 archive, an existing Route53 zone, correctly scoped AWS access,
and a trusted, independently verified release executable. Use the
[operator quick start](doc/operator-quickstart.md#quick-start-existing-account-and-seeded-archive)
for the complete prerequisites, immutable release download and attestation
checks, and failure/recovery guidance.

Once those prerequisites are independently established, an example invocation is:

```bash
./certbotbot.bash \
  --s3-bucket my-existing-certificates \
  --s3-key latest.tar.gz \
  example.com
```

These are illustrative names, not provisioned resources. By default, the
selected DNS name also requests its complementary apex/wildcard SAN. A
successful command does not install or deploy the resulting certificate.

## Common configuration

Settings resolve **CLI > explicitly exported environment >
literal selected `.env` > built-in defaults**. The presence-only
`--no-env` flag disables producer application environment and file
configuration while preserving explicit CLI settings and external AWS
credential mechanisms. It also suppresses environment-only GPG secrets;
use it only when the selected archive and encryption mode are compatible.
Without an explicit `--config FILE`, the optional `./.env` file is read
as strict **data**, never sourced as shell code. Unknown or
duplicate entries and shell expansion are rejected.

Optional `--aws-args`, `--gpg-args` and `--certbot-args` flags accept
bounded JSON argument arrays; the same collections can come from the
exported `AWS_EXTRA_ARGS`, `GPG_EXTRA_ARGS` and `CERTBOT_EXTRA_ARGS`
variables. They are deliberately restricted to the documented safe
upstream options and require `jq` and `base64` only when configured.
See [ADR-056](doc/adr/ADR-056-extra-provider-argv-and-no-env.md).
The [full configuration reference](doc/configuration-reference.md)
is authoritative for values, edge cases, precedence and all
public flags. The [source-checked producer/register option inventory](doc/producer-option-inventory.md)
additionally distinguishes registration-only options, repeatable
whole-collection settings, environment-only provider JSON vectors,
secret-only values, and implemented/destructive bulk-mode support.

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
| `--renew-all` | `RENEW_ALL` | `false`; opt in to checked due-renewal of every original validated archived lineage, without implicit issuance |
| `--remove-orphans` | `REMOVE_ORPHANS` | `false`; **destructive** opt-in, requires an explicit complete desired lineage set and selected certificate |
| `--desired-cert-name` (repeatable) | `DESIRED_CERT_NAMES` | No default; complete desired set for orphan pruning, CLI list or comma-separated environment/file list |
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

Operators starting without an S3 bucket can consult the
[manual AWS bucket-bootstrap and least-privilege runtime IAM guide](doc/examples/aws-bucket-bootstrap.md);
the accompanying [IAM policy template](doc/examples/aws-iam-policy.json)
is intentionally uninstantiated and is not run by this repository.
The account must then be explicitly registered before ordinary issuance.

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

Start with the [from-zero-S3 first-certificate guide](doc/administrator-first-certificate.md)
before activating any certificate-maintenance automation.

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

## Credential-free local protocol E2E CI

The [local protocol CI workflow](.github/workflows/local-protocol-e2e.yml)
exercises real Certbot, Pebble, and SeaweedFS using isolated test fixtures.
DNS-01 validation is intentionally bypassed, and Route53 is stubbed;
success does **not** prove live AWS or Let's Encrypt integration.
See [testing and CI](doc/testing-and-ci.md#credential-free-local-protocol-e2e-ci).

## Manual staging E2E acceptance

Real Let's Encrypt staging and AWS acceptance requires a separately
authorized, operator-triggered test. See the
[staging acceptance overview](doc/testing-and-ci.md#manual-staging-e2e-acceptance)
and [manual staging workflow](doc/milestone-4-live-staging-workflow.md).

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

### Testing regimen

`make check` validates maintained source; `make test` exercises
all three verified producer flavors. CI also checks the independent
client, OCI runtime, release provenance, and local protocol lifecycle.
See the [testing and CI overview](doc/testing-and-ci.md),
[detailed testing contracts](doc/testing.md), and
[release verification](doc/release-verification.md).

`make format` applies the shfmt profile; `make adr-index` and
`make docs` generate ignored reference output.

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

Native issue relationships and optional GitHub Projects v2 status are
maintained by separate repository administration scripts, outside the
certificate-management product. See the
[GitHub issue and Kanban automation guide](doc/github-issue-automation.md#github-issue-metadata-synchronization)
for authentication, commands, safety checks, and governance.

### Native issue dependency synchronization

Dependency synchronization remains **disabled in Actions** pending an
audit. See [the documented safety boundary](doc/github-issue-automation.md#native-issue-dependency-synchronization).

### Read-only Markdown Kanban report

See [how to render the issue-derived board](doc/github-issue-automation.md#read-only-markdown-kanban-report).

### Publish Kanban into a managed issue

See [how the managed issue is created and updated](doc/github-issue-automation.md#publish-kanban-into-a-managed-issue).
