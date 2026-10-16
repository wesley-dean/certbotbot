# certbotbot Threat Model

Status: Initial design threat model, 2026-10-15.  Mitigations below are design requirements, not claims that unfinished implementation has passed testing.

This model applies the inherited `doc/threat-modeling.md` guidance and the imported standards security requirements.  Changes to storage, issuance, encryption, CI authority, archive format, dependency trust, or runtime providers require review.

## Security objectives and assets

Protect the confidentiality and integrity of TLS private keys, historical lineage keys, ACME account credentials, GPG passphrases, AWS/API credentials, certificate metadata, archives, and release artifacts.  Preserve the correctness of DNS challenges and the ability to recover from failures without accidentally overwriting the last known good certificate state.

## Trusted computing base

The trust boundary includes the Bash runtime, generated certbotbot artifact, bundled bashlog/mktext code, Certbot and its DNS plugin, AWS CLI, GPG, tar, local system libraries, CI execution host, cloud identity/permissions, object store, signed/reviewed build inputs, and the release toolchain.  The Bash runtime provides neither strong process isolation nor secure memory erasure.

## Trust and data flows

```mermaid
flowchart LR
  operator[Operator or CI input] --> parser[certbotbot parser and validation]
  creds[CI or host credentials] --> runtime[Private producer workspace]
  parser --> runtime
  s3[Object storage boundary] -->|encrypted or plaintext archive| runtime
  runtime -->|validated restored state| certbot[Certbot with DNS-01 plugin]
  certbot -->|TXT challenge| dns[DNS provider API]
  certbot -->|ACME requests| acme[Let's Encrypt API]
  certbot -->|lineage and account updates| runtime
  runtime -->|validated and optionally GPG-encrypted objects| s3
  s3 -->|selected domain archives only| consumer[TLS-consuming host]
  consumer -->|extract| dir[Local /etc/letsencrypt]
  dir --> services[HAProxy / Apache / nginx]
```

The consumer boundary excludes ACME account state by default and never requires Certbot or the producer program.  Consumer-side reloads and post-install scripts remain outside certbotbot's authority.

## STRIDE-oriented risks and mitigations

| Category | Threat or failure | Required mitigation and evidence |
| --- | --- | --- |
| Spoofing | Unauthorized actors use DNS/S3 credentials or impersonate the publisher | Least-privilege identity, CI secret isolation, audit records; GPG symmetric encryption alone does not authenticate publication |
| Tampering | Poisoned archive paths, symlink escapes, hostile tar metadata, replayed older objects | Validate archive member paths/types/targets before extraction; verify expected per-lineage scope; consider version pinning and signature support later |
| Repudiation | No reliable record of which actor published state | Log object identity, build/version, time, selected lineage and outcome without secrets; document audit trail limitations |
| Information disclosure | Private keys or passphrases leak to logs, temporary files, snapshots, old S3 versions, or consumers | Private workspace, `umask 077`, restrictive file modes, no command-line passphrases, CI masking, encryption when configured, avoid consumer distribution of common account archive |
| Denial of service | Invalid SANs, DNS validation failures, Let's Encrypt rate limits, storage outages, failed uploads, simultaneous writers | Preflight validation, finite retries/backoff where justified, serial processing, clear missing-vs-failed reads, fail closed, storage lock backlog |
| Elevation of privilege | Runtime plugin loading, untrusted shell evaluation, tar extraction, unsafe CI execution of PR code with credentials | In-tree provider bundling only, shell arrays, reject unsafe tar members, least privilege, separate release/secret contexts |

## Additional trust boundaries

### Input parsing and command construction

Do not interpolate operator input into shell source or run `eval`.  Reject hostnames beginning with option prefixes or containing path separators.  Wildcard patterns must remain literal until validated and passed to Certbot through arrays.  Test that malicious characters do not result in process execution.

### Storage state and concurrent writers

No distributed lock exists in the initial release.  Independent runners sharing a bucket/namespace can lose updates.  CI-only or host-only serialization is not a global guarantee.  A storage-backed lease with fencing, contention tests, and stale lease handling is required before advertising multi-writer support.

### Archive content and symlink integrity

Certbot's normal `live/` links are relative references to `archive/`.  Malicious or malformed tar members can replace files outside the intended workspace or create links crossing lineages.  Validate the full extraction plan, not solely file extensions.  Prefer staged extraction with secure ownership and verify link targets and certificate/private-key matching before publication.

### GPG confidentiality and migration

An unset passphrase means explicit plaintext object storage; documentation must disclose this.  Nonempty passphrase means encryption is required uniformly and decrypt failures are fatal.  Encryption does not sign content.  Manual migration must address S3 object version retention and plaintext remnants.  Neither filesystem deletion nor removal of an S3 current version alone guarantees destruction of historical plaintext.

### AWS endpoint and credentials

A custom S3 endpoint can redirect credentials and certificates to a different service; endpoints must be explicit and operator trusted.  Least-privilege Route53/S3 policies must restrict hosted zones, buckets, and prefixes.  Support assumed-role/OIDC temporary credentials and `AWS_SESSION_TOKEN`.  Do not demand static access keys when the SDK credential chain already works.

### Build/release supply chain

Only the pinned released bashdeps bootstrap is directly downloaded by Make.  Bashdeps handles declared artifacts and validates committed digests.  The coding standards snapshot is a separate reviewed governance artifact.  Generated release files must retain provenance and pass all-flavor tests and checksum verification.  Untrusted PRs must not receive issuance/release credentials.

## Initial implementation evidence and remaining integration gap

Build-time included providers expose validated S3 get/put argv construction,
a read-only Certbot probe, and a host-local advisory lock.  PATH-injected
fake-executable tests exercise argument preservation, fail-closed invalid
object/endpoint behavior, and local lock contention.  At this stage no
production-run orchestration calls them.  In particular, the S3 adapter
does **not** yet implement missing-versus-failed classification, safe
archive restoration, atomic local downloads, or publication rollback.
The local lock is not a distributed lease.  Future certificate orchestration
must be reviewed for explicit lock lifecycle, private workspace handling,
and fail-closed object classification before cloud credentials are usable.

## Explicit non-goals and residual risk

The first release does not promise atomic multi-object publication, cross-platform locking, cryptographic publisher authentication, safe execution on a compromised producer host, secure erasure of memory/swap, or automatic consumer deployment rollback.  Storage provider outages and LetsEncrypt service/rate-limit changes can prevent renewal.  The consuming server's root filesystem, service credentials, and post-install behavior are its own responsibility.

## Verification strategy and review triggers

Bats should include negative assertions (no upload on invalid input/failed renewal; no plaintext fallback; no secret logs; no unsafe path extraction) plus functional tests for symlinks, combined PEMs, and independent archive composition.  Integration tests should use isolated storage and Let's Encrypt staging with non-production DNS resources.  Revisit this model when adding DNS providers, storage providers, alternate encryption, GPG rotation, distributed locking, signed archives, CI permissions, or new runtime dependencies.

## Route53 issuance adapter safeguards

The isolated Route53 adapter uses a fixed `certonly` DNS-01 argument vector,
requires owned private Certbot directories, and passes each SAN as a separate
quoted argument.  Mock tests exercise malformed/missing SAN rejection,
unexpected directory permissions, and Certbot failure propagation.  The
public executable still has no issuance path.  A successful mock invocation
does not establish portability of imported Certbot renewal metadata, validate
potential hooks in restored state, or demonstrate real ACME issuance.  ADR-025
requires restore-to-new-workspace integration tests before activation.

## Local producer workspace and PEM assembly

Private mktemp directories and independently private Certbot subdirectories
now form the intended producer staging boundary.  The local PEM assembly
module checks literal standard Certbot live-link targets, owner/type/readability
of target files, private-key file modes, and preexisting output symlinks before
assembling regular 0600 combined PEMs.  The module does **not** trust or
extract raw archives and does not validate certificate/key cryptographic
correspondence.  Its owner checks do not defend against an attacker with
the producer user's credentials.  No producer workflow yet calls the module,
so this is tested local functionality rather than an end-to-end security
claim.\n
## Domain archive pre-extraction listing boundary

The internal domain-only tar validator rejects noncanonical lineage
members, cross-lineage or absolute symlink targets, dangerous entry types,
duplicate paths, missing required state, and permissive key-bearing file
modes.  This metadata inspection is non-mutating.  Archive listings can
themselves be resource intensive; metadata inspection does not guarantee
safe extraction or content integrity.  The producer must copy the downloaded
object into a private workspace, enforce decompression budgets, validate
all extraction effects and actual key/certificate contents, and refuse to
publish until restoration and renewal config portability are proven.
The common ACME archive requires a separate policy.\n
## Post-extraction staging boundary

ADR-027 adds privately copied archive bytes, extraction only into a fresh
isolated tree, and a separate filesystem enumeration/type/mode/symlink
verification after GNU tar.  The staging helper does not write into active
Certbot state and rejects malformed inputs.  It still trusts the producer
user identity and installed GNU utilities and cannot guarantee protection
against all decompression denial-of-service conditions, same-user races, or
hostile renewal-file contents.  Successful staging is not permission to
invoke Certbot or publish the archive.

## Shared ACME account archive trust boundary

ADR-028 limits the common archive to Let's Encrypt ACME v2 account metadata
and keys.  Arbitrary hooks/configuration or symlink entries are rejected.
The account archive is privately copied, preflight-validated, extracted
into an isolated workspace, and independently checked for ownership, types,
and private modes.  Account JSON is untrusted data after these checks;
valid structure does not prove a genuine or active ACME account.  A future
producer must verify account selection and server association before use.
Common archive distribution to TLS-only consumers remains prohibited.

## ACME continuity across producer environments

The common account archive is the shared authority for ACME account
continuity between otherwise stateless workers.  Losing this archive when
lineage state exists must not silently generate an unrelated replacement
account.  A fresh host cannot depend on its predecessor's private files.
Cross-platform scheduling remains an operational single-writer requirement,
since local and per-CI locks do not coordinate all runners.  The complete
continuity claim requires fresh-workspace integration, not merely valid
tar archive structure.

## Cryptographic publication verification and test/prod isolation

Structural validation does not prove the private key matches the leaf
certificate, that the certificate chain validates to a trusted CA, or
that the combined PEM outputs retain the validated bytes.  ADR-029
introduces a runtime OpenSSL gate that MUST precede any remote publication.
It uses a private verification workspace and has no cloud side effects.
Staging trust roots must be explicit rather than disabling verification.
Issue #11 also requires physical/logical separation between staging and
production object names: the same lineage must never allow test credentials
or test certificates to replace production TLS material.

## Production/staging ACME and archive separation

A fixed production-default ACME selector now limits authority to two
official Let's Encrypt directory URLs.  The storage adapter refuses
a production object key while in staging mode and refuses staging-prefixed
keys in production mode.  A staging test must not overwrite deployable
production certificate data.  This logical namespace is not an IAM
boundary: an AWS identity with broad S3 authority can still write
unrelated objects, so bucket/prefix-scoped credentials are encouraged.
Tests use fake AWS/Certbot commands; production operation is still
disabled.  Real integration must verify account/renewal-server matching
and must never add staging CA roots to production trust stores.

## Restored ACME identity consistency

ADR-031 adds a read-only inspection boundary before any restored
lineage can be given to Certbot.  Renewal metadata must name the
selected ACME authority, Route53 authenticator, and an available
owner-private account triplet for that same authority.  Unknown
sections, ambiguous identities, symlinked account keys, and hook
directives are rejected.  The helper does not verify JSON registration,
Certbot's eventual account selection, or the safety and portability
of other renewal configuration fields.  It must not be treated as
permission to run unreviewed restored Certbot metadata.

## Previewed renewal path relocation boundary

ADR-032 permits an internal, non-activating copy of a renewal file
with five strictly validated lineage paths rebased to the new
private producer config root.  It does not follow stale paths from
the source host or mutate the original restored metadata.  Unknown
root-level options, mismatched roots, inherited directory overrides,
and conflicts with restored ACME identity cause rejection.  The
remaining renewal options are not yet proven safe for execution,
and Certbot must not consume the preview before real-version
portability and hook-safety integration tests succeed.

## Read-only Certbot import compatibility testing

ADR-033 permits an isolated, credential-free CI harness to install a
relocated renewal preview only into disposable test state for the real
Certbot `certificates` inspection command.  This does not authorize
active issuer installation or renewal.  The test uses synthetic account
metadata and locally generated locally CA-signed test certificates, so no external
registration or chain trust is implied.  Pinning Certbot does not fully
pin transitive Python packages, and dependencies installed in a CI
environment remain part of the build/test supply-chain attack surface.

## Credential-free real Certbot no-op compatibility exercise

ADR-034 permits a CI-only invocation of `certbot renew` against
a locally generated certificate that is not due.  A Python-level
socket guard is installed and self-tested, directory hooks are
disabled, and absence of attempted network access is asserted.
This is not OS-level network isolation, nor does it prove that
external or native subprocesses could never make network requests.
No real ACME credentials, DNS secrets, or S3 authorization are used.
Activation of real renewal or remote publication remains forbidden.
