# ADR-039: Typed S3 Retrieval and Private Collection Staging

Date: 2026-10-16

## Status

Accepted

## Decision

Introduce a producer-internal, read-only retrieval boundary that downloads the
common ACME account archive and every requested domain archive into a newly
created mode-0700 directory beneath the current owner-private workspace.
The public issuer, GPG decryption, archive extraction, account registration,
DNS operations, publication, and release gate remain disabled.

The retrieval interface takes a configured bucket and one or more distinct
canonical lineage names. It derives each latest-object key through the
existing ADR-030 production/staging namespace builder, and invokes only the
reviewed bundled S3 adapter, preserving argument vectors. The common archive
is always index zero. A parallel presence array and pathname array preserve
the identity and order of requested lineages. Downloaded files are mode-0600
temporary objects whose bytes are not interpreted as valid tar archives
until the separate archive restoration gates have run.

The operation distinguishes these outcomes:

- **0: Existing shared state.** The common archive exists; any selected
  domain archive may be either present or explicitly missing, because a
  newly requested lineage need not exist yet. Presence is recorded per
  requested object. The caller owns successful staged bytes and MUST
  discard the recorded stage.
- **10: Entirely absent collection.** The common and every selected
  domain object returned an explicitly recognized `NoSuchKey` condition.
  The temporary snapshot is discarded before return. This is necessary
  but not sufficient evidence for a future authorized first registration.
- **65: Inconsistent state.** One or more domain objects exists while
  the common account archive is missing. All staged bytes are discarded,
  and automatic replacement account registration is forbidden.
- **69: Unknown or failed remote retrieval.** Authorization failures,
  transport failures, throttling, ambiguous HTTP 404 responses, invalid
  or empty remote object bytes, and other unrecognized service conditions
  are fatal. They MUST NOT be reclassified as an empty collection.
- **64 or 73:** Invalid local input/configuration or a local filesystem
  operation failure. No collection remains staged after recoverable
  local failures, and cleanup failures take precedence.

## Recognition rule

The first supported AWS CLI signature for a confirmed absent S3 object
is exit status 254 accompanied by a GetObject service error beginning:

`An error occurred (NoSuchKey) when calling the GetObject operation:`

A generic `404`, even from `HeadObject` or an S3-compatible service,
is insufficient: bucket absence, endpoint configuration, authorization,
or provider-specific behavior may make a missing-object inference unsafe.
ADR-052 adds a second, precisely anchored AWS CLI 2.37.13 diagnostic form,
with the literal `aws: [ERROR]: ` prefix. It changes only the displayed
CLI-error recognition grammar, not the required status 254, operation,
NoSuchKey code, or fatal handling of other errors.

An unsupported error signature is a fatal retrieval failure. The operator
must not bypass classification to force a first-run registration. Future
endpoint-specific behavior requires test evidence and an explicit policy
review, rather than broad string matching or treating all failed GETs as
absence.

The adapter's raw `get` operation is retained for the future publisher
and existing tests. The new internal module uses it with an exclusively
owned empty destination and redirects CLI service diagnostics to a
temporary owner-private error file. No raw AWS diagnostic or downloaded
credential material is printed. A failed command may have written partial
bytes; those bytes must be discarded before the next step. The helper
confirms that successful objects are nonempty and do not expose
symlinked local destinations.

## Context and drivers

ADR-019 makes the common archive authoritative portable producer state
and permits per-domain archives that are independently requested. ADR-022
forbids replacing a missing or unreadable common archive with a new
registration when existing lineage state depends upon it. ADR-030
requires strict staging/production object-key separation. The initial
S3 adapter passed through AWS CLI errors without proving object absence.
A stateless runner cannot safely choose between first registration and
account reuse unless it can distinguish confirmed missing data from
failed retrieval.

A remote bucket, DNS zone, and original ACME account are not intrinsic to
the new runner. Jenkins, GitHub Actions, and EC2 use the same object-state
collection but independently injected credentials; a previous runner's
temporary files are not required or trusted.

## Assumptions

- The initial storage provider is the bundled AWS CLI S3 API adapter.
- The retrieval command is executed by a trusted host identity inside an
  owner-private workspace; a same-user adversary is outside this boundary.
- AWS CLI status 254 and `NoSuchKey` apply to the exact reviewed
  `s3api get-object` operation. Some S3-compatible endpoints may require
  further provider-specific compatibility work.
- The requested lineage names have no traversal, alternate case, or
  duplicate forms. The batch is bounded to 32 lineages per call.
- Independent writers are externally serialized; there is no cross-host
  S3 lease or atomic multi-object snapshot in v1.
- A single successful GET is not a cryptographic attestation of archive
  safety or freshness.

## Considered alternatives

**Treat any failed GET as a missing object** was rejected because denied,
unreachable, or misconfigured state must not be mistaken for first run.
**Treat all HTTP 404 errors as missing keys** was rejected because the
response may not disambiguate object, bucket, endpoint, or permission
failure. **Use a separate HEAD request as the deciding authority** was
rejected because HEAD/GET can race, and some providers suppress failure
detail on HEAD. **Extract each fetched tarball immediately** was rejected
because the complete set of remote results must be classified before
moving toward account selection. **Fetch into a persistent workspace**
was rejected as incompatible with the cross-runner state contract.
**Introduce a remote state-generation manifest** was deferred because
versioned multi-object consistency and fencing require separate design.

## Promises and residual risks

This boundary never overwrites an active Certbot configuration, invokes
Certbot, publishes an archive, or authorizes registration. It does not
interpret nonempty downloaded bytes as a validated tarball, prove an
ACME account is registered, decrypt GPG ciphertext, or choose a
renewal candidate. Every successful archive must still pass the
existing isolated restoration and ADR-038 renewal-option policy.

S3 latest-object reads are not a transaction across objects, and a
different writer could mutate one key between sequential GETs. Operators
must preserve ADR-022 external serialization. Even in a serialized run,
an application-level multi-object generation protocol would be needed for
stronger snapshot atomicity. This PR does not invent such a guarantee.

When common is missing and domain objects also appear missing, status 10
does not itself permit registration; a future producer must still verify
configured authorization and other first-run preconditions. When common
exists but one selected domain is missing, a later issuer may consider
that domain new only after all other gates and requested input checks.

## Verification

All three standalone artifacts must run mocked AWS CLI tests for full
collections, newly requested missing domains, empty storage, an orphaned
domain with missing common account, denied reads, ambiguous 404 responses,
transport failure, zero-byte objects, intentionally partial downloads,
invalid requests, staging namespace isolation, private file modes,
stage cleanup, and preservation of preexisting active configuration.

A later integration milestone must validate the same behavior against
actual S3 and the intended S3-compatible endpoints using scoped
nonproduction credentials. The release and public issuance gates stay
closed pending end-to-end ACME and publication evidence.

## Related decisions

ADR-019 defines common/domain archive identity, ADR-020 the built-in
provider model, ADR-022 serialized remote publication, ADR-028 portable
account state, ADR-030 selected ACME environment namespaces, ADR-037
non-activating import, and ADR-038 the restored renewal-option policy.
