# Separate Read-Only Certificate Client Contract

Status: design contract for approved [task #51](https://github.com/wesley-dean/certbotbot/issues/51), implementing approved [story #50](https://github.com/wesley-dean/certbotbot/issues/50) in tasks #52-#54.  **The executable is not implemented by this document.**

Governing decision: [ADR-035](adr/ADR-035-standalone-read-only-certificate-client.md).

## Purpose and authority

The standalone client fetches **one** current plaintext certificate-state archive from the operator-selected S3 bucket/key, validates it, and extracts **all** supported contents to a new caller-selected directory.  It is a read-only certificate **consumer**, not a renewal, deployment, S3 administration, or multi-lineage selection command.

"Current" / "latest" means **the object currently stored at the configured authoritative S3 key**.  The client does not list dated backup keys, inspect S3 versions, choose by LastModified time, or seek a fallback object when the selected one is absent or encrypted.

It requires normal preconfigured AWS CLI credentials with bucket read access (GetObject and bucket ListBucket as needed to classify missing objects).  It never requests `PutObject`, `DeleteObject`, Certbot, Route53, or ACME operations.  AWS identity privileges are provisioned by the operator, not constrained by the script.

## Executable and supported interface

After implementation and publication, the release filename will be `certbotbot-client.bash`, with sidecar `certbotbot-client.bash.sha256`.  The target CLI is:

`certbotbot-client.bash --destination DIRECTORY [--s3-bucket BUCKET] [--s3-key KEY | --s3-key-template TEMPLATE] [--config FILE]`

| CLI flag | Environment/.env | Required | Behavior |
| --- | --- | --- | --- |
| `--destination DIR` | Not supported | Yes | New extraction root that must not already exist |
| `--s3-bucket BUCKET` | `S3_BUCKET` | Yes, from some tier | Existing AWS S3 bucket |
| `--s3-key KEY` | `S3_KEY` | No | Exact literal current S3 object key; default `latest.tar.gz` |
| `--s3-key-template TEMPLATE` | `S3_KEY_TEMPLATE` | No | Opt-in current-key template using `{YEAR}`, `{MONTH}`, `{DOM}` |
| `--config FILE` | Not supported | No | Explicit mandatory literal config-file path, replacing automatic `./.env` |
| `--help` | Not supported | No | Print help without AWS access or extraction |
| `--version` | Not supported | No | Print client version and build provenance without AWS access |

Ordinary options accept both `--flag=value` and `--flag value`.  No positional DNS name, certificate name, backup key, encryption key, selected lineage, runtime renewal option, source archive path, or STDIN body is supported.  Unknown/duplicate/conflicting flags and unexpected operands are errors.

Each nonsecret selected setting resolves CLI > explicitly exported environment > literal config file > default.  `--config FILE` is CLI-only; an absent explicit file fails, an absent implicit `./.env` is normal.  The file grammar is the producer's literal `KEY=VALUE` data grammar: no evaluation, shell expansion, sourcing, executable substitutions, duplicate keys, or unrecognized keys.  Existing **recognized** producer-only nonsecret keys may appear for file reuse but have no operational effect on the consumer.  Secrets do not belong in `.env`; `GPG_SYMMETRIC_KEY` is not a supported client input.

`S3_KEY` and `S3_KEY_TEMPLATE` compete for one logical current-key setting at **each source tier**.  The highest tier defining either wins; defining both at that tier is an error, not a preference.  An explicit empty value is invalid.  A literal `S3_KEY` is never reinterpreted as a template.  A template is rendered exactly once from a single frozen UTC date, with the safe ASCII basename/token rules of ADR-032.  The selected bucket/key is fixed for the whole read operation; it does not change after midnight or when backups exist.

## Successful output and destination

The `--destination` argument names a new extraction-root directory, not a file and not an existing directory into which files will be merged.  The client requires an existing canonical parent owned by the invoking effective user, without group/other write permission or ambiguous symlink resolution.  The final path must not already exist, even as a dangling symlink.  Invalid paths, untrusted parents, parent symlinks, and occupied targets fail before archive retrieval.

The executable creates a private mode-0700 staging directory in that **same parent**.  The downloaded bytes and extracted tree remain inside privately owned staging until all validation completes.  The final tree has private directory and key-bearing file modes; extracted tar ownership is never applied.  Supported ordinary file bytes and relative links are retained.  A late same-filesystem directory rename presents the complete tree at the chosen absent destination after success, with an immediate prior absence recheck.  Same-UID concurrent operations against the same target are unsupported and must be externally serialized.

On successful retrieval and activation, stdout contains **only one canonical absolute destination pathname plus a newline**, permitting shell callers to capture the output.  On failure, stdout contains no success pathname; stderr contains fixed, nonsecret actionable diagnostics.  Help and version print their own information without contacting S3.

The full archive is extracted, preserving a supported `accounts/` tree, zero or more complete `renewal/<name>.conf` / `live/<name>/` / `archive/<name>/` lineage triplets and auxiliary supported Certbot files.  No account, lineage, or private key is omitted because it was not selected.  An account-only archive is valid archive content and does not imply issuance.  Canonical renewal file contents may refer to `/etc/letsencrypt`; this client **does not rewrite them** or install them at that path.

## Input and format gate

1. Validate CLI inputs, literal configuration, current bucket/key and secure destination parent before S3 access.
2. Require installed AWS CLI v2 and supported ordinary local tools.
3. Use `s3api head-object` for the exact bucket/key and `s3api head-bucket` only when corroborating a 404.  Denied or ambiguous failures do not mean "missing".
4. Download the object completely into private staging using `get-object`.  Zero bytes or partial/failed reads are errors.
5. Reject the known `CERTBOTBOT-GPG-OCB-V1` envelope, future/unknown encrypted envelopes and all ciphertext or non-gzip inputs.  Do not use a GPG key, attempt decryption, or retrieve another object.
6. Validate the bounded gzip/tar body **before extraction**, using the producer's supported format subset.  Initial constraints: decoded input no more than **32 MiB**, no more than **2,048** tar members; supported ustar/GNU-short forms; no malformed headers, duplicate/conflicting paths, traversal, hardlinks, special/sparse members, unsupported extensions, unsafe modes or symlink escapes.
7. Extract into a fresh private staging subdirectory without restoring tar ownership or privileged modes, and verify final file types, permissions, path containment, supported contents and valid intra-lineage relative `live` PEM links.
8. Recheck absence and activate the complete new destination.  Clean only owned staging paths on failure and report a nonzero error.  Never touch existing destination files, `/etc/letsencrypt`, or S3 state.

An archive being parseable is not proof of certificate/key cryptographic validity, present ACME registration, or authorization to execute renewal hooks.  The consumer does not run scripts found in the archive.

### Exit status contract

| Status | Meaning |
| --- | --- |
| `0` | Requested local help/version, or successfully activated destination |
| `64` | Invalid CLI, conflicting source selection, malformed literal config or input |
| `65` | Invalid, encrypted, corrupt, unsupported, oversized, or unsafe archive |
| `66` | Positively confirmed missing selected S3 object |
| `69` | AWS/required tool unavailable, access denied or ambiguous S3 state |
| `73` | Unsafe, missing-parent, occupied, or unwritable destination |
| `74` | Download, local staging, extraction I/O, or activation failure |

No client error permits a remote write.  Caller-visible diagnostics must not include raw AWS errors, credential values, archive member bytes, ACME account material, or private keys.

## Runtime and release distribution

The client is an independent executable that runs with Bash 4.3+, AWS CLI v2, GNU tar/gzip and ordinary documented local utilities.  It does not require Certbot, the Route53 plugin, GnuPG, a Git checkout, `vendor/` or in-repository `src/` and `lib/` at runtime.  Pure implementation may be assembled from reviewed code at build time, including digest-verified mktext for template rendering where needed.  Build inputs and dependency trust remain governed by existing ADRs.

After task #54, `make build` and verified releases must contain exactly:

`dist/certbotbot.dev.bash`  
`dist/certbotbot.dev.bash.sha256`  
`dist/certbotbot.bash`  
`dist/certbotbot.bash.sha256`  
`dist/certbotbot.min.bash`  
`dist/certbotbot.min.bash.sha256`  
`dist/certbotbot-client.bash`  
`dist/certbotbot-client.bash.sha256`

Each `.sha256` is conventional SHA-256 digest plus executable basename.  Producer artifact flavor tests continue to run three times, one per flavor.  The client has its **own** black-box suite and its own Bash 4.3 compatibility gate, plus syntax, checksum, no-vendor, release provenance, and unexpected-asset checks.  No historical release is rewritten or assumed to contain the client.

## Acceptance matrix for tasks #52-#54

| Case | Required observation |
| --- | --- |
| Explicit CLI bucket/key | Exactly one selected object read, no list of backups or alternate keys |
| CLI/env/file/default source tiers | Deterministic matching producer precedence and same-tier conflict refusal |
| Template crossing UTC midnight | Current key frozen once for invocation |
| Missing current key (404 + HeadBucket success) | Status 66; no destination |
| HeadObject 403/ambiguous 404/transport failure | Status 69; no false "missing" result |
| Truncated/empty GetObject | Nonzero; no activation |
| Valid account-only plaintext archive | Entire supported tree restored privately |
| Valid one-/multi-lineage archive | All lineages, key history and relative `live` links preserved |
| Known GPG envelope/wrong file type | Status 65; no decryption, fallback or extraction |
| Malicious traversal/symlink/hardlink/device/duplicate | Status 65; no external writes, no success destination |
| Unsupported header/overlimit/corrupt gzip | Status 65; no partial final state |
| Existing directory/file/dangling symlink target | Status 73; existing material byte-for-byte unchanged |
| Parent symlink, group/other-write parent, invalid target | Status 73; no S3 read and no activation |
| Local staging/extractor/activation failure | Status 74; staged contents not presented as success |
| Unauthorized AWS PutObject/DeleteObject, Route53 or Certbot mock | Never invoked in any successful or failing case |
| Help and version with broken AWS stub | Success without S3 command |
| Actual built script in clean workspace | Functions without source tree/vendor/Certbot/GnuPG |
| Bash 4.3, checksum and release suite | Client tested independently; all three producer flavors remain covered |
| Secret-output sentinel | No key bytes, AWS credential value, archive member payload or raw tool error on stdout/stderr |

These are **future acceptance checks**, not tests executed or passed by task #51.  Use controlled AWS CLI mocks for S3 behavior, actual local GNU tar/gzip for archive fixtures, and a separate clean runtime workspace.  Do not run real S3, Route53, ACME, or registry operations as an implicit test.

## Explicitly deferred

Client GPG decryption (including GnuPG version/key delivery), selectively extracting one lineage, installing state into system paths, invoking service reloads or deployment hooks, fetching dated backups or S3 versions, replacement-in-place or rollback, alternate archive formats, other object stores, and distribution of client-specific OCI images all require separate approved contracts.

## Traceability

- [ADR-035](adr/ADR-035-standalone-read-only-certificate-client.md) owns the design.
- [Task #52](https://github.com/wesley-dean/certbotbot/issues/52) owns client CLI/configuration and read-only S3 retrieval.
- [Task #53](https://github.com/wesley-dean/certbotbot/issues/53) owns validation, safe extraction, destination activation and failure hygiene.
- [Task #54](https://github.com/wesley-dean/certbotbot/issues/54) owns build/release integration, checksum/attestation update, documentation, and shipped-artifact black-box testing.
- [ADRs 021, 022, 027, 030, 031 and 032](decisions.md) remain authoritative for the overlapping producer S3, archive, lineage, encryption, and key-selection semantics.
