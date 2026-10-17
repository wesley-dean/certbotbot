# ADR-052: Recognize the Exact Prefixed AWS CLI NoSuchKey Signature

Date: 2026-10-17

## Status

Accepted

## Decision

Amend **only the error-format recognition rule** in Accepted ADR-039.
The producer-internal, private `GetObject` classifier continues to require
the AWS CLI return code **254** plus a line anchored at the beginning of
stderr identifying the exact **NoSuchKey** service code and exact
**GetObject** operation. Two narrowly specified CLI display forms are
accepted:

1. `An error occurred (NoSuchKey) when calling the GetObject operation:`
2. `aws: [ERROR]: An error occurred (NoSuchKey) when calling the GetObject operation:`

The second form is confirmed from the GitHub-hosted AWS CLI **2.37.13**,
running against the isolated SeaweedFS S3 API in the ADR-051 end-to-end
test. This is a CLI presentation wrapper around the **same** service
error, not an authorization to reinterpret a generic HTTP 404.

The regular expression must match only zero or exactly one instance of
the literal `aws: [ERROR]: ` prefix. It must continue to require the
literal error code, API name, case, punctuation, and leading start
anchor. No substring search for `NoSuchKey`, generic `404`,
`NotFound`, `NoSuchBucket`, failure of `HeadObject`, status code other
than 254, unexpected diagnostic prefix, or fallback when the AWS CLI
fails is permitted.

On any unrecognized response, the result is the existing fatal 69
with the incomplete/failed download discarded. Raw CLI stderr remains
confined to an owner-private temporary error file and is never surfaced
by production issuer helpers. The existing successful and absent-state
outcomes, key grammar, encryption mode, authority namespace, and
first-run activation gates remain unchanged.

This decision supersedes **ADR-039's first supported CLI format
statement only**, and leaves ADR-039's broader staged retrieval and
security contract Accepted and binding.

## Context

The opt-in real-service harness from PR #40 had not been run against
an actual S3 API. ADR-051 introduced a continuously executable,
synthetic-credential end-to-end test, which promptly exposed two
previously unobserved issues: a Bash syntax defect in the harness and
a new AWS CLI diagnostic prefix. The live test authenticated to
a disposable loopback SeaweedFS container and independently proved
conditional PUT/DELETE behavior. The first internal recovery stage
then attempted an absent key and correctly received an AWS service
`NoSuchKey` condition, but the ADR-039 text parser rejected the new
CLI decoration as an unknown response.

The CI log showed:

`aws-cli/2.37.13`

and the service diagnostic began:

`aws: [ERROR]: An error occurred (NoSuchKey) when calling the GetObject operation:`

Merely silencing the error, treating a failure as an absent object, or
altering the test to avoid absent-state checks would undercut the
cross-runner recovery guarantee. The necessary compatibility change
is deliberately limited to the observed CLI formatting.

## Drivers and assumptions

- A producer must distinguish confirmed missing state from denied,
  timed-out, corrupted, or ambiguous state before choosing an action.
- GitHub-hosted runners update AWS CLI versions outside the product's
  repository governance. Bounded compatibility must therefore account
  for a verified newer rendering without broadening S3 error semantics.
- Production code only sees CLI stderr as untrusted bytes. A string
  that looks like a service error is not proof by itself; the reviewed
  exact operation, status 254, and bounded grammar are all necessary.
- Synthetic SeaweedFS evidence is sufficient to demonstrate the CLI
  **presentation change**. It is not sufficient to prove production
  AWS account, IAM, or endpoint interoperability.
- The producer's public issuer remains intentionally disabled.

## Alternatives considered

**Keep the old prefix only:** rejected because real supported CLI
versions would incorrectly treat a confirmed absent key as an unknown
failure, breaking stateless recovery and first-run paths.

**Strip any `aws:` prefix or use arbitrary whitespace:** rejected
because it would permit unknown or misleading diagnostics to acquire
first-run significance.

**Recognize any line containing NoSuchKey or status 404:** rejected
because denied bucket/access cases and different failing S3 operations
would be misclassified. The original fail-closed distinction remains
essential.

**Migrate to a JSON or structured machine-readable AWS error response:**
worth revisiting if a supported stable CLI error API becomes available,
but no compatible reviewed interface is established here; adding a
new parser surface now would widen scope and risk.

**Pin the entire AWS CLI toolchain to an old version:** rejected as a
substitute for accurate error classification. An old version can
lack conditional delete support, and a stale CLI becomes another
security dependency. The end-to-end workflow records the actual CLI
version and checks conditional operation support.

## Verification and consequences

Add positive Bats evidence for old and new exactly anchored
`GetObject NoSuchKey` forms, with an absent whole collection and an
existing common account plus absent lineage. Add explicit negative
cases for prefixed AccessDenied, generic 404, wrong operation,
unrecognized leading prefix, and a valid-looking NoSuchKey message
with the wrong process exit status. These run against **all three
standalone release artifact flavors**.

The enabled ADR-051 S3 end-to-end job must verify real missing-key
classification, conditional publication/recovery of an existing
collection, and first-run restore-to-absence. A passing status on the
reviewed head commit constitutes evidence only for that tested CLI
and SeaweedFS combination, not arbitrary S3 services.

Future AWS CLI diagnostic changes require fresh negative and positive
evidence and explicit review, rather than automatically treating a new
rendering as absence. This ADR neither authorizes S3 alias mutation
from the public CLI nor relaxes ADR-037, ADR-044, or ADR-050.

## Related decisions

ADR-019 governs portable common/domain state, ADR-022 governs
serialized publication, ADR-030 governs key namespaces, ADR-037
withholds active Certbot import, ADR-039 governs staged missing-object
classification, ADR-047 and ADR-050 govern independent recovery, and
ADR-051 governs the isolated S3 end-to-end integration evidence.
