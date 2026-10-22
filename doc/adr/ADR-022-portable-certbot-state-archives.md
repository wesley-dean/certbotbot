# ADR-022: Portable Certbot State Archives and Isolated Restoration

Date: 2026-10-22

## Status

Accepted

## Decision

The single MVP object contains one ordinary, unencrypted gzip-compressed tar
archive of the **contents** of Certbot's configuration directory, conventionally
`/etc/letsencrypt`. It does not contain an outer `etc/`, `letsencrypt/`,
absolute pathname, runner workspace prefix, or separate account archive. A
pre-seeded archive with only a registered ACME account is an admissible initial
state; an absent archive is never admissible.

The durable state includes `accounts/`, `archive/`, `live/`, and `renewal/`
where present, including Certbot-written auxiliary README files and metadata
needed by that installation. Certbot's independent `--work-dir` and
`--logs-dir` are ephemeral per invocation, isolated from host paths, and
not packed by this MVP. The caller's host `/etc/letsencrypt` must neither
supply fallback state nor be overwritten.

The archive must remain directly extractable under a conventional
`/etc/letsencrypt` installation root, so persisted `renewal/*.conf` uses
canonical `/etc/letsencrypt`-based paths. At execution time, the tool must
use a private `--config-dir`, `--work-dir`, and `--logs-dir`. Since
Certbot renewal metadata may contain absolute paths, **verbatim relocation
is insufficient**. A future adapter must prove a narrowly scoped, reversible
mapping between canonical persistent paths and the private runner paths; it
must verify the mapping before Certbot touches state, and validate the
canonical result before publishing. No unverified rewrite or host-global
symlink workaround is authorized by this decision.

The validator must reject unexpected member types, unsafe member names,
absolute and traversal paths, nested symlink escapes, hardlinks, devices,
FIFOs, sparse files, duplicate or conflicting members, unsafe owners/modes,
compression errors, and unbounded expansion. The legitimate Certbot
`live/<lineage>/<name>.pem` relative symlinks to
`../../archive/<lineage>/<name><N>.pem` are allowed only after checking
their resolved target is within the restored archive tree and points to
an existing regular file in the expected lineage.

This is a **pre-extraction** decision: nothing in the archive is executable
or authoritative until format, structure, linkage, and account checks pass.
An untrusted archive must not activate Certbot hook scripts. The MVP
disables directory hooks and rejects command-bearing renewal hooks or
other execution-injecting archived configuration before calling Certbot.
Live permission to run arbitrary archived hooks is not included in
this milestone.

## Why this decision is required

The source state must survive an execution on a local host followed by
a new isolated runner, and must also remain usable as stored on a
conventional certificate consumer. Certbot keeps versioned certificate
material under `archive/<lineage>/`, symbolic links under
`live/<lineage>/`, and lineage/renewal instructions under
`renewal/<lineage>.conf`. Its renewal configuration commonly contains
absolute `archive_dir`, `cert`, `privkey`, `chain`, and `fullchain`
paths. Merely extracting the same archive under a different absolute
workspace directory does not establish a usable Certbot renewal state.

Certbot's official guidance warns that hand-editing renewal
configuration can break renewals. This means the mapping implementation
requires version-sensitive tests using actual representative Certbot
metadata, and must not be inferred from symlink correctness alone.

The workspace and staging tree contain private keys and ACME account
secrets. Unsafe archive material may also contain names or symlinks
that would escape the isolated root, filesystem special members, or
executable content intended to run under privileged credentials.

## Constraints and assumptions

- One configured bucket and one key, default `latest.tar.gz`, per ADR-020.
- Existing registered ACME account and operator-owned S3/IAM resources.
- One selected certificate lineage per invocation; no orphan deletion or
  global renew-all, regardless of other lineages present in the archive.
- No dependency on host `/etc/letsencrypt` or first runner's absolute path.
- Production runtime uses separately installed Certbot and Route53 plugin,
  not a mock. MVP acceptance uses mock AWS/Certbot and real tar/gzip.
- GNU tar/gzip are candidate tools, but the validation algorithm and
  exact supported archive header dialect require separate test evidence.
- Arbitrary PAX/vendor headers or filesystem member types are not
  automatically safe because tar/gzip can decode them.
- The operator externally serializes writes to the one S3 key.

## Alternatives considered

**Store absolute paths or archive the host /etc path:** rejected. Absolute
tar members allow unsafe extraction and violate the relative-layout
contract, while paths generated under an ephemeral runner would not
be usable on the next runner.

**Write private runtime paths back into the published renewal files:**
rejected. The next runner would inherit stale paths and the archive
would no longer be directly installable on a conventional host.

**Use host `/etc/letsencrypt` during each run:** rejected by ADR-020.
It would leak state between runners and could modify unrelated host
certificates.

**Patch arbitrary lines using sed without schema checks:** rejected.
Certbot renewal configurations are structured and version-dependent;
unconstrained replacement can break lineage identity or alter commands.

**Follow every relative tar symlink:** rejected. Relative symlinks can
still escape the extraction root when chained or used as parent
directories. Only explicitly validated intra-lineage links qualify.

**Drop renewal metadata and infer certificates from PEM files:**
rejected. That loses durable lineage/account linkage and renewal behavior.

**Store split or encrypted archives immediately:** rejected for MVP.
Storage backend extensibility and client-side encryption have their
own future milestones.

## Consequences

The validator and the runtime path adapter are separate security gates.
An account-only archive can be validated without a certificate lineage.
A full archive can be validated without implying that its selected
lineage uses the correct ACME account or DNS provider; those checks occur
before Certbot execution. The public lifecycle must continue to fail
closed until both validation and reversible path mapping are proven.

A format validator cannot claim to sandbox tar or Certbot. Restrictive
workspace permissions, bounded material, controlled link resolution,
explicit command arguments, and a trusted runtime toolchain reduce
risk, but independent penetration and live-service testing remain
future gates. Concurrent writers and partially completed uploads
remain outside this MVP guarantee.

## Acceptance evidence required before restoring and publishing

1. Account-only fixture round-trips through standard gzip/tar without
   altering account identity.
2. Complete fixture retains renewal metadata and relative `live`
   symlinks to versioned `archive` files at a different workspace path.
3. The runtime normalization step resolves canonical paths without
   touching the real host `/etc/letsencrypt` and reverses them for
   publication. Test both first issuance and repeat renewal.
4. Malicious absolute/traversal/linked/special/sparse/truncated archives
   are rejected **before** extraction, with no Certbot or S3 writes.
5. Any account mismatch, unknown execution hook, lineage collision,
   or unsupported Certbot renewal format fails without publication.
6. All three distributed Bash flavors satisfy the same observable tests.

## Relationship to prior decisions

ADR-020 establishes one durable object, deterministic certificate naming
and the private runtime requirement. ADR-021 establishes fail-closed read
semantics. ADR-008 governs document-first, test-second implementation,
ADR-014 preserves standalone deterministic assembly, and ADR-015/016
govern untrusted data and runtime dependency boundaries.

## Sources and compatibility references

- Certbot User Guide:
  https://eff-certbot.readthedocs.io/en/stable/using.html
- Certbot historical portability discussion:
  https://github.com/certbot/certbot/issues/3953
- Certbot documented hook suppression:
  https://manpages.debian.org/trixie/certbot/certbot.1.en.html

The cited documentation supports the known renewal-path and hook risks;
it does **not** establish that an unimplemented normalization adapter
will behave correctly under every Certbot version.
