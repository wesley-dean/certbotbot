# certbotbot Product Specification

Status: Design contract for full implementation.  This document describes intended behavior; template code in the repository does not yet implement it.

## Purpose and scope

certbotbot is a standalone Bash certificate producer.  It uses ACME DNS-01 authentication to obtain/renew certificates with Certbot, preserves issuance state in object storage, and generates domain archives directly usable by TLS-serving consumers.  It does not manage deployment servers, use HTTP-01/TLS-ALPN-01, or automatically delete/revoke unspecified certificates.

Initial production-capable adapters are `route53` for DNS validation and `s3` for archive persistence.  Later backends may be developed, reviewed, and compiled into future releases.  No third-party runtime plugin loading is supported.

## Runtime modes and accepted certificate input

- `certbotbot.bash foo.com www.foo.com` processes one certificate.
- `certbotbot.bash "foo.com www.foo.com"` has identical semantics.
- A multi-line `CERTIFICATES` environment variable or `--certificates-file FILE` input processes one certificate per nonempty line.  CI examples use the environment form.
- The entrypoint MUST reject simultaneous conflicting input modes; it MUST NOT evaluate user-provided text as shell syntax.
- `--validate` MUST perform syntax/provider validation and print one normalized tab-separated record per group: `NAME<TAB>SAN1 SAN2 ...`.  The status is 0 on valid input without any issuance/storage side effects.  It does not imply cloud credentials, ACME connectivity, or certificate validity were checked.
- Before real issuance is implemented, normal certificate requests MUST fail with status 69 and MUST NOT access external systems.
- Built-in provider selection uses `--dns-backend NAME` and `--storage-backend NAME` or the corresponding `DNS_BACKEND` and `STORAGE_BACKEND` environment variables.  Unknown providers MUST fail closed.
- Hostnames are ASCII DNS labels (IDNs must be punycode), normalized to lowercase, with at least two labels and an optional single leading wildcard.  No trailing dots or shell metacharacters are accepted.
- A batch MUST reject duplicate lineage identities before changing remote state.
- Empty or whitespace-only input is a validation failure, not an implicit request to renew everything.
- The first token is the identity for `--cert-name` and archive naming, after removing one leading `*.`.  The first domain `foo.com` or `*.foo.com` always requests both `foo.com` and `*.foo.com`.
- Subsequent SANs are preserved after validation and deduplication; no implicit `*.` is added to them.
- The set of SANs is authoritative.  Adding/removing additional SANs is an intentional lineage update.
- Hostname validation must reject path characters, command-option injection, invalid wildcard placement, and unsafe archive names.  Parsing must not invoke shell globbing.

Example:

```text
CERTIFICATES=
foo.com www.foo.com *.foo.com
bar.com mail.bar.com
```

Two independently managed lineages result: `foo.com` with apex, wildcard, and `www.foo.com`; `bar.com` with apex, wildcard, and `mail.bar.com`.

## Environment configuration

| Variable | Meaning | Required / default |
| --- | --- | --- |
| `CERTIFICATES` | Newline-separated certificate groups | Required when no positional arguments |
| `BUCKET` | Object storage bucket | Required for S3 |
| `EMAIL` | ACME registration contact | Required when registering |
| `REGISTER_ACCOUNT` | Permit account registration if needed | Default `true` |
| `AGREE_TOS` | Permit acceptance of the current ACME terms | Default `true` |
| `AWS_REGION` | Region for AWS API calls | AWS SDK/CLI rules |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | AWS credential environment variables | Normal AWS credential chain; may be absent with roles/OIDC |
| `S3_ENDPOINT_URL` | Custom endpoint for S3-compatible storage (such as MinIO) | Optional |
| `GPG_PASSPHRASE` | Nonempty selects symmetric AES-256 encrypted archives | Optional, unset selects plaintext |
| `DNS_BACKEND` / `STORAGE_BACKEND` | Select compiled-in `route53` / `s3` adapters | Defaults to `route53` / `s3`; CLI options override |

Historical archive patterns (`LATEST_FILENAME_PATTERN`, `ARCHIVE_FILENAME_PATTERN`, and mktext substitutions) are part of the implementation backlog.  Current normative latest-object names are fixed below until a separate naming decision specifies compatibility and collision safeguards.

## Logical archive layout and names

Default object names:

```text
common-latest.tar.gz
foo.com-latest.tar.gz
bar.com-latest.tar.gz
```

When `GPG_PASSPHRASE` is nonempty, append `.enc` uniformly, e.g. `foo.com-latest.tar.gz.enc`.

The common archive contains shared ACME account state and only the shared configuration necessary for producer restore.  It SHALL NOT be required by consumer web servers.

Each certificate archive is rooted at the contents of the logical `/etc/letsencrypt` directory and includes its own lineage:

```text
archive/foo.com/                  # Certbot versioned certificates and keys
live/foo.com/                     # Certbot symlinks and combined.pem
renewal/foo.com.conf              # Certbot renewal configuration
combined/foo.com.pem              # fullchain.pem followed by privkey.pem
```

The live symlinks MUST resolve after extracting that one archive into an otherwise empty `/etc/letsencrypt`.  Distinct lineage archives MUST have disjoint meaningful member paths.  The combined PEM is generated in both `live/<name>/combined.pem` and `combined/<name>.pem`; the latter is not a substitute for retaining the normal `fullchain.pem`/`privkey.pem` paths.

Tar member validation MUST exclude absolute/traversal paths, unexpected links, special files, unrelated certificate lineages, and foreign owner/mode metadata that would subvert the extraction target.  Archive validation MUST precede extraction.

## Internal adapter staging and local serialization

The first internal execution layer provides a nonblocking host-local advisory
lock.  The lock key derives from the storage bucket and configured endpoint;
the directory must be owned by the local principal and be inaccessible to
group/other users.  A simultaneous local request fails with status 75.
This does not provide distributed fencing or protect against unrelated users
and hosts.  The production orchestration must acquire it before reading
remote state and release it on normal exit and signal handling where possible.

The built-in S3 adapter exposes narrow `get` and `put` operations using the
installed AWS CLI with separate argv elements and optional `S3_ENDPOINT_URL`.
The initial supported key grammar is only latest `.tar.gz` / `.tar.gz.enc`
objects.  Calls propagate their original errors and do not yet distinguish
a confirmed missing object from an inaccessible or failed object.  The
Route53 adapter offers a read-only Certbot version probe and fixed DNS-01
option elements.  None of these operations is wired into public issuance
until the subsequent processing phases are implemented.

## Certbot/Route53 issuance command contract

The first built-in Route53 implementation prepares a `certbot certonly`
operation using `--non-interactive`, `--dns-route53`,
`--preferred-challenges dns`, explicit `--cert-name`, private separate
`--config-dir`, `--work-dir`, and `--logs-dir` options,
`--keep-until-expiring`, and `--renew-with-new-domains`.  Every normalized
SAN uses a separate `-d` argv pair.  This permits SAN replacement without
unconditional forced renewal for unchanged lineages.  The initial internal
command adapter requires an explicit account email and acknowledged terms.

This command adapter is callable by isolated tests but is **not** connected to
the normal issuer yet.  When `REGISTER_ACCOUNT=false`, it fails closed until
the producer can verify/select an existing restored ACME account.  The final
producer MUST verify that absolute paths in Certbot's renewal metadata survive
restoration into a different private workspace before publishing archives.
See ADR-025.

## Private workspace and combined PEM assembly

An internal workspace helper creates a fresh, owned, mode-0700 root and private
`config/`, `work/`, and `logs/` directories under a trusted absolute
temporary parent.  It records exactly one active local workspace, refuses
unsafe cleanup targets, and provides explicit cleanup; the future producer
orchestrator remains responsible for traps and lock lifecycle.

A local PEM assembly helper requires a normalized lineage identity, owned
non-symlinked Certbot root/lineage directories, and all four normal Certbot
`live/<name>/` symlinks.  Each symlink's **literal relative target** must be
`../../archive/<name>/<kind><positive serial>.pem`, where kind is `cert`,
`chain`, `fullchain`, or `privkey`.  Each referenced versioned file must be
an owned, readable, nonempty regular file; private keys must exclude all
group/other access.  Preexisting output symlinks and unsafe directory
permissions cause rejection before any output.  The helper generates the
specified combined PEMs with 0600 mode using temporary local files and
per-file atomic renames.

This is structural validation of an already-produced trusted local lineage.
It does not imply safety of extracting an untrusted tar archive, check PEM
cryptographic correctness/key matching, or establish portability of
`renewal/<name>.conf`.  Those checks must precede any production publication.

## Per-certificate archive manifest validation

Before a downloaded archive can be extracted, an internal preflight checks
the GNU tar listing against a narrow allowlist for one canonical lineage.
Only expected relative directories, versioned Certbot PEM regular files,
four standard relative live symlinks, the single renewal configuration,
and the two combined PEM regular files may appear.  Every live symlink
must point to an archived versioned regular file in the same lineage.
Duplicate names, hard links, special files, traversal, unrelated lineages,
permissive key-bearing file modes, missing required members, excessive
member counts, and oversized declared member data cause failure.

This validator reads metadata only.  A later implementation must safely
stage and extract into an isolated filesystem, independently verify the
result and Certbot renewal metadata, and perform cryptographic matching
before any remote publication.  A separate allowlist is required for
the common ACME account archive.  See ADR-026.

## Isolated archive restoration boundary

The internal domain restore helper requires an existing mode-0700 producer
workspace.  It takes a private copy of an owned archive before inspection,
performs the ADR-026 manifest validation, and extracts with GNU tar into a
fresh empty owner-private staging directory using a restrictive umask and
without adopting archived owner or permissive mode metadata.  It then
enumerates every actual extracted filesystem entry without following
symlinks, rejects unexpected paths/types or ownership, checks the four
expected Certbot live symlinks, and verifies presence/permissions of the
required lineage components.  Failures must not modify the active Certbot
config directory.  The caller must discard successful staging explicitly.

Validation of the **common** ACME account archive, renewed Certbot config
portability, cryptographic key matching, staging-to-active integration, and
all S3 publication remain separate release gates.  This helper is internal
and does not change the public fail-closed issuance behavior.

## Shared account-state staging boundary

The initial common archive accepts only approved production and staging
Let's Encrypt ACME v2 account directories.  Each account contains
`meta.json`, `regr.json`, and `private_key.json`; account contents
must not permit group/other access.  Hooks, unrelated files, linked paths,
and lineage data are forbidden.  A common archive is copied into a private
workspace, checked against a bounded GNU tar manifest, extracted into a
fresh isolated directory, and independently inspected afterward.

This is a structural and filesystem validation stage only.  JSON
semantics, account validity/selection, ACME server association, portable
Certbot renewal metadata, and controlled merging into active state remain
future requirements.  A failed restoration must never initialize a new
ACME account as if archived state had never existed.  Consumers continue
to download only their own domain archives.  See ADR-028.

## Stateless cross-run producer contract

Shared object storage is the sole durable certificate-management state.
A brand-new runner MUST reconstruct the same ACME account identity from the
common archive and each selected certificate's lineage from its domain
archive.  A previous runner's home directory, cached `/etc/letsencrypt`,
temporary workspace, process identity, or local secret MUST NOT be required.
Each runner supplies its own supported tools, AWS/Route53 authorization,
configuration, and optional decryption secret.

Acceptance requires sequential runs in **separate freshly created
workspaces**: initial account registration and issuance on runner A;
restore/account reuse and no-op renewal on runner B; a due renewal or SAN
change on runner C.  Destroy the entire workspace between runs.  Confirm
the same ACME account identity, restorable Certbot renewal configuration,
and valid deployable outputs.  Existing lineage state with missing or
corrupt common account state MUST fail without re-registering or publishing.

The initial local and CI locks do not coordinate across Jenkins, GitHub
Actions, and EC2.  Until a real storage-backed lease/fencing mechanism is
implemented, independent writers against one archive namespace MUST be
serialized externally.  Cross-run portability does not imply safe
simultaneous execution.

## Pre-publication cryptographic verification

Every selected lineage MUST pass an explicit OpenSSL verification step
after PEM assembly and before any S3 object is overwritten.  This
verifies leaf X.509 validity at the current time, private-key integrity,
public-key correspondence (algorithm independent), chain verification for
TLS server use against trusted roots, first fullchain certificate matching
the leaf, and exact restrictive combined PEM contents.  Any failure MUST
prevent publication.  The producer MUST additionally reconcile the
actual certificate SANs with the requested names before publishing.
Verification is not a claim of compatibility with individual services.

A custom trusted CA bundle is allowed for controlled staging roots.
OpenSSL's configured trust store is used otherwise.  The final runtime
image/native prerequisites MUST include OpenSSL.  This gate implements
issue #12 and ADR-029; the initial internal function alone does not
activate certificate issuance.

Issue #11 separately requires an opt-in Let's Encrypt staging mode,
defaulting to production.  The future mode switch MUST isolate account
selection and **staging vs production archive keys/namespaces**, so
testing can never overwrite a production certificate archive by sharing
the same lineage identifier.  It must also determine the correct
verification trust roots.  No unreviewed arbitrary-ACME-endpoint option
is part of that backlog issue.


## Fixed ACME environment selection and object namespaces

A single invocation selects `production` (default) or `staging` using
`--staging`, `--acme-environment production|staging`, or
`ACME_ENVIRONMENT`; CLI options override the environment variable.
Conflicting mode flags are invalid.  Production uses the official
`https://acme-v02.api.letsencrypt.org/directory` endpoint and staging
uses `https://acme-staging-v02.api.letsencrypt.org/directory`.
No arbitrary ACME server URL is supported.  The built-in Route53 adapter
must pass the selected server as an explicit, quoted Certbot argument.

Production archive keys remain `common-latest.tar.gz` and
`<name>-latest.tar.gz` (with `.enc` equivalents).  Staging prefixes
all such keys with `staging/`.  The S3 adapter MUST refuse unprefixed
keys in staging mode and prefixed keys in production mode.  The common
account object and every requested domain object must come from the same
selected environment.  A production consumer must never receive a
staging certificate.  See ADR-030.

This is currently an internal command/key selection contract, not a live
issuer.  Before release, separate restored account/renewal server checks,
staging trust-root verification, and fresh-workspace interoperability
must be proven in both environments.


## Restored account/lineage ACME identity gate

Before presenting restored state to Certbot, the producer MUST confirm
that `renewal/<name>.conf` contains unique
`[renewalparams]` values for `server`, `account`, and
`authenticator`, corresponding to the selected Let's Encrypt authority,
one available private account file triplet, and `dns-route53`.
A mismatched staging/production server, absent account, or duplicate
critical fields MUST fail closed without any Certbot or S3 side effects.
External renewal files are parsed as data only and never sourced or
executed.  Hook directives are not accepted during this identity preflight.

This read-only guard does not guarantee valid account JSON,
registration state, Certbot account selection, safe renewal options,
or portable absolute paths in renewal metadata.  Those further
semantic and integration checks remain prerequisites to enabling
issuance.  See ADR-031.


## Producer processing algorithm

1. Validate required configuration, selected providers, credentials availability where testable, and every certificate group's normalized identity/SAN list.
2. Establish private temporary state and local execution serialization.
3. Download the common archive if present.  A confirmed absent object initializes first-run state; access denied, network errors, and mode mismatches fail.
4. Restore common state locally (decrypt first if selected).
5. For every requested group sequentially: download and restore its existing lineage archive if present; issue or renew only the named lineage via DNS-01 and Certbot's own renewal decision; regenerate its two combined PEM outputs; validate and prepare that domain archive; discard unrelated per-lineage working state.
6. Prepare and validate the updated common archive.
7. Only after all requested groups succeed, upload valid output archives with stable names.  Account state must precede any newly dependent domain state.  Publication is not atomic across multiple objects; a failed upload must be surfaced and recovery documented.
8. Remove temporary material where feasible, report outcome via bashlog and appropriate exit status, and never silently reuse stale or incomplete output after a failure.

Archive generation and decryption occur locally.  Neither pipeline nor Docker bind-mounts a consuming web server's `/etc/letsencrypt`.

## Renewal

The tool MUST NOT hard-code a day threshold, certificate expiration date, or fixed validity assumption.  Certbot remains responsible for renewal eligibility.  Changes to the requested SAN set must use deliberate Certbot-supported reissuance behavior and be tested with Let's Encrypt staging; issuance must respect rate limits.  Existing lineages absent from the request are ignored.

## Consumer installation contract

A deployment-only server downloads the appropriate `*-latest.tar.gz` archives (or decrypts `*.tar.gz.enc` archives), validates them, and extracts them into its own `/etc/letsencrypt`.  No Certbot, ACME account, or certbotbot executable is needed.  It does not need `common-latest.tar.gz`.  The consuming server controls its own reloads/restarts, post-install scripts, and rollback.  Common and domain archives need not be mutually downloaded by consumers.

## Failure, consistency, and security

- Non-success Certbot exit or failed artifact validation blocks publication.
- Wrong-format archives do not trigger automatic encryption downgrade, conversion, or new-account initialization.
- Secrets must not be logged, added to process arguments, committed to Git, or published to CI artifacts.
- External storage writers must not run concurrently against one archive collection.  Native/local and CI-level protections are necessary but insufficient cross-platform.
- Multi-object upload atomicity, strong storage locking, archive signing, GPG passphrase rotation, and secure deletion of storage snapshots are not promised in v1.
- AWS credentials must follow minimal permissions for Route53 TXT record changes and selected S3 object operations.

## Build and documentation contracts

`make deps` is network-capable convergence after directly bootstrapping checksum-verified bashdeps.  `make build`, `make docs`, and `make deps-check` do not silently acquire dependencies.  The three artifact flavors and three `.sha256` companions must be byte-verifiable and behaviorally equivalent.  Runtime provider modules are assembled into each shipped artifact, not dynamically loaded from directories.

## Acceptance test inventory

Tests MUST cover SAN parsing (including wildcard-only input), duplicate identities, host-validation rejection, exact lineage scope, missing/denied object distinction, cipher-mode mismatch, combined PEM ordering, archive member disjointness and symlink resolution, failed renewal blocking writes, upload partial failure reporting, serial execution, S3 endpoint propagation, no shell evaluation, Bash 4.3 compatibility, runtime-bundled provider dispatch, offline build boundaries, and cross-flavor behavior.  Live staging issuance and representative consumer extraction should be exercised separately with appropriately scoped credentials.
