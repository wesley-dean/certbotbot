# Archive Filename Template Contract

Status: Naming implementation contract for approved task #79. Current-key
and explicit backup-key templates are resolved through released mktext and
validated before remote operations. Task #80 owns extended cross-feature
verification; dated publication and retention are separate work under
#82 and #85.

Governing decision:
[ADR-032](adr/ADR-032-deterministic-safe-archive-filename-templates.md).

## Operator-visible selection (planned)

The existing literal `S3_KEY` / `--s3-key` remains unchanged and defaults to
`latest.tar.gz`. An explicitly supplied `S3_KEY_TEMPLATE` /
`--s3-key-template` will choose a generated current object name; a separate
`BACKUP_KEY_TEMPLATE` / `--backup-key-template` defaults to
`archive-{YEAR}{MONTH}{DOM}.tar.gz`. Neither template is evaluated as Bash.

Current-key selection uses the highest source tier that defines either the
legacy literal or the new template: CLI > exported environment > literal
`.env` > default. Supplying both at the same winning tier is an error.
A selected empty value is invalid. The backup template resolves independently
using the normal precedence. Backup publication remains off until separately
enabled under task #82; specifying its filename alone does not enable it.

| Input | UTC snapshot | Intended resolution |
| --- | --- | --- |
| Default current key | Any | `latest.tar.gz` |
| Default backup template | 2026-10-20 | `archive-20261020.tar.gz` |
| `cert-{YEAR}-{MONTH}-{DOM}.tar.gz` | 2026-01-02 | `cert-2026-01-02.tar.gz` |
| `archive-{YEAR}{MONTH}{DOM}.tar.gz` | 2026-10-21 | `archive-20261021.tar.gz` |

Supported tokens are **only** `{YEAR}`, `{MONTH}`, and `{DOM}`, with
four/two/two digits. The caller computes the complete UTC date once before
S3 access and freezes the resolved object identities for the invocation.

## Validation boundary (planned)

Templates and their results are individual ASCII filename components, not
paths or commands. They allow letters, digits, period, underscore, hyphen,
and the three exact brace tokens. They reject unresolved, malformed or
unknown braces; dollar signs or backticks; path separators and traversal;
shell-like expressions; empty names; leading dot/hyphen; trailing dot;
and names over 255 bytes. The current gzip-tar format requires `.tar.gz`
in rendered template results. A legacy literal `S3_KEY` continues to follow
its existing validator, including its previous extension flexibility.

When backup publishing is enabled, the current and backup identities must
not resolve to the same bucket/key or provider-normalized object.
No mutation is permitted on a collision or invalid name. There is no
automatic remote key migration when a template changes.

## Integration and non-promises

- When neither the current key nor the backup template is explicitly
  templated, the legacy literal current-key path does not need a UTC clock
  read. A current-key template or explicitly supplied backup template
  freezes one date. Future dated-backup publication will resolve the default
  backup template when that feature is enabled.

- `mktext` only performs one lexical, nonrecursive substitution pass over
  an associative-array context containing the three nonsecret date values.
  Unknown macros survive mktext rendering and are rejected by certbotbot.
- In #79, add pinned released mktext v0.0.17 to the repository-root
  `dependencies.txt` with an immutable release URL, `vendor/` destination,
  and committed SHA-256 digest. `make deps` uses the pinned bashdeps
  bootstrap to acquire it; `make deps-check` validates it offline.
  `make build` consumes the prepared library and embeds it into all three
  standalone executables without network access. No runtime mktext download,
  `vendor/` sourcing, dependency-manifest access, or upstream checkout is
  permitted. Exact acquired-byte verification remains required in #79.
- S3 and gzip tar are today's supported integration baseline. Alternate
  backend/format stories #63/#65 are open; this contract does not claim
  `.tar.bz2`, `.zip`, SFTP, or other backends are working.
- The encrypted transport envelope under ADR-031 does not rename the
  configured object or append `.enc` automatically.
- Repeated same-day backups, two-object partial failures, operator-driven
  recovery, and retention ownership/deletion require separate Accepted
  decisions in #81 and #84; no automatic rollback or deletion is implied.

## Future acceptance examples

Tests against all three public executable flavors must prove that a frozen
2026-10-20 date renders the default recovery name, literal keys remain
literal, source precedence is correct, unknown tokens and shell-looking
text fail before remote mutation, and a midnight crossover cannot split
read/write/backup identities. #80 adds cross-feature coverage after the
relevant backup/retention implementation exists.
