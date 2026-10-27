# Configuration and CLI Reference

This is the producer's **public input contract**, based on the checked-in
`src/main.bash`, `lib/config.bash`, `lib/identity.bash`,
`lib/filename.bash`, `lib/crypto.bash`, related Bats tests, and
Accepted ADR-020–034. It documents the ordinary standalone producer,
including its development and minified representations. The **separate**
read-only `certbotbot-client.bash` has a different CLI; see the
[client settings reference](client-settings.md).

**Explicit account registration is a separate command:**
`certbotbot register [registration options]`, documented in
[the registration contract](acme-account-registration-contract.md).
It requires an email address and affirmative TOS consent, defaults EFF
email signup to `true`, and permits an account-only initialization of a
positively missing object.  It does not issue a certificate. The ordinary
issuer independently supports explicit staging selection under ADR-042;
production remains the compatibility default.

The ordinary command manages **one selected certificate lineage per invocation**,
within one **existing, authoritative S3 archive**. That archive may contain
other complete lineages, which are validated and preserved. No option
creates an initial ACME account, bucket, hosted zone, IAM role, or
missing current archive. A successful invocation does not install or
reload certificates on another host.

For the actual processing order and trust boundaries, see
[How it works](how-it-works.md). For Docker and rootless Podman, see
[the container deployment guide](container-deployment.md).
The ordinary issuer accepts only `production` (default) or explicit
`staging`, with distinct S3 keys and strictly matching account and
renewal metadata. For milestone 4, **staging must be selected explicitly**;
no live production contact is permitted. See
[ADR-042](adr/ADR-042-explicit-ca-bound-staging-issuance.md).

This reference describes supported configuration **without** claiming
that its illustrative production-facing commands have been run against
live AWS, Route53, or Let's Encrypt.

## CLI syntax and input resolution

```text
certbotbot [options] DNS_NAME
certbotbot [options] --domain DNS_NAME
certbotbot --help
certbotbot --version
```

For value-taking named options, both `--option VALUE` and
`--option=VALUE` are recognized. Exactly one primary DNS name is
required for ordinary operation, supplied as a positional argument
or `--domain` (or at a higher-priority non-CLI configuration tier).
Supplying both CLI primary forms, or multiple positional primary
arguments, is an error. `--` terminates option parsing; everything
following it is treated as a positional operand, so only one such
primary name is accepted. Unknown flags, missing option values and
duplicates of single-valued options fail with status 64.
**Only `--san` is repeatable.**

`--help` and `--version` are fast-path commands **only when first**
in the argument vector. The source also accepts `-h` and `help` as
first-argument help aliases, and `-V` and `version` as first-argument
version aliases. These display public usage/build identity and do not
run S3/Certbot. They are not general parser options that can be
interspersed with other arguments; do not depend on
`certbotbot example.com --help` or `--help=true`.

Each supported **nonsecret scalar** is resolved independently using:

**CLI > explicitly exported environment variable > selected literal
configuration file > built-in default.**

For a scalar, higher-priority presence wins, even if an empty value
later fails its validation; there is no fallback after an invalid
explicit selection. Exceptions are the *collection* of additional
SANs and the *mutually exclusive pair* of current S3-key settings,
both detailed below.

When no `--config` is supplied, a regular `./.env` file in the
current working directory is loaded **if it exists**; its absence
is normal. `--config FILE` replaces that implicit source and
requires a readable regular file. `--config` is CLI-only and may
appear once. No project `CONFIG` environment variable exists.

### Canonical input inventory

The table lists **every producer application setting** recognized by
`lib/config.bash`. Environment and literal-file keys are identically
spelled unless noted. "Required" means that an effective usable value
must exist at execution time; inputs can be inherited from a lower tier.

| CLI option | Environment / `.env` key | Default | Accepted value / effect |
| --- | --- | --- | --- |
| `--acme-environment` | `ACME_ENVIRONMENT` | `production` | `production` or `staging`; one bounded CA per archive, no implicit registration or endpoint fallback |
| Primary positional `DNS_NAME` or `--domain` | `DOMAIN` | **Required** | One canonicalizable primary DNS name |
| `--san` (repeatable) | `ADDITIONAL_SANS` | Empty collection | Additional DNS names; CLI: one per flag; environment/file: comma-separated collection |
| `--include-subdomains` | `INCLUDE_SUBDOMAINS` | `true` | Literal `true` or `false`; adds apex/wildcard complement to each explicit name |
| `--cert-name` | `CERT_NAME` | Derived from shortest requested SAN | Existing or new **non-wildcard** stable Certbot lineage name |
| `--s3-bucket` | `S3_BUCKET` | **Required** | Name of existing S3 bucket containing the authoritative object |
| `--s3-key` | `S3_KEY` | `latest.tar.gz` | Existing literal object key; mutually exclusive with template at winning tier |
| `--s3-key-template` | `S3_KEY_TEMPLATE` | No template | Rendered current object filename instead of literal key |
| `--backup-key-template` | `BACKUP_KEY_TEMPLATE` | `archive-{YEAR}{MONTH}{DOM}.tar.gz` | Independently selected dated name; **does not enable backup writes** |
| `--dated-backup-enabled` | `DATED_BACKUP_ENABLED` | `false` | `true` or `false`; opt in to guarded additional publication |
| `--backup-retention-count` | `BACKUP_RETENTION_COUNT` | `0` | `0` disables cleanup; canonical decimal `1`–`10000` requires dated backups |
| `--upload-no-renewal` | `UPLOAD_NO_RENEWAL` | `false` | `true` or `false`; allow republish after a fully validated unchanged no-op |
| `--archive-encryption` | `ARCHIVE_ENCRYPTION` | `auto` | `auto`, `none`, or `gpg-ocb` |
| `--archive-migration` | `ARCHIVE_MIGRATION` | `none` | `none` or `plaintext-to-gpg-ocb` |
| `--archive-migration-backup-confirmed` | `ARCHIVE_MIGRATION_BACKUP_CONFIRMED` | `false` | `true` or `false`; explicit operator acknowledgment required for migration |
| `--config FILE` | **None** | Optional `./.env` | Override file source; a chosen file must be readable |
| `--help` | **None** | Not applicable | First-argument fast path; print usage |
| `--version` | **None** | Not applicable | First-argument fast path; print version, build date, build commit |

The **only additional application-controlled input** is the secret
`GPG_SYMMETRIC_KEY`, accepted as an **explicitly exported environment
variable only**; it has **no CLI or `.env` equivalent**, and its
default is unset. External AWS CLI/Certbot configuration is a separate
dependency, not an additional certbotbot parser key. Do not invent
`--gpg-key`, `--renew-all`, `--remove-orphans`, `--backend`,
`--dns-provider`, or `--archive-format`: none is supported here.

## Literal configuration-file grammar

The selected `.env` file is a **restricted data format**, not a Bash
script. Its accepted key names are exactly the 14 named application
environment/file keys listed in the inventory; `GPG_SYMMETRIC_KEY`,
`AWS_PROFILE`, and other external inputs are **not accepted keys**.

- Blank lines and lines whose first nonwhitespace character is `#`
  are ignored.
- Each other line is `UPPERCASE_KEY=VALUE`, with no spaces around
  the key or equals sign. Keys use only `A-Z`, digits, and underscore,
  and must be among those supported above.
- A value may be unquoted, wrapped in one matching pair of single
  quotes, or wrapped in one matching pair of double quotes. The
  parser removes only that surrounding pair; it does **not** apply
  shell escaping, variable expansion, command substitution, or
  interpolation.
- Unquoted leading/trailing whitespace is rejected. Embedded quote
  characters, dollar signs, and backticks are rejected after stripping
  permitted outer quotes. Inline trailing comments are **not** a
  supported comment syntax.
- Duplicate or unknown keys, malformed lines, unreadable explicit
  files, and invalid effective values fail before S3/Certbot work.
  An invalid lower-tier file is **not ignored** merely because a
  higher-tier CLI value would have overridden the relevant setting.

For example, this is a **nonsecret** literal configuration file,
not a command to create any AWS or ACME infrastructure:

```dotenv
DOMAIN=example.com
S3_BUCKET=preexisting-certificates
S3_KEY=latest.tar.gz
INCLUDE_SUBDOMAINS=true
UPLOAD_NO_RENEWAL=false
DATED_BACKUP_ENABLED=false
BACKUP_RETENTION_COUNT=0
ARCHIVE_ENCRYPTION=none
```

Using a literal file containing `GPG_SYMMETRIC_KEY`, duplicate
`S3_BUCKET` lines, `S3_BUCKET =bucket`, or
`S3_KEY=$(some-command)` is invalid. Store actual credentials
and encryption secrets in a suitable external secret facility.

## Certificate selection and SAN behavior

### `DOMAIN`, positional `DNS_NAME`, and `--domain`

One primary name identifies the certificate request. Input is
ASCII-lowercased before structural validation; trailing dots,
empty labels, absolute paths, spaces, and non-leading wildcards
are rejected. Non-wildcard names have two or more DNS labels;
each label is 1–63 characters with lowercase ASCII letters,
digits or interior hyphens. The nonwildcard name is at most 253
characters. Internationalized names must be supplied in valid
ASCII A-label form, not an arbitrary Unicode domain string.

A leading `*.` is the **only** accepted wildcard spelling.
Providing `--domain` and a positional DNS name together fails;
a positional name overrides any lower-tier `DOMAIN`.
An unset/empty effective primary is invalid. One CLI invocation
still selects **one lineage**, even when that certificate contains
many SANs. See [identity rules](mvp-configuration.md).

### `ADDITIONAL_SANS` and repeatable `--san`

Each CLI `--san name` appends one **literal** additional name.
There is **no comma-separated CLI argument**. The environment/file
`ADDITIONAL_SANS` setting is instead one comma-separated collection,
for example `api.example.net,service.other.org`. Whitespace-separated
lists, empty comma entries, and control characters are invalid.
An explicitly exported *empty* `ADDITIONAL_SANS` value overrides a
nonempty file collection with **zero** extras.

At least one CLI `--san` selects the **entire** CLI collection,
replacing the environment/file collection rather than merging with it.
Without CLI SANs, the explicitly set environment collection overrides
the literal-file collection. Input is limited to **99 additional
explicit names**, plus the one primary (100 explicit total). After
wildcard/apex expansion and deduplication, the final SAN count is
also limited to **100**. Invalid/over-limit lists fail before AWS.

Example of collection replacement:

```bash
# With an existing valid account/archive and AWS role, this requests
# only the CLI additional set, not the inherited ADDITIONAL_SANS list.
ADDITIONAL_SANS=ignored.example.org \
  ./certbotbot.bash --s3-bucket preexisting-certificates \
  --san api.example.net example.com
```

### `INCLUDE_SUBDOMAINS` and `CERT_NAME`

`INCLUDE_SUBDOMAINS` is a strict lowercase boolean. With default
`true`, `example.com` expands to `example.com` and
`*.example.com`; `*.example.com` adds `example.com`.
The complement is applied once **to each explicit primary/additional
name**, then deduplicated in first-seen order; derived names are not
expanded recursively. `false` uses only the names supplied.

The selected certificate lineage is `CERT_NAME`. An explicitly
nonempty value must already be a canonical, **lowercase, nonwildcard**
DNS-like name; unlike `DOMAIN`, it is not silently normalized.
An empty/absent value derives the **shortest full textual SAN**,
including its `*.` prefix in length comparisons, with ASCII
lexical tie-breaking. For `example.com` and `*.example.com`,
the derived name is `example.com`. A derived **wildcard-only**
name with `INCLUDE_SUBDOMAINS=false` is invalid unless an explicit
valid `CERT_NAME` is supplied.

Changing SAN membership does **not** implicitly rename an existing
lineage. Supply the existing explicit cert name when needed, because
a changed shortest name could otherwise select a different lineage.
The producer selects one lineage for issuance/renewal/reconciliation
and preserves all unrelated stored lineages; it does not run global
renewal or silently assign a Certbot numeric suffix.
See [multi-SAN](multi-san-contract.md),
[certificate naming](mvp-certificate-naming.md) and
[shared archive](multi-lineage-contract.md).

## Current S3 identity and filename templating

### `S3_BUCKET`, `S3_KEY`, and `S3_KEY_TEMPLATE`

`S3_BUCKET` is required and must name an **already provisioned**
bucket holding a seeded object with a registered production ACME
account. The project validates that a nonempty bucket was selected,
but actual AWS region, endpoint, credentials, bucket accessibility,
and authorization depend on the external AWS CLI/IAM environment.

`S3_KEY` is the **literal** current object name, defaulting to
`latest.tar.gz`. The literal parser rejects an empty name, a leading
hyphen, a slash, or whitespace; it does **not** render
`{YEAR}` or infer a filename change from encryption mode.
A literal key need not be interpreted as a template merely because
it contains punctuation. The current key is frozen before retrieval
and reused for publication.

`S3_KEY_TEMPLATE` instead selects a constrained single-component
filename ending in `.tar.gz`. Only three uppercase tokens are
recognized: `{YEAR}` (4-digit year), `{MONTH}` (2-digit month)
and `{DOM}` (2-digit day). The renderer uses pinned, embedded
`mktext` with one validated, **frozen UTC calendar date**; no
Bash evaluation or recursive expansion occurs. Template text and
rendered values must begin with an ASCII alphanumeric character,
then contain only ASCII letters/digits, dot, underscore and hyphen
(after recognized tokens are substituted). They reject path
separators, `..`, trailing dots, unknown/malformed braces,
spaces, command-like tokens and rendered names over **255 bytes**.

These are **one logical current-key setting**, not independently
overlaid scalars:

1. If CLI provides either `--s3-key` or
   `--s3-key-template`, that tier wins over environment/file.
2. Otherwise, if exported environment supplies either `S3_KEY`
   or `S3_KEY_TEMPLATE`, that tier wins.
3. Otherwise, the literal file tier wins if either is defined;
   otherwise use `latest.tar.gz`.
4. **Both** forms at the same winning tier are an error. A
   higher-tier literal can mask a lower-tier template, and vice
   versa. An explicitly selected empty form is invalid; do not
   silently fall back to a lower tier.

For example, `--s3-key latest.tar.gz` can override an exported
`S3_KEY_TEMPLATE` without conflict, but both `--s3-key`
and `--s3-key-template` in one command fail. Rendering a date
does not find the newest S3 object, enumerate backups or migrate
an older key. See [filename contract](archive-filename-template-contract.md).

### `BACKUP_KEY_TEMPLATE` and `DATED_BACKUP_ENABLED`

The backup-key template has its own ordinary scalar precedence,
default `archive-{YEAR}{MONTH}{DOM}.tar.gz`, and uses the **same
frozen UTC date** as a templated current key. An *explicitly
provided* backup template may cause date/key validation even when
dated publication is disabled. The resolved current and backup
keys must differ; a collision fails before S3 access.

Naming a backup key **does not** authorize a second remote write.
Only `DATED_BACKUP_ENABLED=true` opts in, and it still requires
successful current-publication preflight, verified candidate state,
and conditional same-day destination safety. A successful unchanged
no-op performs no current or backup write unless another explicit
policy, such as `UPLOAD_NO_RENEWAL=true`, requires a republish.
The dated write uses the **same prepared archive bytes** as the
accepted current write. An absent backup gets an
`If-None-Match: *` conditional PUT; a managed same-date backup
must match the expected metadata and ETag before a conditional
replacement. A confirmed current write followed by failed/uncertain
backup publication is **nonzero partial success**, not rollback.
See [dated backup contract](dated-backup-publication-contract.md).

### `BACKUP_RETENTION_COUNT`

The canonical string `0` disables retention completely. Enabled
retention accepts only ASCII decimal strings `1`–`10000`, without
signs, padding, fractions or leading zeros (examples:
`1`, `7`, `10000`). Values such as `00`, `01`,
`-1`, `1.5`, `10001`, or the empty string are rejected.
Positive retention **requires**
`DATED_BACKUP_ENABLED=true` and a separate strict
date-shaped deletion-eligible backup template.

A valid publication template is not automatically a valid
**retention** template. The retention policy accepts exactly
one contiguous `{YEAR}{MONTH}{DOM}` marker with a sufficiently
long anchored static prefix ending in `-` or `_`, and a safe
literal `.tar.gz` suffix. Retention never runs unless both
the current object and its dated backup have **just been**
successfully published/confirmed. It completes bounded listing and
per-object HEAD/metadata/ETag preflight before deleting any older
eligible object; every deletion is exact-key and conditional.
Unknown or ambiguous matching state aborts without speculative
deletion. A failed deletion may leave a **partial** cleanup result;
there is no automatic rollback or deletion of historical S3 object
versions. See [managed retention policy](managed-backup-retention-policy.md)
and [retention safety evidence](retention-safety-verification.md).

## Publication and encryption controls

### `UPLOAD_NO_RENEWAL`

This strict boolean defaults to `false`. It controls publication
**after successful lifecycle verification**, not whether Certbot
should run. With `false`, a truly unchanged no-op skips
PutObject; a certificate change **or other durable canonical
state change** requires publication regardless of this setting.
With `true`, the producer can republish an unchanged, *fully
validated* state. It does **not** authorize a write after failure
or bypass archive/certificate checks.

| Verified local result | `UPLOAD_NO_RENEWAL=false` | `UPLOAD_NO_RENEWAL=true` |
| --- | --- | --- |
| Changed certificate, SAN set, or durable metadata | Publish | Publish |
| Unchanged successful Certbot no-op | Skip current PUT | Publish |
| Failed restore/Certbot/certificate/package validation | Never intentionally publish | Never intentionally publish |
| Failed/uncertain PutObject | Nonzero, remote state uncertain | Nonzero, remote state uncertain |

### `ARCHIVE_ENCRYPTION` and `GPG_SYMMETRIC_KEY`

The accepted nonsecret mode is `auto`, `none`, or `gpg-ocb`
(default `auto`). `GPG_SYMMETRIC_KEY` is a **secret**, accepted
only from the explicitly exported process environment and
captured before subprocess execution. It is never a valid
CLI/`.env` entry; do not place it in an argument, config file,
Dockerfile, build arg, OCI label, workflow log or repository.
Its value must not contain CR/LF.

| Mode | Exported secret | Result |
| --- | --- | --- |
| `auto` | Unset or empty | Resolve to plaintext `none` |
| `auto` | Nonempty | Resolve to `gpg-ocb` |
| `none` | Unset/empty | Plain gzip-tar mode |
| `none` | Nonempty | **Error** (no accidental plaintext downgrade) |
| `gpg-ocb` | Nonempty | Require authenticated GnuPG OCB |
| `gpg-ocb` | Unset/empty | **Error** |

Encrypted objects preserve the exact **operator-selected S3 key**
and wrap the full gzip-tar in a versioned
`CERTBOTBOT-GPG-OCB-V1` authenticated AES-256/OCB envelope.
There is no implicit `.enc` suffix, no format auto-detection
from S3 bytes, no plaintext fallback on an invalid encrypted
object, and no silent encryption format migration.
The runtime needs **working GnuPG 2.4.7+ OCB support**, checked
by capability, not only version text.

The entrypoint disables xtrace, captures/unexports the secret,
and supplies it to trusted GnuPG via a private file descriptor.
Secret delivery still relies on a trusted host/container runtime;
the environment is not a VM confidentiality boundary.
See [encryption contract](archive-encryption-contract.md) and
[encryption threat model](archive-encryption-threat-model.md).

### `ARCHIVE_MIGRATION` and `ARCHIVE_MIGRATION_BACKUP_CONFIRMED`

`ARCHIVE_MIGRATION` defaults to `none`; the only other
accepted value is `plaintext-to-gpg-ocb`. The confirmation
flag defaults to `false`, and **cannot** be `true` when
migration is `none`. Plaintext-to-encrypted migration
requires selected `gpg-ocb` mode, a suitable secret, and
`ARCHIVE_MIGRATION_BACKUP_CONFIRMED=true`. This flag
records operator acknowledgment of a **separate, already
verified, recoverable backup** of the pre-migration plaintext
object; certbotbot cannot prove that backup exists.

Migration operates against the same authoritative current
key after complete validation, not a newly guessed encrypted
key. Existing encrypted input combined with plaintext-to-OCB
migration is invalid; encrypted input in `none` mode is
also invalid. Failure cannot silently downgrade or roll
back a partially accepted S3 write. See
[encryption migration contract](archive-encryption-contract.md).

## Usage matrices and safe examples

These syntax examples use an **existing, valid account/archive**,
an existing Route53 zone, and separately provisioned AWS identity;
they do not create any of those resources. They are
*production-adjacent illustrations*, **not commands executed
against live accounts** by this documentation task.

```bash
# Default plaintext if no exported GPG_SYMMETRIC_KEY exists.
./certbotbot.bash --s3-bucket preexisting-certificates example.com

# One certificate with unrelated additional SANs and no wildcard expansion.
./certbotbot.bash --s3-bucket preexisting-certificates \
  --include-subdomains false \
  --san api.other.example --san service.example.net \
  --cert-name example.com example.com

# Current-key template, rendered once using the invocation's UTC date.
./certbotbot.bash --s3-bucket preexisting-certificates \
  --s3-key-template 'current-{YEAR}{MONTH}{DOM}.tar.gz' example.com

# Verified unchanged no-op may be explicitly republished.
./certbotbot.bash --s3-bucket preexisting-certificates \
  --upload-no-renewal true example.com

# Dated recovery copy, but no deletion.
./certbotbot.bash --s3-bucket preexisting-certificates \
  --dated-backup-enabled true \
  --backup-retention-count 0 example.com

# Explicitly enable dated publishing and retain newest 7 eligible copies.
# This can delete old managed backups after successful current+dated PUTs.
./certbotbot.bash --s3-bucket preexisting-certificates \
  --dated-backup-enabled true --backup-retention-count 7 example.com
```

For encryption, the operator's trusted secret manager must export
`GPG_SYMMETRIC_KEY` **without revealing it in shell history or logs**.
Then use `--archive-encryption gpg-ocb` for a previously encrypted
object. Migrating a previously plaintext object requires independent
backup verification **before** this invocation:

```bash
# Prerequisite: secret securely exported; prior plaintext backup confirmed.
# Never run this as a normal recurring renewal configuration.
./certbotbot.bash --s3-bucket preexisting-certificates \
  --archive-encryption gpg-ocb \
  --archive-migration plaintext-to-gpg-ocb \
  --archive-migration-backup-confirmed true example.com
```

Invalid combinations include `--archive-encryption none`
with an exported secret; `--archive-encryption gpg-ocb`
without one; confirmation without migration; migration
without confirmation; positive retention without dated
publishing; colliding current/backup keys; an unseeded S3
object; and an implicit wildcard-only lineage when complement
expansion is disabled.

## External AWS, Certbot, and runner dependencies

These are **not certbotbot parser settings**. The program
uses the ordinary externally configured AWS CLI identity/region/
endpoint and Certbot installation. Operators arrange those
dependencies separately:

| External input/capability | Who configures it | Required behavior |
| --- | --- | --- |
| AWS role, workload identity, OIDC federation or SDK credential chain | Operator/cloud runtime | Allow precise S3 reads/writes and Route53 DNS changes as needed |
| `AWS_PROFILE`, `AWS_DEFAULT_REGION`, `AWS_REGION`, `AWS_SHARED_CREDENTIALS_FILE` | AWS CLI / operator, **not** parsed `.env` keys | Select suitable external account/region/credential source |
| Existing S3 bucket and current object | Operator | Seed a valid tar/GPG archive with an existing account matching the explicitly selected Let's Encrypt CA (production by default) |
| Hosted-zone and Route53 policy | Operator | Authorize DNS-01 changes for every requested SAN's zone |
| Certbot and `certbot-dns-route53` | Host/image package owner | Existing-account selected issuance/renewal; no account auto-registration |
| Bash 4.3+, AWS CLI v2, GNU tar/gzip, OpenSSL, filesystem tools | Host/image package owner | Compatible trusted external executables |
| GnuPG 2.4.7+ with AES256/OCB | Host/image package owner, when encrypted | Authenticated full-archive mode, not legacy downgrade |
| Scheduler and concurrency control | Operator | Only one writer per authoritative current key at a time |
| Downstream installation and reload | Operator/consumer | Not performed by producer |

Real IAM needs separate authorization for `GetObject`,
`PutObject`, bucket-scoped reads/listing, Route53
record changes and change-status calls; opted-in dated backups
and retention additionally need conditional-write, metadata,
list and scoped deletion capabilities. The program neither
provisions nor proves the quality of those privileges.
The [deployment guide](container-deployment.md) discusses
runtime secret-mount and role strategies in depth.

## Status, failures, and recovery expectations

A successful operation prints a **nonsecret** outcome identifying
the selected lineage and current `s3://bucket/key` with
`published=true|false`. Dated backup and retention fields
are added when those features are enabled, for example
`backup=confirmed|skipped` and
`retention=completed|skipped; deleted=N`.
These are observations by the producer, **not proof** that a
consumer host installed or reloaded a certificate.

| Exit code | Interpretation |
| --- | --- |
| `0` | Help/version or completed selected lifecycle, including a verified no-op |
| `64` | Invalid CLI, config, DNS identity, filename, mode, or private workspace |
| `65` | Unsafe archive/lineage/certificate/cryptographic state |
| `66` | Mandatory seeded S3 object positively confirmed missing |
| `69` | Required external tool/provider or remote service unavailable/ambiguous |
| `74` | Failed private staging, Certbot provider step, or S3 transfer |

Specific adapters can return their own documented nonzero
stage code; the main lifecycle propagates that status.
Read/config/validation/provider failure prevents a later
**intentional** remote publication. After a PutObject request
begins, a failed/lost response cannot establish whether
the remote bytes changed. A current accepted write followed
by failed backup/retention is **partial success** and must
not be treated as a wholly rolled-back transaction.
Neither ETags nor checksums provide a global lock,
remote-history guarantee, or safe blind retry.
Use independent archive verification and an operator-owned
single-writer/recovery policy. See
[no-op publication](mvp-upload-no-renewal-policy.md),
[remote failure preservation](mvp-failure-preservation.md),
[dated recovery](dated-backup-recovery-verification.md),
and [retention safety](retention-safety-verification.md).

## Implementation and verification sources

- [Public CLI](../src/main.bash) and
  [configuration resolver](../lib/config.bash)
- [Identity derivation](../lib/identity.bash) and
  [filename resolver](../lib/filename.bash)
- [Authenticated archive adapter](../lib/crypto.bash)
- [Public lifecycle tests](../tests/public-lifecycle.bats),
  [configuration/identity tests](../tests/config-identity.bats),
  and [multi-SAN verification matrix](multi-san-verification.md)
- [Encryption verification matrix](archive-encryption-verification.md),
  [dated backup recovery and test evidence](dated-backup-recovery-verification.md),
  and [retention tests](../tests/retention.bats)
- [Architectural decisions](decisions.md) and
  [full lifecycle guide](how-it-works.md)

This document does not change runtime behavior. Upstream
release/OCI publication and the separate read-only client
remain governed by their own contracts and tests.
