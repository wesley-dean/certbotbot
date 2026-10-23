# MVP Public Selected-Certificate Lifecycle

Task #27 connects the previously reviewed component interfaces into one public
command and follows ADR-020 through ADR-028. This document covers the
orchestration boundary, not the subsequent real-service staging acceptance.

## Execution

`certbotbot --s3-bucket BUCKET [--s3-key KEY] DNS_NAME` resolves the existing
literal .env/environment/CLI settings, selects the one lineage, then:

1. Creates one fresh owned, mode-0700 workspace and installs cleanup handlers.
2. Checks the mandatory existing S3 object and downloads its bytes using the
   resolved bucket/key. No missing-object bootstrap or host-account fallback.
3. Validates and restores relative Certbot state into isolated `config/`.
   Requires the single recognized existing production ACME account and
   unambiguous selected lineage.
4. If the lineage is absent, issues exactly that certificate with installed
   Certbot/Route53 and the restored account, then canonicalizes the generated
   renewal paths. If present, checks it with selected-only renewal or approved
   same-apex SAN reconciliation.
5. Requires complete selected lineage and canonical renewal configuration,
   exact requested certificate SANs, parseable leaf/chain, a currently valid
   leaf, a matching certificate/private public key, and a fullchain whose
   first PEM certificate equals the selected leaf.
6. Publishes with the **same bucket/key** using the verified durable-change
   result or explicit UPLOAD_NO_RENEWAL override. No-op without changes or
   override performs no PutObject. Changed state must be published successfully
   or the command fails.
7. Emits a non-secret final selected-lineage/key and `published=true|false`
   message and removes the owned workspace. The EXIT handler retains the
   invocation-owned workspace path at script scope so that cleanup still runs
   after the lifecycle function's local variables have gone out of scope.

All external Certbot, AWS and OpenSSL output is suppressed or handled by
bounded adapters. A failed stage returns a nonzero status without intentionally
starting a later stage, and no success message is printed. Remote state is
**uncertain** after a failed or interrupted PutObject. The command is not an
ACME sandbox, remote certificate chain verifier, distributed lock, or
transaction. Operator-supplied tools and credentials have their normal
authority. The host's `/etc/letsencrypt` is never used as a state fallback.

The issuer and selected-renewal adapters use the production Let's Encrypt
endpoint and **do not register an account**. This remains the existing MVP
contract. All automated lifecycle tests replace Certbot/AWS with controlled
local mocks and use actual local OpenSSL and tar/gzip; they do not establish
real ACME/Route53/S3 interoperability. Milestone #4 governs authorized live
staging evidence.

## Verification

`tests/public-lifecycle.bats` exercises the public executable for seeded
first issuance, a separate restored no-op run, forced republish, missing or
unreadable S3 object, failed Certbot, and failed publication. Every generated
artifact flavor must run the full suite under `make test`. Tests require
OpenSSL for locally generated fixtures; no external credentials are used.

The full cross-runner renewal, metadata-only publication, corrupt-state,
failed-serialization and uncertain-PutObject matrix for task #40 is recorded
in [MVP S3 Roundtrip and Publication Fault Evidence](mvp-s3-roundtrip-validation.md).
