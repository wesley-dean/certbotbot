# ADR-032: Deterministic and Safe Archive Filename Templates

Date: 2026-10-23

## Status

Accepted

## Decision

Certbotbot will support a strictly bounded, opt-in filename-template layer for
the authoritative current archive and optional dated recovery copies. The
existing literal `S3_KEY` remains exactly literal and defaults to
`latest.tar.gz`. A separate `S3_KEY_TEMPLATE` selects a rendered current key
when explicitly configured; `BACKUP_KEY_TEMPLATE` selects the recovery-copy
basename and defaults to `archive-{YEAR}{MONTH}{DOM}.tar.gz`. Those settings
are target public interfaces for implementation task #79; this design PR
does not make them available in the current executable.

The caller, certbotbot, captures one UTC calendar date for each invocation that
needs template resolution. It supplies only `YEAR` (four decimal digits),
`MONTH` (two decimal digits, 01–12), and `DOM` (two decimal digits, 01–31),
then asks the pinned released `mktext` library to render literal text **once**.
It validates date consistency, source templates, final rendered names, and
current/backup separation before remote reads, writes, or deletions. Neither
`mktext` nor user-provided templates read clocks or execute shell commands.

The authoritative current object remains the same exact selected key on
retrieval and publication. A dated backup is an additional, separately
authorized object under story #67 and its ADR, not a new current-key selection
mechanism. **This ADR authorizes no second remote write and no deletion.**
Tasks #81 and #84 must separately settle backup publication and retention
ownership before either operation is implemented.

## Context, constraints, and assumptions

- ADR-020 and ADR-028 govern the mandatory seeded S3 object, stable
  read/write key, validated publication, no-op policy, uncertain failed writes,
  and externally serialized writers. ADR-031 keeps encrypted and plaintext
  transport under the operator-selected key, without implicit `.enc` renaming.
- Only S3 and gzip-compressed tar are currently implemented. Approved but
  unfinished stories #63 and #65 concern alternate storage and formats. This
  decision does not claim capabilities or migrate archives for those stories.
- The existing parser resolves nonsecret values as CLI > exported environment
  > literal `.env` > defaults and rejects executable configuration. The existing
  `S3_KEY` accepts a literal single-component key, including non-template
  characters that need not be legal in new templates.
- `mktext` is a sourced Bash 4.3+ library, not an executable date formatter.
  Its public entry point is `mktext render CONTEXT`, reading standard input
  and writing standard output. Unrecognized macros survive unchanged by
  design, so certbotbot must reject them itself.
- For one operation, the current object and a dated backup use the same
  configured bucket and backend identity. Future backend normalization rules
  must be checked rather than assumed compatible with bytewise comparisons.

## Public configuration and precedence contract

The following nonsecret names use the established source precedence:

| Setting | CLI | Default | Meaning |
| --- | --- | --- | --- |
| `S3_KEY` | `--s3-key` | `latest.tar.gz` | Legacy literal current key; never rendered |
| `S3_KEY_TEMPLATE` | `--s3-key-template` | absent | Optional template for the current key |
| `BACKUP_KEY_TEMPLATE` | `--backup-key-template` | `archive-{YEAR}{MONTH}{DOM}.tar.gz` | Template for a dated backup key |

For the current key, `S3_KEY` and `S3_KEY_TEMPLATE` represent **one**
logical selection. Examine CLI, then exported environment, then literal
`.env`; the first tier that defines either setting wins over lower tiers.
If both are explicitly defined **at the winning tier**, fail configuration
rather than picking one. If neither appears, use the literal default
`latest.tar.gz`. An explicitly selected empty value is invalid; it does not
fall back. This preserves a higher-precedence CLI literal override of a
lower-precedence template, and the reverse, without silently treating an
old literal as a new template. At one tier, ambiguous selection is an error.

`BACKUP_KEY_TEMPLATE` resolves independently with ordinary precedence.
Its default exists as a future naming contract even when date backups are
disabled; declaring a name does not opt into publication or retention.
The separate opt-in controls, failure handling, and duplication policy belong
to #81/#82 and #84/#85.

## Date and rendering contract

1. Once after nonsecret configuration has been validated and before the
   first remote operation, take a single successful UTC calendar snapshot
   in a fixed, locale-independent decimal `YYYYMMDD` representation.
   Split and validate it; do not make separate clock reads per token or
   recompute dates during publication or retention. Failed clock acquisition
   or invalid date is a configuration/preflight error, not permission to use
   local time or a partial date.
2. Supply exactly the three values `YEAR`, `MONTH`, and `DOM` through
   a caller-owned Bash associative-array context. The tokens are
   case-sensitive and contain no interior whitespace in certbotbot templates,
   although mktext's general-purpose grammar is more permissive.
3. Recognize exactly `{YEAR}`, `{MONTH}`, and `{DOM}` (braces included)
   within otherwise safe filename text. Unknown, malformed, nested,
   lower-case, whitespace-padded, or unresolved brace expressions fail
   validation. There is no shell interpolation, recursive rendering,
   expression language, command substitution, or second rendering pass.
4. Resolve each selected template once, save the exact resulting current
   and backup names in the invocation context, and pass those names unchanged
   through retrieval, publishing, diagnostics, and any later retention
   operations. Day rollover while the command runs cannot change names.
5. For the fixed reference date 2026-10-20, the default dated template
   produces `archive-20261020.tar.gz`. A current template consisting only of
   literals produces that exact literal basename without a clock-derived
   suffix.

The date source is the executing runner's UTC clock, not S3 metadata,
certificate expiration, Certbot state, object creation time, or locale-specific
wall time. If a runner has an inaccurate clock, certbotbot does not promise the
name represents the true civil day. Two separate invocations on the same UTC
day can intentionally derive the same key; #81 must choose the collision
policy before writes.

## Filename safety, identities, and format boundaries

For **new template input and its rendered output**, enforce these constraints:

- Exactly one basename, not a path: no forward/backslash separators,
  colon, control characters, whitespace, leading dot/hyphen, `..`,
  URL escaping, non-ASCII bytes, or storage-provider metacharacters.
- Only ASCII letters, decimal digits, period, underscore, and hyphen may
  appear outside supported macro delimiters. Before rendering, every
  opening/closing brace must belong to a supported complete token;
  dollar signs, backticks, quotes, percent signs, glob characters, and
  other shell-like syntax are invalid **data**, never something to execute.
- The resolved basename must begin with an ASCII letter or digit and
  contain between 1 and 255 ASCII bytes, including its extension. Do
  not allow an empty name or a basename ending in a dot.
- For the currently supported gzip-tar format, the rendered name must
  end in the exact `.tar.gz` suffix. This is a filename/transport
  consistency rule, not a replacement for validating actual archive
  bytes or the encrypted envelope.
- An explicit legacy literal `S3_KEY` retains its existing validation
  and exact identity, even if its suffix is unconventional. Introducing
  templates must not reinterpret previously accepted brace text within
  that legacy field or silently narrow its established compatibility.
- A selected current key and enabled backup key must be distinct
  within the same bucket/backend namespace **after** resolution, and
  must not alias after provider-defined normalization. Detect collisions
  before any remote mutation. Unsupported or ambiguous naming semantics
  fail closed, rather than guessing from path text.

The first S3 implementation uses existing single-component keys and exact
bucket/key identity. A later backend may impose a stricter filename rule,
reserved names, separate namespace, or normalization check; it must reject
unsupported names rather than silently rewrite them. Extension mapping for
`.tar.bz2` or `.zip` is not adopted here. Story #65 must define matching
format selection, extension rules, migration, and content verification before
those combinations can be declared supported. No implicit archive-format
migration follows a change to a name template.

## Dependency and trust review

The candidate release for task #79 is `wesley-dean/mktext` **v0.0.17**
(published 2026-10-06), specifically its ordinary released
`mktext.bash` artifact:

- Release: https://github.com/wesley-dean/mktext/releases/tag/v0.0.17
- Artifact: https://github.com/wesley-dean/mktext/releases/download/v0.0.17/mktext.bash
- Release-reported SHA-256:
  `9119e3b563512a8fe015f2b4666dd5da44494b8e61bd402b24dbefcc6f3a322b`
- Upstream public API: `mktext set CONTEXT KEY VALUE` and
  `mktext render CONTEXT`. Bash 4.3+; published license: CC0-1.0.

Task #79 must acquire the exact released bytes via a committed
bashdeps manifest identity and digest, inspect the acquired script, verify
checksum and license/provenance, and arrange deterministic in-build sourcing
or assembly into all three standalone artifacts. Neither a mutable
upstream branch nor a runtime network fetch is acceptable. The digest is
release metadata observed during design; no independent downloaded-artifact
hash verification is claimed by this ADR. If the published artifact differs,
or its composition is incompatible with the build, task #79 must stop and
propose a reviewed amendment rather than substitute different bytes.

Under ADR-015, sourcing this code enlarges the trusted computing base:
it runs in the same Bash process and can in principle observe process
variables, sensitive in-memory state, AWS configuration, or filesystem
authority even if certbotbot passes only nonsecret date values. The library
is documented to use Bash-only lexical rendering without external commands
for normal operations, but documentation and checksum pinning are **not**
security proofs. Keep the public integration narrow, do not pass keys,
credentials, archive contents, or GnuPG secrets in the template context,
and review embedded code paths for unexpected execution or side effects.

## Alternatives considered

**Make `S3_KEY` automatically interpret braces:** rejected. Historically
literal keys, including braces, must remain literal. An opt-in setting
keeps that compatibility explicit.

**Use shell expansion, `eval`, `date` syntax inside a template, or a
new template DSL:** rejected. They would cross an unnecessary code-execution
boundary and conflict with mktext's lexical/literal contract.

**Use local time, independent clock reads, or S3 object timestamps:**
rejected. They create timezone/rollover drift, implicit external dependencies,
or inconsistent identities. A single UTC snapshot is deterministic relative
to the runner's reported instant.

**Implicitly append `.enc` or repair invalid extensions:** rejected.
ADR-031 preserves the same configured authoritative object key when
ciphertext wrapping is enabled. Rewriting unknown names conceals operator
mistakes and complicates recovery.

**Allow arbitrary paths or broad S3 prefixes in templates:** rejected
for the initial interface to avoid path traversal, normalization aliases
and future backend hazards. A future safe storage namespace is a separate,
explicit adapter/retention decision, not a template escape hatch.

**Choose same-day overwrite/skip/versioning now:** deferred to #81 because
that choice creates persistence semantics beyond naming.

## Consequences, verification, and residual risks

The static MVP default continues to identify `latest.tar.gz`; backups and
retention remain disabled until separately opted into and implemented.
Operators may deliberately choose date-named current keys once #79 ships,
but they then own continuity of the mandatory seeded key: the program
must not infer, migrate, or discover a previous key automatically.

Acceptance evidence for #79/#80 will include all three public artifacts
under Bash 4.3+, literal compatibility, date/token rendering, source
precedence, unknown-macro and shell-text rejection, name collisions,
format restrictions, and a frozen-date midnight boundary. Failures in
configuration and local rendering must make zero AWS writes/deletions.
Backup collision and retention safety require additional #81–#86 evidence.
This design-only task cannot itself establish those future executable
behaviors or cross-backend compatibility.

The renderer protects against template-as-code interpretation, not a
compromised runner, wrong date, compromised sourced dependency, S3/IAM
misconfiguration, concurrent writes, object replay, or ambiguous lost
responses. No second object write or deletion is authorized by this ADR.

## Related decisions

- ADR-005 and ADR-015: pinned acquisition and trusted-code review.
- ADR-008, ADR-009, ADR-014 and ADR-016: docs-first sequencing,
  observable testing, assembly boundaries, and threat-model evidence.
- ADR-019: `approved` label authorization.
- ADR-020, ADR-028: stable single authoritative key and no-op publishing.
- ADR-030: complete shared account and multi-lineage state.
- ADR-031: authenticated envelope without automatic remote renaming.
- Task #78 governs this design; #79 implements it, #80 verifies it.
- Tasks #81 and #84 must establish separate publication/retention ADRs.
