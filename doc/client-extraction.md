# Separate Client: Safe Plaintext and Authenticated Extraction

Status: implemented, with separate authenticated-client release qualification added under #188; original extraction was implemented for approved [task #53](https://github.com/wesley-dean/certbotbot/issues/53). Task [#54](https://github.com/wesley-dean/certbotbot/issues/54) adds the standalone distributable and release/CI integration. The design is governed by [ADR-035](adr/ADR-035-standalone-read-only-certificate-client.md), [ADR-022](adr/ADR-022-portable-certbot-state-archives.md), and the [separate-client contract](separate-client-contract.md). A client release must pass separate black-box tests and attestation before publication.

## Observable behavior

The client reads exactly the operator-selected current S3 object through the approved read-only adapter. In plaintext mode, it accepts an ordinary **gzip tar**; in encrypted mode, it first requires an exact ADR-031 GnuPG AES-256/OCB envelope, complete authenticated decryption in private staging and the same gzip/tar validation. The decoded size limit is 32 MiB and the member-count limit is 2,048. Wrong mode, unsupported crypto/envelopes, corrupted/truncated input, traversal, hardlinks, unsupported members and escaping or broken PEM links fail with status 65. It never falls back to an alternate S3 object.

The new `lib/client-extract.bash` module composes the shared `lib/archive.bash` validator and `lib/restore.bash` private restore adapter. It extracts only into a new mode-0700 directory nested under the client's private staging directory. The restore adapter validates an exact private copy **before** invoking GNU tar, extracts without applying archived file ownership, and verifies the resulting filesystem and relative PEM links. Its `workspace/config` directory is *inactive*, never the selected user destination.

After all checks, the client narrows ordinary-file modes to **0600** and directory modes to **0700**, ensuring private keys, account material and renewal metadata remain private even if a publisher supplied broader read permissions. It preserves the complete supported archive, ordinary file contents and valid relative `live/<lineage>/*.pem` links. It does not execute archived files, renewal hooks or content, and it does not verify ACME registration, certificate chain trust or key/certificate cryptographic matching.

The destination is an **absent immediate child** of a preexisting canonical, owned, non-group/world-writable parent. The parent must also permit the caller to create files. The client revalidates the parent and destination immediately before activation. A GNU same-filesystem `mv -n -T` transfers only a complete, validated directory into the still-absent location. A newly occupied destination causes nonzero exit rather than replacing it; the client checks whether the staged root actually moved because GNU `mv -n` may report success when skipping an occupied target. POSIX rename is not a universal no-replace primitive, and ADR-035 explicitly excludes hostile same-UID races. Such cooperating processes must be externally serialized.

On success, **stdout contains only the canonical absolute destination path followed by a newline**. On any failure, no success path is printed, and the EXIT trap removes only client-owned staging (not the destination or caller files). The task #54 build assembles `dist/certbotbot-client.bash` and verifies its SHA-256 sidecar before release.

## Trust boundaries and failure handling

| Boundary | Accepted authority and checks | Non-promise / residual risk |
| --- | --- | --- |
| Operator CLI/environment/literal file | Selected current key and new destination, no code evaluation | The caller's account and host are trusted |
| AWS CLI v2 / S3 object | HeadObject, optional HeadBucket, GetObject only; fixed diagnostics | S3 content is untrusted, not authenticated by format checks |
| Downloaded bytes / gzip tar | Bounded validator, no extensions, limited relative symlinks | GNU tar, gzip, Bash, GNU coreutils and the kernel are in the TCB |
| Staging filesystem | Mode-0700 private directory and 0600 file staging; inactive extraction | A malicious same-UID local process is outside isolation guarantees |
| Activation | Full-tree postchecks, private mode normalization and late no-clobber rename | No general cross-process transaction or same-UID adversarial race guarantee |
| Secret output | No archive contents or raw AWS/tar stderr; nonsecret fixed diagnostics | Host-level logging, compromised tools and root are out of scope |
| Issuer permissions | No Certbot, ACME, Route53 or S3 mutation calls | IAM least privilege must be provisioned and audited by the operator |

The client documents stable status classes: 0 for successful activation or local help/version; 64 for invalid CLI/configuration; 65 for unsupported or unsafe archive content; 66 for corroborated absent object; 69 for missing archive tooling or an uncertain/denied remote operation; 73 for an unsafe, missing-parent or occupied destination; and 74 for local staging/extraction/activation failures. Invalid destinations fail **before** contacting S3.

## Representative acceptance evidence

`tests/client-extract.bats` assembles maintained client source with its real tar validator and restore adapter, uses a controlled local AWS read-only mock and **real GNU tar/gzip fixtures**. It checks account-only success, complete multi-lineage restoration, relative symlinks, private key modes, canonical renewal bytes, no-op staging cleanup, damaged and encrypted formats, traversal, malformed symlinks, unsupported filesystem members, duplicate/hardlinked members, size limits, occupied/untrusted destinations, and denied/uncertain S3 results. Existing `tests/client-read.bats` retains the original read/error precedence checks against an intentionally invalid downloaded body.

The task #54 test runner sets `BASH_STARTER_CLIENT_ARTIFACT` to the verified, standalone client and reruns both client fixture suites against an isolated copy, without needing `src/`, `lib/`, or `vendor/` at runtime. A green source-level test alone does not prove release readiness; publication must also pass the eight-file handoff, Bash 4.3 checks, attestation, and late-tagging gates.

Further changes to plaintext member-dialect support, encrypted envelope versions or algorithms, destination replacement, client selection/installation or concurrency guarantees require a new, explicitly approved design review.

## Authenticated restoration of the current encrypted object (task #186)

ADR-037 extends the standalone client with producer-compatible authenticated
restoration. A selected `gpg-ocb` mode retrieves **exactly** the configured
current S3 object as before, but requires the byte-exact
`CERTBOTBOT-GPG-OCB-V1` plus LF envelope. The payload must have precisely
one complete symmetric-key packet (tag 3) and one complete AEAD-encrypted
packet (tag 20), with no trailing bytes. A bounded streaming length check
recognizes ordinary and partial new-format OpenPGP packet lengths. A separate
GnuPG packet inspection enforces ADR-031 AES-256/OCB and SHA-512
iterated/salted S2K identity; neither inspection is itself authentication.

GnuPG must then **complete** AEAD decryption successfully inside the client's
private sibling workspace. Any plaintext written before authentication
completes is quarantined; no tar validator or extractor receives it. After
success, the existing 32 MiB / 2,048-member gzip/tar validator accepts or
rejects the decrypted object, and the existing extraction/permission/link
checks and absent-destination activation remain unchanged. Encrypted archives
restore all supported lineages, not merely one selected certificate.

Wrong mode, unknown envelope, malformed/legacy packet, tampering, bad key,
unsafe plaintext, and truncation fail without a final directory, fallback S3
read, archive contents or key on stdout/stderr. Both ciphertext and any
temporary plaintext are deleted by the owned-workspace cleanup on ordinary
failure; this does not promise forensic secure erasure or recovery after a
host crash. The plaintext path still requires neither GnuPG nor a secret.

The new packet frame check also uses a locally installed `awk` interpreter
together with GNU `od` (ordinary runtime/core utilities); these become
part of the conditional encrypted-input parsing trust boundary. Real-GnuPG
source and shipped-client fixtures exercise this behavior, while task #187
expands the adversarial matrix and task #188 establishes mandatory
release-level encrypted-client gates.

## Encrypted-client acceptance before release

Under ADR-037, the shipped client is exercised with real GnuPG in a
private isolated runtime, including positive account-only and multiple
lineage restoration and adversarial wrong-key, tampering, unsupported
format, unsafe tar, no-clobber and no-leak cases. Task #188 adds a
non-skippable, independently required **Test and Versioning** gate for
these fixtures, consuming only the same checksum-verified eight-file
handoff that will be published. Any missing or skipped fixture is
insufficient evidence of authenticated restoration, even if the
plaintext suite passes. Full release acceptance requires a successful
post-merge main-branch workflow and late attestation/tagging.
