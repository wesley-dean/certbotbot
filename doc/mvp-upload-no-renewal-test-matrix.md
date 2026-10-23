# MVP UPLOAD_NO_RENEWAL Black-Box Verification Matrix

Status: scoped test plan and regression evidence for approved technical task
#103 under story #90. The accepted [publication policy](mvp-upload-no-renewal-policy.md)
and ADR-020, ADR-025, ADR-027, and ADR-028 remain authoritative.
This is the final mocked MVP verification gate for the opt-in publication
flag; there is no change to the public setting or to remote object naming.

## Fixture and observations

`tests/public-lifecycle.bats` starts with one seeded pre-existing
production ACME account held in one local file acting as the authoritative
S3 object. An executable AWS CLI mock logs HeadObject/GetObject/PutObject
with their exact bucket and key, rejects unexpected key values and can fail
before or after accepting a simulated PutObject. An executable Certbot
mock records issuance or named renewal operations. Real GNU tar/gzip
and local OpenSSL construct and inspect certificate state.

Each public invocation is executed through the normal
`BASH_STARTER_ARTIFACT` entrypoint. The Make test workflow runs the
whole Bats suite against **development, ordinary, and minified** consumer
scripts and verifies the adjacent SHA-256 checksum companions. These
tests establish observational equivalence of the behavior on all three
artifacts. They do not invoke real AWS, Route53, or Let's Encrypt.

Tests assert the public `published` status, expected nonzero failure
status, exact and counted S3 calls, selected-only Certbot operations,
the current archive's integrity and lineage/account state, and
preservation of the last-known-good mock remote bytes when no
PutObject is authorized. An attempted PutObject with a lost response
has **uncertain** remote status even if its bytes were accepted.

## Configuration resolution

| Lower-priority values | Effective higher-priority value | Expected successful unchanged run |
| --- | --- | --- |
| Absent (default false) | None | `published=false`, 0 PutObject |
| No exported variable; config absent | CLI true | `published=true`, 1 PutObject |
| File false, exported false | CLI true | `published=true`, 1 PutObject |
| File true, exported true | CLI false | `published=false`, 0 PutObject |
| File false | Environment true | `published=true`, 1 PutObject |
| File true | Environment false | `published=false`, 0 PutObject |
| No exported variable | Literal .env true | `published=true`, 1 PutObject |
| No exported variable | Literal .env false | `published=false`, 0 PutObject |
| Any lower level | Invalid CLI/env/file Boolean or duplicated CLI setting | Status 64 before AWS/Certbot; 0 PutObject |

Both CLI spellings `--upload-no-renewal=true|false` and
`--upload-no-renewal true|false` are exercised. An explicit
`false` always defeats a lower-priority `true`; configuration
is parsed as literal data rather than Bash source.

## Public operation / remote-write truth table

For each applicable `UPLOAD_NO_RENEWAL=false|true` setting:

| Verified public operation | False | True | Certificate side effects |
| --- | --- | --- | --- |
| First issuance from valid account-only S3 state | One PutObject | One PutObject | Exactly one selected `certonly` |
| Unchanged selected renewal check | No PutObject | One PutObject | Named `renew`, no `certonly` |
| Selected due renewal with changed leaf | One PutObject | One PutObject | Named `renew`, changed verified leaf |
| No certificate renewal but changed durable ACME metadata | One PutObject | One PutObject | Named `renew`, unchanged leaf |
| Missing/corrupt S3 state | Nonzero, zero PutObject | Nonzero, zero PutObject | No provider execution |
| Failing Certbot | Nonzero, zero PutObject | Nonzero, zero PutObject | No remote mutation |
| Invalid certificate/lineage after provider | Nonzero, zero PutObject | Nonzero, zero PutObject | Failed candidate never written |
| Rejected PutObject before mock acceptance | Nonzero, uncertain report | Nonzero, uncertain report | The controlled mock keeps old bytes |
| PutObject accepted then response lost | Nonzero, uncertain report | Nonzero, uncertain report | Mock bytes may have changed |

A successful forced no-op is **not** an ACME issuance or
certificate renewal and does not create a new account. Any durable
change must still publish under `false`, and `true` never
authorizes publication of failed or invalid state.

## Single-key and confidentiality invariants

The same literal effective key (default `latest.tar.gz`, or an
operator-provided alternate key) is used for HeadObject, GetObject,
and any authorized PutObject. Forced republishing must not create a
dated, unique, per-run, account-specific or temporary remote object.
All keys and operations are visible in the fake AWS call log and
tested by exact matches; real tar/gzip is used to validate the
selected lineage in the resulting object.

Raw AWS diagnostic text, including a deliberate non-realistic
test secret injected at rejected and uncertain upload boundaries,
must not reach the public response. Static, non-sensitive status
messages distinguish a verified no-op, successful publication, and
failed PutObject without claiming rollback. The last-known-good
mock remote hash is checked on failures that occur *before* any
PutObject request.

The MVP assumes one externally serialized writer per configured S3
key. It provides no remote lock, versioned backup, independent
S3 read-after-write confirmation, or recovery guarantee from a
lost upload reply. Full real-cloud staging belongs to milestone #4.

## Acceptance and closeout

Green build/test/CI on all three generated artifacts, passing Bash
4.3 compatibility, MegaLinter, CodeQL and verified SHA-256
companion files provide task evidence. Task #103 closes only after
its PR is approved and merged; story #90 is independently checked
against its own acceptance criteria afterward, rather than
auto-accepted when the technical issue closes.

No new ADR is needed because this matrix does not change accepted
publication behavior. The tested public contract is defined by
[the publication policy](mvp-upload-no-renewal-policy.md), and
[the focused public integration](mvp-upload-no-renewal-integration.md)
provides additional clean-runner evidence.
