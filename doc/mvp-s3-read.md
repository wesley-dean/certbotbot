# MVP S3 Read Boundary

This contract implements the independently testable Amazon S3 retrieval
boundary for task #28. It is a component of, not a replacement for, the
public restore-and-issue lifecycle.

## Inputs and supported environment

The adapter accepts one existing AWS S3 bucket, one exact object key, and
a private workspace created for this invocation. The key defaults to
`latest.tar.gz` through the already-approved configuration resolver.
The operator supplies AWS CLI v2, credentials, the correct AWS region, and
suitable `s3:ListBucket` and `s3:GetObject` rights on existing resources.
The later upload phase additionally requires `s3:PutObject`.
No code creates AWS resources, an ACME account, or a replacement archive.

The archive path within the private workspace is `downloaded.tar.gz`.
A completed adapter read means bytes were retrieved but **not** that they
have been validated or restored. The archive is not extracted here.

## Calls and error semantics

The adapter calls AWS CLI `s3api head-object` with the selected bucket/key.
On success it calls `get-object` with the same bucket/key, staging output in
a private temporary file. The candidate moves into `downloaded.tar.gz`
only after a successful, nonempty download. On a 404 HeadObject error the
adapter also calls `head-bucket`; a successful bucket check yields a
confirmed missing object. Any ambiguous failure prevents further action.

| Exit status | Meaning |
| --- | --- |
| 0 | Nonempty object bytes staged, not yet validated |
| 64 | Invalid caller inputs or unsafe workspace |
| 66 | Missing seeded object, positively classified |
| 69 | AWS CLI unavailable, access denied, or uncertain remote state |
| 74 | Download or local staging failed |

All diagnostics are fixed phrases. AWS command output and stderr are
captured privately and not repeated to the operator. Failure never
attempts a remote upload or local host-account fallback. The adapter
does not claim a remote atomic snapshot between HEAD and GET.

## Public lifecycle integration

The public command now uses this read adapter before any Certbot
operation and aborts on confirmed missing or unsafe seeded state.
The full mocked workflow, including publication to the identical
bucket/key, is specified in
[mvp-public-lifecycle.md](mvp-public-lifecycle.md).

## Matching publication boundary

The later publication adapter is specified in
[mvp-s3-publication.md](mvp-s3-publication.md) and governed by ADR-028.
It uses the **same caller-resolved BUCKET/KEY** after successful
Certbot processing and candidate validation. It writes only that one
object with `s3api put-object`, never creates a bucket, and obeys
the durable-change and UPLOAD_NO_RENEWAL policy. A successful read
does not itself authorize publication.
