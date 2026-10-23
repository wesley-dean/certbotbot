# MVP UPLOAD_NO_RENEWAL Publication Policy

Status: approved technical-task #101 specification for user story #90.
This document is the explicit product behavior contract for the existing
single-archive MVP. It elaborates **Accepted ADR-020, ADR-025, ADR-027,
and ADR-028** without amending or superseding them. The policy already has
a parser/publisher implementation; task #102 verifies and completes its
public integration, and task #103 owns the full black-box matrix.

## Configuration and precedence

`UPLOAD_NO_RENEWAL` is a literal Boolean with the default `false`.
The four independent input sources use the same precedence as every MVP
configuration value:

1. Explicit CLI `--upload-no-renewal true|false` or
   `--upload-no-renewal=true|false`.
2. Exported environment variable `UPLOAD_NO_RENEWAL=true|false`.
3. A supported literal `UPLOAD_NO_RENEWAL=true|false` assignment in
   the implicitly loaded `./.env` or explicitly chosen `--config FILE`.
4. The built-in default `false`.

An explicit `false` **must override** a lower-priority `true`.
Values are exactly lowercase `true` or `false`; uppercase variants,
blank values, unrecognized words, repeated CLI options, or malformed
literal configuration fail status 64 **before AWS or Certbot access**.
The .env parser does not evaluate, source, interpolate or execute its
contents. The value is resolved once per invocation and passed as a
quoted argument to the selected-key publisher.

The setting is named for the usual no-renewal case, but is **not** a
request to force certificate issuance or to skip any durable changes.
It only permits a verified republish of an otherwise unchanged
successful invocation.

## Distinguishing certificate renewal from durable change

Certbot's success status can mean renewal was due, issuance succeeded,
or an unchanged no-op. The public orchestrator verifies the selected
account and certificate independently; a zero Certbot exit alone is not
publication authority. Its provider reports two separate post-operation
facts:

- `CERTBOTBOT_RENEWAL_OCCURRED`: whether the selected certificate or
  its current symlink changed after a successful selected renewal.
- `CERTBOTBOT_DURABLE_CHANGED`: whether *any* persisted Certbot config
  content, file/link state or permissions changed, including ACME account
  metadata, renewal metadata, or changed certificate material.

An unchanged certificate with altered durable account metadata is
**changed state**, and publication is mandatory regardless of the
override. The publication argument `CHANGED` is the verified durable
change result, never the simpler fact that `renew` returned zero or
that certificate bytes alone changed. First issuance into seeded
account-only state is necessarily changed. A supported same-lineage
SAN change is also changed. The publisher never decides whether
Certbot was due for renewal.

## Decision table

All success rows require a previously retrieved valid S3 archive,
unambiguous selected production ACME account/lineage, successful bounded
Certbot processing, post-provider certificate/key/SAN and canonical
metadata verification, and private candidate packaging before any write.

| Public outcome | Renewal occurred? | Durable state changed? | Override=false | Override=true |
| --- | --- | --- | --- | --- |
| First issuance from a seeded account-only object | New issue | true | One validated PutObject | One validated PutObject |
| Due ordinary selected-lineage renewal | true | true | One validated PutObject | One validated PutObject |
| Supported same-lineage SAN reconciliation | Reissued | true | One validated PutObject | One validated PutObject |
| Successful selected `renew` no-op, but ACME or renewal metadata changed | false | true | One validated PutObject | One validated PutObject |
| Successful selected `renew` with unchanged durable state | false | false | No PutObject, no candidate | One validated PutObject |
| Any S3 retrieval, restore, ACME account, provider, certificate, archive validation, or packaging failure | Irrelevant | Not authoritative | Nonzero; no PutObject | Nonzero; no PutObject |
| PutObject rejected or response lost after an attempted write | Irrelevant | true or forced | Nonzero; publication not reported as success | Nonzero; publication not reported as success |

The final failure row applies only **after an upload request was attempted**.
A nonzero response does **not** prove S3 retained the old object. The
public status reports remote state as *uncertain*, even if a controlled
test mock rejected bytes before acceptance. No automatic retry,
rollback, S3 compare-and-swap, second-object staging, lock, or version
retention is provided.

For the successful unchanged/no-override case, no new candidate or S3
write is required. The existing preflight and canonical renewal
metadata validation still apply. That successful `published=false`
report means that **this invocation did not upload**, not that a
recent independent S3 verification or certificate renewal occurred.

## Same-object and validity invariants

The effective S3 bucket/key is resolved under the same CLI > environment
> literal .env > default precedence. The default key is
`latest.tar.gz`, and the *same exact selected key* must be passed to
HeadObject, GetObject, and (only when authorized) PutObject. This option
cannot cause a second, dated, templated, backup or per-run S3 object.

Before any authorized PutObject, the publisher internally calls the
bounded archive packager for the **complete, current verified** private
configuration tree. Candidate contents, account continuity, selected
lineage, canonical renewal references, file ownership/privacy,
tar members and gzip form are checked. Supplying `true` must never
bypass those gates, reuse an unvalidated downloaded blob, register a
new account, invoke a global `certbot renew`, force ACME renewal, or
alter the selected Certbot name.

A successful upload returns `published=true`; an unchanged skipped
no-op returns `published=false`. Provider/validation failure never
prints a successful final status, and failed PutObject is reported
nonzero with remote status uncertain. Static diagnostics suppress raw
AWS/Certbot output and sensitive account/certificate data.

Externally serialize writers for the one remote S3 object; the MVP
does not provide concurrency safety or transactional rollback.
Actual AWS/Route53/Let's Encrypt interoperability and operator IAM
policies are evaluated separately under milestone #4.

## Verification and acceptance ownership

Task #102 confirms the **public** lifecycle passes the resolved
literal Boolean after verified provider success and preserves exact
key continuity. Its focused behavioral evidence and clean-runner case
are documented in [the public forced-republish integration](mvp-upload-no-renewal-integration.md).
It introduces no new interface or remote S3 object.

Task #103 verifies the complete public-executable table: default,
CLI/environment/.env precedence (including explicit `false`),
changed/no-change, actual renewal, metadata-only update, failure gates,
PutObject errors, non-secret output, and equivalent behavior across all
three artifacts. The [public regression matrix](mvp-upload-no-renewal-test-matrix.md)
records the concrete expected outcomes and scope limitations. The Bats
harness uses fake AWS/Certbot and real local OpenSSL/tar/gzip, and checks
PutObject counts, exact key values, archive bytes, and exit status.

Existing supporting suites include `tests/config-identity.bats`,
`tests/s3-publish.bats`, `tests/public-lifecycle.bats`, and
`tests/archive-package.bats`. This task specifies the policy and
does **not** claim that the later expanded verification is complete.

## Related governance

- [MVP configuration and identity](mvp-configuration.md): configuration grammar.
- [Public lifecycle](mvp-public-lifecycle.md): post-success dispatch.
- [Single-key S3 publication adapter](mvp-s3-publication.md): publisher boundary.
- [Failure preservation](mvp-failure-preservation.md): remote-status uncertainty.
- ADR-020: single seeded durable object and opt-in republish.
- ADR-025: distinguish certificate renewal from durable change.
- ADR-027: validated candidate before any remote write.
- ADR-028: exact one-key publication and four-row Boolean truth table.

No new ADR is introduced because the accepted decisions already establish
these semantics. Any incompatible behavior found during task #102 must
be called out explicitly and resolved under those decisions.
