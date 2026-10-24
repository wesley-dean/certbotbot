# ADR-035: Standalone Read-Only Certificate Consumer and Additional Release Artifact

Date: 2026-10-24

## Status

Accepted

## Intent and Documentation Posture

This decision defines the initial standalone certificate-consumer product before its implementation.  It makes the public interface, authority boundary, data activation policy, build/release contract, and exclusions explicit so tasks #52-#54 can implement and verify the same behavior.  It does not change the current issuer executable or imply that the new executable already exists.

## Context

Approved story #50 requires certificate consumers to retrieve the **current** S3 archive produced by certbotbot and safely extract it to an explicitly chosen local location without installing or invoking the certificate issuer.  Approved design task #51 must settle the public and release contracts before implementation.

The producer currently delivers three standalone scripts: `dist/certbotbot.dev.bash`, `dist/certbotbot.bash`, and `dist/certbotbot.min.bash`, each with a `.sha256` companion.  ADR-006 establishes these three producer representations; ADR-012 establishes the checksum naming and the six-file producer release model.  The release workflow presently assumes exactly three executable Bash files.  Adding a consumer executable without a narrow governing decision would contradict both the textual artifact-count contract and release checks.

The durable object stores the relative **contents** of Certbot's configuration directory, not an enclosing `etc/letsencrypt` directory.  Its supported plaintext form is a bounded gzip-compressed tar archive retaining account state, renewal metadata, versioned certificate files, and relative `live/<lineage>/*.pem` links.  Under ADR-030, a single archive can contain zero, one, or multiple complete lineages; retrieving that archive does not mean choosing or renewing a lineage.

ADR-031 now permits the producer to publish a versioned authenticated GnuPG envelope at **the same S3 key**.  Story #50 explicitly excludes client decryption in its initial scope.  Reading the correct S3 key therefore does not guarantee that its body is a supported plaintext archive.  The consumer must refuse encrypted objects rather than guess, discard the envelope, or attempt an undocumented downgrade.

The existing configuration contract uses CLI > explicitly exported environment > literal `.env` > defaults.  ADR-032 extends current-key selection to a mutually exclusive literal `S3_KEY` or rendered `S3_KEY_TEMPLATE` at the winning source tier, with one frozen UTC date when rendering.  Backups, retention, and object-version discovery do not redefine the authoritative current key.

## Decision Drivers

- A certificate consumer should not need Certbot, Route53, ACME authority, or the issuer's deployment environment.
- The initial product must preserve the exact supported full archive layout and certificate private-key confidentiality.
- Untrusted S3 bytes must not be activated as user-visible certificate state before complete validation.
- An existing target must never be overwritten, even when a remote read or extraction fails.
- Public CLI/configuration semantics should agree with the producer where both address the same S3 object.
- The three existing producer artifacts and release guarantees must remain intact.
- Bash 4.3, deterministic offline assembly, checksum verification, and release provenance remain binding.
- Later decryption support must require its own product approval, threat review, and compatibility decision.

## Decision

### Product identity and deliverables

Introduce **one** independent Bash executable named `certbotbot-client.bash` and one adjacent checksum companion named `certbotbot-client.bash.sha256`.  The two files will be generated beneath `dist/` by `make build`, tested as shipped, and included in the same verified release process as the producer.

The client is not another producer flavor.  It SHALL NOT receive `.dev.bash` and `.min.bash` variants in v1.  It SHALL expose `--version` with the same project release version and build provenance scheme as the producer, but have its own command identity and usage.  Full-line Doxygen comments stay in maintained client source; its single distribution representation follows the ordinary readable/comment-stripped Bash artifact convention.  A generated-file notice is retained in maintained assembly inputs as appropriate but is not a separate published debug flavor.

Following implementation, a normal build/release SHALL have **eight** current files: the unchanged three producer executables and three corresponding `.sha256` companions, plus the client executable and its `.sha256` companion.  ADR-006 and ADR-012 continue to govern the producer's three representations, their metadata, their checksum conventions, historical `.256` read compatibility, and the existing behavior matrix.  This ADR supersedes **only** their assumption that six files are the exhaustive release inventory.

### Public command and configuration

The v1 command is:

`certbotbot-client.bash --destination DIRECTORY [--s3-bucket BUCKET] [--s3-key KEY | --s3-key-template TEMPLATE] [--config FILE]`

Option order is arbitrary; `--name=value` and `--name value` are equivalent.  `--help` and `--version` are local queries with no AWS, filesystem activation, or archive dependency.  `--destination` is required on successful retrieval, is CLI-only, and names a **new, absent** extraction-root directory.  No domain, certificate name, positional target, STDIN archive, install hook, or cert-selector option is accepted.  The client extracts the **complete** supported object and does not filter lineages.

`S3_BUCKET` is required and has no built-in bucket default.  The current object key defaults to the literal `latest.tar.gz`.  `--s3-bucket`, `--s3-key`, `--s3-key-template`, and `--config` use the producer's established spelling and input expectations.  Current-key resolution MUST preserve ADR-032's single logical choice and source-tier conflicts; literal keys are not rendered, and an explicitly selected template freezes one UTC date for that invocation.  `--config FILE` selects one required explicit literal config file; otherwise an existing `./.env` is read and an absent implicit file is normal.  Config files are never sourced.

A client configuration reader MAY recognize existing producer-only nonsecret `.env` keys to permit reuse of the same file, but MUST ignore their operational effects and MUST still reject unknown/duplicate or executable syntax.  In particular, producer renewal, publication, migration, backup/retention, and lineage controls cannot cause actions in the consumer.  `GPG_SYMMETRIC_KEY` is not a supported config-file secret or a client decryption input.  The client's effective S3 identity must match the producer's selection for the same shared inputs and frozen date.

On complete success, standard output SHALL contain only the canonical absolute destination pathname followed by a newline.  Diagnostics SHALL use standard error and fixed, nonsecret descriptions; failed operations SHALL not emit a success path.  Successful `--help` and `--version` are the only non-retrieval stdout cases.  Untrusted archive member names and raw external CLI diagnostics SHALL NOT be echoed.

The complete normative option, error, format, and security matrices are maintained in [the separate-client contract](../separate-client-contract.md).

### Read-only retrieval and runtime dependencies

The client SHALL use AWS CLI v2 `s3api` requests on exactly one operator-resolved existing bucket/key.  It SHALL distinguish a positively corroborated missing object from ambiguous authorization, bucket, or transport errors following the fail-closed classification of ADR-021: a HeadObject 404 requires successful HeadBucket corroboration, otherwise it is not proof of absence.  A successful GetObject stages bytes privately and is not itself archive approval.

Its externally installed runtime tools are Bash 4.3 or newer, AWS CLI v2, GNU tar, gzip, and necessary ordinary core utilities.  The implementation MAY assemble existing reviewed pure configuration, filename, S3 read, and archive-validation code at build time when their contracts match the consumer, but SHALL NOT assemble or run Certbot, Route53, issuer orchestration, renewal, publication, backup deletion, or the GnuPG encryption/decryption adapter.  If the filename implementation requires pinned mktext, it is embedded and digest-verified **at build time**, never fetched or sourced from `vendor/` at runtime.  The public client is self-contained as a script, not a vendor-directory checkout.

An operator SHOULD authorize consumer credentials for `s3:GetObject` on the selected key and `s3:ListBucket` as required for HeadBucket/missing-key classification.  The client SHALL request no S3 write/delete, Route53, or ACME operations.  The script cannot technically prevent a too-broad operator-provided AWS identity from having additional permissions; least privilege is an operator IAM responsibility.

### Plaintext format and destination activation

The initial client SHALL accept only validated ordinary plaintext gzip/tar bytes compatible with the current bounded archive validator.  Recognized `CERTBOTBOT-GPG-OCB-V1` envelopes, future envelope versions, ciphertext, and unknown inputs fail **without** decryption or fallback.  No trailing extensions or key suffixes determine body trust: the body itself must validate.

The validator SHALL reject unsupported headers, traversal or absolute paths, duplicate/conflicting members, hardlinks, unsafe symlink chains, special/sparse members, unsafe permissions, decompression failures, and over-limit input *before* extraction.  The existing producer's currently verified limits (32 MiB decoded content and 2,048 members) provide the initial client acceptance envelope; changes to them require coordinated validator tests and compatibility review.  All four supported relative `live` PEM symlinks must resolve within their own lineage to valid regular archived PEM files.  The entire accepted archive tree, including account state and other complete lineages, must be retained; no arbitrary member pruning or host-state fallback is authorized.

`--destination` must resolve to a new non-existing immediate child of a pre-existing, canonical, caller-controlled parent directory.  The selected parent must be owned by the effective invoking user, must not be group/other writable, and must have no symlink ambiguity in the evaluated destination path.  Reject a destination that already exists as any filesystem type, including an empty directory or dangling symlink.  Reject unsafe path components and untrusted parents before retrieving data.

Construct a fresh mode-0700 private staging directory **as a sibling of the final destination on the same filesystem**.  Validate the complete downloaded object and stage extraction only inside private paths.  Extract without applying archived ownership or privilege bits.  Verify resulting file types, link destinations, permissions, structure, and required private-key restrictions.  Only after every gate passes may the implementation activate the staged directory by a same-filesystem rename to the still-absent chosen destination.  On failure, remove only client-owned private staging; never replace, merge into, or clean up a pre-existing destination.

The final extracted root and account/key-bearing subtrees must remain private to the effective user.  The tool SHALL preserve supported logical file contents and relative link topology, not assert that executable hooks or archived renewal configuration are trustworthy commands.  Extraction does not install into `/etc/letsencrypt`, restart a server, execute hooks, or validate certificate issuance/trust chains.

POSIX rename is not a universal no-replace primitive.  Under this v1 contract the destination parent is caller-controlled and not writable by other users; concurrent processes operating as the **same UID** must be externally serialized.  The implementation must recheck absence immediately before activation and MUST NOT claim to resist deliberate same-UID races or provide general transaction semantics.  If ordinary filesystem failure precludes activation, report nonzero without presenting staged data as successful output.

### Failure statuses

The client SHALL document stable observable classes: `0` success, `64` invalid CLI/configuration, `65` unsupported/invalid archive or unsafe content, `66` positively confirmed missing S3 object, `69` required tool unavailable or ambiguous S3 failure, `73` invalid/occupied/untrusted destination, and `74` local staging/download/extraction I/O failure.  Every failure is nonzero with no successful destination path printed.  More precise internal errors may be logged only as nonsecret fixed diagnostics.

### Build, test, and release boundary

Tasks #52 and #53 implement retrieval and safe extraction, and task #54 integrates assembly and release.  `make build` must remain offline and produce checksum companions in conventional `sha256sum` format.  The release pipeline must validate **the explicit four executable names** (three producer plus one client), their four checksums, Bash syntax, minimum Bash 4.3 behavior, independent client black-box tests and absence of unexpected/stale release assets.  Artifact discovery patterns must not accidentally treat the client as another producer flavor or reduce producer coverage to keep a hard-coded count green.

All exact released files receive their usual release attestations and provenance association.  Historical six-file releases remain unchanged and verifiable.  The client is released alongside a producer version, but older tags are not assumed to contain a client.  The consumer SHALL not silently download an absent sidecar from an earlier release and pretend that release supported the client.

## Promises

1. The client reads the one current configured S3 object and never intentionally performs remote writes, provisioning, Certbot/Route53 operations, or renewal.
2. Only a fully validated plaintext archive can become a completed destination.
3. An already-existing destination is not an update target; failure cannot replace its pre-existing files.
4. Account state, the full supported lineage inventory, and legitimate relative live links are preserved together.
5. All client runtime source is self-contained in one released executable, with one verified checksum companion.
6. The producer's three existing flavors, their checksums, build provenance, release checks, and tests remain intact.

## Non-Promises

- No decryption, key migration, automatic S3 backup search, object-version listing, retention, or rollback.
- No certificate issuance, renewal, private-key rotation, ACME account registration, service installation, or web server reload.
- No isolation from a compromised AWS CLI, tar/gzip binary, same-UID adversary, privileged host process, or malicious runtime environment.
- No distributed S3 snapshot or freshness guarantee between HeadObject and GetObject; "latest" never means highest object timestamp.
- No automatic retry on an encrypted current object with a previously plaintext backup.
- No guarantee that locally extracted keys and certificates are currently valid, match a target service, or are trusted by clients.
- No claim that an S3 response, checksum sidecar, or tar validator proves remote historical provenance or archive authorship.

## Adversary and Failure Model

| Boundary | Hazard | Required mitigation | Residual risk |
| --- | --- | --- | --- |
| CLI and literal config | Shell injection, source-tier confusion, wrong key | Parse as data; reject ambiguous inputs; freeze selected key | Operator can deliberately select wrong valid object |
| AWS access | Denial mistaken for 404, partial download | Corroborate missing result; private staged bytes | Writer can change object between requests |
| S3 object body | Encryption envelope or malicious tar | Hard refuse ciphertext; bounded pre-extraction validation | Supported format alone is not authenticity |
| Tar extraction | Traversal, dangerous links or mode changes | Preflight and private staging; validate restored tree | Trusted external tar implementation is in TCB |
| Local destination | Clobber, symlink redirect, partial success | Controlled parent; absent destination; sibling staging and late activation | Same-UID concurrent writer not sandboxed |
| Key/credential exposure | Echoed secrets, loose mode, inherited authority | Private workspace; fixed diagnostics; least-privilege IAM | Compromised caller or host can read its keys |
| Build/release | Incorrect artifact count, untested client bytes | Explicit inventories, tests, sidecars, attestations | Release verification is not a proof of no defects |

Security evidence belongs in focused mocked-S3 and real local tar/gzip tests, plus negative assertions that no write/Certbot/Route53 tool is invoked and no existing destination is modified.  A missing or ambiguous IAM result, malformed archive, bad link, unsafe parent, or failed activation must all fail closed.

## Operational Constraints

- MUST create exactly one new client script and one `.sha256` companion, while preserving six producer files.
- MUST keep the client plaintext-only until an approved follow-up expands the feature.
- MUST treat the exact current key as authoritative and implement ADR-032 selection semantics.
- MUST accept complete supported multi-lineage archives without choosing a lineage.
- MUST keep both S3 authority and local filesystem authority narrower than the issuer's.
- MUST validate before extraction and activate only fully checked private staged contents.
- MUST refuse existing destinations and never use host Certbot state as fallback.
- MUST test shipped client bytes independently and retain existing producer tests at the Bash 4.3 floor.
- MUST not introduce unapproved extra client flavors or a second release channel.

## Considered Alternatives

### Ship the consumer as a fourth producer flavor

Rejected.  The consumer has different inputs, authority, output, tests, and dependencies.  An additional producer flavor would obscure its purpose and violate the producer three-flavor model.

### Ship three client variants

Rejected for v1.  It adds two executables, two checksums, and testing complexity without an approved requirement.  More than one client representation requires its own documented justification.

### Source the issuer's release executable at runtime

Rejected.  It would couple a read-only consumer to Certbot/Route53, issuer code paths and potentially broader privileges, and make helper distribution depend on another artifact.

### Duplicate all issuer implementation verbatim

Rejected.  It would invite divergent S3, key-selection, and archive-validation behavior.  Explicit build-time reuse of reviewed **pure** modules is preferred when boundaries match.

### Add client-side GnuPG decryption now

Rejected for this story.  Story #50's approved v1 scope explicitly excludes it.  ADR-031 governs the issuer's encrypted envelope and does not authorize new secret-handling functionality for certificate consumers.

### Discover the "newest" dated backup

Rejected.  Dated backups are separately governed recovery copies; selecting by timestamps, prefixes or object versions would violate the one-authoritative-key contract.

### Extract directly to an existing or created target

Rejected.  Files could be partially written or replaced on invalid or interrupted extraction.  Late activation of fully validated private staging provides a stronger observable success/failure boundary.

### Require a Python/third-party archive library

Rejected for the initial design.  The project has a reviewed Bash/GNU tar/gzip validator boundary; additional runtime dependencies would expand the attack surface without a demonstrated need.

### Force the client to install all private state under /etc/letsencrypt

Rejected.  Installation/host mutation are outside the approved client scope and would encourage unnecessary privileges.

## Consequences

The release pipeline and its artifact-count assumptions require deliberate changes in task #54, and client tests must be separate from the producer's three-representation behavior matrix.  The initial refusal of encrypted objects will limit usefulness for operators who have enabled ADR-031; documentation must make that limitation prominent instead of offering a silent fallback.  A strict new-directory policy means operators must explicitly manage deployment, rotation, and cleanup after extraction; that cost is intentional to avoid clobber and half-installed state.

One source repository and release version now encompass two distinct command products.  Their authority boundaries and tests remain separate even when pure validation or filename logic is reused at build time.  Reconsider the decisions if a future approved story adds decryption, selective extraction, non-Linux filesystem semantics, additional archive formats, or target-host installation.

## Expected Outcomes and Compatibility

The first client release can be downloaded, checksum-verified, and executed without its source tree or Certbot.  A valid existing plaintext object produces a private, complete Certbot state directory at a newly selected destination.  Invalid or encrypted input produces a nonzero result and cannot modify an existing target.  Existing producer scripts, existing S3 keys, and historical releases continue to work unchanged.

## Source Lineage

This decision is required by approved story #50 and task #51.  It refines ADR-006/012's release cardinality using their existing formats, ADR-014's assembly/runtime distinction, ADR-021's S3 read classification, ADR-022/027/030's archive and lineage invariants, ADR-031's wire-format refusal, and ADR-032's current-key resolution.  ADR-015/016 guide dependency and security review; ADR-019 establishes the authoritative task-approval label.

## Superseded Decisions

ADR-006 and ADR-012 are superseded **only** where their text implies that six files are the exhaustive release inventory for this specific repository.  Their requirements for three producer flavors and checksum sidecars remain in force, and the earlier ADR records are not rewritten.

## Open Questions and Follow-Ups

- Task #52 must prove the separate client can share configuration/filename/S3 logic without importing issuer authority, or document any bounded separate parser that preserves the public rules.
- Task #53 must establish evidence for the staging-to-destination activation path, unsafe-parent rejection, same-UID concurrency assumptions, and complete multi-lineage restoration.
- Task #54 must update explicit release inventories and Bash 4.3 black-box gates without weakening producer validation.
- A future client encryption story would need its own human approval, passphrase-delivery design, authenticated-mode tests, IAM/secret threat model, and explicit backward compatibility.
- A target-host installer or atomic replacement of an installed current directory would need separate architecture and approval.

## Related Decisions

ADRs 001, 002, 003, 004, 006, 008, 009, 012, 014, 015, 016, 019, 020, 021, 022, 027, 030, 031, and 032.  See [the public contract](../separate-client-contract.md).
