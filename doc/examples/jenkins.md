# Jenkins: manual, validated certbotbot producer example

For first-time setup, finish the [complete administrator walkthrough](../administrator-first-certificate.md)
before installing this manually invoked renewal example. This job
cannot provision AWS resources or register a Let's Encrypt account.

The [reviewable Jenkinsfile](Jenkinsfile) is an **example only**, deliberately
under `doc/examples/` rather than the repository root. Merging it does
not create or schedule a Jenkins job, issue a certificate, change S3,
register an account, or install anything. An administrator must review and
copy it into a separately trusted, access-controlled **manual** Jenkins
Pipeline. Task [#291](https://github.com/wesley-dean/certbotbot/issues/291)
updates the earlier limited Jenkins example to the source-audited
[full producer option inventory](../producer-option-inventory.md) created
by task #290. The example is intentionally **stricter** than the
general-purpose producer in a few high-risk places.

## What this example does and does not authorize

The Jenkins job, if *separately installed and manually authorized*, downloads
the **ordinary** `certbotbot.bash` artifact at an explicitly reviewed
immutable release tag, checks its downloaded checksum sidecar and a
separately reviewed 64-character SHA-256 pin, verifies Bash syntax, and
invokes the release with bounded, validated literal arguments. The real
producer restores the **already seeded** current S3 archive and matching
Let's Encrypt account, performs selected issuance/renewal or an **explicitly
opted-in** supported bulk operation, and conditionally publishes a fully
verified archive. The producer does **not** install its resulting
certificate on a consumer machine.

This Jenkins example does not automatically create an S3 bucket,
IAM identity, Route53 zone, Certbot/Let's Encrypt account, new account-only
archive, recovery lock, a Jenkins job, scheduled timer, consumer
installation, or new producer API. It never invokes `register`.
For a **first-time setup**, use the separate, operator-run
[`certbotbot register` contract](../acme-account-registration-contract.md)
and [README registration walkthrough](../../README.md#explicit-account-registration)
**before** activating this renewal job. Story #284's full
"I want a certificate for example.com" administrator tutorial is tracked
separately in [task #293](https://github.com/wesley-dean/certbotbot/issues/293);
its separate [manual AWS bucket-bootstrap and scoped IAM reference](aws-bucket-bootstrap.md)
is delivered under [task #292](https://github.com/wesley-dean/certbotbot/issues/292).
Neither prerequisite is run or provisioned by this Jenkins example.

**Important:** `example.com` is a reserved illustrative name. Do
not use it or its subdomains for live issuance. Replace it with an
actually delegated Route53 zone controlled by the operator.

## Install and protect the example

1. Provision a **dedicated trusted Linux Jenkins agent** with label
   `certbotbot-trusted-linux`, a workspace inaccessible to untrusted
   jobs, Bash 4.3+, AWS CLI v2, installed Certbot **with dns-route53**,
   OpenSSL, GNU tar/gzip, `curl`, `sha256sum`, `stat`,
   `jq`, and core POSIX/GNU tools. The validation stage requires
   `jq` even for empty JSON provider collections so that unsafe
   parameter syntax is rejected *before* release/network access.
   Install GnuPG 2.4.7+ with demonstrably working AES-256/OCB
   capability only when encrypted mode is selected.
2. Configure the agent's **external** AWS role, network access,
   region and trusted credential chain with least-privilege S3 and
   Route53 permissions. Do **not** place AWS access keys, tokens,
   KMS secrets, or encryption passphrases in build parameters, source,
   release URLs or CLI extra-argv JSON. The job deliberately relies
   on external AWS credential delivery and does not define
   `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` or a role creation step.
   See the [operator-owned S3/Route53 IAM policy example](aws-bucket-bootstrap.md)
   from #292; this Jenkins job itself neither grants nor proves permissions.
3. Provision the account **before** ordinary issuance by explicitly
   running `certbotbot register` with the correct email, affirmative
   TOS consent and matching selected Let's Encrypt environment, against
   a pre-existing bucket. Only this separate registration command can
   initialize an **account-only archive** at a positively missing
   current key. A denied S3 read is **not** evidence of a missing key.
   Match the selected `ACME_ENVIRONMENT` and S3 object key to the
   registration archive; never mix staging and production account state.
4. Independently inspect the immutable release, checksum companions and
   [attestation/release-verification evidence](../release-verification.md).
   Replace **both** `CERTBOTBOT_RELEASE_TAG` and
   `CERTBOTBOT_RELEASE_SHA256` in the reviewed Jenkinsfile with a
   previously accepted `vMAJOR.MINOR.PATCH` tag and its exact
   64-character lowercase SHA-256 digest. The example fails closed
   with its conspicuous placeholders. A sidecar and release binary
   downloaded from the same origin **do not** independently establish
   trust. The job does not bypass an operator's out-of-band release,
   signature/attestation and provenance policy.
5. Configure a manually invoked Pipeline from **reviewed protected
   Jenkinsfile content**, without untrusted SCM/PR change requests or
   webhook, Git polling, cron, upstream or auto-retry triggers.
   The Jenkinsfile has `skipDefaultCheckout(true)` and **no**
   `triggers` block. Access to "Build with Parameters" and Jenkins
   administrative configuration is itself a credentialed security
   decision: only authorized operators should be able to run it.
   Leave `CONFIRM_RUN` unchecked by default, and affirm the exact
   selected bucket/key/domain, account, expected side effects and
   requested flags on **each** manual invocation.
6. If `CONFIG_MODE=reviewed-file` is selected, an administrator
   must create and review **only** the nonsecret restricted literal
   file `/etc/certbotbot/jenkins.env` on the trusted runner.
   It must be a readable, root-owned **regular non-symlink file**
   and not writable by group or others. The path is intentionally
   fixed in the example; it is **not** a user-supplied arbitrary
   path or a shell script. The file's content is parsed as data,
   never sourced or evaluated; invalid lower-tier keys still fail.
   The Jenkinsfile passes `--config` for this mode, or an explicit
   `--no-env` for the corresponding mode, but not both.
7. Arrange a **single writer across all independent jobs and hosts**
   for the exact current S3 bucket/key. Jenkins'
   `disableConcurrentBuilds` protects this *one job* only.
   It is not distributed locking across other Jenkins jobs,
   GitHub Actions, containers, scheduled jobs or manual invocations.

The default choices are deliberately inert until `CONFIRM_RUN=true`
and the immutable release pin, bucket and domain/mode are provided.
The example chooses **staging by default**, not the producer's
compatibility default of production. A staging registration and **a
distinct staging current key** must already have been provisioned;
selecting staging alone does not create either resource. Moving to
production is a separate operator decision requiring production-bound
account state and a suitable current archive.

## Jenkins parameter-to-producer coverage matrix

**No build parameter is a secret.** All user-supplied values may be
visible in Jenkins job/build metadata; prohibit access for untrusted
users. Most choices are passed as **explicit named CLI arguments**
to prevent ambient application configuration from changing their
meaning. The exception is the environment-only `GPG_SYMMETRIC_KEY`,
which is bound only within the producer's credentialed execution
stage for `gpg-ocb`. The complete interface and validation details
are in [the producer inventory](../producer-option-inventory.md).

| Jenkins parameter | Default | Actual emitted producer option / restrictions |
| --- | --- | --- |
| `CONFIRM_RUN` | `false` | **Jenkins-only authorization gate**, never passed to producer; no download without `true` |
| `DOMAIN` | Empty | `--domain NAME`; deliberately absent only for domainless `RENEW_ALL=true`, with `DOMAIN` unset from child environment |
| `ADDITIONAL_SANS` | Empty | Comma-separated list parsed locally into repeated literal `--san NAME` argv; max 99, no whitespace or empty fields |
| `CERT_NAME` | Empty | Optional `--cert-name NAME`; this Jenkins example **requires explicit exact name** when `REMOVE_ORPHANS=true` |
| `INCLUDE_SUBDOMAINS` | `true` | `--include-subdomains true|false`; apex/wildcard complement as in producer |
| `ACME_ENVIRONMENT` | `staging` | `--acme-environment staging|production`; staging example default is **stricter** than producer production default |
| `S3_BUCKET` | Empty | `--s3-bucket BUCKET`; required pre-existing bucket |
| `CURRENT_KEY_MODE` | `literal` | Jenkins-only selector for **one** of `--s3-key` or `--s3-key-template`, never both |
| `S3_KEY` | `latest.tar.gz` | Literal selected current S3 object when key mode is `literal`; default string is ignored when template mode is selected |
| `S3_KEY_TEMPLATE` | Empty | `--s3-key-template TEMPLATE` when key mode is `template`; frozen UTC `{YEAR}`, `{MONTH}`, `{DOM}` |
| `BACKUP_KEY_TEMPLATE` | `archive-{YEAR}{MONTH}{DOM}.tar.gz` | `--backup-key-template`; **naming only** does not enable backup writes or deletions |
| `DATED_BACKUP_ENABLED` | `false` | `--dated-backup-enabled true|false`; explicitly authorizes guarded dated publication |
| `BACKUP_RETENTION_COUNT` | `0` | `--backup-retention-count`; 1–10000 is destructive and needs dated publishing plus eligible managed naming |
| `UPLOAD_NO_RENEWAL` | `false` | `--upload-no-renewal true|false`; republish successful validated no-op only when `true` |
| `RENEW_ALL` | `false` | `--renew-all true|false`; can be domainless **only** without selected inputs and with a populated valid archive |
| `REMOVE_ORPHANS` | `false` | `--remove-orphans true|false`; **destructive**: exact desired lineage collection and explicit selected name required here |
| `DESIRED_CERT_NAMES` | Empty | Comma-separated names emitted as repeated `--desired-cert-name NAME`; complete independent set of every lineage to keep, not the SAN list |
| `ARCHIVE_ENCRYPTION` | `none` | `--archive-encryption none|gpg-ocb|auto`; only explicit `gpg-ocb` binds a Jenkins Secret text key; `auto` has no bound secret and resolves plaintext here |
| `ARCHIVE_MIGRATION` | `none` | `--archive-migration none|plaintext-to-gpg-ocb`; a one-time explicit operation, not a scheduled renewal setting |
| `ARCHIVE_MIGRATION_BACKUP_CONFIRMED` | `false` | `--archive-migration-backup-confirmed true|false`; requires explicit gpg-ocb and a separately verified recoverable prior plaintext backup |
| `CONFIG_MODE` | `none` | Jenkins-only: `none` runs from a new `.env`-free private download cwd; `no-env` adds `--no-env`; `reviewed-file` adds `--config /etc/certbotbot/jenkins.env` |
| `AWS_EXTRA_ARGS` | `[]` | `--aws-args JSON`; whole single JSON-array value, approved connect/read timeout switches only |
| `GPG_EXTRA_ARGS` | `[]` | `--gpg-args JSON`; approved compression switches only |
| `CERTBOT_EXTRA_ARGS` | `[]` | `--certbot-args JSON`; approved logging/user-agent and dns-route53 wait controls only |

Jenkins string/text/choice/boolean parameters are exported to the
shell, so the invocation deliberately **unsets the exported
`DESIRED_CERT_NAMES`** after converting it to repeatable CLI values.
An explicitly exported *empty* desired set would otherwise fail the
ordinary parser even when pruning is false. For domainless bulk
operations the invocation also **unsets `DOMAIN`**, because an empty
but explicitly supplied environment identity is forbidden by
ADR-058. Both are correctness requirements, not workarounds that
authorize implicit deletion. The `S3_KEY` versus
`S3_KEY_TEMPLATE` conflict is resolved by emitting **only** the
selected winning-tier CLI option; lower-tier Jenkins environment
values do not override that explicit selection.

The complete producer's CLI > exported application env > literal file >
default rules remain in force, including the strict lower-tier file
parse. `CONFIG_MODE=none` is a *Jenkins example setting*, not a
`certbotbot` option: it runs the producer from the clean private
release directory and does **not** disable ordinary external AWS
credentials. `CONFIG_MODE=no-env` explicitly suppresses application
environment and selected literal file settings, including the **only**
encryption secret; it cannot be combined with authenticated
`gpg-ocb` here. The mode `reviewed-file` is never enabled for
untrusted job parameters pointing to arbitrary paths.

## Pre-network input and provider validation

The first stage validates **all** nonsecret inputs before using
AWS, Route53, S3, Certbot or downloading a producer. It checks
explicit run authorization, exact immutable-release tag and
independently pinned hash shape, DNS labels and canonical lowercase
selected identities, a required existing-bucket name, the
mutually exclusive current-key mode, frozen date tokens, retention
range and enabled-backup dependency, all strict booleans/modes,
archive migration confirmation, the unselected domainless bulk
exception, and mutually exclusive `RENEW_ALL`/
`REMOVE_ORPHANS`.

The example is intentionally more restrictive than the product:
it requires canonical lowercase input rather than letting ordinary
`DOMAIN` normalize uppercase names, forbids reserved
`example.com` identities, and requires a **separately explicit
`CERT_NAME`** for a destructive prune so a derived name cannot
silently change deletion authority. It validates the separate
whole desired-lineage set, including uniqueness and membership of
that selected name; no SAN or existing archive listing is
substituted for the desired collection. The producer performs its
own deeper archive/member/filename validation before contacting
provider services.

All three provider extras are validated independently as bounded
**JSON arrays of strings** (at most 16 tokens and 4096 encoded bytes
per vector), then passed **unparsed** as one quoted CLI argument
per provider. No user input becomes shell code, eval, an argument
in Groovy interpolation, or an executable shell string.

| Provider | Allowed extra options | Validation |
| --- | --- | --- |
| AWS | `--cli-connect-timeout`, `--cli-read-timeout` | Separate canonical decimal 1–600 |
| GPG | `--compress-level`, `--no-compress` | 0–9 level; compression controls mutually exclusive |
| Certbot | `--max-log-backups`, `--user-agent-comment`, `--dns-route53-propagation-seconds` | 1–1000; restricted printable 1–80-character comment; DNS-01 propagation 1–300 and selected operations only |

JSON strings may contain permitted spaces and literal quotes, such
as `["--user-agent-comment","QA Team \"nightly\""]`. The values
stay **one JSON argument**, never flattened with unquoted splitting.
An empty `[]` vector overrides ambient provider environment values.
Arbitrary `--endpoint-url`, `--server`, arbitrary Certbot options,
provider command substitutions and raw credential-bearing argument
vectors are not supported. `jq` is installed on the trusted agent
for the example's pre-network validation; the producer itself only
conditionally needs `jq` and `base64` for nonempty extra arrays.

## Secrets, trusted agent and publishing safety

There are no secret Jenkins parameters. For authenticated GPG
archives, add a Jenkins Credentials Binding **Secret text** credential
with ID `certbotbot-gpg-symmetric-key`, restricted to the intended
trusted folder/job. The Jenkinsfile binds it with `withCredentials`
**only** when `ARCHIVE_ENCRYPTION=gpg-ocb` and only around the
execution step. The Groovy shell script is a **triple-single-quoted
literal** and calls Bash with a quoted argv array; credentials are
expanded by the shell from the trusted environment, never interpolated
into the Jenkins/Groovy step body. No script prints all arguments,
key material, private archives or environment variables. For
`ARCHIVE_ENCRYPTION=none` or `auto`, the invocation explicitly
**unsets any accidentally inherited `GPG_SYMMETRIC_KEY`** before
the producer is started. Do not globally export it on the Jenkins
agent. With a signed-in but compromised Jenkins controller/agent,
masking does not create a confidentiality boundary.  

**Bulk renewal and deletion do different things.** Ordinary
selected-only behavior remains the default. `RENEW_ALL=true` makes
bounded due-renewal checks on every original archived lineage.
`REMOVE_ORPHANS=true` requires a **complete independent desired
set** of all lineage identities to retain, plus the selected exact
lineage. It may remove verified archived members, but does not revoke
certificates, erase earlier S3 versions or backups, or update remote
consumers. These flags **cannot be true together**; the example
refuses that combination before release/network work. See
[bulk renewal](../renew-all-contract.md) and
[orphan pruning](../orphan-removal-contract.md).

A positive `BACKUP_RETENTION_COUNT` may delete only managed
eligible older dated backups after successful current and dated
publication. It is independent of `REMOVE_ORPHANS`, which prunes
the *current archive's* lineages. Both require separately reviewed
permissions and recovery. One-off plaintext-to-GPG migration requires
`ARCHIVE_MIGRATION_BACKUP_CONFIRMED=true`, the selected authenticated
mode and an **already independently verified recoverable backup**;
the flag cannot verify or create that backup.

After S3 PutObject begins, a timeout or nonzero result does **not**
prove that prior bytes remain. A successfully written current object
followed by failed dated backup or retention is **partial success**,
not rollback. The `exec bash "$producer" "\${args[@]}"` form propagates
the producer's status without swallowing failure. Avoid `|| true`,
implicit retries, status masking, or interpreting a failed run as
proof of an unchanged remote object. Coordinate one writer and
inspect the exact current object before any repair.

Jenkins `post { always { deleteDir() } }` cleans the job workspace,
including the verified executable. It is not cryptographic erasure;
the producer itself is responsible for its private temporary
Certbot workspace. Never archive ACME account state, certificates,
GPG keys, downloaded archives or temporary workspaces as Jenkins
build artifacts.

## Verification and evidence limits

The repository adds
[`tests/jenkins-example.bats`](../../tests/jenkins-example.bats)
to extract and **execute the same Bash validation and invocation
blocks** that the maintained Jenkinsfile contains. Tests use a fake
AWS `--version` command and a fake producer, assert correct literal
argv boundaries and exit statuses, and check malformed JSON, duplicate
desired names, domainless bulk, mutually exclusive dangerous modes,
GPG secret suppression, and failed-value preflight. They do **not**
reach S3, Route53, Certbot/ACME or Jenkins. The maintained Test
workflow runs the Bats suite against the public artifact build matrix.

The repository can statically inspect and Bash-syntax-check these
embedded scripts, but **the Declarative Jenkins Pipeline itself
must still be validated in an operator-controlled Jenkins controller
with the requisite plugins** before use. It was not executed on a
real Jenkins controller, and no live IAM/Route53/Let's Encrypt or
certificate-installation evidence is claimed. Jenkins administrators
should use the Declarative Pipeline syntax validator and a
credential-free sandbox job before connecting any real authority.

See [source-verified configuration](../configuration-reference.md),
[release verification](../release-verification.md),
[container operator guidance](../container-deployment.md),
[trust model](../mvp-certificate-state-threat-model.md),
[client retrieval](../client-retrieval.md),
and [ADR-019](../adr/ADR-019-authoritative-approval-labels.md).
For Pipeline parameter/directive semantics and literal shell script handling,
see the official [Jenkins Pipeline syntax](https://www.jenkins.io/doc/book/pipeline/syntax/)
and [Credentials Binding step](https://www.jenkins.io/doc/pipeline/steps/credentials-binding/)
documentation. Groovy's triple-single quoted strings do not interpolate
`$VARIABLE`, but still interpret backslash escapes; the maintained
Jenkinsfile doubles backslashes so the evaluated Bash receives literal
regex/printf escapes. Its offline tests unescape that one Groovy layer
before running the extracted scripts.
