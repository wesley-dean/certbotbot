# ADR-043: Verified, Exact-Byte Remote Recovery Checkpoints

Date: 2026-10-16

## Status

Accepted

## Decision

Before any later producer implementation is allowed to replace S3
`*-latest.tar.gz` or `*.tar.gz.enc` objects, it must have a
**complete, validated, private recovery checkpoint** for the exact
selected common account and domain key set.  This milestone provides
that read-only prerequisite without enabling remote publication.

The new internal `certbotbot_publication_checkpoint` operation requires
an already successful ADR-042 local publication candidate.  The candidate
records the bucket and selected ACME environment when it is prepared.
A checkpoint may use only that exact bucket, environment, and ordered
key set; passing another bucket or changing the selected mode is a
failure before any remote request.

The operation retrieves the entire selected current S3 object collection
using the typed ADR-039 logic and its explicit
GetObject/NoSuchKey-versus-failure contract.  It validates the downloaded
common ACME state independently even if every selected lineage was
confirmed missing.  Every existing selected domain archive must also
pass the complete non-activating, account-linked renewal and path
assessment in ADRs 037 and 038.  No object is accepted as a recovery
baseline merely because a GET succeeded.

Only after the entire existing collection passes may the operation
copy each **exact as-downloaded object body** into its own private
mode-0700 checkpoint directory.  The body remains unchanged:
plaintext archives retain their original compressed tar bytes,
and encrypted archives retain their exact ciphertext bytes.
The decrypted plaintext copy used for validation is **not** mistaken
for the previous encrypted object.  Every captured object has a
recorded SHA-256 digest; an accompanying ordered key array, presence
flag array, and private file array describe each previous key.
Missing keys are recorded with flag zero and no file body.

The operation distinguishes an entirely absent collection from one
whose common archive exists but some selected domains are new.
An existing domain without its common account is inconsistent.  Any
ambiguous retrieval, corrupt archive, wrong ACME authority, rejected
renewal option, GPG failure, or local staging error rejects the
whole checkpoint and discards private candidate-checkpoint staging.
If existing objects are absent, that absence is represented explicitly;
it is **not** authorization to create a replacement ACME account.

The producer must explicitly discard the successful checkpoint.
The existing full publication candidate remains separately owned and
must also be discarded by its caller.  There are no S3 PutObject,
DeleteObject, CopyObject, or remote rollback commands in the new
checkpoint implementation.

## Why this decision exists

ADR-022 requires prior versions to remain recoverable across
multi-object publishing failures. S3 does not provide an atomic
transaction across a common account and multiple domain objects,
and a different runner cannot rely on the old runner's disk.
Replaying incomplete or corrupt baseline archives as an automatic
rollback could worsen a partial publication failure.

The project already has typed S3 retrieval, encryption-aware
private staging, and isolated archive validators.  The new boundary
composes those established pieces into a durable *within-invocation*
recovery snapshot, preserving the original S3 bytes and logical
absence status for a future coordinator.

Binding the checkpoint to the candidate's original bucket and
environment is mandatory because a valid proposed collection could
otherwise be paired with another bucket's prior state, yielding an
incorrect rollback plan.  The raw/plaintext dual-path addition to
ADR-039 staging exists solely to retain encrypted originals for
recovery while validating decrypted archive contents.

## Assumptions and constraints

- A single trusted Bash process owns the private workspace, the candidate,
  and the checkpoint. Other processes with the same OS identity are outside
  this filesystem threat boundary.
- Every participating independent writer must be externally serialized
  across Jenkins, GitHub Actions, and EC2 as required by ADR-022. There is
  no distributed lock or snapshot transaction.
- A checkpoint is a **local recovery input**, not remotely persistent
  backup media. If a runner crashes after overwriting remote objects,
  its private checkpoint may be lost. A future actual publisher must
  create a remotely recoverable prewrite generation or another durable
  recovery protocol before touching any latest key.
- Readable previous state may legitimately be old or expired; this
  checkpoint validates its structural and account/renewal consistency,
  not current issuance eligibility or leaf trust.
- The selected format cannot change during this operation; a nonempty
  GPG passphrase selects encrypted keys, with no plaintext fallback.
- Success confirms neither ACME account registration with Let's Encrypt,
  certificate issuance, nor recovery from a failed multi-object upload.

## Alternatives considered

**Use a successful GetObject response as sufficient rollback evidence**
was rejected because the previous remote bytes may be malformed or
linked to another account.

**Store only decrypted ciphertext archives** was rejected because
re-encryption can change bytes, metadata, and compatibility, so it
would not reproduce exactly what existed remotely before mutation.

**Treat unknown or denied reads as absence** was rejected by ADR-039
and would risk replacing an inaccessible but valid existing account.

**Download a second time after validating existing state** was
rejected because the object may change between inspection and
snapshotting. The checkpoint copies the exact already downloaded
bytes and uses their corresponding decrypted validation copies.

**Perform immediate PutObject calls with local rollback copies**
was rejected because a crash can destroy the local recovery data,
and the collection's remote writes are not transactional.
A future accepted ADR must define remote generation retention,
publication ordering, retry idempotence, partial failure recovery,
and visibility during publication.

**Introduce a distributed S3 lock in this step** was deferred by
ADR-022; a correct lease and fencing system is a separate design.

## Expected outcomes and tests

The all-artifact Bats suite must exercise an existing common/domain
checkpoint, an entirely empty collection, a valid common account with
a previously absent requested domain, an orphan domain with missing
common state, corrupt previous common archives, malicious renewal
options, denied and indeterminate service errors, wrong-bucket
preflight, and cleanup after failure. Separate encrypted-mode tests
must prove exact original ciphertext recovery after private decrypt
and account validation. Every scenario verifies zero AWS writes.

The rollback metadata must remain private and must not be presented
as an activation token or an autonomous decision to upload.

## Future publication contract

An eventual S3 publisher must first complete all issuance/renewal
operations and ADR-042 candidate validation; then it must obtain a
verified recovery snapshot; then it must persist a **remote,
independently recoverable** copy of prior objects or an equivalent
durable generation reference. Only after those checks and suitable
serialization may it update latest-object keys. It must report
each attempted mutation, preserve common-before-dependent ordering,
verify the final remote collection, and provide a tested recovery
procedure when a partial failure occurs.

This ADR does not grant that future mutation authority, supersede
ADR-037's genuine staging ACME evidence requirement, or relax
the disabled normal certificate entrypoint (status 69).

## Related decisions

ADR-019 governs common/domain state; ADR-021 and ADR-041 govern
format choice and symmetric GPG encryption; ADR-022 requires remote
recovery and external serialization; ADR-028, ADR-031, ADR-037,
and ADR-038 govern account and renewal trust; ADR-039 provides typed
remote reads; ADR-040 provides complete read-only assessment; and
ADR-042 provides a frozen cryptographically verified candidate.
