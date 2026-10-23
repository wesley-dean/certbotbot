# Multi-SAN Selected-Lineage Acceptance Matrix

Status: task #46 verification scope. Parent story #15; design ADR-029,
implementation task #45. This document records the acceptance evidence
required for additional SANs on **one certificate**, including unrelated
DNS zones. It does not authorize or demonstrate multiple independent
certificate lineages in one archive (story #56).

## Evidence Mapping

The public executable tests in `tests/public-lifecycle.bats` use the real
three released artifact flavors through `make test`/`make test-report`.
The fixture uses actual local OpenSSL, GNU tar and gzip, but controlled
`aws` and `certbot` executables. The mock issues parseable, locally signed
certificates and records its invoked flags; it does not call Route53,
Let's Encrypt, S3 or live account registration.

| Contract | Bats evidence |
| --- | --- |
| Unrelated-zone names on one certificate | Exact `-d` argument set, issued leaf check, one selected renewal file and one PutObject |
| Complement per explicit name and global deduplication | Mixed wildcard/ordinary, repeated and uppercase names; no recursive wildcard expansion |
| `INCLUDE_SUBDOMAINS=false` | No derived apex/wildcard and exact literal desired SANs |
| CLI/environment/literal-file precedence | CLI collection replaces exported and file lists; exported list replaces file, including an explicit empty value; file-only list |
| Stable lineage and account across runners | Five distinct private runner roots, issue/renew-no-op/add/remove/renew-no-op sequence, unchanged account bytes and single preserved lineage |
| Ordinary due renewal | Existing unrelated SANs retained through renewed leaf publication |
| Stable name when new shortest SAN changes | Implicit mismatch fails before provider; explicit established name permits change |
| Forced unchanged publication | Selected no-op with `UPLOAD_NO_RENEWAL=true` results in one same-key put |
| Reject invalid configuration | Bad DNS names, comma-separated CLI token and empty comma-file element fail before AWS or Certbot |
| Failed SAN update | Certbot failure cannot publish, last remote bytes preserved in mock |
| Successful but wrong certificate | Certbot success with unexpected SANs is rejected before PutObject |
| Malformed restored leaf extension | Non-DNS SAN fails before Certbot and PutObject, mock remote bytes unchanged |

The existing focused tests in `tests/config-identity.bats`,
`tests/certbot-provider.bats`, `tests/selected-renewal.bats` and
`tests/san-reconciliation.bats` remain complementary coverage for
input caps, malicious values, account preflight and provider dispatch.

## Execution and Limits

Required review evidence is the **final PR head SHA** with passing
`make check`, `make test`, all three release artifact flavors,
Bash 4.3 compatibility and applicable CI checks. The task is not
complete until those gates and human review/merge have passed.

Failures before PutObject are asserted to leave the controlled remote
bytes unchanged. A real failed/interrupted PutObject may already have
reached S3; this suite **does not guarantee remote rollback**. Live
ACME/Route53/S3 interoperability belongs to separately authorized
end-to-end acceptance, not to these mock tests. No concurrent writer
or multi-lineage behavior is asserted. Production operator guides and
runbooks are deferred to Milestone #13.
