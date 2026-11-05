# Shipped Producer and Registration Option Inventory

**Status:** Implementation-checked inventory for [task #290](https://github.com/wesley-dean/certbotbot/issues/290), the first technical task of [story #284](https://github.com/wesley-dean/certbotbot/issues/284). This document audits the checked-in public entrypoint and actual configuration parsers after the merged \`RENEW_ALL\` and \`REMOVE_ORPHANS\` work. It is a reference for downstream manual Jenkins and first-certificate documentation, **not** authorization to use production credentials or a new configuration API.

**Implementation baseline:** \`src/main.bash\`, \`lib/config.bash\`, \`lib/register-config.bash\`, \`lib/identity.bash\`, and \`lib/filename.bash\` on \`main\` after merged PR #289. [Configuration and CLI reference](configuration-reference.md) explains detailed behavior; the [registration contract](acme-account-registration-contract.md) explains account-only initialization. The client is a [different executable](client-settings.md) and has no ordinary producer or registrar flags.

## Command boundary and precedence

The same assembled producer ships as \`certbotbot.dev.bash\`, \`certbotbot.bash\` and \`certbotbot.min.bash\`. Each accepts **ordinary** \`certbotbot [options] [DNS_NAME]\` and, only when the first argument is exactly \`register\`, **registration** \`certbotbot register [registration options]\`. The normal selected issuance needs a DNS identity; domainless \`RENEW_ALL=true\` is the sole documented exception and requires a populated validated archive. Registration takes **no DNS operand**, does not issue a certificate, and cannot be reached implicitly from ordinary issuance.

Most *nonsecret scalar* settings use **CLI > explicitly exported application environment > restricted literal file > built-in default**. For the ordinary producer, the optional \`./.env\` is discovered in the current working directory unless \`--config FILE\` selects another readable file. The registration parser uses the same literal reader but **rejects issuer-only keys** in its selected file. An invalid lower-tier file is not silently ignored by an overriding CLI value. \`--no-env\` is a separate presence-only flag, suppressing application environment, its \`./.env\` discovery and literal-file inputs; explicit \`--no-env\` with \`--config\` fails. External AWS credentials/profile/region, PATH and HOME are **not** erased by this flag.

Both value-taking parsers accept \`--option VALUE\` and \`--option=VALUE\`. Ordinary positional \`DNS_NAME\` and \`--domain\` are alternatives; supplying both as CLI operands is an error. Ordinary \`--\` ends option parsing and leaves at most one positional identity. Duplicate scalar options fail. Only **two ordinary CLI names are repeatable**: \`--san NAME\` and \`--desired-cert-name NAME\`. JSON provider vectors are each **one** CLI option with a complete JSON-array value; repeating the flag does not append. Registration has **no** repeatable option.

The ordinary \`--help\`/\`-h\`/\`help\` and \`--version\`/\`-V\`/\`version\` aliases work as **first-argument** fast paths. They do not authorize network activity. The registrar does not accept \`register --help\` or \`register --version\` as options: use the ordinary top-level help and the registration reference.

## Ordinary producer: every recognized public setting

The "File" column means that the shared literal-file reader accepts the corresponding key **for ordinary execution**. \`—\` means no accepted application environment or file counterpart. All listed ordinary flags are **implemented**, not planned. The values and exact spelling are taken from the current option dispatch and resolver.

| CLI / positional syntax | Exported application environment | Literal file | Resolved default / required | Effect, restrictions and source |
| --- | --- | --- | --- | --- |
| \`DNS_NAME\`, \`--domain NAME\` | \`DOMAIN\` | Yes | Selected identity required except unselected \`RENEW_ALL=true\` | Exactly one primary name. DNS names normalize to ASCII lowercase then validate. No empty explicit identity or simultaneous CLI primary forms. \`lib/config.bash\`, \`lib/identity.bash\` |
| \`--acme-environment production|staging\` | \`ACME_ENVIRONMENT\` | Yes | \`production\` | Only the two exact Let's Encrypt CA profiles, bound to matching persisted account/renewal identity; staging requires deliberate selection and a distinct archive key. \`lib/config.bash\`, ADR-042 |
| \`--san NAME\` (repeatable) | \`ADDITIONAL_SANS\` | Yes | Zero extras | CLI occurrences jointly replace the full environment/file collection. Environment/file use comma-separated fields, not CLI commas; max 99 explicit extras and final limit 100 SANs. \`lib/config.bash\`, \`lib/identity.bash\` |
| \`--include-subdomains true|false\` | \`INCLUDE_SUBDOMAINS\` | Yes | \`true\` | Strict boolean; includes complementary apex/wildcard for each explicit name, with deduplication. \`lib/config.bash\`, \`lib/identity.bash\` |
| \`--cert-name NAME\` | \`CERT_NAME\` | Yes | Derived selected lineage name | Exact lowercase nonwildcard stable identity when explicit; independent of overlapping SANs and preserved across intentional SAN changes. \`lib/identity.bash\` |
| \`--s3-bucket BUCKET\` | \`S3_BUCKET\` | Yes | Required | Names an **already provisioned** S3 bucket. It neither creates that bucket nor grants IAM. \`lib/config.bash\`, ADR-020/021 |
| \`--s3-key KEY\` | \`S3_KEY\` | Yes | \`latest.tar.gz\` | Single literal current key, no slash/whitespace/leading hyphen. Paired alternative to \`S3_KEY_TEMPLATE\`, not independently merged across sources. \`lib/config.bash\`, \`lib/filename.bash\` |
| \`--s3-key-template TEMPLATE\` | \`S3_KEY_TEMPLATE\` | Yes | Unset | Uses frozen UTC \`{YEAR}\`, \`{MONTH}\`, \`{DOM}\` substitution to select **the** current key; conflicts with \`S3_KEY\` at one winning tier. \`lib/filename.bash\`, ADR-032 |
| \`--backup-key-template TEMPLATE\` | \`BACKUP_KEY_TEMPLATE\` | Yes | \`archive-{YEAR}{MONTH}{DOM}.tar.gz\` | Chooses a date-based secondary object name **without** authorizing publication or deletion. Filename and retention eligibility have separate validation. \`lib/filename.bash\`, ADR-033/034 |
| \`--dated-backup-enabled true|false\` | \`DATED_BACKUP_ENABLED\` | Yes | \`false\` | Opts in to separately guarded dated publication after successful current-object verification/publication. \`lib/backup.bash\`, ADR-033 |
| \`--backup-retention-count N\` | \`BACKUP_RETENTION_COUNT\` | Yes | \`0\` (no deletions) | Canonical decimal \`1\`–\`10000\` enables managed deletion **only** with dated publication and a retention-eligible template. \`lib/config.bash\`, ADR-034 |
| \`--upload-no-renewal true|false\` | \`UPLOAD_NO_RENEWAL\` | Yes | \`false\` | Permits a **fully validated unchanged** result to republish; durable changes publish independently of this flag. \`src/main.bash\`, \`lib/publish.bash\` |
| \`--renew-all true|false\` | \`RENEW_ALL\` | Yes | \`false\` | Checks every original complete archived lineage exactly once without implicit issuance, unselected SAN changes or global Certbot renew. May be domainless only with valid nonempty inventory. **Merged/supported** under ADR-058, PRs #283/#285/#286 |
| \`--remove-orphans true|false\` | \`REMOVE_ORPHANS\` | Yes | \`false\` | **Destructive** opt-in; requires a valid selected certificate and **separately explicit complete desired set**. No host-global Certbot delete, revocation or removal of backups. **Merged/supported** under ADR-059, PRs #287/#288/#289 |
| \`--desired-cert-name NAME\` (repeatable) | \`DESIRED_CERT_NAMES\` | Yes | No collection | Exact lowercase nonwildcard stable identities; max 100 and no duplicates. CLI is a **whole-collection** replacement; environment/file use comma-separated lists and whole-tier precedence. Must include selected identity when removal is true. \`lib/config.bash\`, \`lib/orphans.bash\` |
| \`--archive-encryption auto|none|gpg-ocb\` | \`ARCHIVE_ENCRYPTION\` | Yes | \`auto\` | \`auto\` selects plaintext only without a GPG secret, authenticated OCB with one. No implicit encryption-mode downgrade, secret export to provider or S3 key rename. \`lib/config.bash\`, ADR-031 |
| \`--archive-migration none|plaintext-to-gpg-ocb\` | \`ARCHIVE_MIGRATION\` | Yes | \`none\` | One-way opt-in from backed-up plaintext to authenticated encrypted archive at **same current key**. \`lib/config.bash\`, ADR-031 |
| \`--archive-migration-backup-confirmed true|false\` | \`ARCHIVE_MIGRATION_BACKUP_CONFIRMED\` | Yes | \`false\` | Positive acknowledgement required **with** migration; cannot be true when migration is \`none\`. Does not itself create/verify backup. \`lib/config.bash\` |
| \`--config FILE\` | — | — | Discover \`./.env\` if present | Selects an existing readable literal file; not a shell script, only one explicit file, conflicts with \`--no-env\`. \`lib/config.bash\` |
| \`--no-env\` | — | — | Absent (\`false\`) | Presence-only; suppresses application environment/file, **including** environment-only GPG secret. External AWS environment remains. \`lib/config.bash\`, ADR-056 |
| \`--aws-args JSON\` | \`AWS_EXTRA_ARGS\` | **No** | \`[]\` | One bounded nonsecret JSON string-array of approved AWS **global** options. CLI replaces exported collection, no token merging. \`lib/config.bash\`, ADR-056 |
| \`--gpg-args JSON\` | \`GPG_EXTRA_ARGS\` | **No** | \`[]\` | Approved GPG compression options only, not cipher or passphrase overrides. CLI replaces exported collection. \`lib/config.bash\`, ADR-056 |
| \`--certbot-args JSON\` | \`CERTBOT_EXTRA_ARGS\` | **No** | \`[]\` | Approved Certbot logging/user-agent options; DNS-01 propagation delay is selected issuance/renewal only. CLI replaces exported collection. \`lib/config.bash\`, ADR-056 |
| First argument \`--help\`, \`-h\`, \`help\` | — | — | No operation | Prints public top-level usage, does not parse general trailing arguments. \`src/main.bash\` |
| First argument \`--version\`, \`-V\`, \`version\` | — | — | No operation | Prints assembled build identity, does not parse general trailing arguments. \`src/main.bash\` |

**Secret-only setting (no CLI or literal file):** \`GPG_SYMMETRIC_KEY\` is read **only** from an explicitly exported application environment at the trusted public entrypoint, captured privately and removed from the inherited environment. It is absent by default. Its presence conflicts with explicit \`ARCHIVE_ENCRYPTION=none\`. \`--no-env\` disables this application secret and therefore cannot read an existing authenticated encrypted archive.

**Source precedence that is *not* a scalar overlay:**

1. \`S3_KEY\` **or** \`S3_KEY_TEMPLATE\` is one mutually exclusive logical current-key choice at each tier. CLI wins the *pair* over environment, then file; specifying both in the same winning tier is invalid.
2. Repeated CLI \`--san\` values are one full list and replace, rather than append to, exported \`ADDITIONAL_SANS\`. An *exported empty* SAN collection deliberately clears an otherwise nonempty file list. File/environment syntax is comma-delimited.
3. Repeated CLI \`--desired-cert-name\` values are one full desired set. Without CLI, an **explicitly present** \`DESIRED_CERT_NAMES\` export overrides the complete file set. Here an empty explicitly present higher tier is an **error**, not an authorization to prune everything or an instruction to use a lower tier.
4. Each extra provider JSON vector is one independent complete CLI-over-exported-environment selection. The restricted literal file does not admit JSON vectors; a CLI \`[]\` deliberately replaces an exported nonempty collection.

**Provider allowlist and bounds:** Up to 16 string tokens and 4096 JSON bytes **per provider**; \`[]\` needs no conditional \`jq\`/\`base64\`, while a nonempty selection does. No \`eval\`, arbitrary endpoint overrides or \`--flag=value\` in provider arrays. AWS permits \`--cli-connect-timeout\` and \`--cli-read-timeout\` (separate canonical 1–600). GPG permits \`--compress-level\` (0–9) or \`--no-compress\` (not both). Certbot permits \`--max-log-backups\` (1–1000) and \`--user-agent-comment\` (printable 1–80 characters with restricted alphabet, including spaces or quotes); the additional \`--dns-route53-propagation-seconds\` (1–300) is rejected during \`register\`. Extra arrays **may not contain secrets**. See [ADR-056](adr/ADR-056-extra-provider-argv-and-no-env.md) for exact parse/dispatch restrictions.

**Incompatible or security-relevant combinations:** \`RENEW_ALL=true\` and \`REMOVE_ORPHANS=true\` are mutually exclusive **before S3 access**; destructive orphan reconciliation cannot be domainless and cannot infer the desired set from \`CERT_NAME\` or SANs. Positive retention requires independently enabled dated publication. Migration requires a real exported GPG secret, authenticated \`gpg-ocb\` and positive prior backup confirmation. Encrypted/plaintext mismatches, ambiguous S3 reads and unverified archived lineages fail closed. All cloud credentials, object-key serialization, trust in provider binaries and real recovery copies remain operator responsibilities.

## Separate \`register\` command: complete allowed settings

Registration is selected with **first argument \`register\`**, then zero DNS operands. Unlike the ordinary issuer, it is allowed to create a validated **account-only current S3 object** when that key is *positively absent*, with an independent S3 bucket existence check and conditional first write. It does **not** create a bucket, issue certificates or implicitly install keys. The registration parser resolves the following exact scalar options; **all registration options are single-occurrence**.

| Registration CLI | Environment | Literal file? | Default / required | Registration-specific condition |
| --- | --- | --- | --- | --- |
| \`--email ADDRESS\` | \`EMAIL\` | Yes | **Required** | Valid contact email, 254-character limit, syntactic checks. Required even when reusing an account; reuse does not automatically change account contact |
| \`--agree-tos true|false\` | \`AGREE_TOS\` | Yes | \`false\` | Must resolve to literal \`true\` for *every* invocation, including reuse. A false/unset value blocks registration before remote calls |
| \`--eff-email-signup true|false\` | \`EFF_EMAIL_SIGNUP\` | Yes | \`true\` | Explicit \`true\` passes \`--eff-email\`; false passes \`--no-eff-email\`. Distinct from TOS consent |
| \`--acme-environment production|staging\` | \`ACME_ENVIRONMENT\` | Yes | \`production\` | Exact Let's Encrypt directory and matching account; no CA fallback |
| \`--s3-bucket BUCKET\` | \`S3_BUCKET\` | Yes | **Required** | Existing authorized bucket, not automatically provisioned |
| \`--s3-key KEY\` | \`S3_KEY\` | Yes | \`latest.tar.gz\` | Literal current key, one tier-level choice |
| \`--s3-key-template TEMPLATE\` | \`S3_KEY_TEMPLATE\` | Yes | Unset | Alternative to literal key, same frozen UTC template mechanism as ordinary producer |
| \`--archive-encryption auto|none|gpg-ocb\` | \`ARCHIVE_ENCRYPTION\` | Yes | \`auto\` | Uses only environment-only \`GPG_SYMMETRIC_KEY\`, and cannot silently downgrade |
| \`--config FILE\` | — | — | Optional discovered \`./.env\` | Supplied literal file must contain **registration-allowed** keys only |
| \`--no-env\` | — | — | Absent | Suppresses application environment/file including secret, conflicts with \`--config\` |
| \`--aws-args JSON\` | \`AWS_EXTRA_ARGS\` | **No** | \`[]\` | Same bounded CLI-over-environment AWS option vector |
| \`--gpg-args JSON\` | \`GPG_EXTRA_ARGS\` | **No** | \`[]\` | Same bounded authenticated-encryption tuning vector |
| \`--certbot-args JSON\` | \`CERTBOT_EXTRA_ARGS\` | **No** | \`[]\` | \`--dns-route53-propagation-seconds\` is **forbidden** during registration |

Only \`EMAIL\`, \`AGREE_TOS\`, \`EFF_EMAIL_SIGNUP\`, \`ACME_ENVIRONMENT\`, \`S3_BUCKET\`, \`S3_KEY\`, \`S3_KEY_TEMPLATE\` and \`ARCHIVE_ENCRYPTION\` are permitted as **registration file keys**. The shared literal reader recognizes other issuer-specific file keys but **the registration parser rejects them** rather than ignoring them. To register under \`--no-env\`, provide contact email, affirmative TOS, bucket/key and optional CA choice via supported explicit CLI options; no application environment/file setting survives that mode.

In particular, **ordinary** \`--san\`, \`--domain\`, \`--cert-name\`, backups/retention, \`--upload-no-renewal\`, \`--renew-all\`, \`--remove-orphans\`, \`--desired-cert-name\`, archive migration, and backup confirmation are **not** accepted \`register\` CLI options. Normal issuance does **not** accept \`--email\`, \`--agree-tos\` or \`--eff-email-signup\` as CLI options. This command separation is intentional and must be preserved by Jenkins and administrator guides.

## Literal configuration, external dependencies and source status

The literal file is **not Bash**. Blank lines and full-line comments are allowed. Other lines must use a recognized \`UPPERCASE_KEY=VALUE\` without whitespace around \`=\`. One optional pair of matching outer quotes is stripped; embedded quotes, dollars/backticks, shell expansion and inline shell comments are not supported. Repeated keys, unknown keys, malformed spacing and unreadable explicit files are errors, including when another tier would override the value. \`GPG_SYMMETRIC_KEY\`, \`AWS_EXTRA_ARGS\`, \`GPG_EXTRA_ARGS\`, \`CERTBOT_EXTRA_ARGS\`, \`AWS_PROFILE\` and any real credential never belong in this file.

AWS credentials, region and profile are configured by AWS CLI/IAM separately; route53 authentication is an external Certbot plugin dependency. Neither \`--no-env\` nor the producer's normal config resolver is a sandbox for the trusted host environment, executable PATH or user account. Runtime libraries do not grant bucket or hosted-zone access.

\`RENEW_ALL\` and \`REMOVE_ORPHANS\` are **implemented and merged**, including independent acceptance coverage. No longer treat them as planned-only flags. Conversely, \`--gpg-key\`, \`--backend\`, \`--dns-provider\`, \`--archive-format\`, arbitrary ACME URL selection, generic provider argument passthrough, automatic bucket creation and implicit account registration **are not supported**.

## Reviewer crosswalk and evidence boundary

| Contract claim / interface | Current implementation source | Existing verification to consult |
| --- | --- | --- |
| Ordinary option parsing, strict booleans, precedence, no-env, literal .env, SAN and desired set | [config parser](../lib/config.bash), [entrypoint](../src/main.bash) | [config and identity Bats](../tests/config-identity.bats), [provider args Bats](../tests/provider-extra-args.bats) |
| Registrar-only parameters, consent defaults, no implicit issue | [register config](../lib/register-config.bash), [register entrypoint](../lib/register.bash) | [register Bats](../tests/register.bats), [registration continuity](../tests/register-continuity.bats) |
| Stable selected certificate, wildcard and SAN selection | [identity resolver](../lib/identity.bash) | [selected renewal](../tests/selected-renewal.bats), [SAN reconciliation](../tests/san-reconciliation.bats) |
| Frozen key templates, independent dated backups and scoped retention | [filename resolver](../lib/filename.bash), [backup](../lib/backup.bash), [retention](../lib/retention.bash) | [filename template Bats](../tests/filename-template.bats), [retention safety Bats](../tests/retention-safety.bats) |
| \`RENEW_ALL\` true, default-false isolation and fresh-runner behavior | [bulk renewal](../lib/bulk.bash), [ADR-058](adr/ADR-058-opt-in-archived-lineage-bulk-renewal.md) | [bulk acceptance](../tests/bulk-renewal-acceptance.bats) |
| \`REMOVE_ORPHANS\` true, explicit desired membership, guarded deletion | [orphan module](../lib/orphans.bash), [ADR-059](adr/ADR-059-explicit-desired-lineage-orphan-removal.md) | [orphan acceptance](../tests/orphan-prune-acceptance.bats) |
| Encrypted state / one-key publication / immutable checksums | [crypto](../lib/crypto.bash), [publisher](../lib/publish.bash), [artifact builder](../Makefile) | [encryption and migration](../tests/public-lifecycle.bats), [artifact tests](../tests/artifacts.bats) |
| Read-only retrieval (distinct public product) | [client entrypoint](../src/client.bash), [client config](../lib/client-config.bash) | [client tests](../tests/client-shipped.bats) |

The above is a *maintained-source crosswalk*; link presence and implemented parsers do not themselves establish a successful live AWS IAM decision, DNS-01 propagation, Let's Encrypt issuance, or a specific released tag. CI must still build and verify all three public producer flavors, their checksum companions, Bash 4.3 compatibility and behavior tests before anyone asserts current compiled-artifact parity. Any remaining documentation/CLI discrepancy that requires a runtime behavior change is **outside task #290** and needs separately approved work, rather than an unreviewed implementation alteration.
