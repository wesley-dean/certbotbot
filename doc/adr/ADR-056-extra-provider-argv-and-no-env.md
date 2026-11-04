# ADR-056: Bounded Extra Provider Arguments and No-Environment Producer Mode

Date: 2026-11-04

## Status

Accepted

**Scope:** Milestone 17, approved user stories #233 and #234 and the
cohesive technical task #279.  This ADR is intended for review and acceptance
through the one associated implementation pull request.  It affects only the
three shipped producer variants, including their explicit `register`
command.  The separately shipped read-only client is unchanged.

## Decision

The producer will accept `--aws-args JSON`, `--gpg-args JSON`, and
`--certbot-args JSON`, together with their respective exported
`AWS_EXTRA_ARGS`, `GPG_EXTRA_ARGS`, and `CERTBOT_EXTRA_ARGS`.
Each value represents an **entire argument vector** as a JSON array
of strings, for example `["--cli-read-timeout","45"]`.
An explicitly supplied CLI array replaces the entire matching environment
array; collection elements are never merged across tiers.  Missing
collections mean zero additional arguments.  An explicit `[]` means
zero arguments even when a lower-priority collection is nonempty.
Literal `.env` files do not accept these collections because their
restricted grammar excludes JSON quoting and they do not hold secrets.

JSON parsing is mandatory only when a nonempty extra-argument configuration
is selected.  The optional operation needs an installed `jq` executable
and standard `base64` utility to decode into Bash indexed arrays without
shell evaluation, word splitting, or globbing.  Data is bounded to at most
16 tokens and 4096 encoded bytes per provider.  JSON strings may contain
spaces and literal quote characters without re-tokenization.  Embedded
control characters, NUL, and unsupported or empty individual option tokens
are refused; the empty **collection** `[]` is supported.  Malformed
JSON and wrong element types fail before external providers are invoked.
No `eval`, `source`, or argument re-parsing is authorized.

### Exactly supported extra arguments

Do **not** forward arbitrary upstream options.  Only the following
reviewed options and ranges are permitted, as separate option and value
tokens (except the single GPG switch).  Unrecognized flags, positional
tokens, `--option=value` shorthand, incomplete pairs, conflicting
GPG compression settings, and values outside the bounds are errors.
Repeated valid pairs preserve their input order; when the upstream tool
supports repetition its native last-wins behavior applies.

| Program | Supported extra option | Argument contract | Applicable invocations |
| --- | --- | --- | --- |
| AWS CLI | `--cli-connect-timeout` | Decimal integer 1–600 | Every producer-owned AWS `s3api` operation, including registration and backup/retention probes |
| AWS CLI | `--cli-read-timeout` | Decimal integer 1–600 | Same AWS operations |
| GnuPG | `--compress-level` | Decimal integer 0–9 | Authenticated symmetric encryption packet creation, including the capability probe |
| GnuPG | `--no-compress` | Presence-only; mutually exclusive with `--compress-level` | Same encryption calls |
| Certbot | `--max-log-backups` | Decimal integer 1–1000 | Registration, account checks, authenticator probes, issuance, and selected renewal |
| Certbot | `--user-agent-comment` | Printable 1–80-character string beginning alphanumeric; spaces and double quotes permitted; no shell metacharacters | Same permitted Certbot calls; the comment may be sent to the selected ACME service |
| Certbot | `--dns-route53-propagation-seconds` | Decimal integer 1–300 | Selected issuance and selected renewal only; not available for `register` |

The fixed command name, required security arguments, private workspaces,
account identity, selected CA/server, S3 bucket/key, conditional
PutObject/retention constraints, and GnuPG authenticated cipher,
S2K, passphrase FD, and output paths remain authoritative.
The producer adds these validated tokens **after its named options
and before positional operands** when applicable, preserving
the order of extra tokens without treating them as shell syntax.
Forbidden options include endpoint and CA overrides, certificate
force-renewal or global renewal switches, account/consent overrides,
AWS output/endpoint/credential substitutions, GPG option-file,
homedir, cipher/S2K/passphrase, and command execution flags.
These are examples of forbidden classes, not an additional allowlist.

### `--no-env` producer mode

A presence-only `--no-env` flag, default off, is supported by both
ordinary issuance and explicit `register`.  It is detected **before**
reading any application configuration or capturing the exported
`GPG_SYMMETRIC_KEY`.  It suppresses all Certbotbot application
environment settings, any implicit `./.env`, all literal file
configuration and the three extra-argument environment collections.
An explicit `--config` together with `--no-env` is rejected
rather than silently ignored.  Explicit CLI settings, positional
identities, and built-in defaults continue to apply.  An invocation
that needs encryption under `--no-env` cannot obtain its sole
supported secret and therefore fails closed; `auto` with no key
chooses plaintext, subject to existing archive-format checks.

This flag does **not** sanitize or block the broader operating-system
environment, `PATH`, `HOME`, or AWS CLI's own ambient credential
and profile mechanisms.  Such external dependency state is outside
Certbotbot's application configuration namespace.  Operators requiring
a fully isolated execution environment must supply their own wrapper
or container restrictions.  The existing secret is still removed
from child environments, and the flag does not create a CLI/file
alternative for `GPG_SYMMETRIC_KEY`.

## Context, Constraints, and Assumptions

Producer configuration uses two distinct parsers:
`lib/config.bash` for ordinary certificate management and
`lib/register-config.bash` for explicit registration.
The existing CLI > exported environment > literal config file > default
precedence and strict file grammar protect nonsecret scalar settings.
A separately exported GPG secret is an intentional exception in ADR-031.
Provider commands are distributed across S3, backup, retention, publish,
registration, selected renewal, certificate issuance and cryptography
modules.  Simply appending unvalidated shell strings would risk
remote-side effects, token injection, privilege/endpoint changes,
metadata mismatch, or bypass of selected-lineage guarantees.

The minimum supported Bash interpreter is 4.3.  `jq` and `base64`
are conditional, operational dependencies used **only when a nonempty
extra-argument selection is provided**.  If those tools are absent,
an operator using additional arguments receives a clear failure; the
ordinary unconfigured producer has no new prerequisite.  No new
dependencies become embedded into release artifacts.

The default public CA remains production, while dedicated staging
acceptance explicitly selects staging.  The extra provider arguments
cannot create accounts implicitly, create buckets, alter selected
lineages, weaken archive validation, redirect a private Certbot
workspace, or change the authoritative S3 object identity.

## Threat and Trust-Boundary Review

- **Configuration parsing:** Untrusted JSON is decoded as data only.
  Bound length/count, validate string types and allowable characters,
  preserve argv boundaries, and reject unexpected pairs before remote
  operations.  Invalid lower-priority environment JSON is ignored
  when a valid CLI collection has replaced it; no environment data is
  consulted under `--no-env`.
- **Command authority:** Strict option allowlists prohibit endpoint,
  process-command, credential, filesystem, CA, encryption and
  publication control.  Tests assert exact argument placement and
  absence on unrelated commands.  The runtime still trusts installed
  AWS CLI, GPG and Certbot implementations.
- **Credential confidentiality:** No raw extra-argument values are
  written into diagnostics.  Operator-supplied sensitive values must
  use native credential mechanisms instead of process arguments.
  Same-user or privileged process-inspection of argv, inherited
  process environment and execution by compromised dependencies
  cannot be prevented by Bash.
- **Encryption integrity:** GnuPG options cannot change authenticated
  AES-256/OCB, passphrase FD, S2K settings or output destination.
  Compression tuning does not bypass packet validation or plaintext
  authentication checks.  Decryption continues its existing strict,
  unmodified packet-validation path.
- **Operational failure:** A missing optional decoder, malformed
  configuration, unsafe option, or conflicting `--no-env`/`--config`
  combination fails without contacting the provider.  Remote write
  errors remain uncertain under ADR-028; retries and backup retention
  semantics are unchanged.

## Alternatives Considered

1. **Free-form shell text** split using whitespace or `eval`:
   rejected because quoted spaces and empty tokens cannot be
   represented safely and shell interpretation adds code execution.
2. **One environment string per token:** rejected because it
   requires a cumbersome fixed number of variables and cannot
   conveniently preserve a variable-length argument collection.
3. **Unrestricted JSON argument forwarding:** rejected because the
   supplier could override mandatory authority, side-effect,
   encryption or output flags.  A future safely reviewed option
   may be added through a new or amended ADR and tests.
4. **Automatic appending of env and CLI argument arrays:** rejected
   as ambiguous when an operator intends to override a lower tier.
5. **Remove the entire OS environment under `--no-env`:**
   rejected because the flag is for Certbotbot application
   configuration, not external AWS credential sourcing or runtime
   process services.
6. **Introduce a new CLI encryption-key flag:** rejected as an
   unsafe secret surface conflicting with ADR-031.
7. **Conditional strict JSON arrays and bounded option allowlists:**
   accepted for inspectable, fail-closed behavior and faithful argv.

## Consequences, Migration, and Verification

Existing invocations with none of the new flags or variables retain
their prior input resolution, provider argv, and dependencies.
`--no-env` is an explicit opt-in; it alters encrypted and otherwise
environment-configured invocations intentionally.  Registration
and ordinary issuance share the same collection semantics.

Tests must cover all three shipped producer flavors, non-evaluated JSON
(strings with spaces and quotes), CLI/env replacement, missing and
empty collections, repeated valid pairs, malformed/unapproved options,
subcommand-specific forwarding, registration, inherited AWS credentials
in `--no-env` mode, skipped malformed `.env`, explicit config
conflicts, secret suppression, no output leaks, and provider-side
effects on error.  The existing protected isolated local E2E
suite remains required on the final candidate commit, separate from
any real AWS or Let's Encrypt staging acceptance.

## Related Decisions

ADR-008, ADR-009, ADR-015, ADR-016, ADR-019,
ADR-020 through ADR-034, ADR-041, ADR-042, ADR-043 and ADR-055.
