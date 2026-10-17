# ADR-056: Offline Least-Privilege IAM Documents for Authorized Real Staging

Date: 2026-10-17

## Status

Accepted

## Decision

Provide a maintained, **offline**, Bash-only policy document generator at
`scripts/staging-iam-policies.bash` for the separately operator-authorized
six-runner real Let's Encrypt staging evidence workflow (ADR-044/053/055).
It generates one document per invocation on STDOUT:

1. `--document trust`: a GitHub Actions OIDC role trust policy binding
   the exact, chosen AWS account's OIDC provider, audience
   `sts.amazonaws.com`, and `sub` to one explicit GitHub repository's
   protected `acme-staging` environment.
2. `--document permissions`: a Route53 permissions policy for exactly
   one specified public hosted zone, allowing DNS changes **only**
   for the three staging challenge TXT record names:
   `_acme-challenge.<domain>`, `_acme-challenge.<extra_name>`,
   and `_acme-challenge.<second_name>`. The `domain` and second
   lineage's wildcard use the same DNS-01 challenge record name.
   Only CREATE, UPSERT, DELETE and TXT record mutations are accepted,
   with explicit ForAllValues and non-null IAM conditions. The pinned
   Certbot Route53 authenticator additionally needs read-only
   `route53:ListHostedZones` on `*` and `route53:GetChange` for Route53
   change IDs. These read/list permissions must not extend into
   any write permission for another hosted zone.

The generator is **only a document renderer**. It MUST NOT use AWS
credentials, contact AWS/GitHub, create/change roles, install GitHub
workflows, create DNS records, read secret stores, or dispatch real
staging. The operator reviews the output, creates the narrowly scoped
role with appropriately privileged tools, configures the protected
environment and trusted staging CA, and explicitly installs/dispatches
the separately governed inactive workflow (Issue #46).

The generator validates *every* parameter, even for a trust-only
document, before producing any stdout. Inputs include the exactly
12-digit AWS account identifier, canonical `owner/repo` GitHub
repository identity, Route53 hosted-zone identifier (no `/hostedzone/`
prefix), lower-case concrete base name, and two distinct lower-case
concrete subdomains strictly below that base. It rejects shell
metacharacters, glob patterns, credentials, newlines, unknown options,
duplicate names, or invalid DNS labels. No JSON output may be produced
for an invalid request. The generator emits no transient files and
uses fixed static JSON syntax with only grammar-validated ASCII
interpolations.

The generated trust policy pins the protected GitHub environment,
not the specific installed workflow filename. GitHub's default OIDC
`sub` for environment jobs has the structure
`repo:<owner>/<repo>:environment:acme-staging`. The operator MUST
configure environment protections (approval reviewers and deployment
branch restriction to trusted main) **before** creating or using the
AWS trust relationship. AWS validates the OIDC provider and audience;
the generator does not install or verify an OIDC provider in the
account, an IAM role, an environment, or a GitHub workflow.

The generated Route53 policy is **an allow policy**, not a guarantee
against grants from other policies attached to the same role. For
least privilege, the operator must ensure the staging role has no
other policies, permission boundary escape, or trusted principal
outside the reviewed environment. The chosen public hosted zone must
actually contain the three selected names and the operator must have
authority to place TXT records there. A DNS suffix and a hosted-zone
ID supplied by an operator are not independent proof of ownership.

## Context

ADR-044 reserves genuine staging credentials, protected environment
review, and manually installed workflow dispatch for the actual
portability gate. ADR-053 and ADR-055 require two separate lineages,
including an apex-plus-wildcard second lineage, under one staging
account. All six staging jobs are now prepared, but the user must
still configure a narrow OIDC role and environment before any genuine
run can occur.

Issue #46 centralizes this setup, but a hand-authored IAM role is
easy to overprivilege or mistype. IAM conditions for Route53 records
are multi-value comparisons, and DNS record names must be normalized.
The recommended least-privilege policy can be assembled reproducibly
without access to AWS credentials or DNS. This removes manual policy
drafting, **not** the explicit operator consent requirement.

The official Route53 plugin documents the need to list hosted zones,
poll changes, and change record sets. AWS documents
`route53:ChangeResourceRecordSetsNormalizedRecordNames`,
`route53:ChangeResourceRecordSetsRecordTypes`, and
`route53:ChangeResourceRecordSetsActions` as condition keys for
per-name, per-type, per-action restrictions. This policy explicitly
uses all three.

## Trust assumptions and constraints

- This helper is run on a trusted workstation or CI environment,
  with no inherited AWS authority required or consumed.
- The operator owns and has externally checked a **public** Route53
  hosted zone for all three staging names. No account-wide DNS
  administrator permission is acceptable.
- The GitHub repository is a reviewed, trusted location with a
  protected main branch. The environment's reviewer and branch
  controls are separately enforced by GitHub.
- The AWS account has its trusted GitHub Actions OIDC identity
  provider installed. The policy generator does not install one.
- The same challenge TXT owner can serve apex and wildcard
  validation; distinct lineages use independent selected names.
- Static JSON generation using fixed syntax and narrowly validated
  interpolation does not introduce a dependency on Python, jq,
  cloud SDKs, templating engines, or user-supplied JSON.
- No generated policy is automatically granted to a pull request.
  Production certificate issuance stays status 69.

## Alternatives considered

**Create role/environment and install the workflow automatically:**
rejected. This would make a code-generation tool an AWS/GitHub
administrator, bypass the deliberate operator installation decision,
and potentially expand the exposure of high-impact credentials.

**Embed a wide Route53 zone-admin sample policy:** rejected because
a dedicated test environment does not warrant changing arbitrary
records in the selected zone.

**Use static AWS keys in Actions:** rejected because long-lived
credentials are incompatible with the protected OIDC model
established by ADR-044.

**Limit only the hosted-zone ARN:** rejected because that still
permits changing unrelated record names and record types in the
staging zone.

**Depend on arbitrary external JSON generation binaries:** rejected
because finite validated inputs can be safely interpolated into
an audited fixed JSON structure. Tests use Python as a *development*
parser only, never as a runtime requirement.

**Avoid the generator and ask the operator to build IAM JSON by hand:**
rejected because it creates avoidable review friction and increases
opportunity for permission scope mistakes.

**Pin specific workflow path in OIDC:** not selected here because the
default GitHub OIDC subject identifies the protected environment.
A future custom OIDC claim template would require explicit operator
configuration and separate validation before it could be safely
included as a required condition.

## Consequences and verification

Tests must verify valid JSON shape and precise actions, allowed
hosted-zone IDs, normal-form TXT records, exact environment OIDC
subject, and absence of any other write action. They must reject
unknown options, missing parameters, malformed DNS names,
unrelated names, duplicate names, malformed accounts/zones,
and invalid repository identities before any JSON output.

The output remains advisory until installed by an authorized
operator. AWS policy simulation and an actual approved staging
run still must confirm the intended Route53 authenticator call
permissions. Errors in policy semantics will block real staging;
they must not be "fixed" by broadening the role to DNS admin.
The review must compare logs and upstream documented API calls.

No active import decision, new public issuer, additional
cloud-credential access, or production S3 write is authorized.
The exact external dependencies remain tracked in Issue #46.

## Related decisions

ADR-015 governs dependency authority; ADR-018 the certificate
SAN contract; ADR-022 external writer serialization; ADR-025
Certbot Route53 arguments; ADR-030 staging separation;
ADR-037 active import prohibition; ADR-044 operator authorization;
ADR-053/055 genuine dual-lineage portability.
