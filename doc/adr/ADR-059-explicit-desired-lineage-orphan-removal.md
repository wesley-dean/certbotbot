# ADR-059: Explicit Desired-Lineage Membership and Bounded Orphan Removal

Date: 2026-11-04

## Status

Accepted

By project convention, this decision becomes operative upon review and merge
of technical task #95's pull request. This design-only task does **not**
enable `REMOVE_ORPHANS`, make it a recognized CLI/config key, or authorize
any current archive deletion. The implementation and independent acceptance
remain separate approved tasks #96 and #97.

## Decision

### Separate, deliberately destructive opt-in

Introduce `REMOVE_ORPHANS` to the **ordinary producer**, accepting only
the literal scalar values `true` or `false`, defaulting to `false`.
Expose `--remove-orphans true|false`, exported `REMOVE_ORPHANS`, and
literal-file `REMOVE_ORPHANS`. The existing CLI `--option=value` form,
scalar precedence (**CLI > exported environment > literal file > default**),
restricted literal file parser and `--no-env` rules apply.

When `REMOVE_ORPHANS=false`, perform exactly the existing one-selected-lineage
operation, preserving other lineages under ADR-030; a supplied desired-lineage
collection **does not** grant deletion authority. Do not allow this option on
`register`, the read-only client or extra-argv provider collections.

When `REMOVE_ORPHANS=true`, require (1) a usable ordinary selected DNS
identity, (2) a complete, independently **explicit** desired-lineage identity
set from the dedicated input below, and (3) the selected lineage's exact
stable identity **in that set**. All three conditions must be established
before provider mutation. This feature does not create a new prune-only,
domainless entry point. A missing `DOMAIN`, partial selected input,
ambiguous derived name or empty desired set fails closed. The account-only
archive is not an error when there is a proper explicitly selected first
issuance that passes the normal checks. No deletion is authorized if
selected issuance or verification fails.

**Unlike `RENEW_ALL`, an orphan-removal run never performs operations on
unselected lineages.** One selected certificate may be issued, renewed or
SAN-reconciled as currently authorized; remaining desired lineages are
preserved, not renewed or issued. The previous scope of the ordinary
selected certificate does not expand merely because it is named among
several retained lineages.

### Dedicated canonical desired-set interface

The only authoritative desired set comes from a **distinct, whole-collection**
setting, not `DOMAIN`, `--san`, `ADDITIONAL_SANS`, `CERT_NAME`, a
filename, certificate CN/SAN, an implicit wildcard/apex complement or
enumeration of all archived entries.

- **CLI:** `--desired-cert-name NAME`, repeatable one time per wanted
  independent lineage, alongside `--remove-orphans true`. Both
  `--desired-cert-name NAME` and `--desired-cert-name=NAME` spellings
  are supported. All CLI occurrences jointly form *one* desired-set source.
- **Exported application environment:** `DESIRED_CERT_NAMES`, a
  comma-separated **nonempty** set of canonical names.
- **Restricted literal configuration file:** the same
  `DESIRED_CERT_NAMES` setting, with the same comma-separated syntax.
- **Precedence:** the first present tier wins for the **entire**
  collection: one or more CLI occurrences > explicitly exported
  `DESIRED_CERT_NAMES` > literal file `DESIRED_CERT_NAMES`. A present
  but invalid higher tier is a failure; do not silently fall back to
  another tier or merge lists across tiers.
- **Environment suppression:** `--no-env` discards application
  environment/file values and honors only an explicitly provided CLI
  desired set. This does not disable externally managed AWS credentials.
- **No default collection.** An unset collection remains absent, not
  an implicit selection. Empty strings and empty list members do not
  express permission to remove anything.

Each desired entry must be an *exact*, lowercase ASCII, non-wildcard
stable Certbot lineage name that satisfies the existing
`certbotbot_dns_valid`/explicit `CERT_NAME` restrictions. Comparison
is byte-for-byte case-sensitive on the complete lineage identity, under
`LC_ALL=C`. The parser must reject uppercase aliases rather than
normalizing/destructively matching a different stored name. Reject empty
comma components, whitespace, control characters, wildcard identities,
duplicate entries, excess members (limit 100) or a value outside existing
archive/member bounds. The CLI collection rejects a zero-length or
repeated `--desired-cert-name` entry. Canonical ordering for diagnostics,
set comparison and removal is C lexical ascending; input ordering does
not imply operations or privilege. No untrusted value is evaluated as
shell code or supplied as a path without validation.

**Presence is deliberate authority.** Even if the only explicitly
selected lineage is `example.com`, `REMOVE_ORPHANS=true` must fail
without an explicit `DESIRED_CERT_NAMES` or
`--desired-cert-name example.com`. It must not invent the set
`{example.com}`, thereby silently deleting unrelated certificates.

### Restore, preflight, and membership proof

Resolve all scalar and collection inputs, exact identity, and conflicting
flags *before* any S3 access. Retrieve the same existing authenticated,
size/member-bounded, authoritative S3 archive into the owned mode-0700
workspace. Do not create a bucket, object, account or host-global Certbot
directory. Safely extract and validate the complete shared state and
matching selected CA/account **before** issuance/renewal/removal, as
required by ADR-030 and ADR-058.

Build one immutable sorted inventory of complete
`renewal/N.conf`, `live/N/`, and `archive/N/` triplets. Verify
canonical renewal mapping, safe intra-lineage live symlinks, bounded
member types, actual certificate identity and account constraints for
**every original lineage**. A malformed, partial, dangling, mixed-name,
hook-bearing, or otherwise invalid lineage is **not** an orphan to be
silently repaired by deletion: refuse the run. Do not infer membership
from overlapping SANs or permit path-traversal, symlink following,
lineage renaming or case-folded matching.

For each name in the explicit desired set, require proof that it already
exists as a complete member of the original inventory **unless** that
identity is the one properly selected, absent name for an explicit first
issuance in this invocation. Nonselected desired identities that are
absent or unresolved must fail **before** provider mutation, rather than
pretending they were processed or silently skipping them. The resolved
ordinary selected name must be in the desired set, including when it is
derived deterministically from SANs; a mismatched selected/desired set is
a configuration error. With a valid selected name and otherwise
account-only archive, successful explicit issuance of that name is
allowed; an empty archive does not authorize any orphan deletion.

For each original identity `N`, classification is exactly:

- `N` is in the explicit desired set: **retained**. If `N` is the
  selected identity, it may receive its ordinary authorized provider
  action, otherwise it must be preserved byte-for-byte at the restored
  filesystem level.
- `N` is absent from the explicit desired set: **confirmed orphan**.
  It must remain untouched until the selected operation, complete
  eligibility checks, and all selected post-verification succeed.
- `N` is incomplete, unsupported, unsafe, or ambiguously represented:
  **invalid state**; fail, never classify it as a removable orphan.
- An identity in the desired set not present in the original archive and
  not the explicitly selected first issuance: **unresolved**, fail.

A desired set equal to all archived lineages is a legitimate no-prune
operation. A subset may remove precisely the excluded members. The
post-reconciliation set must remain **nonempty** and equal the desired
set; the selected identity cannot be removed. The operator has
affirmatively authorized each exclusion by providing the entire desired
set and setting `REMOVE_ORPHANS=true`, not by guessing identities.

### Exactly bounded local deletion and validation

After a successful selected issue, renewal/no-op or SAN reconciliation,
verify the previously snapshotted nonselected state has not changed.
Then remove only these three namespaced paths for **each confirmed
orphan**, using the validated immutable name and literal owned root:

1. `WORKSPACE/config/renewal/N.conf` (ordinary renewal metadata);
2. `WORKSPACE/config/live/N/` (the orphan's intra-lineage PEM symlinks);
3. `WORKSPACE/config/archive/N/` (the orphan's versioned leaf, chain,
   fullchain and private-key material, including permitted history).

The removal implementation must use the already validated private root
and refuse symlinks or unexpected files/directories at the deletion
boundary. It must never follow links into another lineage or out of the
workspace. Use literal validated paths, `--` operand delimiters, no
filename globs or `eval` derived from untrusted data. No host-global
`certbot delete` or unqualified shell `rm -rf /etc/letsencrypt` is
allowed. No external ACME/Route53 operation is necessary for pruning
itself.

The deletion operation must not touch
`accounts/`, `WORKSPACE/config` itself, shared CA metadata, unrelated
state, surviving lineage paths, temporary host files, S3 backup objects,
remote archive generations, or the bucket/key configuration. Account
metadata may change *only* through the independently authorized selected
provider operation. After pruning, verify exact post-state membership,
surviving original-lineage file bytes/modes/symlinks, account identity,
complete canonical metadata, and the selected certificate/key/SAN/chain.
Build and validate one complete canonical archive candidate using
existing archive checks before any publication. If any stage fails,
return nonzero, discard the invocation-owned local workspace, and
**never intentionally upload** partially pruned state.

A successful positive orphan count is always a *durable change*, even
when Certbot reported a due-renewal no-op. The current
`UPLOAD_NO_RENEWAL` default/override still governs successful,
fully validated **zero-removal and zero-certificate-change** runs.
Publish only through the same authorized single S3 key, preserving
the existing GnuPG authentication, dated backup, retention, and
recovery gates. Existing backup or retention operations remain
separate independently configured authorities and must not be
silently enabled by `REMOVE_ORPHANS`. Operator serialization is
still required; S3 PutObject can have an uncertain remote outcome.

### Mutually exclusive bulk modes

After applying configuration precedence, **reject
`REMOVE_ORPHANS=true` with `RENEW_ALL=true` before S3 access or
provider execution**, regardless of whether the selected certificate
appears in the desired set. This maintains ADR-058's approved policy
and avoids ambiguous ordering, inadvertent renewal of a lineage that
is about to be removed, or falsely treating an exclusion as consent
for both operations. Future composition requires a separate accepted
decision and review of provider and deletion authority.

### Status and evidence

On a complete successful run, report the ordinary selected outcome
and a **bounded, nonsecret numeric summary** of desired, retained,
removed, changed, and current-key publication status; do not print
private account IDs, certificate/key bytes, raw archive paths,
provider output, environment secrets or removed DNS identity names.
Any local failure returns nonzero without a successful completion
summary. A failure after an S3 PutObject request may leave the remote
outcome uncertain; no automatic rollback, atomic S3 multi-write, or
guaranteed permanent erasure is implied.

## Context and Drivers

Approved story #88 and design task #95 require pruning independent
Certbot certificate lineages in one shared portable archive. ADR-030
allows valid complete lineages with overlapping SANs, but explicitly
preserves unselected lineages during ordinary runs. ADR-058 adds an
opt-in named renewal check for all original archived lineages, while
reserving destructive membership for a separate feature. The existing
program uses one runtime `CERT_NAME` with a single SAN collection:
without a new public desired-set input, the administrator has no
means to express which **other** lineage identities should survive.
Using the selected name alone would therefore be an unsafe
interpretation of story #88.

## Assumptions and Constraints

- The existing ACME account, CA and authoritative S3 archive preexist,
  with one optional explicitly selected first issuance under existing
  account rules.
- All original lineages can be validated in a single bounded restored
  private filesystem before any destructive operation. No trusted
  manifest or second authoritative archive is introduced.
- Orphan pruning is an archive-content reconciliation, **not**
  revocation of certificates with the CA, deletion of consumer
  deployments, cleanup of backups or destruction of prior S3 versions.
- AWS IAM, DNS provider and ACME credentials and local binaries are
  external operator-managed trust boundaries.
- The producer remains Bash 4.3 compatible. All development, ordinary,
  and minified executable variants must share the exact public contract.
- `REMOVE_ORPHANS=false` is the safe default in every config tier,
  and existing read-only/client and `register` commands are unchanged.
- The new desired-set setting is a **deliberate public interface**.
  PR #95's review and merge constitute acceptance of this contract;
  implementation under #96 must not silently change its grammar or
  expand destructive scope.

## Alternatives Considered and Rejected

**Treat the one selected `CERT_NAME` as the whole desired set:**
rejected. A normal one-certificate renewal would implicitly authorize
deleting every other independently managed lineage.

**Treat SANs or wildcard/apex complements as independent lineage IDs:**
rejected. SANs can overlap across identities; selected SAN expansion
does not express a desired list of stored certificates.

**Infer desired membership from every stored lineage, or from file
system order:** rejected. An implicit retain-all set would make pruning
a no-op; an inferred subset would not represent operator authorization.

**Use a single unstructured whitespace-separated environment list:**
rejected. Splitting is shell-sensitive and can silently change
membership. Exact comma fields or repeated CLI arguments are safer.

**Merge partial desired sets from CLI, exported environment and
literal file:** rejected. A surprising lower-precedence extra name
can prevent intended cleanup, or a stale CLI subset could delete
unintended members. Resolve the full collection from exactly one tier.

**Prune-only / domainless mode in this first release:** rejected as a
new destructive operation without a selected-certificate verification
anchor. A future explicit command would need a separate contract and
authorization.

**Silently discard missing desired identities:** rejected. A
spelling mistake would produce an archive inconsistent with the
operator's desired state and could delete correct but differently named
lineages.

**Delete invalid lineages to make the archive pass preflight:**
rejected. Treat malformed untrusted state as a security failure, not
as a conveniently removable orphan.

**Call host-global `certbot delete`, delete entire archive/S3 key, or
revoke certificates automatically:** rejected. The operator has only
authorized scoped replacement of the existing shared archive.

**Remove each orphan directly from the S3 object or publish in a
loop:** rejected. There is one authoritative full archive and only one
validated final candidate can safely replace it.

**Run orphan pruning after `RENEW_ALL` in the same invocation:**
rejected pending separate governance. No existing approval grants
combined renewal and deletion.

**Always enable dated backups and retention for orphan removal:**
rejected. These independent opt-ins have separate IAM and failure
semantics. Operators should make a recoverable backup **before**
the destructive invocation and use existing backup/versioning tools.

## Threat Model and Residual Risks

The protected assets are account private keys, active and historical
certificate private keys, exact lineage identity, complete archive
integrity, S3 remote authority, and retained recovery generations.
Threat actors or failure sources include malformed untrusted S3
archives, stale automation variables, typographical errors,
partially injected configuration, compromised runner/provider binaries,
unexpected directory links, interrupted local deletion, failed S3
writes, concurrent writers, and misplaced confidence that pruning
erases previously published credentials.

The trust boundaries are: supplied CLI/env/file inputs (explicit
authority); untrusted archive bytes entering safe extraction; validated
owned workspace paths entering deletion operations; restored account
entering a narrowly scoped Certbot call; complete verified candidate
entering S3 publication. Mitigations include exact desired-set
presence and whole-source precedence, strict DNS identity validation,
nonempty and selected-member guards, complete archive preflight,
checked nonselected mutations before deleting, literal path
construction under the owned root, symlink refusal, exact post-inventory,
surviving-material checks, and the existing one-key publisher.

Residual risks remain: remote object replacement after uncertain
PutObject, concurrent last-writer-wins, optional dated
backup/retention side-effect failure after current-key publication,
persisted secret copies in S3 version history or backups, prior
consumer copies, external ACME issuance before a later local failure,
and compromised trusted binaries. Local deletion cannot revoke
already issued certificates or guarantee that private keys have been
cryptographically erased from historical storage. Document recovery
and external serialization rather than promising unavailable atomicity.

## Compatibility, Verification and Follow-Up

No storage-layout migration is needed. A default-false invocation
continues to use the current ADR-030 selected-only implementation,
even when a shared archive contains several complete lineages.
An explicitly opted-in run operates only on complete existing
portable state, keeps the same CA/account and S3 object, and
publishes a new complete archive after all successful checks.

Task #96 must implement the strict parser and whole-collection
precedence, prove the desired set including selected name before any
provider step, perform the selected ordinary action, prune only the
confirmed orphans in the restored owned workspace, revalidate all
survivors and exact membership, and publish at most one complete
current object. All public help/config docs and function Doxygen
must be synchronized with actual shipping behavior.

Task #97 must provide public-executable, three-flavor Bats and
fresh-runner tests, including: default preserve; retain/remove with
overlapping SANs; ordering independence; exact case and duplicate
rejection; missing, malformed or partially absent desired sets;
missing selected identity; absent nonselected desired identities;
account-only selected issuance; invalid or corrupt archived state;
symlink/path attacks; failed selected issuance; non-target mutation;
interrupted/deletion/candidate failure; encrypted archives; S3
uncertainty and `UPLOAD_NO_RENEWAL`; negative combined bulk flags;
unchanged surviving private-key material; preserved account identity;
and no secret values in logs. Mocked AWS/Certbot and local
Pebble/SeaweedFS tests are **not** live DNS/IAM/ACME acceptance.

## Relationships

This ADR narrowly extends ADR-030's preservation policy solely
for an explicit `REMOVE_ORPHANS=true` call with a verified complete
desired set. ADR-020 and ADR-029 still resolve **one selected**
certificate and its SANs. ADR-021–023 and ADR-027–028 continue to
govern safe restoration, complete candidate checks and single-key
publication. ADR-031, ADR-033–034, ADR-041–043 and ADR-058 continue
to govern encryption, backups, retention, account, CA and bulk-renew
exclusion. ADR-019 remains the authoritative approval gate.
