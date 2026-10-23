# MVP Public Selected-Certificate Lifecycle

## Command

`certbotbot [options] DNS_NAME` now executes the selected-certificate
lifecycle using the existing configuration, naming, and SAN contracts
in [mvp-configuration.md](mvp-configuration.md). The supplied S3
bucket/key **must already exist**, holding at least the one registered
Let's Encrypt production account.

A valid command is consequential: it can contact real Amazon S3,
Let's Encrypt, and Route53 using the operator-installed AWS CLI v2,
Certbot plus dns-route53, OpenSSL, and available IAM/ACME authority.
No live provider checks are performed in the MVP automated suite.

## Operation

1. Resolve one primary name, optional complementary apex/wildcard,
   one stable cert name, S3 bucket, effective object key, and
   UPLOAD_NO_RENEWAL Boolean with existing per-setting precedence.
2. Create an owned 0700 workspace, and download and safely restore
   the authoritative `downloaded.tar.gz` from that single exact
   S3 object. A missing object, invalid tar/gzip or missing/ambiguous
   ACME account fails before any Certbot operation.
3. On an account-only archive, issue the requested selected lineage
   through Certbot DNS-01 Route53 using the existing account; map the
   new renewal metadata to canonical persistent paths. On a present
   lineage, use ordinary due renewal or explicitly bounded SAN
   reconciliation against that same stable name.
4. Assert the resulting selected certificate and key are usable and
   consistent: exact SAN set, validity interval, parseable PEM
   certificate/chain/fullchain, matching public/private key, first
   fullchain leaf equals selected cert, complete lineage and single
   selected account, and canonical persistent renewal paths.
5. Invoke the one-key publisher with the verified durable-change
   result and UPLOAD_NO_RENEWAL policy. It builds/revalidates a
   candidate only when publication is required, then performs
   exactly one `s3api put-object` at the original effective key.

The complete workspace is removed after return or handled signal.
Public stdout contains only selected bucket/key and the
`uploaded`/`unchanged` outcome. No account JSON, private key,
certbot logs or AWS command output are forwarded.

## No-op and error behavior

A successful renewal attempt that does not replace a certificate or
change durable metadata skips PutObject by default. A successful
no-op with UPLOAD_NO_RENEWAL=true builds/verifies a complete candidate
and uploads it to the same key. Any verified durable change requires
publication regardless of the flag.

Errors before PutObject leave the known-good remote object unchanged.
After an attempted PutObject that returns nonzero, remote state is
**unknown**; operators should recheck it before another writer.
A successful command is local/CLI evidence only and does not claim
live interoperability of ACME, Route53 and AWS beyond the mocked
tests. External serialization of writers remains required.

The public command does not register an ACME account, create a bucket,
rename an existing lineage, run archived hooks, renew unselected
lineages, delete orphans, or create any additional S3 keys.

## Certificate check limitations

OpenSSL checks the selected X.509 leaf's dates, exact DNS SANs, PEM
decodability, public/private key match and fullchain leaf match.
It does not perform independent CA trust-chain verification,
revocation lookup, issuance authorization or DNS validation.
These remain external Certbot/ACME trust and later live testing
responsibilities. Failed local assertions never authorize upload.

## Evidence

`tests/mvp-lifecycle.bats` exercises the generated executable
end to end with **mock** AWS CLI and Certbot services and actual
OpenSSL/tar/gzip. All three release variants use identical tests.
No real credentials or DNS/ACME calls are required. See ADR-029.
