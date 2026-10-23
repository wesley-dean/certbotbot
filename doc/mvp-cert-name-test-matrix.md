# MVP CERT_NAME Public Verification Matrix

Status: testing and documentation evidence for approved task #94 and story #87,
governed by ADR-020, ADR-023, ADR-026 and the
[certificate lineage naming contract](mvp-certificate-naming.md).

## Public command and durable-state evidence

`tests/public-lifecycle.bats` invokes each assembled, release-like executable
with a pre-existing account-only S3 archive. A mock AWS CLI serves exactly
one configured object; the mock Certbot records the selected name, private
config/work/log paths, literal DNS SAN values and bounded named reconciliation
requests. Real OpenSSL signs certificate test fixtures, and real tar/gzip
packages and restores the complete durable account and selected lineage.
All-artifact Bats execution is part of the established Make test workflow.

| Observed scenario | Public acceptance condition |
| --- | --- |
| Apex or wildcard primary name with complementary SAN enabled | Both select shorter `example.com` lineage; one same-key PutObject |
| No explicit `CERT_NAME` | Derive shortest valid selected name rather than using host state |
| CLI `--cert-name=...`, exported `CERT_NAME`, and literal config `CERT_NAME` | CLI wins over environment, environment over file, file over derived default; one exact lineage |
| Invalid explicit name or derived wildcard-only lineage | Status 64 before any AWS or Certbot call; no remote change |
| Wildcard-only certificate SAN with valid explicit non-wildcard lineage | Permit selected issuance, retaining the literal wildcard SAN and same object key |
| Existing lineage, changed complementary SAN policy in either direction | Named `certonly --renew-with-new-domains` on that lineage, same ACME account, verified new SANs, one selected-key publication |
| Existing restored lineage, unchanged SANs | Named `renew`, no reissue, no PutObject on unchanged durable state |
| Existing lineage with a different requested certificate name | Nonzero before Certbot or publication, no silent rename or numeric suffix |
| Existing archive containing an extra `-0001` renewal lineage | Fail closed, no provider or PutObject; authoritative mock archive bytes unchanged |
| Separate runner temp roots with same explicit name | Preserve ACME account and selected certificate lineage; no-op uses no remote write; private workspaces removed |
| Equal-length candidate SANs supplied to the internal selector | ASCII lexically smallest candidate regardless of order in each artifact flavor |

The current MVP has **one primary input DNS name**, and may derive its
single apex/wildcard complement. It cannot expose two independent,
equal-length public SAN candidates. The final row is therefore a
white-box assertion of the internal selector through each assembled
artifact; it is **not** falsely presented as a public multi-SAN interface.

These tests do not contact real S3, Route53, Let's Encrypt or Certbot
infrastructure. They do not prove external account suitability, issuance
and DNS interoperability, real concurrent-writer safety or rollback after
an attempted remote PutObject. Those limitations remain governed by the
MVP threat model and live end-to-end testing milestone.

## Story acceptance boundary

This test matrix adds observable behavior evidence after naming contract
task #92 and integration task #93. Story #87 can be independently
accepted only when the three approved technical tasks have been merged,
their checks passed, and all story acceptance criteria have been confirmed
against the authoritative merged code. Task/PR closure does not itself
authorize acceptance of another story or milestone.
