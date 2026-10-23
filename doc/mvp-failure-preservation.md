# MVP Failure Preservation and Remote-Write Evidence

Approved technical task #35, parent story #10. The model in
[MVP Certificate-State Threat Model](mvp-certificate-state-threat-model.md)
and Accepted ADR-020 through ADR-028 govern this work. No new
durable-state semantics, locking, rollback or remote object are introduced.

## Preconditions and evidence

The public executable must start from a pre-existing S3 object holding
a registered production ACME account. The regression fixture first issues
the single selected certificate into that seeded object and then uses the
resulting **known-good remote archive** as the baseline. Each failure
test records its SHA-256 before the next invocation, runs with mocked
AWS/Certbot and real local OpenSSL/tar/gzip, then compares the remote
object's digest afterward. The mock records all AWS and Certbot calls.
A nonzero exit alone is never accepted as proof of remote preservation.

The existing Bats matrix runs the same public command against **all three
shipped artifact variants**, with separate private runner workspaces. No
live cloud, DNS, or ACME call occurs during the test. A checksum comparison
establishes only mock-object byte identity, not server-side S3 integrity
or durable replication.

## Local failure / publication matrix

| Failure at or before the publish gate | Expected public result | Mock remote SHA-256 | PutObject calls |
| --- | --- | --- | --- |
| HeadObject denied or transport failure | Nonzero; unavailable | Unchanged | 0 |
| GetObject partial/failed or corrupted bytes | Nonzero; no Certbot | Unchanged | 0 |
| Restored account, lineage or format invalid | Nonzero; no Certbot | Unchanged | 0 |
| Certbot renewal modifies local account then fails | Nonzero | Unchanged | 0 |
| Certbot returns success but leaf mismatches private key | Nonzero; post-provider verification fails | Unchanged | 0 |
| Certbot returns success but chain or renewal metadata invalid | Nonzero; validation fails | Unchanged | 0 |
| Successful renewal metadata update, but tar packaging fails | Nonzero; local candidate not accepted | Unchanged | 0 |
| Successful no-op with no forced upload | Zero; `published=false` | Unchanged | 0 |
| Forced republish, PutObject rejects before accepting bytes | Nonzero; remote result reported uncertain | Unchanged **in this specific mock** | 1 |
| Accepted PutObject followed by failed response | Nonzero; remote result reported uncertain | May differ from baseline | 1 |
| Successful changed state and accepted PutObject | Zero; `published=true` | Different when certificate/account changed | 1 |

The final two failure cases deliberately separate **caller observation**
from **remote reality**. The public caller must not claim successful
publication when AWS returns an error, but once a PutObject has started,
the caller cannot guarantee the previous object survived unchanged.
The tests model both rejected-before-write and accepted-but-lost-response
cases. Remote state may require operator reconciliation.

## Security invariants and limitations

- Every failure before publication prevents any remote write request.
  Unsafe state is discarded with the invocation-owned private workspace.
- The publisher validates selected ACME state, canonical renewal metadata,
  complete candidate tar.gz and approved change/override status before
  PutObject. The operation always targets the exact key already read.
- Only mock remote bytes are checksummed: `sha256sum` is not an AWS
  transaction or an ETag assertion. No post-PutObject GET, rollback,
  remote version or compare-and-swap is introduced.
- An externally serialized single writer per key is **required**.
  Races, remote deletions, forged external executables, lost responses,
  AWS consistency/outage behavior, and live service interoperability are
  outside the guaranteed protection boundary.

This document records implementation-stage assurance for task #35;
operator-controlled staging under milestone #4 remains the separate
real-service verification gate.
