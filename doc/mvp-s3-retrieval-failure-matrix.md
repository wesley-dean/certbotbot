# MVP S3 Retrieval Failure Matrix

Task #30 verifies the publicly invocable read/restore lifecycle according to
Accepted ADR-021 and ADR-022. The public runtime and S3 read adapter are
unchanged by this test-only increment.

## Test assumptions and boundaries

The operator has already seeded one existing S3 bucket/object with state for a
previously registered production Let's Encrypt ACME account. The object is
mandatory. The selected name is either `example.com` or `*.example.com`;
both are treated as data and yield the same stable selected lineage under the
approved default complementary-SAN policy.

`tests/public-lifecycle.bats` runs the real assembled command with deliberately
limited, mock-only `aws` and `certbot` executables on PATH. Local GNU
tar/gzip and OpenSSL remain real. No live AWS, Route53 or ACME network call is
permitted by the test setup. The existing `make test` matrix exercises each
test against development, ordinary and minified consumer artifacts.

## Expected public behavior

| Read/restore scenario | Expected outcome | Required negative evidence |
| --- | --- | --- |
| Existing seeded, valid account-only archive | Issue selected certificate and publish one key | No host account registration/fallback |
| Positively absent key: HeadObject 404, HeadBucket succeeds | Exit 66 | No Certbot invocation or PutObject |
| Ambiguous absence: HeadObject 404, HeadBucket fails | Exit 69 | No Certbot invocation or PutObject |
| HeadObject denied (403) | Exit 69 | No GetObject, Certbot or PutObject |
| HeadObject service/transport failure | Exit 69 | No GetObject, Certbot or PutObject |
| GetObject interrupted after writing partial local bytes | Exit 74 | No Certbot or PutObject; workspace removed |
| GetObject succeeds with zero bytes | Exit 74 | No Certbot or PutObject; workspace removed |
| GetObject succeeds with corrupt compressed bytes | Nonzero restore rejection | No Certbot or PutObject |
| Restored account files missing or wrong ACME endpoint | Nonzero state preflight rejection | No Certbot or PutObject |
| Restored archive has an unrelated/inconsistent lineage | Nonzero lineage preflight rejection | No Certbot or PutObject |

Tests compare the mock authoritative remote bytes before and after every
failure, assert no publication, ensure candidate data is never passed to
Certbot, and confirm the invocation-owned temporary directory is cleaned.
Captured mock AWS error messages (including a deliberate fake sensitive token)
must not appear in stdout or stderr.

The test distinguishes *remote object deletion* (a confirmed missing key)
from *temporary loss of access* (including ambiguous 404, denied or timeout).
It does not claim immutable GET snapshots, simulate authenticated AWS service
semantics, or establish that a real existing Certbot account can issue through
Route53. Those service tests remain with the separately governed live
end-to-end milestone.
