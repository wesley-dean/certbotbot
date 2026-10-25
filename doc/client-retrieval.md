# Separate Client: Read-Only S3 Retrieval (Task #52)

Status: implemented in **maintained development source** under approved task
[#52](https://github.com/wesley-dean/certbotbot/issues/52). Task #53 integrated plaintext extraction and late activation in maintained
source. Task [#54](https://github.com/wesley-dean/certbotbot/issues/54)
now integrates the separately assembled client and checksum into the
release/test handoff. Published availability depends on a successful
main-branch release following review and merge.

Governing contract: [ADR-035](adr/ADR-035-standalone-read-only-certificate-client.md)
and [the separate-client contract](separate-client-contract.md).

## Maintained source and trust separation

- `lib/client-config.bash` resolves a deliberately narrow CLI
  (`--destination`, `--s3-bucket`, `--s3-key`,
  `--s3-key-template`, `--config`), exported environment and
  literal configuration, with the producer's source-tier rules.
  It does not source or evaluate a file, and producer-only
  nonsecret file settings are inert.
- `lib/filename.bash` supplies the existing validated template/UTC
  resolver. The pinned mktext renderer will be embedded into the
  standalone client during task #54. Tests inject a controlled
  one-pass renderer without fetching runtime dependencies.
- `lib/client-s3.bash` is the consumer-specific AWS CLI v2 boundary.
  It issues only `s3api head-object`, an optional `s3api
  head-bucket` on a 404, and `s3api get-object` for the exact
  configured key. It does not list backups, enumerate versions,
  read Certbot state or issue remote writes.
- `src/client.bash` owns CLI help/version, destination-parent
  safety validation, sibling private staging and cleanup. These
  sources are not yet added to the producer's three-flavor
  assembly, and the client does not depend on Certbot, Route53,
  GnuPG or issuer orchestration.

This separation is intentional: the eventual distribution
executable must contain only its reviewed client and pure shared
modules, assembled at build time and independent of `src/`,
`lib/` and `vendor/` on a consumer machine.

## Source-tier configuration

`S3_BUCKET` is required; `S3_KEY` defaults to
`latest.tar.gz`. Literal and templated key alternatives are
mutually exclusive **at the winning tier**, ordered CLI >
exported environment > literal `.env` file > default.
`--config FILE` selects a mandatory explicit literal file
instead of the optional implicit `./.env`.

The only client CLI settings are the five documented options,
plus standalone `--help` and `--version`. No positional DNS
identity, certificate selector, archive encryption secret or
backup search is accepted. Values are parsed as data, not shell
code, and no externally supplied values or credentials are
echoed in diagnostics.

An explicit template is validated and rendered using one
frozen UTC date under ADR-032. A literal key remains literal,
even if it contains brace-looking text. A higher-tier literal
masks a lower-tier template, and vice versa.

## Private staging and current task's safe boundary

`--destination` must identify a **new and absent** directory
beneath a pre-existing, canonical parent owned by the effective
user without group/other write access or symlink ambiguity.
The client refuses an existing file, directory or dangling
symlink target **before contacting AWS**.

The client creates an owned temporary mode-0700 sibling
directory, obtains at most one selected object, stages
nonempty bytes as `downloaded.tar.gz` and never prints their
content. A HeadObject 404 is classified as missing (status
66) only after a successful HeadBucket probe. Ambiguous
denials and transport failures remain status 69, whereas
local staging and empty-body failures are status 74.

**Current maintained-source behavior:** a successful download is
validated against the shared, bounded tar/gzip contract and extracted
privately before any activation. Invalid plaintext or GnuPG envelopes
return status **65**, removing staged bytes without creating a destination.
Only a complete validated tree is renamed to the absent destination
and reported on stdout. See [client extraction](client-extraction.md).
The separately built client binary and checksum are verified by the
#54 release gates before publication.

Successful `--help` / `--version` have no AWS dependency.
The final CLI statuses and success-path output are specified
in the [contract](separate-client-contract.md).

## Test evidence and next steps

`tests/client-read.bats` assembles the maintained client
sources in an isolated test-only fixture and uses a mocked
AWS CLI and controlled filename renderer. It covers:
unsupported downloaded bytes followed by deliberate fail-closed
status, absence/denial/transport/GetObject/empty
classifications, non-clobber and unsafe-parent refusal,
CLI/file precedence, key template resolution, and rejection
of executable/duplicate/unknown config data. Its AWS mock
refuses operations other than the specified read-side
commands; neither real AWS nor ACME credentials are used.

The existing producer release inventory is **unchanged**:
the client is not one of its three producer flavors. Task
#53 provides shared validation/extraction and real-tar archive
safety fixtures in `tests/client-extract.bats`. Task #54 adds the one standalone `certbotbot-client.bash` and `.sha256`,
independent black-box suite coverage, and explicit eight-file
CI/release artifact verification.

## Approved encryption preflight (task #185; decryption remains deferred)

ADR-037 adds one nonsecret `--archive-encryption auto|none|gpg-ocb`
setting with CLI > exported `ARCHIVE_ENCRYPTION` > literal file >
default `auto` precedence. With no exported secret, `auto` keeps the
existing plaintext path; with a nonempty exported
`GPG_SYMMETRIC_KEY`, `auto` selects authenticated decryption.
Explicit `none` plus a key, explicit `gpg-ocb` without a key,
invalid modes and line-broken keys are rejected as configuration errors
(64). Local help/version do not require a usable key or GnuPG.

Before running external tools, the entrypoint disables inherited
xtrace, captures the environment-provided secret in an unexported
Bash-local variable and removes `GPG_SYMMETRIC_KEY` from child
environments. Encrypted mode probes GnuPG >= 2.4.7 through the actual
issuer-compatible AES-256/OCB packet generation, SHA-512 iterated/salted
S2K parameters, authenticated decryption and exact roundtrip. It uses
a private isolated home and sends the key only on GnuPG FD 3.
Missing/incompatible tools fail 69 before the selected S3 fetch.
Plaintext operation requires no GnuPG. The original selected-key,
read-only AWS, private staging and existing destination rules remain.

**Task #185 does not activate encrypted archives.** After a successful
encrypted-mode capability preflight and one selected-object retrieval,
the current implementation deliberately rejects encrypted-mode
restoration with status 65, removing private staging without a destination.
Task #186 adds the actual authenticated envelope decryption, before
the existing tar validator and extraction. No raw key, ciphertext or
tool diagnostics are user-facing. Shell process memory and the
inherited initial environment are not isolated from privileged or
same-user host inspection. See
[client encryption threat model](client-encryption-threat-model.md).
