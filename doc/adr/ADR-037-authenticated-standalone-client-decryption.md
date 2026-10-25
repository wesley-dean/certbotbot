# ADR-037: Authenticated GnuPG Decryption in the Standalone Read-Only Client

Date: 2026-10-24

## Status

Accepted

## Intent and Documentation Posture

This decision defines the **approved extension's target contract** for story #183 before executable changes.  It authorizes the narrowly scoped implementation in tasks #185-#188 after review and merge.  An ADR with status Accepted in an unmerged PR expresses the decision that will become operative upon merge; it does **not** claim that decryption already works.

## Context

ADR-035 deliberately made the first standalone consumer plaintext-only.  That was the correct boundary for story #50, but the issuer can already publish encrypted archives using ADR-031.  An operator who publishes only the authenticated ciphertext at the current authoritative S3 key cannot restore it on a separate machine with the current client.  Approved story #183 requires that consumer capability without granting the consumer the issuer's ACME, Route53, S3 write, migration, or renewal authority.

ADR-031 specifies an exact `CERTBOTBOT-GPG-OCB-V1\n` envelope carrying a GnuPG binary OpenPGP AES-256/OCB encrypted **whole gzip/tar archive**.  Its producer cryptography and migration policy are already implemented.  ADR-035 governs the client CLI, eight-file release identity, full multi-lineage restore, restricted destination parent, late no-clobber activation, and stable exit classes.  ADR-032 fixes current-key selection; ADR-036 fixes released-byte identity and CI gates.  No additional S3 object or release executable is authorized.

Material assumptions: the caller controls the destination parent and provides a trustworthy local runtime and secret distributor; the selected S3 object may be untrusted or tampered; a correct symmetric secret is independently provisioned to the consumer; existing GnuPG 2.4.7+ producer fixtures represent the target envelope.  No cryptographic authenticity claim extends to the unauthenticated envelope text itself, S3 object freshness, or archive authorship independent of key possession.

## Decision Drivers

- Preserve a single understandable producer/client encryption-mode contract.
- Keep the previously successful plaintext path entirely usable without GnuPG or a secret.
- Refuse mode confusion, cryptographic downgrade, wrong keys, partial authenticated output, and malformed packets.
- Protect operator secrets from subprocess inheritance, shell tracing, argv, logs, literal configuration, and published assets.
- Keep already accepted archive-validation and destination no-clobber boundaries unchanged.
- Avoid importing issuer capabilities merely to share code.
- Preserve Bash 4.3, deterministic offline assembly and the exact eight-file release.
- Make the format and failure matrix specific enough to drive black-box and CI tests.

## Decision

### Consumer interface and mode resolution

Add one **nonsecret** client option, `--archive-encryption auto|none|gpg-ocb` (both `--flag=value` and `--flag value`), resolving `ARCHIVE_ENCRYPTION` from CLI > explicitly exported environment > literal config file > default `auto`.  The existing parser's duplicate, malformed, unknown and conflict rules remain in force.  This option selects a permitted format; **it does not detect the format and automatically switch modes**.  The client neither accepts producer migration controls as actionable commands nor gains a migration flag.

The *sole* secret input is a nonempty exported `GPG_SYMMETRIC_KEY` supplied by the operator's secret manager.  The secret MUST NOT be accepted through CLI, `.env`, a positional argument, or an archive.  The key is not subject to ordinary nonsecret tier precedence.  The following cases are normative:

| Effective mode | Exported secret | Required selected S3 body | Result |
| --- | --- | --- | --- |
| `auto` (default) | Absent or empty | Plaintext bounded gzip/tar | Existing plaintext behavior; no GnuPG |
| `auto` | Nonempty valid key | Exact authenticated v1 envelope | Require authenticated decryption |
| `none` | Absent or empty | Plaintext bounded gzip/tar | Existing plaintext behavior; no GnuPG |
| `none` | Nonempty key | None | Configuration error; refuse silent plaintext |
| `gpg-ocb` | Absent or empty | None | Configuration error; no remote read |
| `gpg-ocb` | Nonempty valid key | Exact authenticated v1 envelope | Require authenticated decryption |

A mismatched **downloaded** body (ciphertext when plaintext was selected, plaintext when encrypted mode was selected), an unknown `CERTBOTBOT-GPG-` envelope version, raw OpenPGP without the envelope, and any unknown format fail with status 65.  Selection never triggers another GetObject, backup/version enumeration, conversion, alternate S3 key, or plaintext fallback.  A `--help` or `--version` invocation remains a local query with no need for secret, GnuPG, AWS, or a destination.

### Key handling and conditional crypto dependency

Before launching any child tool (including AWS CLI), disable Bash xtrace and capture the exported key in a nonexported shell-local variable; unset `GPG_SYMMETRIC_KEY` from the process environment.  Reject a key containing LF, CR, NUL where representable, or other bytes the fixed single-line passphrase-FD protocol cannot represent.  Bash cannot represent NUL in a variable, securely erase its memory, or guarantee that the **initial inherited environment** was not visible to a parent process.  Never re-enable tracing while the key remains in memory.  Set restrictive umask and avoid propagating the secret to ordinary helpers.

On the encrypted path only, require trusted GnuPG **2.4.7 or newer**, a private mode-0700 isolated home, `--no-options`, `--batch --no-tty --pinentry-mode loopback --no-symkey-cache`, and `--passphrase-fd 3` over a private non-argv descriptor.  Suppress or sanitize all GnuPG stdout/stderr; never use `--passphrase STRING`, `eval`, a literal key file, or key-bearing arguments.  OpenPGP S2K is not memory-hard.  Operators MUST use a randomly generated, high-entropy secret, recommended at least 256 bits, and independently safeguard/distribute it.  The script does not claim to assess entropy.

The client MUST perform a functional GnuPG encrypt/decrypt probe with the exact producer AES-256/OCB, SHA-512 iterated/salted S2K parameters, inspect the probe's packet form and compare its authenticated roundtrip, not merely check `gpg --version` or flag availability.  Missing/incompatible GnuPG fails status 69 *before the selected S3 fetch*; plaintext mode never performs or requires that probe.  The trusted GnuPG executable, libgcrypt, agent if used, process environment, and host kernel become conditional trusted computing base.  This approval does not install or vendor GnuPG.

### Wire-format and authentication gates

The exact envelope bytes are `CERTBOTBOT-GPG-OCB-V1` followed by one LF byte and one binary OpenPGP payload.  The v1 payload MUST match the issuer's exact supported packet contract: symmetric-key packet **version 5**, AES-256 cipher identifier **9**, OCB AEAD identifier **2**, iterated/salted S2K mode **3**, SHA-512 hash identifier **10**, S2K count **16777216**, and an authenticated AEAD encrypted-data packet with cipher 9 / AEAD 2.  Mere presence of the version marker or an AEAD-looking substring is insufficient.  A parser must reject extraneous/unsupported packet sequences and ensure the **complete ciphertext** is consumed; review and test this boundary explicitly rather than assuming that `--list-packets` textual matches alone authenticate anything.  The issuer's `lib/crypto.bash` is relevant prior art, **not** automatically authorized to be sourced wholesale.

Keep the full downloaded object private.  Validate the exact envelope, isolate the ciphertext payload, inspect the supported packet format, then use noninteractive GnuPG authenticated decryption to a separate private, initially absent staging file.  GnuPG may write plaintext before final tag authentication.  **Until GnuPG exits successfully, the file is untrusted and MUST NOT be passed to archive validators, GNU tar, or any active destination.**  On successful complete authentication only, subject the staged plaintext to the unchanged bounded gzip/tar validator, private full-state extraction, permission/link checks and late absent-destination activation.  A supported authenticated envelope is not a waiver of archive validation, certificate trust or safe symlink checks.

No stdout success path, final destination, or fallback content is emitted on any failed gate.  On error, clean only client-owned private files including partial plaintext, ciphertext, GnuPG home and probe artifacts, retaining any preexisting destination untouched.  Cleanup cannot guarantee forensic secure deletion of disk blocks.  The destination remains an absent immediate child of a preexisting secure, caller-owned parent; same-UID cooperating processes must serialize themselves, as under ADR-035.

### Implementation authority and release identity

Implement a small reviewed **client-specific** cryptographic adapter and call it from client orchestration; reuse carefully separated pure packet/preflight helpers from the producer only when they neither import nor invoke issuer, Certbot, Route53, archive migration, S3 publication, retention, or certificate-selection code.  Keep AWS operations restricted to HeadObject, conditional HeadBucket corroboration, and one GetObject for the same ADR-032-resolved key.  No producer format or issuer operation changes are allowed in this story.

Maintain exactly one `certbotbot-client.bash`, one adjacent `.sha256`, and the original three producer flavors and three checksums.  `make build` remains network-free given prepared pinned dependencies; no runtime `vendor/`, source checkout, or separate client artifact flavor.  Shipped-client **real-GnuPG** positive/adversarial cases must run as required CI and release gates on a runner proven to support ADR-031 OCB; those gates must coexist with plaintext, Bash 4.3, all three producer variants, exact artifact provenance and attestation-before-tagging from ADR-035/036.

### Stable error and output matrix

| Condition | Exit | Output and effects |
| --- | --- | --- |
| Help/version or complete validated activation | 0 | Local help/version or canonical destination path only |
| Invalid flag, conflicting modes, malformed literal config, missing/unrepresentable key | 64 | Fixed diagnostic; no AWS read for key/mode errors |
| Wrong mode for fetched body, unknown v1/future envelope, unsupported packet/S2K, wrong key, tamper, truncated ciphertext, failed authentication, malformed decrypted tar or unsafe contents | 65 | No destination, no success stdout, no second S3 read |
| Corroborated absent selected object | 66 | Existing missing-object classification |
| AWS denial/ambiguous remote state or missing/incompatible GnuPG in encrypted mode | 69 | Fixed diagnostic; GnuPG preflight failure precedes fetch |
| Unsafe, occupied, unowned, or unwritable destination | 73 | Existing destination untouched; fail before fetch |
| Download, filesystem staging, extraction, cleanup/activation I/O failure | 74 | No successful activation; fixed nonsecret diagnostic |

No raw external diagnostics, archive names or contents, key fragments, filesystem plaintext contents, or secrets may be sent to stdout/stderr.  On successful retrieval stdout contains only the canonical destination path and newline; raw crypto diagnostics are not user-facing.

## Promises

1. Plaintext operation without a secret remains functional without GnuPG.
2. The client selects exactly one current S3 object and performs no writes or issuer actions.
3. Encrypted activation requires exact v1 packet compatibility, complete successful authenticated GnuPG decryption, then the existing tar/tree validation.
4. No secret is intentionally passed to child processes other than the trusted GnuPG passphrase descriptor.
5. Private staged content is not activated until all checks succeed, and an existing destination is not replaced.
6. The eight-file release contract and producer behavior remain intact.

## Non-Promises

- Ciphertext is not protected against valid older-object replay, a compromised trusted secret-holder, or a deliberately selected but otherwise valid historical S3 object.
- The version header is **not** itself AEAD-associated data, and encryption does not prove a certificate is trusted or current.
- Bash cannot hide the initial exported secret from parent/privileged/same-UID monitoring, promise secure memory erasure, or withstand a compromised GnuPG, AWS CLI, tar, kernel or host.
- Cleanup of temporary files is not guaranteed after abrupt host failure and is not forensic disk erasure.
- No key management, rotation, migration, legacy CFB/MDC compatibility, backup discovery, certificate installation, service restart, or source authenticity independently of secret possession is provided.
- No general atomic replacement of an existing destination, S3 snapshot isolation, or defense against malicious same-UID races is claimed.

## Adversary and Failure Model

Untrusted S3 object bytes can carry wrong format, valid-looking headers, malformed OpenPGP packets, corrupted/authentication-failing ciphertext, unsafe compressed tar members, or a valid replay.  A configuration mistake can supply a mismatched mode, missing key, or unsupported GnuPG.  A crash can leave temporary staged plaintext until external cleanup.  A malicious same-UID process or privileged host process can defeat confidentiality and pathname guarantees outside the supported threat boundary.

The client-specific threat review and test evidence requirements are maintained in [the client encryption threat model](../client-encryption-threat-model.md).  Authenticated ciphertext and read-only IAM are separate properties: neither is a substitute for private staging or least privilege.

## Operational Constraints

- MUST fail closed on ciphertext format, packet, decryption and post-decryption tar errors.
- MUST NOT automatically infer encryption from downloaded bytes, fall back to plaintext, accept unknown/legacy OpenPGP, or retry an alternate S3 key.
- MUST reject inconsistent key/mode configuration before remote access.
- MUST keep initial AWS/other helper environments free of the captured secret.
- MUST require a proven GnuPG 2.4.7+ OCB capability only for encrypted mode.
- MUST authenticate before validating or extracting any staged plaintext.
- MUST retain ADR-035 destination, status, full-lineage and release behavior.
- MUST NOT import or authorize issuer write/renew/migration authority.

## Considered Alternatives

### Envelope auto-detection

Rejected.  Automatically switching to decryption based on untrusted bytes would change key requirements and allow confusing changes in object representation to alter the command's behavior.  Explicit effective-mode selection follows ADR-031's producer contract; `auto` means **key-based mode selection**, not body-based guessing.

### Require an explicit encrypted flag on every invocation

Rejected as the sole control: it would diverge from the producer's existing `auto` plus exported-secret semantics and make shared nonsecret configuration unexpectedly inconsistent.  Explicit `gpg-ocb` remains available for deterministic deployments.

### Keep the client plaintext-only

Rejected for approved story #183 because encrypted-only producer archives at the same current key are otherwise unusable by a separate consumer.

### Import all issuer crypto, configuration and lifecycle modules

Rejected.  Their coupling would risk granting unnecessary provider, S3 write, migration, backup and other issuer behaviors to the client.  A bounded adapter and reviewed pure helpers preserve least authority even at some maintenance cost.

### Decrypt legacy CFB/MDC, older OpenPGP, or unknown envelopes

Rejected as an unapproved, cryptographically weaker compatibility surface.  Failure to support the required OCB is an error, not permission for downgrade.

### Put passphrases in argv, literal config or persistent files

Rejected because process listings, shell history, repository files, logs and retained data expand disclosure paths.  A private passphrase descriptor narrows but does not eliminate host/process risk.

### Stream GnuPG plaintext directly into tar

Rejected: decryption can emit bytes before an authentication failure is known, exposing untrusted content to the extractor before proof of integrity.

## Consequences

An encrypted consumer requires a suitable trusted local GnuPG toolchain, a separate high-entropy key distribution plan and more mandatory test and release infrastructure.  Fail-closed mismatch behavior can interrupt operation when someone changes the producer's selected mode or S3 object without coordinating clients; that is preferable to silently accepting plaintext or partially extracted state.  A new public nonsecret option must be documented and implemented consistently across parsing, shipped help, tests and release.  One shared source of truth for compatible pure packet logic is desirable, but security isolation is more important than preventing all duplication.

## Expected Outcomes and Verification

Task #185 implements nonsecret mode/key resolution, early secret capture and encrypted-only GnuPG preflight.  Task #186 implements exact envelope/packet acceptance, complete authenticated staging, existing validator/extraction integration and failure cleanup.  Task #187 supplies real-GnuPG shipped-client positive/adversarial cases including wrong-key, tamper, unknown packet, secret sentinel, no-clobber and plaintext-without-GPG.  Task #188 makes proven OCB capability and those cases mandatory in checksum/attestation-coupled CI and release and updates operator help/examples.  Until these tasks are reviewed, merged and release-verified, this ADR describes a target design, not a shipping capability.

## Supersedes

This ADR **partially supersedes ADR-035** solely in its plaintext-only prohibition, exclusion of client GnuPG/decryption, and associated unsupported-format/runtime assertions.  All ADR-035 constraints on read-only S3 access, exact selected key, complete archive, secure destination, failure output, eight-file release and no-clobber remain in force.  ADR-035 remains Accepted as historical and otherwise current governance.

ADR-031 remains authoritative **unchanged** for producer format, packet parameters, producer key handling and migration.  This ADR extends the compatible **consumer** side only; it does not supersede or modify ADR-031.  ADR-036 remains authoritative for CI/release handoff; tasks #187/#188 add required client cryptographic validation, not an alternative release path.

## Related Decisions

ADRs 002, 006, 009, 012, 015, 016, 019, 021, 022, 028, 030, 031, 032, 035 and 036; approved story #183 and tasks #184-#188; [separate-client contract](../separate-client-contract.md).
