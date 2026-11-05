I want a certificate for example.com.

# First certificate: from an existing Route53 zone to verified renewal

**This is an operator-run walkthrough, not an executable CI recipe.**
`example.com` is a reserved illustrative domain. **Replace it with a
real domain that you own and control** for any live certificate request.
The AWS bucket, region, account ID, IAM role, hosted-zone ID, contact
address, release digest and credential context in this document are
**not real values** and must be independently reviewed. Do not attempt
to issue a public certificate for the literal `example.com`.

This guide addresses [approved story #284](https://github.com/wesley-dean/certbotbot/issues/284)
and technical task #293. It joins the merged
[source-audited option inventory](producer-option-inventory.md) (#290),
[safe manual Jenkins example](examples/jenkins.md) (#291), and
[administrator-owned AWS bootstrap with an IAM template](examples/aws-bucket-bootstrap.md)
(#292). The operational authority remains with the administrator.
**No commands on this page run in repository tests or workflows.**

## What I start with, and who is allowed to do what

I already control a **correctly delegated, public Route53 hosted zone**
for my DNS domain, with public DNS pointing at its nameservers.
I have an authorized **AWS provisioning administrator** credential
and a real operator contact email. I do **not** yet have:

- A private S3 bucket for certbotbot, or its authoritative current key.
- A dedicated, scoped certificate producer/registrar runtime IAM role.
- A native Certbot ACME account or an account-only seeded S3 archive.
- A first issued certificate, a trusted read-only retrieval environment,
  or an activated renewal job.

The **provisioning administrator** creates/reviews the bucket and role.
The **runtime principal** may read and publish only the approved current
key and perform the restricted Route53 DNS-01 operations. A
**read-only client principal** can retrieve the current key without
S3 write or Route53 permissions. Installation and reload of web
services belong to another operator-controlled process. These are
separate trust boundaries, even when one person operates them.

Certbotbot does **not** create S3 buckets, IAM roles, DNS zones,
registered accounts during ordinary issuance, scheduled Jenkins
jobs, distributed locks, certificate deployments, or service reloads.
Only the **explicit** `certbotbot register` subcommand can initialize
a genuinely missing S3 current object with valid **account-only**
state. Ordinary issuance refuses absent/unsafe state.

## 1. Choose an environment and exactly one authoritative S3 key

For a first exercise, use the **Let's Encrypt staging CA** and a
**separate staging S3 object key**. Staging certificates are **not publicly trusted** by production browsers
and clients; do not deploy them to a production service as if they
were publicly trusted. The ordinary
producer defaults to **production** unless
`--acme-environment staging` is explicitly supplied; registration
also defaults to production. Never allow those defaults to silently
mix account directories.

Choose a real domain and these **manual operator placeholders** in
the same trusted shell session, before running any later command:

```bash
# Illustrative local variables; this block performs NO AWS/ACME operation.
REAL_DOMAIN='REPLACE_WITH_YOUR_DELEGATED_DOMAIN'
S3_BUCKET='REPLACE_WITH_PRIVATE_BUCKET'
AWS_REGION='REPLACE_WITH_AWS_REGION'
HOSTED_ZONE_ID='REPLACE_WITH_HOSTED_ZONE_ID'
CONTACT_EMAIL='REPLACE_WITH_CONTACT_EMAIL'
RUNTIME_PROFILE='REPLACE_WITH_REVIEWED_RUNTIME_PROFILE'
CA_ENVIRONMENT=staging
CURRENT_KEY=staging-current.tar.gz
CERT_NAME="$REAL_DOMAIN"

for value in "$REAL_DOMAIN" "$S3_BUCKET" "$AWS_REGION" \
  "$HOSTED_ZONE_ID" "$CONTACT_EMAIL" "$RUNTIME_PROFILE"; do
  case "$value" in
    *REPLACE_WITH_*|'')
      printf '%s\n' 'Replace and review ALL operator placeholders' >&2
      exit 64
      ;;
  esac
done
[[ "$REAL_DOMAIN" != example.com &&
   "$REAL_DOMAIN" != *.example.com ]] || exit 64
```

For a later **production** rollout, deliberately use
`CA_ENVIRONMENT=production`, a **different**
`CURRENT_KEY=production-current.tar.gz`, a production ACME
registration, and matching separately reviewed permissions.
The example [base IAM template](examples/aws-iam-policy.json) grants
one exact current object, **not both keys**; instantiate and review
distinct role/policy instances or explicit exact-key grants when needed.
A key template changes which object is selected by date, so it
requires a separate IAM scope review. An arbitrary alternate S3 key
is **not** a recovery fallback.

## 2. Provision the bucket and runtime identity (administrator only)

Follow the [manual AWS provisioning guide](examples/aws-bucket-bootstrap.md)
**in its order**, under the separate administrator profile. It covers:

1. Verify the AWS account, public hosted-zone ID and actual DNS
   delegation, not merely the zone's displayed name.
2. Select a Region and **globally unique** private bucket name.
   Create the bucket manually (the `us-east-1` create-bucket request
   differs from other Regions).
3. Enable all four S3 Block Public Access settings, inspect bucket
   ownership and at-rest encryption, and deliberately choose whether
   S3 versioning/recovery controls are needed.
4. Instantiate the
   [tracked five-statement IAM JSON template](examples/aws-iam-policy.json)
   by replacing **every** placeholder in a private copy. The base
   grants bucket-scoped `s3:ListBucket`, exact-key
   `s3:GetObject`/`s3:PutObject`, read-only Route53 hosted-zone
   discovery/change polling, and TXT-only DNS-01 changes in one
   explicitly named zone for the exact normalized
   `_acme-challenge.REAL_DOMAIN` name.
5. Review **role trust/credential delivery separately** from the
   permissions policy. Validate the instantiated JSON using
   AWS IAM Access Analyzer under administrator authority,
   inspect warnings, and explicitly review the actual caller.
   Offline JSON syntax is **not** evidence of effective AWS
   authorization. No real IAM changes are performed by certbotbot.
6. Confirm the intended Route53 plugin version uses the expected
   read/list/change operations. The stock plugin discovers zones;
   the example's TXT-name condition handles one apex/wildcard
   identity and **does not** silently authorize arbitrary additional
   SAN zones. Review any expanded challenge-name/zone set first.

**No runtime policy provisioning permissions:** bucket creation,
`iam:*`, `kms:*`, S3 version listing/deletion, backup-key writes,
and managed retention deletion are **not** in the base policy.
Do not widen it merely to make an error disappear.

On the **trusted runtime machine**, arrange an AWS CLI v2 credential
chain for the newly reviewed runtime role, separately from the
administrator's profile. Configure the chosen Region and verify the
**actual principal** before any privileged operation:

```bash
# OPERATOR-RUN AWS identity read: manually inspect account and assumed role.
export AWS_PROFILE="$RUNTIME_PROFILE"
export AWS_DEFAULT_REGION="$AWS_REGION"
aws sts get-caller-identity
aws s3api head-bucket --bucket "$S3_BUCKET"
```

Do **not** use the provisioning administrator credentials for routine
certificate issuance. An assumed-role caller ARN differs from its IAM
role ARN; compare the account and role/session identity intentionally.
A successful HeadBucket does not prove that the current S3 object
exists or that DNS modification is authorized.

At this stage the selected current object is **expected to be absent**.
An AWS `HeadObject` 403 is not proof of absence: AWS can return 403
rather than 404 when `s3:ListBucket` is missing. The explicit registrar
performs its own fail-closed `HeadObject` and `HeadBucket` checks.
Do not pre-create an empty `tar.gz`, upload a dummy object, or treat
an authorization denial as permission to bootstrap.

## 3. Acquire and independently verify BOTH released executables

On a trusted Linux runner install **Bash 4.3+**, AWS CLI **v2**,
Certbot **with dns-route53**, OpenSSL, GNU tar/gzip, and compatible
GNU userland tools. Producer and read-only client are **distinct
shipped products**. The client needs no Certbot or Route53 permission.
GnuPG **2.4.7+ with working AES-256/OCB** is only needed if an
encrypted archive is deliberately selected.

Use [release-verification.md](release-verification.md) as the
authority for release approval, provenance and attestations.
One release contains `certbotbot.bash`, `certbotbot-client.bash`
and their separate `.sha256` sidecars, alongside the development
and minified producer variants. Review and obtain the two expected
SHA-256 digests **independently** of the downloaded executable and
same-origin checksum before trusting them.

This **offline-verification template** presumes the four files have
already been downloaded from the **same reviewed immutable release**
into a private, trusted, `.env`-free directory:

```bash
# LOCAL ONLY; no AWS, Route53 or ACME requests.
# Operator must supply both independently reviewed digests.
EXPECTED_PRODUCER_SHA256='REPLACE_WITH_REVIEWED_PRODUCER_SHA256'
EXPECTED_CLIENT_SHA256='REPLACE_WITH_REVIEWED_CLIENT_SHA256'
[[ "$EXPECTED_PRODUCER_SHA256" =~ ^[0-9a-f]{64}$ &&
   "$EXPECTED_CLIENT_SHA256" =~ ^[0-9a-f]{64}$ ]] || exit 64
sha256sum --check certbotbot.bash.sha256
sha256sum --check certbotbot-client.bash.sha256
[[ "$(sha256sum certbotbot.bash | awk '{print $1}')" == \
   "$EXPECTED_PRODUCER_SHA256" ]] || exit 65
[[ "$(sha256sum certbotbot-client.bash | awk '{print $1}')" == \
   "$EXPECTED_CLIENT_SHA256" ]] || exit 65
bash -n certbotbot.bash
bash -n certbotbot-client.bash
chmod 0700 certbotbot.bash certbotbot-client.bash
./certbotbot.bash --help
./certbotbot.bash register --help
./certbotbot-client.bash --help
```

Also independently verify the release attestations using the
approved GitHub CLI and release workflow identities before executing
the files; passing `sha256sum --check` alone is insufficient
because the sidecars are acquired from the same source. See the
[operator quick start's pinned-release example](operator-quickstart.md#quick-start-existing-account-and-seeded-archive).
The examples below presume you are now in the trusted directory
containing both verified executables, **not** an arbitrary checkout or
a directory with unreviewed `.env`.

## 4. Register the Let's Encrypt account before issuing anything

First review the actual
[Let's Encrypt subscriber agreement](https://letsencrypt.org/repository/)
and your organization's registration/CA policy. The
`--agree-tos true` choice is affirmative operator consent and
**defaults to false**. `--email` is required for the contact
address; registration does **not** consume a DNS positional name.
`--eff-email-signup` defaults to **true** (opt-in enabled by
default) and may be turned **off** with
`--eff-email-signup false`.

Once the runtime IAM/zone/bucket and selected CA/key are reviewed,
run this **manually** with the explicit staging CA (or deliberately
substitute the matching production CA/key after independent approval):

```bash
# LIVE OPERATOR-ONLY: calls AWS S3 and Let's Encrypt staging ACME.
# Do not invoke in CI, PR validation, or as automatic Jenkins bootstrap.
./certbotbot.bash register \
  --no-env \
  --email "$CONTACT_EMAIL" \
  --agree-tos true \
  --eff-email-signup false \
  --acme-environment "$CA_ENVIRONMENT" \
  --archive-encryption none \
  --s3-bucket "$S3_BUCKET" \
  --s3-key "$CURRENT_KEY"
```

Here the EFF opt-out is **explicit for illustration**. Omit that flag
to use the documented `true` default. The `--no-env` flag ignores
application `.env` and exported application settings but does **not**
erase external AWS credentials, profile, Region or system PATH. No
GPG secret is used for the plaintext first-run example.

The registrar uses an isolated Certbot configuration root, ensures
the selected ACME account is suitable, then publishes account-only
state with a conditional S3 write **only after a positively confirmed
missing current key**. It never runs DNS-01 challenges and does
**not** issue a certificate. Reusing a valid matching account may
produce **no S3 write**. Do not interpret an ambiguous S3 access
error as an opportunity to start over or delete the current object.

After the registrar returns success, **read back the selected S3
metadata** with the runtime read-capable principal:

```bash
# LIVE OPERATOR-ONLY, read-only S3 inspection after registration.
aws s3api head-object --bucket "$S3_BUCKET" --key "$CURRENT_KEY" \
  --query '{Size:ContentLength,ETag:ETag,Modified:LastModified}'
```

A successful HEAD with positive size establishes a readable current
object; it **does not** prove that its bytes are a valid account-only
archive, an approved issuer or an issued certificate. The producer
enforces native account/archive validation when it next retrieves
the object. An independent read-only restore later supplies further
evidence.

## 5. Issue the first certificate into the SAME account archive

Before execution confirm: runtime principal is scoped to the
**exact** `S3_BUCKET` and `CURRENT_KEY`; the ACME environment
is **the same** as registration; `REAL_DOMAIN` is controlled by
the operator; the public Route53 zone is correctly delegated; and
the reviewed Route53 IAM TXT-name condition matches the actual
`_acme-challenge.REAL_DOMAIN` challenge.

The producer/Certbot DNS-Route53 plugin requests DNS-01 TXT record
UPSERT/DELETE and checks propagation through Route53. Certbotbot
does not itself create the zone or install the result.

```bash
# LIVE OPERATOR-ONLY: DNS-01 TXT mutation, ACME issuance, current S3 PUT.
# Staging selected explicitly to match the account-only archive.
./certbotbot.bash \
  --no-env \
  --acme-environment "$CA_ENVIRONMENT" \
  --archive-encryption none \
  --s3-bucket "$S3_BUCKET" \
  --s3-key "$CURRENT_KEY" \
  --cert-name "$CERT_NAME" \
  --include-subdomains true \
  --domain "$REAL_DOMAIN"
```

**Default wildcard behavior:** `INCLUDE_SUBDOMAINS=true` is the
actual producer default. For `example.com`, it requests both
`example.com` and `*.example.com` on **one** stable certificate
lineage. The wildcard covers first-level subdomains under the
standard wildcard rules; it is not a request for every deeper name.
The two requested names use the same base DNS-01 challenge name.
This tutorial selects `true` explicitly to make the intent visible.

**Apex-only alternative (separately chosen first issuance):**
If the administrator wants only the apex name, replace the command's
`--include-subdomains true` with
`--include-subdomains false` **before the initial issuance**.
Do **not** blindly run both commands as if they created two independent
certificates: with a stable `CERT_NAME` that would change the
selected lineage's SAN set and invoke reconciliation.

A completed provider invocation is not sufficient. The producer
must authenticate the original archive, validate the account,
verify the selected certificate/private-key pairing and exact SAN
set, then conditionally publish the full updated archive at the
same selected current key. First issuance changes durable state,
so a successful first issue normally reports
`published=true`; any missing selected account, wrong CA,
malformed certificate or unsuccessful verification fails closed.

## 6. Independently retrieve and examine the archive

Use the **separate** checked-and-approved
`certbotbot-client.bash` with a read-only S3 credential where
possible. It does not need Route53, Certbot, write authority or
ACME registration capability. It validates and extracts the current
archive to a newly **absent** destination beneath an existing
private, owned directory; it neither searches backups nor installs
certificates. This example intentionally creates a **private parent**
but leaves the child destination **absent** before the client runs.

```bash
# LIVE OPERATOR-ONLY: reads the exact current S3 object into private local state.
umask 077
RESTORE_PARENT="$(mktemp -d)" || exit 74
RESTORED="$RESTORE_PARENT/current-state"
[[ ! -e "$RESTORED" && ! -L "$RESTORED" ]] || exit 73
./certbotbot-client.bash \
  --archive-encryption none \
  --s3-bucket "$S3_BUCKET" \
  --s3-key "$CURRENT_KEY" \
  --destination "$RESTORED"
```

Ideally perform this operation under a **separate consumer role**
limited to read access to the exact object; if changing profiles,
verify the principal again before retrieving. Because `S3_BUCKET`
and `S3_KEY` are explicit CLI values, their ordinary configuration
precedence remains deterministic. The client has **no**
`--no-env` flag; run it from the reviewed private directory
without an implicit `.env`, and avoid exported
`GPG_SYMMETRIC_KEY` for the plaintext run.

Once the client reports success, inspect the specific selected
certificate, private key and account state **without printing
private keys or account credentials**:

```bash
# LOCAL ONLY after a successful client restore. Never echo the private key.
CERT="$RESTORED/live/$CERT_NAME/cert.pem"
KEY="$RESTORED/live/$CERT_NAME/privkey.pem"
RENEWAL="$RESTORED/renewal/$CERT_NAME.conf"
[[ -f "$CERT" && -f "$KEY" && -f "$RENEWAL" ]] || exit 65
[[ -d "$RESTORED/accounts" ]] || exit 65
openssl x509 -in "$CERT" -noout -subject -issuer -dates -serial \
  -ext subjectAltName
openssl x509 -in "$CERT" -noout -checkend 0 || exit 65
# Verify matching public keys; no private key material is printed.
openssl x509 -in "$CERT" -pubkey -noout |
  openssl pkey -pubin -outform DER >"$RESTORE_PARENT/cert-public.der"
openssl pkey -in "$KEY" -pubout -outform DER \
  >"$RESTORE_PARENT/key-public.der"
cmp -s "$RESTORE_PARENT/cert-public.der" \
  "$RESTORE_PARENT/key-public.der" || exit 65
```

Independently inspect the SAN extension for **exactly the intended
apex and wildcard** (or only the apex if chosen). Confirm the issuer
and validity period against the selected CA policy. A staging
certificate is **not** publicly trusted even if these structural
checks pass. Public-trust chain validation requires the separately
reviewed production CA context and a real trust store, which this
local inspection does not establish. The account private key is
sensitive; preserve the entire restored state under restrictive
permissions and delete it according to your recovery policy, not
as a public CI artifact.

**Installation is a separate operation.** The administrator decides
which certificate/fullchain/key files to deploy, validates the
specific server's configuration, atomically stages/replaces the
active files according to that service's procedures, tests service
configuration, and reloads/restarts the service. Neither certbotbot
nor its read-only client installs a certificate, changes a web
server, or rolls back a failed deployment. Keep a known-good
previous active certificate until the replacement is serving
correctly.

## 7. After a successful manual run, enable reviewed renewals

Run a second **manually authorized** producer invocation under the
same selected CA, bucket, key, lineage and SAN policy. A successful
renewal check may leave every byte unchanged. With the default
`UPLOAD_NO_RENEWAL=false`, a validated unchanged operation
normally returns success with `published=false` and no S3 PUT.
A verified renewal or changed account/metadata state may publish.
`--upload-no-renewal true` is a deliberate option to republish
an otherwise successful unchanged archive; it is **not** a repair
for unknown remote state.

Only after the operator independently checks registration, issuance,
retrieval and actual service installation should they activate a
reviewed **manual Jenkins job** using the
[Jenkinsfile example](examples/Jenkinsfile) and
[adoption guide](examples/jenkins.md), or a separate protected
[GitHub Actions example](examples/github-actions.md). Both are
inert until independently installed/authorized. They should pin
the exact reviewed release/digest and restrict secrets, AWS role
assumption, trusted branches and credentialed execution. A future
**scheduled job** is an additional explicit decision: choose
a monitored cadence, recovery policy, review controls and one global
writer across **every** job and host writing the same bucket/key.
Per-job Jenkins and workflow concurrency do **not** create a
cross-system distributed lock.

Ordinary selected-only renewal leaves other archived lineages
unchanged. Two **implemented but independently optional** modes
are available in the shipped producer:

- `RENEW_ALL=true` / `--renew-all true` validates every original
  archived lineage and performs bounded due-renewal checks; a
  domainless bulk invocation is permitted **only** when a valid,
  populated archived inventory exists and no selected-only input
  is supplied. Default: `false`. See
  [bulk renewal contract](renew-all-contract.md).
- `REMOVE_ORPHANS=true` / `--remove-orphans true` is
  **destructive**, default `false`. It requires a selected
  identity plus an **independently explicit complete desired
  collection** (`--desired-cert-name` repeated for each lineage to
  **retain**). It removes only validated excluded current-archive
  lineages; it does **not** revoke certificates, remove historical
  backups/S3 versions, or uninstall remote copies. Never derive
  this collection from the SAN list or turn it on for ordinary
  recurring renewal. See
  [orphan removal contract](orphan-removal-contract.md).

The two modes **cannot** be true together. They are not
registration or read-only-client options.

**Optional storage/security changes** require separate readiness:

- `ARCHIVE_ENCRYPTION=auto|none|gpg-ocb` is a source-tier
  selection. The authenticated `gpg-ocb` envelope requires a
  securely delivered high-entropy `GPG_SYMMETRIC_KEY` in the
  **exported environment only**, GnuPG 2.4.7+ with verified OCB
  support, and matching consumer support. A one-time plaintext
  migration requires an **independently recoverable prior backup**
  and both explicit
  `--archive-migration plaintext-to-gpg-ocb` and
  `--archive-migration-backup-confirmed true`.
- `DATED_BACKUP_ENABLED=true` opts into a **second conditional
  S3 object write** after the current object succeeds, with
  separately granted S3 key permissions; default: `false`.
  `BACKUP_RETENTION_COUNT` defaults to `0` and a positive
  value may **delete older managed dated keys** only after the
  appropriate validated publication and retention gates.
  The narrow base IAM template grants **neither** backup-object
  writes nor deletion.
- `S3_KEY_TEMPLATE`, `BACKUP_KEY_TEMPLATE`, additional SAN
  sets, and JSON-vector
  `AWS_EXTRA_ARGS`/`GPG_EXTRA_ARGS`/`CERTBOT_EXTRA_ARGS`
  are supported under the audited
  [configuration reference](configuration-reference.md).
  Evaluate the effective object name and any additional Route53
  challenge names against the **actual** IAM scope before use.
  An explicit `--no-env` suppresses application environment/file
  values, including the only GPG secret, but **not** external AWS
  credentials.

## 8. Fail-closed troubleshooting and recovery

| Symptom | Verify before attempting recovery | Safe next step |
| --- | --- | --- |
| Registration reports no bucket or HeadBucket/HeadObject 403 | Wrong account/profile, Region, bucket, runtime trust, `s3:ListBucket` and exact-key `s3:GetObject` | Reconcile identity/policy; do **not** synthesize missing object or bypass the 403 |
| Selected object truly absent during ordinary issuance | Confirm exact bucket/key and success of prior account-only `register`; distinguish 404 from 403 | Run an **explicit**, authorized registration for a positively absent key; do not let ordinary issuance auto-create an account |
| ACME account/issuer mismatch | Selected `production` vs `staging`, archive account directory, email and current key | Stop and use the correct separately registered CA/key; do not reuse/rename archive state across CAs |
| DNS-01 challenge failure | Actual public NS delegation, TXT challenge owner, plugin zone discovery, TXT IAM record-type/action/name constraints, propagation and CAA policy | Correct DNS/role/plugin configuration and separately retry the planned staging run; no wildcard IAM expansion by default |
| Certificate verification fails or SANs differ | Correct `CERT_NAME`, canonical requested SAN set, account metadata, actual issued certificate and key | Refuse publication/deployment; diagnose selected-lineage or signer error; no silent fallback to another lineage |
| S3 PutObject timeout, partial backup success or nonzero result | Read the **exact current key** independently and compare validated restored state, version history and externally retained recovery copies | Treat remote state as **uncertain**, not rolled back; avoid blind retries or orphan/retention cleanup |
| Read-only client cannot activate destination | Existing path, unsafe/unowned parent, wrong S3 object, encryption mismatch or corrupted archive | Use a new absent child under a safe private parent, match selected key and encryption, preserve old active certificate |
| Expired or untrusted staging certificate | Staging CA is not in public trust stores; check dates, chain context and operator's real production rollout | Never treat staging success as production-trusted deployment; register and issue separately against production when approved |

For recovery, first **stop competing writers**, inspect the
current object without modifying it, and validate any separately
authorized backup/version with the appropriate read-only recovery
identity. No S3 version or dated backup is an implicit fallback key
for the producer/client. Restoration is not the same as reissuing,
revoking or installing a certificate. After determining which exact
validated state is authoritative, arrange a deliberate,
reviewed recovery action. Do not respond to a failed PUT or a
possible partial backup/retention by running destructive cleanup.

## 9. Story #284 reviewer and acceptance crosswalk

This table records where each acceptance group is **addressed**.
Final acceptance still requires normal CI, CODEOWNERS review and
operator-run live evidence for any actual AWS/ACME interoperability
claim; local mocks are not a claim of public certificate issuance.

| Story acceptance section | Maintained evidence and reviewer checklist |
| --- | --- |
| **1. Complete supported-option documentation** | [Option inventory](producer-option-inventory.md), [configuration reference](configuration-reference.md), [registration contract](acme-account-registration-contract.md), and [README](../README.md). Review shipped names, defaults, source tiers/whole collections, registrar-only EFF/TOS/email, actual merged `RENEW_ALL` and `REMOVE_ORPHANS`, migration and provider allowlists |
| **2. Safe Jenkins example** | [Manual Jenkinsfile](examples/Jenkinsfile), [operator guide](examples/jenkins.md), and [offline Jenkins tests](../tests/jenkins-example.bats). Verify quote-safe argv, bounded JSON providers, secret bindings, immutable release pin, no schedule, and no implicit registration |
| **3. From-zero-S3 operator guide** | This exact-opening walkthrough, [manual S3/IAM bootstrap](examples/aws-bucket-bootstrap.md), [IAM JSON](examples/aws-iam-policy.json), [client settings](client-settings.md), and [standalone client examples](examples/certbotbot-client.md). Verify CA/key consistency, manual account initialization, first issuance, readback, private-key handling, installation boundary, and renewal |
| **4. Verification and evidence boundaries** | [IAM offline policy tests](../tests/aws-iam-policy.bats), [Jenkins shell tests](../tests/jenkins-example.bats), [new first-certificate documentation tests](../tests/administrator-first-certificate.bats), [repo testing contract](testing.md), and [release validation](release-verification.md). Verify links/Bash parse without cloud calls and distinguish mocks/local Pebble from live Route53/S3/Let's Encrypt |

**Non-promises:** No live AWS IAM Access Analyzer result, real
Route53 delegation/record modification, real Let's Encrypt staging or
production issuance, actual Jenkins Declarative Pipeline execution,
trusted deployed TLS endpoint, or recovery drill is established by
this documentation PR. The workflow permissions, chosen role's
actual effective access, reviewed release tag, DNS propagation,
and private-key lifecycle must all be checked separately by
the authorized operator.
