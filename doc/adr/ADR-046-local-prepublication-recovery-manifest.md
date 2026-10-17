# ADR-046: Local Manifest of Proposed and Previous Publication Bytes

Date: 2026-10-16

## Status

Accepted

## Decision

Prepare a **read-only, local, checksummed publication/recovery manifest** by
pairing an existing complete ADR-042 cryptographic publication candidate
with a complete, validated ADR-043 previous-state checkpoint. The manifest
documents the exact S3 latest-object keys, new object hashes and sizes,
previous-object presence, and exact previous-object hashes and sizes.
Neither the preparation nor validation functions may issue any cloud
write, invoke Certbot, touch DNS, or mutate the active Certbot configuration.

The helper `certbotbot_publication_plan_prepare` requires that both
previously reviewed components are present in the same private invocation.
Their key arrays must have the same length, ordering, and exact
environment-scoped names, beginning with the common account object.
Bucket and ACME environment must remain those recorded when the
new candidate was prepared. The configured encryption mode must
still match the proposed object-key suffix. A previous object may
be recorded as absent **only** when the ADR-043 typed S3 retrieval
already confirmed absence; no inference is made from a failed GET.

The helper first revalidates the old checkpoint and checks the modes,
ownership, and SHA-256 digests of the proposed object bodies. It creates
a fresh owner-private mode-0700 directory in the producer's workspace,
then writes a single mode-0600 TSV manifest using a bounded and
deterministic grammar:

```text
certbotbot-prepublication-plan<TAB>1
environment<TAB>production|staging
bucket<TAB>validated-bucket-name
objects<TAB>integer-count
object<TAB>index<TAB>latest-key<TAB>old-present<TAB>old-sha256-or-dash<TAB>old-bytes<TAB>new-sha256<TAB>new-bytes
```

All field identifiers and key names come from established validators,
not interpolated shell program text. Filesystem paths and private
key material are excluded. Index zero describes the common account
object. The remaining indices describe only selected lineages and
retain the accepted domain key order. A missing old object uses
presence `0`, checksum `-`, and size `0`; an existing old object
uses presence `1`, the as-downloaded object body's SHA-256, and its
byte length. New objects must be present and nonempty.

The manifest digest is recorded separately. A caller may invoke
`certbotbot_publication_plan_verify` before any later operation to
detect changes in the manifest, proposed bytes, or the stored prior
checkpoint; success does **not** prove authenticity against another
same-user process that can modify all of the metadata. A successful
plan is explicitly discarded by its owner, independently from
the candidate and checkpoint. If preparation fails, the plan is
discarded without deleting the still-owned candidate or checkpoint.

The manifest is a **local inspectable contract**, not a remote
transaction, lock, durable backup, commit authorization, or
announcement that issuance has succeeded. It cannot by itself
survive loss of the producing runner, determine safe first-time ACME
registration, or make multiple latest-object writes atomic.

## Context

ADR-019 requires stable common and selected domain archives that
remain compatible with ordinary certificate-consuming hosts.
ADR-022 requires complete local verification before publication,
common-before-dependent sequencing, operator serialization, and
recovery from partially completed remote writes. ADR-042 creates
cryptographically verified proposed bytes, and ADR-043 captures exact
previous S3 bytes while explicitly warning that a local checkpoint
cannot survive a runner crash.

Those inputs lacked a single auditable representation of what would
change remotely. This manifest is the final offline planning and
precondition-check boundary before a **separately accepted** S3
durable-generation and write/recovery protocol may be implemented.

## Constraints and assumptions

- Proposed certificates have already passed the complete static
  account, cryptographic trust, key, combined PEM, and exact SAN
  verification required by ADR-042.
- Previous S3 state has been read and structurally validated by
  ADR-043. A previous certificate may be expired; this plan records
  its bytes but does not authorize deploying or reissuing it.
- Existing S3 key grammar remains unchanged; the manifest does not
  introduce remote revision or backup object keys.
- New and previous bodies are owner-private local regular files.
  An attacker controlling the producer's operating-system identity
  remains outside this integrity model.
- Cross-platform writers remain externally serialized. A successful
  plan does not protect against another runner modifying S3 before
  publication, and no remote state is rechecked by this module.
- Bash 4.3 and the existing SHA-256 tooling are required; no JSON
  serialization library or new package dependency is introduced.
- No consumer is promised this internal TSV format. Changes to the
  grammar require review before a remote publisher is connected.

## Alternatives considered

**Start uploading after a valid ADR-042 candidate** was rejected:
a valid replacement does not establish what prior objects exist or
how they can be recovered.

**Treat the local ADR-043 checkpoint as complete crash recovery**
was rejected because a new runner cannot access a crashed runner's
private files.

**Give the manifest permission to upload objects immediately**
was rejected because remote backup-generation retention, missing-key
rollback semantics, idempotent retries, and mixed-generation recovery
still need independent design and tests.

**Use a mutable or unstructured list of shell assignments** was
rejected because it would be harder to inspect safely and would
invite executable data interpretation.

**Store absolute private filenames in the manifest** was rejected:
they are ephemeral runner-specific implementation details, not
portable publication metadata.

**Hash only the manifest text** was rejected because the referenced
archive bytes could change while the text remained the same. The
verification step also recomputes hashes of both proposed and
previous bytes.

## Consequences, tests, and limitations

All three standalone artifact flavors must pass credential-free
Bats tests for an existing common/domain collection, a fully
confirmed missing collection, exact common-first ordering, and
local mutation of a proposed object, prior object, or manifest.
Every test must verify no S3 PutObject, no Certbot invocation,
unchanged active configuration, and disposal of the plan while
preserving separate ownership of the candidate and checkpoint.

A later accepted decision must define how to retain previous
generations **durably in remote storage**, associate them with
a generation identifier, verify bytes after remote write, preserve
or restore confirmed absences, sequence common and domain aliases,
handle lost responses and partial crashes, and document an
operator-verifiable recovery path from a fresh runner.

This decision does not supersede ADR-037, authorize active account
import, satisfy the genuine Let's Encrypt staging evidence gate,
or enable the public issuer (which still returns status 69).

## Related decisions

ADR-019 (common/domain archives), ADR-021 and ADR-041 (optional GPG),
ADR-022 (serialization and publication), ADR-030 (staging isolation),
ADR-037/038 (account/renewal trust), ADR-039 (typed reads),
ADR-042 (verified proposed collection), ADR-043 (previous-state
checkpoint), and ADR-045 (inactive multi-lineage assembly).
