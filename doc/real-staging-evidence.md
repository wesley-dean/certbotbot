# Real Let's Encrypt staging portability evidence

This runbook covers the **optional integration example and harness**, not
normal certbotbot usage. Production certificate issuance and S3 publication
remain disabled.
See [ADR-044](adr/ADR-044-opt-in-real-acme-portability-evidence.md)
and the existing [active-import restriction](adr/ADR-037-gated-active-certbot-import.md).

## Inactive example versus installed workflow

The GitHub Actions workflow is stored as an **inactive example** at
`examples/github-actions/real-staging-evidence.yml`. GitHub Actions
registers executable repository workflows from `.github/workflows/`,
not from `examples/`. The certbotbot repository therefore ships no
installed staging workflow: merging a PR containing the example does
not create an Actions entry, enable manual dispatch, or run Certbot.

The actual integration harness remains at
`tests/integration/live-staging-portability.bash`. Normal Bats tests
exercise its authorization guards without staging credentials,
Route53 access, or ACME network operations.

To collect real evidence, an authorized operator must explicitly choose
a controlled GitHub repository containing the matching certbotbot
source and build scripts, review the example and staging privileges,
then copy the example YAML into that repository's
`.github/workflows/real-staging-evidence.yml` on a reviewed trusted
branch. Installing it is a separate operational choice, **not** part
of the certbotbot build or release. Configure environment reviewers
and secrets before dispatching it. After the evidence run, remove
the installed workflow if continuous availability is not intended.

Once intentionally installed, the workflow has only a
`workflow_dispatch` trigger, checks the trusted `main` branch, and
requires an explicit `authorize` checkbox. Its jobs use separate
GitHub-hosted runners and never automatically run on ordinary PRs.

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

## Manual run after deliberate installation

Only after the example has been copied into a controlled repository's
active `.github/workflows/` directory, open **Actions → Example -
opt-in real ACME staging portability evidence → Run workflow**.
Select `main` and supply:

- `domain`: a lower-case, owned apex/base name, such as
  `example.your-controlled-zone.test`, whose apex and wildcard
  records are within the Route53 role's permitted zone.
- `extra_name`: a different lower-case, non-wildcard DNS name
  strictly below that base, such as
  `proof.example.your-controlled-zone.test`.
- `second_name`: a distinct, previously unused, lower-case concrete
  subdomain beneath `domain` (for example, `second.example.your-controlled-zone.test`).
  Both the second name and its `*.` wildcard are requested in its new
  certificate, so explicitly authorize its DNS-01 TXT challenge records.
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

Certbot also writes informational `README` files beneath the live
certificate directories. The staging export omits those README entries
before packaging its portable domain archive because they are not part
of certbotbot's approved archive schema. The strict archive validator
still rejects any other unexpected member; no wider file-policy
exception or active-import permission is introduced.

The archived common account and TLS private keys move only as
`.tar.gz.enc` artifact bodies. No plaintext archive, Certbot log,
AWS environment file, or passphrase is included in an uploaded
artifact. Artifact retention is one day, but admins should also review
repository artifact access, organization policy, logs, and backups.
Job outputs contain only SHA-256 fingerprints used for comparison.
No job modifies S3, even under the staging prefix.

## Expected evidence and possible incompatibilities

An explicitly installed and authorized run is useful evidence of real
account key continuity only if every stage succeeds: independent no-op
renewal, changed SAN issuance under
the same account, encrypted archive handoff, and final independent
restoration. Inspect **all six** job results rather than treating an intermediate
success as conclusive. The fifth runner issues the independent
base-plus-wildcard second lineage; the sixth verifies both restored
lineages without a DNS role.

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


## Additional real two-lineage evidence (ADR-053)

The inactive example now accepts a third independently owned DNS name via
`second_name`, distinct from both `domain` and `extra_name` and a concrete,
lower-case subdomain within the same authorized DNS zone. Do not use a
production customer name. The role must allow only the expected staging
`_acme-challenge` TXT records, including both the second base name
and its wildcard challenge (which can use the same DNS-01 TXT owner
name), and must not allow unrelated hosted zones or record types.

After the original four successful staging jobs, the fifth fresh runner
downloads their encrypted account/first-lineage archive and obtains
a **second independent lineage** under the same staging ACME account.
The script verifies that the previously issued base/wildcard/extra-SAN
certificate is unchanged, verifies the new certificate has exactly the `second_name` and
`*.second_name` SANs, as required by ADR-018 and ADR-055, and matches
the explicitly provided staging CA bundle,
then exports three independently encrypted validated objects:
`common.tar.gz.enc`, `domain.tar.gz.enc`, and `second.tar.gz.enc`.
The per-domain archive validator must reject any accidental inclusion
of files from the other lineage.

The sixth runner receives those three ciphertext files only. It receives
**no Route53/AWS OIDC role or Certbot executable from the workflow**.
After decryption in a new owner-private filesystem, it runs
`certbotbot_import_candidate_prepare` to validate and assemble both
lineages together under the original common account. The candidate
**remains inactive** and is never installed into a Certbot configuration
or used for issuance. Both certificates receive exact SAN, key, chain,
and combined-PEM validation, and SHA-256 comparisons against earlier
independent-runner account and leaf identities. A successful stage
prints no credential or private-key content.

The final evidence review now requires **all six jobs** to succeed;
success on the original four remains insufficient for ADR-037's
two-lineage requirement. The same explicit, protected environment
approval and short artifact retention are mandatory. Genuine AWS S3
production interoperability, independently enforced external writer
serialization, and a separately accepted failure-atomic activation
decision remain outstanding after any successful real staging run.


## Generate narrow IAM policies without cloud credentials (ADR-056)

The checked-in `scripts/staging-iam-policies.bash` prints two standalone,
reviewable JSON documents. Replace these **illustrative** values with
your own AWS account, public staging hosted zone, and owned names:

```bash
for doc in trust permissions; do
  bash scripts/staging-iam-policies.bash \
    --document "$doc" \
    --account-id 123456789012 \
    --repository wesley-dean/certbotbot \
    --zone-id Z12345ABCDE \
    --domain staging.example.org \
    --extra-name proof.staging.example.org \
    --second-name second.staging.example.org >"staging-$doc.json"
done
```

The trust output binds the chosen GitHub repository's protected
`acme-staging` environment and OIDC audience. The permissions output
allows changes only to three exact `_acme-challenge` TXT owners in the
selected zone, with only CREATE/UPSERT/DELETE; listing hosted zones
and polling DNS change status are separately read-only. Apex and
wildcard DNS-01 validation share the same challenge record owner.

The generator **never** calls GitHub or AWS. The operator must install
the OIDC identity provider and IAM role, confirm this public hosted
zone actually owns the names, check no other policies grant broader
permissions, configure environment reviewers and main-only deployment,
and supply the four environment settings listed above. The inactive
example is installed and dispatched **only after explicit consent**.
Failure to perform a DNS operation should be investigated against
the pinned plugin's documented actions, not "fixed" by enabling broad
zone administration.

Policy references: [AWS Route53 record conditions](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/specifying-conditions-route53.html)
and [Certbot Route53 plugin permissions](https://certbot-dns-route53.readthedocs.io/en/stable/).
