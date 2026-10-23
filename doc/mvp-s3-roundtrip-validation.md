# MVP S3 Roundtrip and Publication Fault Evidence

This specification records the black-box mocked-public-command verification
for approved task #40, parent story #13. It does not introduce new production
behavior or amend Accepted ADR-020, ADR-021, ADR-022, ADR-027, or ADR-028.

## Method and trust boundaries

`tests/public-lifecycle.bats` executes the same assembled CLI that users run,
against a fake AWS CLI and fake Certbot, while exercising actual OpenSSL,
GNU tar/gzip, filesystem links and the built-in archive validator. The mock
starts with an existing S3 object containing a pre-registered production ACME
account and no selected certificate. Subsequent invocations never share a
private runner workspace: each reconstructs its account and certificate from
the single mock remote object. No test needs AWS credentials, access to
Route53, a Let's Encrypt account, or an ACME network connection.

Each test selects exactly one S3 bucket and one effective object key. The
default key is `latest.tar.gz`; an explicit override remains identical
through the head/get/put operations. The account and selected Certbot lineage
must survive local archive serialization and a later independent restore.
All three standalone release artifacts are exercised by the existing
`make test` and `make test-report` loops.

For credential boundaries, remote-write uncertainty, and other residual
risks, see the [MVP Certificate-State Threat Model](mvp-certificate-state-threat-model.md).

## Failure and publication matrix

| Condition | Expected public result | Expected remote outcome |
| --- | --- | --- |
| Seeded account, selected lineage absent | Issue and publish | One validated same-key PutObject |
| Restored lineage, unchanged successful renewal | Success, `published=false` | No PutObject and original bytes |
| Restored lineage, actual certificate renewal | Success, `published=true` | One PutObject; selected lineage/account preserved |
| Restored lineage, account metadata only changes | Success, `published=true` | One PutObject despite unchanged leaf |
| Unchanged state and `UPLOAD_NO_RENEWAL=true` | Success, `published=true` | One verified same-key PutObject |
| Confirmed missing remote object | Nonzero | No provider call or PutObject |
| Corrupt or unreadable remote object | Nonzero | Remote bytes unchanged, no provider call or PutObject |
| Issuance failure or bad generated leaf/fullchain | Nonzero | Remote bytes unchanged, no PutObject |
| Candidate tar serialization failure | Nonzero | Remote bytes unchanged, no PutObject |
| PutObject fails before accepting bytes | Nonzero | Mock retains prior object bytes |
| PutObject writes bytes but responds with failure | Nonzero | **Indeterminate** to caller; mock may show changed object |

The final row is important: after a failed PutObject, the client cannot
guarantee whether the service accepted the candidate. Assertions about remote
byte preservation are limited to failures before a remote write or a mock
failure mode explicitly representing pre-acceptance rejection. The tool does
not provide a two-phase commit, distributed lock, or rollback guarantee.

Tests assert observable exit status, AWS/Certbot command families,
single-key consistency, restored account identity and canonical renewal
metadata, archive bytes, and the absence of premature publication. They do
not claim verification of production AWS behavior or Let's Encrypt/Route53
interoperability; operator-controlled live evidence belongs to milestone #4.
