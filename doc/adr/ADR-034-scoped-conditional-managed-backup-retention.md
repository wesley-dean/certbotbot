# ADR-034: Scoped, Conditional Retention of Managed Dated Backups

Date: 2026-10-24

## Status

Accepted

## Decision

Certbotbot will provide **opt-in, count-based retention** for its own dated
recovery-copy objects, but only after a successful and independently confirmed
current-plus-backup publication under ADR-033. The future public nonsecret
setting is `BACKUP_RETENTION_COUNT`, CLI `--backup-retention-count`, using
the established CLI > exported environment > literal `.env` > default
precedence. Absent or literal `0` means **no listing for retention and no
deletions**; an explicit canonical decimal integer from `1` through
`10000` keeps that many newest eligible dated copies. Negative values,
signs, whitespace, fractions, leading zeroes, empty values, nondecimal
digits, and values over 10000 are invalid (status 64). The bound prevents
uncontrolled arithmetic and resource consumption on a small Bash runtime.

A positive retention count requires the separately enabled
`DATED_BACKUP_ENABLED=true` and the supported S3/gzip-tar backend.
If these prerequisites are not satisfied, refuse the configuration before
remote work rather than silently ignoring a requested deletion policy.
Merely setting `BACKUP_KEY_TEMPLATE` or enabling dated backups does **not**
enable retention.

Only current **visible** S3 objects with a narrowly provable v1 managed
backup identity, belonging to the current S3 bucket/current-key/format/
encryption scope and exactly matching the selected dated name template, can
be considered. Never delete the authoritative current key, any key not
created/recognized under the current template, a historical migration
recovery copy, an object of unknown provenance, or any individual historical
S3 version. Eligibility must be established from a complete, validated
enumeration and exact-key HeadObject checks **before any DeleteObject**.
Every deletion requires a specific captured ETag precondition
(`aws s3api delete-object --if-match ETAG`); no plain or wildcard delete
is permitted. Stop on the first ambiguous or failed operation.

This ADR authorizes **future behavior under approved implementation #85**.
This task #84 is design-only; it adds no public option to today's binary
and issues no ListObjectsV2 or DeleteObject request. Task #86 owns public
destructive-failure verification.

## Why and under which governance

Story #68 requires a configurable maximum number of successful dated recovery
copies without putting the canonical latest archive or unrelated customer
objects at risk. This feature increases cloud authority from exactly
selected-object HEAD/GET/PUT into scoped listing and destructive requests.
It must therefore be its own decision and threat model rather than an
incidental extension of archive publication.

- ADR-020, ADR-021, ADR-027, ADR-028 and ADR-030 preserve a single mandatory
  authoritative current object holding the full original ACME account and
  every certificate lineage. Retention has no authority over that object.
- ADR-031 requires external pre-migration recovery proof and authenticated
  ciphertext, including no plaintext fallback. A dated backup is not a
  substitute for an independent migration recovery copy.
- ADR-032 protects legacy literal `S3_KEY`, makes new templates single
  safe basenames and freezes one UTC date per invocation.
- ADR-033 separately defines opt-in backup publication, metadata v1,
  safe same-day conditional replacement, nonzero partial success and
  manual recovery. **Only its positively verified backup result** permits
  a subsequent retention attempt.
- ADR-015/016 govern the additional trusted AWS CLI, list parsing,
  destructive side effects and explicit failure/authority model.
- Stories #63 (alternate storage) and #65 (alternate archive formats)
  remain open. This decision implements no generic adapter or new format.

The operator supplies an existing bucket and credentials; certbotbot
does not create IAM roles, change a bucket policy, configure bucket lifecycle
rules or manage S3 Versioning. Writers must remain externally serialized
as specified in the existing decisions. No cloud operation is a transaction
across multiple objects.

## Retention namespace and template eligibility

Filename publication is more flexible than destructive retention.
For deletion, the configured `BACKUP_KEY_TEMPLATE` must have **exactly one**
contiguous literal sequence `{YEAR}{MONTH}{DOM}`, surrounded only by
static ASCII filename characters; e.g. the default
`archive-{YEAR}{MONTH}{DOM}.tar.gz` qualifies. The static prefix
before this date marker must:

- contain at least four ASCII bytes, begin with an ASCII letter or digit,
  use only letters, digits, underscores or hyphens, and **end in a hyphen
  or underscore**, thereby providing an unambiguous anchored scope;
- remain constant through this invocation and not overlap the exact
  current key; and
- be passed as the **entire literal Prefix** to ListObjectsV2 in the same
  exact bucket, without any directory traversal, URL encoding,
  wildcard expansion or broadening.

The static suffix after the date marker must end in the exact `.tar.gz`
and contain only safe ASCII letters, digits, underscores, hyphens or dots.
New backup templates using separately punctuated date tokens, reversed
tokens, no literal prefix, repeated tokens or a purely static name may
be valid for **publication** under ADR-032 but are **ineligible for
automatic deletion** under this ADR. If retention is positively
configured with an ineligible template, fail preflight before publication
rather than guess at historical names. No implicit rewrite, migration or
adoption of a previous template is authorized.

For any listed candidate, require byte-exact reconstruction of its key as
`PREFIX + YYYYMMDD + SUFFIX` with precisely eight ASCII date digits and
a valid UTC Gregorian date (including leap-year validation). The parsed
date must not be after this invocation's frozen UTC date. The configured
current key is protected by exact identity before *any* other eligibility
test, even if an operator somehow selected a current key resembling a
dated backup. Provider normalization collisions fail closed.

Objects with an entirely different key shape are **outside the retention
set and are ignored**, even if they share a listing prefix. A listed key
that **does** match the exact selected date-shaped namespace but is
missing, inconsistent, inaccessible, or not unambiguously associated with
the current publisher makes the **whole cleanup ineligible**: abort
before deletion, never infer ownership from the name alone. This protects
manually seeded keys and intentionally abandoned naming schemes.

## Managed identity and candidate proof

For each exactly date-shaped key, perform a separate exact-key HeadObject.
All five ADR-033 v1 custom metadata fields must match:

| Field | Required value |
| --- | --- |
| `certbotbot-backup-schema` | `v1` |
| `certbotbot-utc-date` | Exactly the YYYYMMDD digits recovered from the key |
| `certbotbot-current-key-sha256` | SHA-256 hex of selected authoritative current key bytes |
| `certbotbot-archive-format` | `tar.gz` |
| `certbotbot-encryption` | Exactly the selected payload mode: `none` or `gpg-ocb` |

Require an unambiguous, nonempty ETag, a positive object size, and the
expected S3 bucket and key. The newly published backup must be among
these confirmed candidates and must match the same exact frozen current
publication identity; otherwise the list is not trusted and **no
deletions may begin**. A valid current-key hash is only a namespace
scoping signal: S3 metadata is **not cryptographically authenticated
ownership** and can be forged by anyone with unrestricted write access
to those keys. The operator must enforce least-privilege, separated
writer and delete access in IAM and bucket policy.

For initial S3 support, use ListObjectsV2 with pagination over exactly
this anchored prefix and parse all returned keys, truncation flags,
continuation tokens and responses without shell `eval`, command
substitution of untrusted expressions, loss of key delimiters, or
unsafe path expansion. A successful HTTP response with malformed or
ambiguous body is not a valid enumeration. Require complete and
nonrepeating pagination; if a token is missing, loops, pages are
inconsistent, results are duplicated, the result cannot be parsed, or
any request is denied/uncertain, abort with **zero deletes**. An
implementation safety ceiling of **100000 listed entries or 1000
pages** applies; exceeding it fails closed, never processes a partial
list. Pagination and returned keys are external untrusted data.

Once the complete list has been validated, HEAD every exact-shaped
candidate and freeze a distinct map from key to UTC date and ETag.
A missing, changed, unverified, improperly tagged, future-dated or
inaccessible match aborts the entire retention plan before deletion.
Preflight itself never authorizes changing another key.

## Deterministic ordering and which objects survive

Eligible backups are sorted by **UTC calendar day encoded in their
canonical name**, latest first (eight-digit ASCII `YYYYMMDD` descending).
`LastModified`, ETag, object size, lexical metadata from other keys and
S3 listing order **do not determine retention order**. Under the
one-date-sequence contract, a given UTC date produces exactly one key.
A repeated listed key or two conflicting identities for one date
constitutes an ambiguous enumeration and forbids deletion; there is no
invented timestamp tie-break or partial delete.

Preserve the newest `N` eligible keys. All older eligible keys (if
any) become **provisional deletion candidates**. The positively
verified just-published recovery key must be in the kept set, and the
current key is never in the candidate set. A count `N` greater than
or equal to the number of eligible keys means **zero deletes**.
Do not treat excluded, legacy, unknown, manually seeded or
different-format/encryption objects as consuming any of `N`.
Same-day re-publication updates one current-day key under ADR-033,
rather than adding an additional retention slot.

An operator who changes the backup template, current authoritative key,
archive format or encryption mode starts a **new retention scope**.
Previously written objects are neither counted nor deleted by the new
scope, even if this allows storage to grow beyond the selected limit.
Migrating old data requires a separately reviewed, manual operator
procedure. Never scan the whole bucket to find old identities.

## Destructive execution and failure isolation

Before any remote work, validate count, compatibility, exact bucket/key,
template shape, frozen UTC date, and the capability of the selected
storage adapter. A successful ordinary no-op, a refused candidate,
a failed/uncertain current PutObject, failed/uncertain dated PutObject,
or failed backup HeadObject must **not** start a retention listing.
When count is zero, retention should not even call ListObjectsV2.

After *positively verified* current plus dated publication, and
completion of full listing and HEAD preflight, process provisional
oldest candidates **one at a time** using the exact stored key and its
captured ETag via S3 conditional DeleteObject `--if-match ETAG`.
Never use `DeleteObjects` bulk deletion, unconditional `delete-object`,
`--if-match '*'`, S3 lifecycle configuration, recursive filesystem
deletion, a prefix-only delete, or permanent version-specific deletion.
An ETag is a conditional-match token and does **not** establish SHA-256
integrity, unique object history, cryptographic ownership or an atomic
cross-object transaction. A changed object, unsupported conditional
delete, 403, 404, 409, 412, timeout or lost response must be reported
as failed/uncertain; do not substitute unconditional deletion or retry
automatically with a new ETag.

Stop immediately after the first failed/uncertain delete. No further
targets are attempted and there is **no rollback**: some earlier old
copies may already be gone. Where possible, confirm the object is
unambiguously absent with an exact-key HEAD after accepted deletion;
if absence is uncertain, treat cleanup as incomplete and stop. A
versioned bucket generally receives a delete marker from a plain-key
DeleteObject; this policy never removes existing historical version IDs
or promises physical space reclamation when S3 Versioning is enabled.

Retention failures occur **after** successful current and backup
publication. Return nonzero partial success with fixed, nonsecret
stage-specific diagnostics distinguishing `current accepted`,
`backup confirmed` and `retention failed/uncertain` and, if safely
observable, the number of positively completed deletions. Do not
claim an entirely successful invocation or silently roll back
published certificate state. No secret, S3 raw error text, private
file path, archive contents or untrusted key string may be echoed
in public output. Exact CLI diagnostics and return-code allocation
remain the implementation task's concern.

## S3 permissions and capability limitations

Initial support targets S3 **general-purpose** buckets using AWS CLI
with ListObjectsV2, HeadObject and ETag-conditional DeleteObject.
Required permissions include scoped `s3:ListBucket` on the bucket
with a restricted prefix, `s3:GetObject` for inspected objects, and
`s3:DeleteObject` for selected backup keys, never for the authoritative
current key. Prefer a separate narrowly scoped deletion principal and
bucket-policy enforcement requiring `s3:if-match`. IAM conditions do
**not** independently validate user-supplied v1 object metadata.
Do not rely on name filtering alone to protect against a compromised
credential or incorrectly broad IAM permission.

Unsupported storage backend, directory-bucket behavior, provider
normalization, inability to conditionally delete the same current
key that was HEAD-verified, or absent list/delete permissions
must produce an explicit nonzero error if N > 0. Story #63 must
adopt equivalent scoped enumeration and conditional deletion semantics
before advertising retention for another backend. Story #65 must
establish matching archive-format naming and recovery contracts
before alternate formats can be eligible. New runtime dependencies
or unsafe parsing shortcuts are not authorized by this design.

## Alternatives and why they were rejected

**Delete by age, S3 LastModified or automatic lifecycle expiration:**
does not express the required fixed number of validated current-scope
backup objects; it can also expire unrelated data.

**Delete everything matching a simple prefix or older than the date:**
cannot distinguish unrelated objects, old templates, mixed formats,
old encryption modes or forged-looking objects. Key shape plus full
metadata checks is necessary but not a cryptographic trust proof.

**Enumerate bucket-wide, or scan old templates by pattern inference:**
creates unnecessary read authority and an unsafe migration path.

**Treat malformed/mismatching date-shaped objects as harmless skips:**
allows a compromised or ambiguous portion of the *selected* namespace
to go unexamined while destructive operations proceed. Abort before
all deletes instead.

**Enable retention whenever dated backups are enabled:** violates
the explicit default-off deletion requirement. An independent
count must be selected.

**Run retention on every successful no-op or on a background timer:**
could delete copies without any newly verified recovery point and
introduce a new scheduler/permission boundary.

**Sort by LastModified, object ETag, or arbitrary lexical order:**
these properties do not mean the civil date represented by the chosen
dated-backup scheme. Require one canonical YYYYMMDD key.

**Use unconditional DeleteObject, bulk DeleteObjects or version-ID
deletion:** does not provide the required per-object current-ETag
precondition and may destroy historical versions irreversibly.
Single-key conditional requests allow stopping on uncertainty.

**Continue deleting other backups after a failed delete:** rejected
to minimize additional irreversible effects under uncertain remote
state. A partial outcome is reported and no speculative rollback occurs.

**Require a global manifest or index object:** avoided to preserve
the two-object publication limit and keep retention scope reconstructible
from the current selected template and metadata. If the exact-key
proof proves insufficient, implementation must seek a new ADR before
adding authority or objects.

## Threat model, residual risks and verification plan

Protected assets include the authoritative complete account/lineage
archive, current-day validated backup, older recovery history,
independent pre-migration backup, encryption secret, other operators'
objects, S3 authorization and reliable reporting. The trust boundary
runs from CLI/.env/template input and potentially hostile S3 JSON,
keys, metadata and ETags through a Bash planner into IAM-authorized
DeleteObject calls. Principal threats include overbroad bucket policy,
forged metadata, mistaken template migration, list truncation,
misordered dates, malformed object names, writer races, misclassified
404/403 errors and uncertain destructive transfer results.

Mitigations are independent count opt-in, bounded anchored template,
fully paginated enumeration, byte-exact date reconstruction, v1
ownership checks, complete HEAD preflight, identity-based current-key
exclusion, newest-verified-backup preservation, conditional single-key
deletion, least-privilege IAM, fail-closed errors and no rollback.
Residual risks remain: metadata can be forged by an authorized writer;
ETags may repeat across equal-content overwrites (the ABA problem);
uncoordinated writers can mutate metadata between HEAD and DELETE;
S3 failures may leave deletion outcome uncertain; same-day overwrites
can reduce previous recovery points; versioning may preserve underlying
versions and costs. These are not solved by labeling the result
transactional.

Task #85 must provide a separately reviewable first-party retention
implementation and Doxygen/CLI configuration. Task #86 must prove all
three public artifact flavors and Bash 4.3 where appropriate with
mocked ListObjectsV2 pagination, zero/positive/invalid counts,
duplicate/ambiguous listings, mixed formats and metadata, changed
template/current key, valid leap-year dates, full protected-set
preservation, number/date ordering, precondition conflicts, failed
backup gate, read failures, missing IAM permissions and interrupted
deletes. No live S3 or ACME acceptance is implied by mocked tests.
If required AWS CLI conditional features are unavailable, fail closed
and amend this decision rather than weaken deletion guarantees.

## Related decisions and references

- ADR-015/016: trusted code, destructive authority and threat modeling.
- ADR-020/021/027/028/030: one mandatory full-state authoritative object.
- ADR-031: authenticated encryption and independent migration recovery.
- ADR-032: deterministic, bounded filename templates and UTC date.
- ADR-033: v1 backup ownership metadata and verified opt-in publication.
- Story #68, design task #84, implementation #85, verification #86;
  dependent stories #63/#65/#66/#67.
- AWS S3 conditional deletes:
  https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-deletes.html
- AWS S3 DeleteObject, versioning and conditional behavior:
  https://docs.aws.amazon.com/AmazonS3/latest/userguide/DeletingObjects.html
- AWS S3 ListObjectsV2 and pagination:
  https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html
