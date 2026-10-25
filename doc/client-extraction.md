# Separate Client: Safe Plaintext Extraction and Activation

Status: maintained-source implementation for approved [task #53](https://github.com/wesley-dean/certbotbot/issues/53). The standalone distributable and release/CI integration remain task [#54](https://github.com/wesley-dean/certbotbot/issues/54). The design is governed by [ADR-035](adr/ADR-035-standalone-read-only-certificate-client.md), [ADR-022](adr/ADR-022-portable-certbot-state-archives.md), and the [separate-client contract](separate-client-contract.md). There is no claim of a shipped client yet.

## Observable behavior

The client reads exactly the operator-selected current S3 object through the approved read-only adapter. It accepts a **plaintext gzip tar** whose member paths, header types, size, member count, symlink relationships, permissions and structure pass the existing shared `certbotbot_archive_validate` implementation. The decoded size limit is 32 MiB and the member-count limit is 2,048. GnuPG OCB envelopes, unsupported formats, corrupted/truncated archives, traversal and absolute paths, hardlinks, devices, sparse and unsupported tar extensions, duplicate names and escaping or broken PEM links fail with status 65. It neither decrypts nor falls back to an alternate S3 object.

The new `lib/client-extract.bash` module composes the shared `lib/archive.bash` validator and `lib/restore.bash` private restore adapter. It extracts only into a new mode-0700 directory nested under the client's private staging directory. The restore adapter validates an exact private copy **before** invoking GNU tar, extracts without applying archived file ownership, and verifies the resulting filesystem and relative PEM links. Its `workspace/config` directory is *inactive*, never the selected user destination.

After all checks, the client narrows ordinary-file modes to **0600** and directory modes to **0700**, ensuring private keys, account material and renewal metadata remain private even if a publisher supplied broader read permissions. It preserves the complete supported archive, ordinary file contents and valid relative `live/<lineage>/*.pem` links. It does not execute archived files, renewal hooks or content, and it does not verify ACME registration, certificate chain trust or key/certificate cryptographic matching.

The destination is an **absent immediate child** of a preexisting canonical, owned, non-group/world-writable parent. The parent must also permit the caller to create files. The client revalidates the parent and destination immediately before activation. A GNU same-filesystem `mv -n -T` transfers only a complete, validated directory into the still-absent location. A newly occupied destination causes nonzero exit rather than replacing it; the client checks whether the staged root actually moved because GNU `mv -n` may report success when skipping an occupied target. POSIX rename is not a universal no-replace primitive, and ADR-035 explicitly excludes hostile same-UID races. Such cooperating processes must be externally serialized.

On success, **stdout contains only the canonical absolute destination path followed by a newline**. On any failure, no success path is printed, and the EXIT trap removes only client-owned staging (not the destination or caller files). The current source is not yet a published `dist/certbotbot-client.bash`.

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

These tests are source-level acceptance until task #54 produces the actual shipped client, checks its SHA-256 companion and runs black-box fixtures without `src/`, `lib/` or `vendor/` on the consumer. In the absence of a shipped artifact, a claim of end-to-end released-client acceptance would be premature.

Further changes to plaintext member-dialect support, encrypted archives, destination replacement, client selection/installation or concurrency guarantees require a new, explicitly approved design review.
