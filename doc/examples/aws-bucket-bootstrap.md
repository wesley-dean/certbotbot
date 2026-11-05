# AWS bucket bootstrap and minimal runtime IAM for certbotbot

**Purpose:** Administrator-operated provisioning reference for approved technical
task [#292](https://github.com/wesley-dean/certbotbot/issues/292) under
[story #284](https://github.com/wesley-dean/certbotbot/issues/284).
No command in this document is invoked by a repository workflow or the
[manual Jenkins example](jenkins.md). The tracked
[base runtime IAM policy](aws-iam-policy.json) is **a template with required
placeholders**, not a deployable policy or an AWS account change.

**Starting point:** The administrator already controls a *public, correctly
delegated* Route53 hosted zone for their real DNS name, but has **no**
dedicated certbotbot bucket, runtime IAM role, initialized current archive or
Let's Encrypt account. `example.com` is reserved documentation text and
must **never** be submitted for a real certificate. The administrator
chooses a private bucket, current object key, AWS region and constrained
runtime identity. This page stops **before** executing `certbotbot register`
or issuing any certificate; the complete walkthrough is task #293.

## Authority and threat boundaries

There are **three separate identities**, with different permissions:

1. **Provisioning administrator (manual):** Already authorized to inspect
   account/zone ownership, create and secure a new S3 bucket, optionally
   configure encryption/versioning/recovery, create or attach IAM permissions,
   and configure trusted credential delivery. These capabilities **must
   not** be granted to the runtime certificate job merely because the
   administrator uses them during setup.
2. **Certbotbot producer/registrar (runtime):** A narrow role/session
   authorized to read and publish **one exact current S3 object**, inspect
   its dedicated bucket and create/remove only expected DNS-01 TXT records
   within **one exact hosted zone**. The base policy does not grant
   `s3:DeleteObject`, `s3:DeleteObjectVersion`, `s3:CreateBucket`,
   `s3:ListBucketVersions`, `iam:*`, `kms:*` or public S3 ACL grants.
   This same role is used first by explicitly selected registration
   and later by ordinary issuance/renewal. Multiple zones or separate
   production/staging archives need independently reviewed expansion.
3. **Downstream read-only consumer:** A different identity with only
   `s3:GetObject` on the **correct current object** (plus applicable
   KMS decrypt if selected). It does not receive S3 PutObject, Route53
   changes, account registration or archive-delete authority.

The base policy has **two unavoidable observable scopes** under the
current integrations. `s3:ListBucket` applies to the selected *bucket*,
rather than only one object, to support the producer's HeadBucket check
and unambiguous missing-key classification. The stock Certbot
`dns-route53` plugin automatically calls `ListHostedZones`, whose IAM
resource is `*`; it does **not** use a certbotbot-provided hosted-zone-ID
argument to skip discovery. Use a **dedicated private bucket** and
tightly scope **writes** to the exact object, **record mutations** to
the exact hosted zone and normalized DNS challenge name. Neither
discovery permission authorizes modification elsewhere. The
`GetChange` wildcard is limited to the Route53 **change resource ARN
type**, not every AWS resource.

Threats explicitly considered include unintended bucket/object writes,
overbroad zone changes, public bucket exposure, credential leakage,
accidental deletion of historical versions, ambiguous 403/404 responses,
failed conditional publication, unauthorized CI triggers, cross-environment
account mixing and hostile or stale S3 object contents. Controls include
separate provisioning and runtime roles, trusted credential delivery,
named IAM resource/condition scopes, S3 Block Public Access,
an existing seeded account archive, the application's private
archive validation, independently reviewed recovery, and one-writer
serialization. A policy alone does **not** protect a compromised
trusted runtime or prevent an authorized role from overwriting its
single object.

## 1. Confirm the actual administrator and zone (manual only)

Choose private values *before* copying any commands. Examples in this
page use visibly invalid `REPLACE_WITH_...` placeholders. Replace
the placeholders and review each command; do not paste this file into
an automated job or run it under the certbotbot production role.

| Placeholder | Administrator-supplied actual value | Handling |
| --- | --- | --- |
| `REPLACE_WITH_AWS_ACCOUNT_ID` | Expected 12-digit AWS account ID | Check actual CLI caller before changes |
| `REPLACE_WITH_ADMIN_PROFILE` | Trusted provisioning-only AWS CLI profile | Never export its keys to Jenkins/CI |
| `REPLACE_WITH_AWS_REGION` | Selected S3 region, e.g. `us-east-2` | Route53 is global; bucket creation is regional |
| `REPLACE_WITH_PRIVATE_BUCKET` | Globally unique, privately controlled S3 bucket name | Must not be an existing unrelated bucket |
| `REPLACE_WITH_CURRENT_KEY.tar.gz` | Exact authoritative object key | E.g. `latest.tar.gz`; this **one key** is all the base role can write |
| `REPLACE_WITH_HOSTED_ZONE_ID` | Existing **public** hosted-zone identifier | No slash or leading `/hostedzone/` in the policy |
| `REPLACE_WITH_LOWERCASE_DOMAIN` | Actual zone-owned lowercase domain | E.g. `service.your-owned-zone.tld` |
| `REPLACE_WITH_RUNTIME_ROLE_ARN` | Reviewed role to which policy will be attached | Trust policy/assumption is administrator-owned |
| `REPLACE_WITH_CONTACT_EMAIL` | Legitimate operator ACME contact | Used only by the later explicit `register` step |

The administrator can establish ownership using:

```bash
# MANUAL administrator shell only; replace every value, then inspect.
ADMIN_PROFILE='REPLACE_WITH_ADMIN_PROFILE'
ACCOUNT_ID='REPLACE_WITH_AWS_ACCOUNT_ID'
REGION='REPLACE_WITH_AWS_REGION'
ZONE_ID='REPLACE_WITH_HOSTED_ZONE_ID'
BUCKET='REPLACE_WITH_PRIVATE_BUCKET'
CURRENT_KEY='REPLACE_WITH_CURRENT_KEY.tar.gz'
DOMAIN='REPLACE_WITH_LOWERCASE_DOMAIN'
CONTACT_EMAIL='REPLACE_WITH_CONTACT_EMAIL'

# Fail closed if any template input is still present.
for entry in "$ADMIN_PROFILE" "$ACCOUNT_ID" "$REGION" "$ZONE_ID" \
  "$BUCKET" "$CURRENT_KEY" "$DOMAIN" "$CONTACT_EMAIL"; do
  case "$entry" in *REPLACE_WITH_*|'') printf '%s\n' \
    'Administrator placeholders are not resolved' >&2; exit 64 ;; esac
done
[[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || exit 64
[[ "$ZONE_ID" =~ ^Z[A-Za-z0-9]+$ ]] || exit 64
[[ "$BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ &&
  "$BUCKET" != *..* ]] || exit 64
[[ "$CURRENT_KEY" == *.tar.gz && "$CURRENT_KEY" != */* ]] || exit 64
[[ "$DOMAIN" =~ ^[a-z0-9.-]+$ && "$DOMAIN" == *.* ]] || exit 64

caller="$(aws --profile "$ADMIN_PROFILE" sts get-caller-identity \
  --query Account --output text)" || exit $?
[[ "$caller" == "$ACCOUNT_ID" ]] || { printf '%s\n' \
  'Wrong AWS administrator account' >&2; exit 65; }

# Inspect public hosted-zone identity, DNS delegation and account ownership.
aws --profile "$ADMIN_PROFILE" route53 get-hosted-zone \
  --id "$ZONE_ID"
# Verify the output is a PUBLIC zone and matches the real delegated domain.
# Use DNS lookups/registrar data separately to verify the actual delegation.
```

The script does **not** issue a certificate or initialize a current
object. Checking the hosted-zone ID alone does not prove that the
domain registrar points public DNS to it. Verify the delegated
nameservers and the specific DNS-01 name independently. A
**private** Route53 hosted zone is not suitable for public Let's Encrypt
DNS-01 validation.

## 2. Create and secure an ordinary private S3 bucket (manual only)

Use a **general purpose bucket**; do not substitute an S3 Express
directory bucket or bucket already holding someone else's objects.
The administrator must possess the appropriate provisioning
permissions independently of the producer role. AWS region selection
has a special case for `us-east-1`: omit the
`--create-bucket-configuration` there.

```bash
# Continue in the administrator shell with verified variables above.
if [[ "$REGION" == us-east-1 ]]; then
  aws --profile "$ADMIN_PROFILE" s3api create-bucket \
    --bucket "$BUCKET" --region "$REGION"
else
  aws --profile "$ADMIN_PROFILE" s3api create-bucket \
    --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration "LocationConstraint=$REGION"
fi

aws --profile "$ADMIN_PROFILE" s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
aws --profile "$ADMIN_PROFILE" s3api get-public-access-block \
  --bucket "$BUCKET"
aws --profile "$ADMIN_PROFILE" s3api get-bucket-location \
  --bucket "$BUCKET"
aws --profile "$ADMIN_PROFILE" s3api get-bucket-ownership-controls \
  --bucket "$BUCKET"
aws --profile "$ADMIN_PROFILE" s3api get-bucket-encryption \
  --bucket "$BUCKET"
aws --profile "$ADMIN_PROFILE" s3api get-bucket-versioning \
  --bucket "$BUCKET"
```

**Verify**, rather than assume, that all four Block Public Access
controls are true; bucket ownership is acceptable (prefer
Bucket owner enforced), and regional/encryption settings are suitable.
Modern general-purpose S3 buckets have server-side encryption by
default; encryption at rest **does not replace** certbotbot's
application-level authenticated archive encryption. If any inspection
call is denied, troubleshoot with the administrator, not by widening
the runtime identity.

**Optional versioning for recovery:** An operator may deliberately
enable versioning **before** initialization:

```bash
# OPTIONAL, administrator only: evaluate cost, version access and recovery.
aws --profile "$ADMIN_PROFILE" s3api put-bucket-versioning \
  --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws --profile "$ADMIN_PROFILE" s3api get-bucket-versioning \
  --bucket "$BUCKET"
```

AWS advises allowing propagation time after first enabling versioning
before writing new objects. Bucket-version access and restoration
need separate authorized administrator/backup permissions; the
runtime example below **cannot** inspect or delete old versions.
An S3 object version or dated backup is *not* a producer fallback
current key. For sensitive private-key content, consider a separately
administered recovery copy, retention/lock policy, disaster-recovery
test, access logging and key rotation according to the organization's
threat model. The account-only current archive does not exist yet.

## 3. Review and instantiate the runtime policy

Read [`aws-iam-policy.json`](aws-iam-policy.json) before using it.
The base JSON uses five statements:

| Runtime capability | IAM action | Scope / why required |
| --- | --- | --- |
| HeadBucket and positive missing-key classification | `s3:ListBucket` | Only `arn:aws:s3:::BUCKET`; **bucket-level** access is required for reliable HeadObject 404 and HeadBucket. It may expose object names within this dedicated bucket |
| HeadObject and GetObject | `s3:GetObject` | Exactly `arn:aws:s3:::BUCKET/CURRENT_KEY`; includes current-object ETag inspection |
| PutObject | `s3:PutObject` | Exactly the same current object; explicit registration uses conditional first write, ordinary producer publishes validated state |
| Discover zones | `route53:ListHostedZones` | `*` (read-only discovery required by the installed Certbot DNS-Route53 plugin) |
| Poll DNS changes | `route53:GetChange` | `arn:aws:route53:::change/*`; status only |
| Create/remove expected DNS-01 TXT | `route53:ChangeResourceRecordSets` | Exact `hostedzone/ZONE_ID` plus TXT-only, UPSERT/DELETE-only, exact normalized `_acme-challenge.DOMAIN` record conditions |

To instantiate, replace **all** placeholders in a **separate private
copy**. Use the exact full current key in the object ARN; it is *not*
an S3 prefix. AWS S3 bucket and object ARNs have no region/account
fields, while Route53 hosted-zone and change ARNs omit account/region
fields. Do not substitute an account-scoped ARN format for those
resources. Save the resulting JSON with restricted permissions, parse
with `jq` or another standards-compliant JSON parser, and review
the exact action and ARN set before attaching it.

**Important plugin compatibility:** The stock Certbot plugin discovers
the closest hosted zone using `ListHostedZones`, then submits DNS-01
TXT changes with `UPSERT` and `DELETE`, and polls their status
through `GetChange`. The example fixes only
`_acme-challenge.DOMAIN`. If the selected SANs contain independent
DNS identities, delegated subdomains or additional unrelated names,
list **every exact normalized challenge name** in the condition and
review **every actual hosted zone** to which the plugin could resolve.
This sample is safe for one straightforward apex/wildcard identity,
**not** an automatically authorized arbitrary multi-SAN fleet.
Do not use a loose `*.DOMAIN` IAM wildcard to approximate all SANs.
Change only after verifying the plugin version and its actual
hosted-zone discovery, record actions and expected TXT name set.

The `ForAllValues:StringEquals` conditions cover **all** changes in
each batch. The `Null=false` checks require the relevant Route53
condition context keys to be present. Record type `TXT` and actions
`UPSERT`/`DELETE` are allowed; the policy does **not** allow
creating/changing A, MX, NS, CAA or other record types, or writing
outside the authorized zone/name. Multi-zone or changed plugin
behavior requires a new threat review, not a silent wildcard.

Attach the instantiated policy **only** to the reviewed runtime role
or a similarly constrained principal via the provisioning administrator.
Role trust and assumption rights are different from the role's
**permissions policy**: restrict the trusted caller (specific Jenkins
agent identity, instance/task execution role, or GitHub OIDC identity
with protected repository/ref/environment claims), session duration,
auditing and permissions boundary **separately**. This JSON has no
`Principal` or `sts:AssumeRole`, because it is an **identity
permissions policy**, not a trust policy or a bucket policy.

AWS IAM is a combination of identity policies, resource policies,
trust, permission boundaries, organizations SCPs and optional KMS
grants. An allowed identity-policy action alone does not prove the
request will succeed. Resolve errors by reviewing the exact
principal, resource ARN, CLI API call and deny decision; do not
add `s3:*` or `route53:*` to make a test green.

## 4. Independently validate authorization before issuance

With the fully substituted JSON locally available under
`/private/reviewed-certbotbot-policy.json`, the **provisioning
administrator** can ask AWS IAM Access Analyzer for policy
validation:

```bash
# OPTIONAL, administrator-owned private path and AWS profile:
aws --profile "$ADMIN_PROFILE" accessanalyzer validate-policy \
  --policy-type IDENTITY_POLICY \
  --policy-document file:///private/reviewed-certbotbot-policy.json
```

Review *all* findings, especially action/resource mismatch, broad
scope and condition warnings. IAM Access Analyzer is a **cloud API**
with its own permissions and availability; this repository neither
calls it in CI nor claims a successful policy validation in an actual
AWS account. Use `aws iam simulate-principal-policy` under
appropriate administrator permissions or a controlled staging role
to check expected allow/deny actions if required. Do not interpret
the simulator as proof that the application, Route53 DNS propagation,
external bucket policy or a real ACME challenge is working.

Before calling `certbotbot register`, verify that the runtime
identity can successfully **head-bucket** the intended bucket,
differentiate **a verified 404 from 403** for the exact current
object, and resolve its hosted zone *without changing live records*
when testing authorization. The explicit registrar may create one
account-only object **only when missing has been positively proved**;
ordinary issuance requires that seeded current archive and never
creates it implicitly. Denied, ambiguous, wrong-account or
wrong-region results must **not** be treated as permission to bootstrap.

Use separate production/staging object keys and ideally separate
runtime roles/policy instances. The policy's exact-object scope must
match the actual `S3_KEY` used at registration and subsequent issue
and renew calls. `S3_KEY_TEMPLATE` can resolve to **different keys
on different dates**; an exact-key role will then refuse new keys.
An operator can pin a finite known set of exact keys under
separate review, but a broad wildcard object-prefix scope is
**not** part of this minimal example.

## 5. Optional permissions: never silently included

The five-statement policy intentionally omits each of these
capabilities. Enabling a related feature requires an explicit
permissions change and a separate risk/rollout review:

| Optional feature / caller | Additional IAM capability | Security consequence |
| --- | --- | --- |
| Creating/configuring S3 bucket (administrator) | `s3:CreateBucket`, `s3:PutBucketPublicAccessBlock`, `s3:PutBucketVersioning`, plus administrator read/ownership controls | Never grant through the normal producer runtime role |
| IAM role/policy/trust administration (administrator) | Narrow `iam:CreateRole`, `iam:PutRolePolicy`, `iam:PassRole` or chosen managed-policy attachment, depending on reviewed workflow | Can expand credential authority and must be separately protected |
| Explicit SSE-KMS for stored S3 objects (runtime) | KMS `GenerateDataKey` for writes and `Decrypt` for reads scoped to the exact key and authorized S3 encryption context/grants | Requires chosen regional KMS key, key policy, possible cross-account permissions and provider compatibility verification |
| Dated backup publication (producer) | `s3:GetObject`, `s3:PutObject` for each **exact eligible** dated backup key, or carefully bounded managed-key set | Optional extra PutObject/HeadObject; no backup delete in this mode |
| Managed dated-backup retention (producer) | `s3:ListBucket` with relevant prefix behavior plus `s3:DeleteObject` only on matching managed backup keys | Destructive, conditionally deletes **current versions** of managed copies; never authorize delete on current key or `s3:DeleteObjectVersion` as an accidental side effect |
| Version history recovery (administrator/backup role) | `s3:GetObjectVersion`, `s3:ListBucketVersions` and separately reviewed restore/put authority | Version enumeration/recovery is intentionally not a producer capability |
| Read-only client (separate consumer) | `s3:GetObject` for one exact current key, plus required KMS Decrypt if configured | No S3 PutObject, zone changes, or ability to read unrelated archives |
| Multiple independently managed zones/SANs | Explicit additional hosted-zone ARNs and normalized exact TXT challenge names | Current example does not silently grant broad zone changes |
| Distinct production/staging accounts | Separate exact S3 keys and corresponding access profiles/policies | Account metadata and CA selection must never cross environment |

Object retention logic calls S3 `ListObjectsV2` with a
**validated prefix**, then `HeadObject` on each eligible managed
backup, then conditional `DeleteObject` **only** after validation
and successful current/backup publication. The base bucket-level
`ListBucket` already covers listing, but optional retention's
destructive object authority remains absent. Never add
`s3:DeleteObject` on `arn:aws:s3:::BUCKET/*` merely to match
the listing scope.

## 6. Source verification and limits

This authorization inventory comes from the current actual repo
adapters: [S3 fetch](../../lib/s3.bash) uses `head-object`,
`head-bucket`, `get-object`;
[registration](../../lib/register.bash) uses conditional
`put-object`; [publisher](../../lib/publish.bash) uses one current
`put-object`; [optional dated backups](../../lib/backup.bash)
add managed `head-object` and conditional `put-object`;
[opt-in retention](../../lib/retention.bash) adds
`list-objects-v2`, managed `head-object` and conditional
`delete-object`. The separate [read-only client](../client-retrieval.md)
is not part of the producer role. [ADR-020](../adr/ADR-020-one-selected-certificate-and-one-durable-archive.md),
[ADR-033](../adr/ADR-033-conditional-dated-backup-publication.md),
[ADR-034](../adr/ADR-034-safe-retention-of-managed-dated-backups.md)
and [ADR-041](../adr/ADR-041-explicit-acme-account-registration-and-state-initialization.md)
govern the corresponding operations.

Authoritative external verification sources, **reviewed for this
documentation**, are:

- [Certbot DNS Route53 plugin IAM guidance](https://certbot-dns-route53.readthedocs.io/en/stable/)
- [AWS Route53 IAM action/resource types](https://docs.aws.amazon.com/service-authorization/latest/reference/list_route53.html)
- [AWS Route53 normalized record/action/type conditions](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/specifying-conditions-route53.html)
- [AWS HeadObject behavior and 403 versus 404 classification](https://docs.aws.amazon.com/AmazonS3/latest/API/API_HeadObject.html)
- [AWS S3 bucket/object ARN distinctions](https://docs.aws.amazon.com/AmazonS3/latest/userguide/security_iam_service-with-iam.html)
- [AWS CLI regional bucket creation](https://docs.aws.amazon.com/cli/latest/reference/s3api/create-bucket.html)
- [AWS Block Public Access](https://docs.aws.amazon.com/cli/latest/reference/s3api/put-public-access-block.html)
- [AWS S3 bucket versioning and propagation caution](https://docs.aws.amazon.com/cli/latest/reference/s3api/put-bucket-versioning.html)
- [AWS IAM Access Analyzer policy validation](https://docs.aws.amazon.com/IAM/latest/UserGuide/access-analyzer-policy-validation.html)

The repository's [offline IAM policy regression tests](../../tests/aws-iam-policy.bats)
verify structural JSON, exact allowlist, scoped resource patterns,
challenge-only conditions, and explicit absence of destructive or
provisioning authority. **They do not call AWS or Certbot** and cannot
prove an actual runtime caller, organization deny, KMS key grant,
DNS delegation, public challenge propagation, AWS policy validity
against a live analyzer, or real Let's Encrypt issuance.
The administrator remains responsible for replacing every placeholder,
reviewing policy semantics, securely provisioning resources and credentials,
and testing the actual staging integration before production rollout.
