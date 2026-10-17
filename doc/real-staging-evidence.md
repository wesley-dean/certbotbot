# Real Let's Encrypt staging portability evidence

This runbook covers the **opt-in integration harness**, not normal certbotbot
usage. Production certificate issuance and S3 publication remain disabled.
See [ADR-044](adr/ADR-044-opt-in-real-acme-portability-evidence.md)
and the existing [active-import restriction](adr/ADR-037-gated-active-certbot-import.md).

## Before you enable the workflow

The workflow `.github/workflows/real-staging-evidence.yml` has only a
`workflow_dispatch` trigger, checks for the `main` branch, and
requires an explicit `authorize` checkbox. Its jobs use separate
GitHub-hosted runners. It is **not** part of PR CI and does not run
automatically when this PR merges.

Choose a dedicated, controlled domain under an AWS Route53 hosted zone
where you explicitly authorize temporary TXT changes for Let's Encrypt
staging DNS-01 challenges. Use a second, previously unused name under
that same base as the SAN-change target. Do not select production
customer zones merely because they are available.

Create a GitHub Actions environment named `acme-staging`. Configure
required reviewers and restrict deployment branches to `main`.
In that environment, configure:

| Setting | Type | Purpose |
| --- | --- | --- |
| `CERTBOTBOT_STAGING_AWS_ROLE_ARN` | Secret | OIDC-assumable role restricted to the authorized Route53 zone |
| `CERTBOTBOT_STAGING_GPG_PASSPHRASE` | Secret | Long, single-line, high-entropy test archive passphrase |
| `CERTBOTBOT_STAGING_CA_PEM` | Secret | Explicit PEM trust bundle for the current Let's Encrypt staging chain |
| `CERTBOTBOT_STAGING_EMAIL` | Variable | Staging ACME account contact email |

The trust bundle must be chosen from the official Let's Encrypt staging
documentation and verified by the operator. The script does not silently
download or trust a substitute root. Keep staging roots distinct from
the system's ordinary production TLS trust store.

The role's GitHub OIDC trust policy must restrict the issuer repository
and the `acme-staging` environment, and should restrict the workflow
to `main`. Use a session policy scoped to the intended hosted zone:
Route53 change actions should permit only authorized `TXT` updates
for the staging DNS-01 name, with read/list permissions as required by
the pinned Route53 authenticator. Do not use an organization-wide
DNS administrator role or static long-lived AWS user keys.

## Manual run

Open **Actions → Opt-in real ACME staging portability evidence →
Run workflow**. Select `main` and supply:

- `domain`: a lower-case, owned apex/base name, such as
  `example.your-controlled-zone.test`, whose apex and wildcard
  records are within the Route53 role's permitted zone.
- `extra_name`: a different lower-case, non-wildcard DNS name
  strictly below that base, such as
  `proof.example.your-controlled-zone.test`.
- `aws_region`: the AWS region used by the scoped OIDC role.
- `authorize`: explicitly set to true after checking DNS ownership
  and the intended external staging requests.

The sample names above are illustrative and should not be treated
as real DNS zones or configured without ownership verification.

Runner A registers or reuses a real staging ACME account and obtains
the base/wildcard certificate. Runner B has **no AWS credentials**:
it restores the encrypted state and checks a no-renewal-needed decision.
Runner C has the scoped role again and requests the added SAN.
Runner D has **no AWS credentials** and validates the independently
restored final archive. Real Certbot and the bundled validators
operate inside private disposable workspaces.

The archived common account and TLS private keys move only as
`.tar.gz.enc` artifact bodies. No plaintext archive, Certbot log,
AWS environment file, or passphrase is included in an uploaded
artifact. Artifact retention is one day, but admins should also review
repository artifact access, organization policy, logs, and backups.
Job outputs contain only SHA-256 fingerprints used for comparison.
No job modifies S3, even under the staging prefix.

## Expected evidence and possible incompatibilities

A complete successful run is useful evidence of real account key
continuity, independent no-op renewal, changed SAN issuance under
the same account, encrypted archive handoff, and final independent
restoration. Inspect the run's four job results rather than treating
an intermediate success as conclusive.

A failure is also useful evidence. The strict renewal-option
allowlist may reject new settings written by real Certbot, or the
archive member policy may expose assumptions that held only for
synthetic tests. Do **not** loosen an allowlist merely to force the
run to pass. Examine sensitive Certbot logs only inside the
ephemeral trusted runner context, record sanitized findings, and
review the relevant ADR and tests before changing policy.

Other possible failures include an incorrect trust bundle, insufficient
Route53 IAM access, absent TXT propagation, staging CA rate limits,
unexpected ARI-triggered renewal in Runner B, or changed Certbot
metadata formats. The harness suppresses raw Certbot stdout/stderr
from ordinary CI logs to reduce accidental key or token disclosure.
It intentionally does not try production ACME as a fallback.

## What successful evidence does not yet authorize

Success does not prove safe multi-object S3 publication, durable
remote rollback after a crashed worker, cross-platform distributed
locking, or two simultaneously selected lineage archives in an active
Certbot configuration. Production activation still requires a
separate Accepted ADR and failure-atomic importer, plus verification
of two coexisting lineages and end-to-end storage recovery under
ADR-037 and ADR-022. The released public executable continues
to exit status 69 for ordinary issuance requests.
