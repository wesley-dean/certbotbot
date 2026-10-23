# ADR-027: Verified Candidate Archive Before Single-Key Publication

Date: 2026-10-22

## Status

Accepted

## Decision

The MVP packages *only* the complete selected Certbot configuration tree
that has passed the local ACME account/lineage preflight and read-only
verification of its canonical renewal metadata. The archive builder does
not invoke Certbot, AWS, Route53, or a shell hook. It does not decide
whether to publish a no-op or which S3 key should receive the result.

The builder accepts `WORKSPACE CERT_NAME`. The caller supplies a
canonical, owned, mode-0700 private workspace with an already restored,
successful selected lineage under `WORKSPACE/config`. It writes exactly
one private candidate at `WORKSPACE/candidate.tar.gz`. If this destination
exists, including as a dangling symlink, the builder refuses to overwrite
it. A new, private temporary file in the same workspace is used as the
staging target, and failures remove only that owned staging file.

Before archiving, the builder requires a complete selected lineage and
a single recognized existing production ACME account. It validates the
selected renewal configuration against the same bounded
`certbotbot_renewal_map` parser used by ADR-022, extended with a
**read-only `verify` mode** requiring all five canonical
`/etc/letsencrypt` references and the expected Route53/account values.
`verify` performs no file replacement. The builder also rejects
non-private selected certificate-key versions and a non-private
configuration tree.

The builder serializes the *contents* of `config/`, not the `config`
directory itself, using GNU tar with explicit ustar headers, a stable
path ordering, and normalized numeric ownership. It retains source
file permissions, versioned PEM files, selected live symlinks, account
data and renewal configuration. GNU gzip produces one ordinary
`.tar.gz` candidate; there is no proprietary container or split object.
Certbot work/log directories, temporary downloads, host paths and AWS
credentials outside `config/` are excluded.

The exact candidate bytes are then checked by the existing bounded
pre-extraction validator. If tar/gzip serialization, permission checks,
member limits, or archive format checks fail, there is no candidate
at the public workspace path. Only after successful validation does
the builder rename the temporary file to the fixed candidate path.
The builder never uploads the candidate or modifies the known-good
remote archive.

## Context and constraints

ADRs 020 and 022 make the seeded S3 object authoritative, with archive
members directly usable when extracted under a conventional
`/etc/letsencrypt`. ADR-023 requires a specific restored ACME account
and exactly one selected lineage; ADR-025/026 classify renewal/no-op and
SAN changes. The current pre-extraction validator accepts bounded
ustar/GNU short-header inputs and selected Certbot PEM symlinks, and
rejects unknown members rather than guessing compatibility.

The builder therefore *fails closed* on source trees which contain
unsupported files or nonconforming metadata. It must not silently
exclude those files, because other Certbot-written state might be
renewal-critical. A revised compatibility matrix requires its own
tests and architectural review; this PR does not widen the format.

## Alternatives considered

**Archive directly to S3 with `tar | aws`:** rejected. It crosses
the remote mutation boundary before verifying the complete candidate.

**Copy the workspace or root `/etc/letsencrypt` verbatim:** rejected.
Private work/log paths, host state and stale runtime renewal paths
could leak into the published state.

**Use an independent ad-hoc renewal parser:** rejected. The preexisting
reversible parser already defines accepted fields and semantics;
`verify` reuses that bounded logic and writes nothing.

**Run `prepare` and `finalize` to test canonical paths:** rejected.
Validation should not modify the source configuration just to
determine whether its paths are suitable for publication.

**Archive a curated short list of files:** rejected. It could silently
discard future Certbot-written durable metadata. The entire supported
configuration tree is serialized; unknown content is rejected by the
format validator.

**Rely only on source-state preflight:** rejected. File and symlink
shape alone does not demonstrate the emitted tarball is valid or
portable.

**Always publish successful no-ops:** rejected by ADR-020. The
`UPLOAD_NO_RENEWAL` policy is enforced by the later publisher.

## Consequences, tradeoffs and residual risk

- Candidate creation performs only local filesystem operations and
  cannot overwrite the remote object.
- Staging runs under an owned private workspace; emitted tar headers
  normalize owners to numeric root 0, but restoration uses
  `--no-same-owner`. Tar metadata cannot create privileged members
  accepted by the existing validator.
- The validator enforces its existing 32 MiB decoded data and
  2,048-member bounds. Archives outside this subset fail.
- The packaging operation is not a general-purpose filesystem snapshot.
  The caller must externally serialize Certbot/writers and prevent
  simultaneous modification of its workspace.
- Successful archive creation is **not** proof of a valid certificate
  signature, key relationship, trust chain, or current ACME registration.
  Those checks are required by the later public lifecycle task.
- Permission checks prevent publishing an obviously world-readable
  private key, but do not replace a comprehensive host compromise or
  cloud IAM threat model.
- A successful candidate is not proof of S3 publication, atomic
  `PutObject`, or a multi-writer lock. Remote failure and concurrency
  behavior remain separate approved work.

## Verification and migration

Bats tests generate realistic account-only and selected-lineage fixture
state, use actual GNU tar/gzip, check that the candidate revalidates
and restores under a distinct workspace, and compare account bytes,
lineage name, PEM symlink targets, key permissions and renewal text.
Negative tests refuse absent/foreign lineage, malformed and private
runtime renewal references, world-readable private key, unsupported
additional files, unsafe config root, existing destination, and failed
serialization. Tests assert no remote command and no candidate after
failed staging. All three release flavors run the same tests.

The archive layout remains unchanged. The `verify` mode is an additive
internal API; `prepare` and `finalize` retain their existing contracts.
The public CLI continues to exit status 69 until complete candidate
certificate assertions and verified S3 publication are connected.

## Relationships

ADR-020 governs selected identity, one existing object and no-op
publication; ADR-022 governs portable Certbot state and tar constraints;
ADR-023 governs local account preflight; ADR-025 and ADR-026 govern
successful Certbot outcomes and drift. Task #38 authorizes packaging;
#37 shared validator/roundtrip, #39 publication, and #27/#40 public
lifecycle and mock-system acceptance remain separate.
