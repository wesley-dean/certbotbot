# ADR-040: Non-Activating Assessment of Retrieved S3 Certificate State

Date: 2026-10-16

## Status

Accepted

## Decision

The producer gains one internal, non-activating operation that retrieves a
selected S3 certificate-state collection and evaluates **every present
object** using the previously accepted private archive and renewal
validators. This is the first composition of ADR-039 remote retrieval with
ADR-037 and ADR-038 isolated import assessment. It must not install a
renewal-path preview, register an account, execute Certbot, or write to S3.

The operation accepts a bucket and one or more distinct canonical lineage
names. ADR-039 fetches all selected latest objects before any tar archive
is inspected. A retrieval error aborts the entire operation, preserving
its distinction among confirmed missing, orphaned state, permission
failure, and transport failure.

When common account state exists, it is independently restored, validated,
and discarded **even if no selected lineage archive exists**. A corrupt
common archive is a fatal error, never a reason to re-register. Every
present lineage archive is assessed using one canonical batch invocation
against a snapshot of the downloaded common archive. The existing batch
path applies structural member validation, account/CA association,
approved renewal-option grammar, and safe preview-only path relocation
before disposing of its owned stages.

A selected lineage whose object returned confirmed NoSuchKey is omitted
from the existing-lineage batch only after common state has passed
validation. Its canonical name may be recorded in an ordered, internal
`CERTBOTBOT_STATE_MISSING_NAMES` array after **all** present lineages
pass. The array is cleared on failures; it is a report about storage
presence, **not authorization to issue** a certificate or mutate S3.

Every successful or failed assessment discards the complete local
download stage, including the common account key, and leaves the
active workspace configuration empty. Cleanup failure takes priority
over an earlier validation result.

## Result classification

- **0:** A common archive was present and valid. Every present selected
  domain passed non-activating assessment; an ordered array records
  confirmed-missing requested domain archives, if any.
- **10:** The common archive and all selected domain archives were
  confirmed absent by ADR-039. The caller receives no staging paths or
  trusted account state. No automatic registration is authorized.
- **65:** A selected domain was present without a common archive, or
  account/authority identity validation failed.
- **69:** S3 retrieval or authentication failed ambiguously.
- **64 or 73:** Input/archive-policy rejection or local staging/cleanup
  failure. Earlier archive validator statuses may also propagate.

A fully valid common archive with zero existing requested domains is
distinguished from an entirely absent collection. A valid first-run
decision cannot be inferred from the domain objects alone.

## Context and rationale

The project is intended to run sequentially on Jenkins, GitHub Actions,
and EC2 without requiring persistent local state from any earlier run.
ADR-019 makes a common account archive authoritative and separates
domain lineage archives so users can select only the certificates
currently requested. ADR-039 established how to retrieve their exact
object keys and distinguish missing remote state from failed reads.
ADR-037 and ADR-038 established private staged analysis and an explicit
renewal-option allowlist. Until those capabilities are composed, the
runtime does not have a single reviewable path from untrusted remote
bytes to an assessed existing collection.

The adapter intentionally remains separate from both public CLI and
certificate issuance. Merely joining retrieval to validation does not
prove ACME registration, remote freshness, a coherent multi-object
generation, or cryptographic validity of a leaf certificate.

## Assumptions

- A selected collection contains at most the bounded number of lineages
  enforced by ADR-039, and names are canonical and nonduplicate.
- Private workspace ownership and strict modes are provided by the
  existing workspace manager.
- Multiple independent producers using the same S3 namespace are
  externally serialized as required by ADR-022.
- The first supported stored object form is plaintext `.tar.gz`.
  Encrypted archives need the separate GPG mode and migration decision.
- The common archive can be validated alone, without an existing
  selected lineage; its account-record shape is governed by ADR-028.
- An assessed historical lineage is not yet an importable Certbot state
  tree, and successful assessment does not verify X.509 chain or SANs.

## Alternatives considered

**Treat S3 GET success as archive validity** was rejected because a
remote object may contain malicious tar content, wrong accounts, or
unsafe renewal hooks.

**Validate common only if at least one lineage exists** was rejected:
corrupt account material alongside new requested lineages cannot be
treated as a valid existing collection.

**Interpret absent domain archives as permission to issue immediately**
was rejected because registration/issuance still requires an authenticated
account, safe active import, and current request validation.

**Retain downloaded archive stages for future commands after assessment**
was rejected in this integration boundary to avoid accidental use of
stale or unchecked private state. A future activation coordinator may
define a separately owned candidate lifecycle in an Accepted ADR.

**Merge selected lineages into an active configuration as they validate**
was rejected by ADR-037. Partial active state and imported hook execution
cannot be allowed while later domains remain unchecked.

**Use a remote common/domain generation pointer now** was deferred:
stronger snapshot atomicity and cross-writer fencing require a separate
concurrency and storage protocol decision.

## Consequences and verification

This milestone requires network-free Bats integration tests using a
mocked S3 API and real local tar archive shapes. Positive cases must
include two independently selected existing lineages, all-new
lineages with a valid common account, and mixed present/absent lineages.
Negative cases must include entirely empty storage, corrupt common
state, invalid later lineages, foreign ACME authority, rejected renewal
settings, missing common with existing lineage, authorization failures,
invalid or duplicate requests, and preexisting active workspace files.

The same tests run for development, ordinary, and minified standalone
artifacts and must leave no private downloaded stages after returning.
No remote S3 service is used in these tests; integration with real S3
and MinIO-compatible services remains a separate acceptance gate.

A future activating ADR must still be preceded by genuine Let's Encrypt
staging registration/account reuse, no-op renewal, and due or changed-SAN
renewal evidence across independently recreated workspaces. Until that
evidence is reviewed, the public issuer continues to fail with status
69, releases remain gated, and S3 uploads are disabled.

## Related decisions

ADR-019 governs split portable archives, ADR-022 external serialization,
ADR-025 Certbot portability, ADR-028 account archive shape, ADR-030
environment isolation, ADR-031 account/lineage identity, ADR-032
non-activating previews, ADR-037 active-import gating, ADR-038 renewal
option policy, and ADR-039 typed S3 retrieval.
