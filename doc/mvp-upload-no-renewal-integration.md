# MVP Forced-Republish Public Integration Evidence

Approved task #102 verifies the **already implemented** public
`UPLOAD_NO_RENEWAL` gate under the policy recorded for task #101.
This is a bounded integration verification, with no change to the accepted
single-archive architecture or public CLI syntax.

## Public integration contract

The assembled executable resolves the selected bucket, key, certificate
lineage and literal Boolean independently. Its private lifecycle first
retrieves the mandatory seeded archive, safely restores state, selects and
executes exactly the intended Certbot operation, then verifies the
complete selected certificate, key and canonical renewal metadata.
Only then does the caller supply the **verified durable-change result**
and the resolved `UPLOAD_NO_RENEWAL` Boolean to
`certbotbot_s3_publish` using the exact originally selected S3 key.

The publisher already implements the four rows in ADR-028:

| Durable change | Explicit override | Authorized result |
| --- | --- | --- |
| false | false | Verified no-op; `published=false`, zero PutObject |
| false | true | Validated same-key candidate; one PutObject |
| true | false | Validated same-key candidate; one PutObject |
| true | true | Validated same-key candidate; one PutObject |

A successful forced upload **does not** mean a certificate was renewed.
Neither the override nor a durable metadata change may trigger an
additional `certonly` invocation, an ACME registration, a dated backup,
or a second S3 key. The distinction is visible in the public success
message, the intercepted provider calls, the exact S3 object key, and the
resulting portable tarball.

If S3 retrieval, provider execution, certificate verification or
archive packaging fails, PutObject is never attempted. When an attempted
PutObject fails, public invocation returns nonzero and the remote state
is reported **uncertain**: client-side code cannot prove that bytes
were not accepted by S3 before the error.

## Focused task #102 verification

The task-specific Bats scenarios in `tests/public-lifecycle.bats`
exercise the actual public executable with a mocked AWS CLI and Certbot,
real OpenSSL, and real local tar/gzip:

- First run issues normally, then a separate clean runner uses
  `--upload-no-renewal=true` with a non-default key. It renew-checks
  exactly the selected lineage without a new issuance, writes once to
  that **same** key, and persists the original ACME account and canonical
  renewal metadata.
- A metadata-only Certbot state change with an explicit
  `--upload-no-renewal=false` still uploads once, demonstrating
  that real durable change takes precedence over the opt-in flag.
- A forced republish following Certbot failure does not reach PutObject
  or alter the original mock remote bytes.
- Forced publication of an invalid post-Certbot fullchain is blocked
  before PutObject; the seeded remote bytes stay intact.

All release artifact flavors run the same Bats suite. These cases are
*integration evidence*, not a claim of actual AWS/ACME/Route53
interoperability or strong distributed write atomicity. Task #103
owns the larger public truth-table/Boolean-precedence/error-status
matrix and separate story #90 acceptance. No additional ADR is
necessary because ADR-020/025/027/028 already establish these
behaviors; this task introduces no new decisions.
