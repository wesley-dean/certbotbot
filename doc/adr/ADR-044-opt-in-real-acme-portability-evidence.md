# ADR-044: Operator-Authorized Real ACME Staging Portability Evidence

Date: 2026-10-16

## Status

Accepted

## Decision

Add a **manual-only, staging-only evidence workflow** to demonstrate the
real account and lineage portability requirements withheld by ADR-037.
The workflow is deliberately separate from the released certbotbot
producer and its disabled issuance entrypoint. It runs only through
`workflow_dispatch`, only from the repository's `main` branch, and
only when the human initiating the job explicitly confirms that real
DNS-01 changes and Let's Encrypt staging requests are authorized.

This decision permits **test-only active Certbot configuration
construction inside short-lived, isolated CI runners** after passing
the existing account/archive identity, renewal-option, and path-preview
validators. It does **not** authorize the product's active import,
normal issuance command, AWS S3 mutation, release workflow, or
production ACME authority.

Each stage uses a newly provisioned GitHub-hosted runner with no
persistent predecessor filesystem:

1. **Runner A: genuine staging issuance.** Pin Certbot and its
   Route53 authenticator to 5.8.0, obtain a staging DNS-01 certificate
   for the exact base and wildcard SAN pair, assemble combined PEMs,
   verify the staging chain against an explicitly configured staging
   CA bundle, and emit the selected common and domain archives.
2. **Runner B: restored account no-op.** Download only the encrypted
   archives exported by A, decrypt them in an owner-private ephemeral
   workspace, apply the existing isolated account/domain validators
   and renewal-path preview, and copy the reviewed state into a
   disposable **test-only** active Certbot root. Run Certbot's
   selected-lineage no-op `renew` operation without AWS credentials,
   verify the leaf has not changed, and export account/domain archives
   with accepted ARI metadata preserved.
3. **Runner C: changed requested SANs.** Restore the encrypted B state
   independently under another private root, verify its account
   identity, and invoke staging Certbot with the same named lineage
   and an explicitly specified additional DNS SAN under the owned
   base domain. Require a different leaf certificate, the same ACME
   account private key, chain/key/combined-PEM checks, and exactly
   the requested new three-name SAN set. Export encrypted archives.
4. **Runner D: fresh, read-only confirmation.** Reconstruct C's
   archives on a fourth independent runner without AWS credentials,
   rerun the strict private validators, and validate the resulting
   certificate's chain, private key, and exact SAN identity. The
   account fingerprint must match A.

The protocol uses **encrypted archive files only** as GitHub Actions
artifacts between jobs. The common archive includes ACME account
private keys and is encrypted just like the domain archive.
`GPG_PASSPHRASE` is sourced only from a protected environment
secret and is never passed as a CLI argument or written to workflow
logs. Each artifact is retained for no more than one day; the
operator must also consider GitHub organization retention policies,
artifact access, and repository backup controls.

The evidence workflow never contacts the production ACME directory.
Its script hardcodes Let's Encrypt's staging ACME URL. The owned
base name and additional SAN are strictly validated to reject
wildcards in the lineage identity, extra names outside the base,
shell metacharacters, and unsupported case or canonical forms.
It never accepts arbitrary Certbot flags or ACME endpoints.

The AWS OIDC role is made available only to runners A and C.
The role's trust policy must restrict GitHub repository, branch,
workflow environment, and expected audience; the IAM policy must
restrict Route53 TXT-record changes to the explicit authorized
hosted zone. Runners B and D have no AWS OIDC permission or
credentials. The workflow's GitHub `acme-staging` environment
should have required reviewers and the required secret/variable
configuration described in the operator runbook.

## Context and why now

Certbotbot's primary product contract requires a previously unseen
Jenkins, GitHub Actions, or EC2 runner to recover the same account
and selected certificate state from portable archives and function
without trusting a predecessor's local filesystem. Synthetic
three-workspace and ARI tests established useful mechanical
portability, but their account JSON never represented a real
registration with Let's Encrypt. ADR-037 deliberately refuses
to activate product import based only on those fixtures.

Further local archive, S3 checkpoint, and publication helper work
cannot independently supply this missing external evidence.
A narrowly consented staging harness directly probes the open
assumptions about Certbot's actual account JSON, renewal configuration,
challenge plugin behavior, no-op ARI changes, and changed-SAN
replacement. It may fail, and that failure is valuable evidence
requiring a reviewed correction rather than a permissive fallback.

## Relationship to ADR-037

ADR-037 prohibits producer activation until evidence is reviewed and
another Accepted ADR governs safe installation. This ADR creates a
limited **integration-test exception**: the staging harness may
copy validated private archives into its own disposable test-only
Certbot config directory solely to produce the very real staging
evidence needed for that decision. It cannot run from the public
issuer or from the build artifacts' production command path.
The harness must not be treated as a reusable general-purpose
import API, and its test-only copy operation may not be moved into
`lib/` or `src/` without a separate accepted product activation
decision. The production ban in ADR-037 remains unchanged.

## Preconditions, assumptions, and constraints

- The operator controls the Route53 hosted zone and both requested
  DNS names. They have permission to create the necessary ACME
  staging TXT challenges and accept staging CA rate limits.
- The operator configures a constrained AWS OIDC role in the
  `acme-staging` GitHub environment and supplies a valid contact
  email, protected GPG secret, and **explicit staging CA trust PEM**.
- The staging CA bundle is an input selected by the operator, never
  opportunistically downloaded from untrusted response data.
- Certbot 5.8.0 and `certbot-dns-route53==5.8.0` remain pinned.
- The GitHub Actions artifact service is trusted to transmit
  ciphertext within this workflow; ciphertext is not proof of
  publisher identity, and encrypted archives remain sensitive.
- No production ACME credentials or long-lived AWS access keys
  are needed or accepted by the workflow.
- The workflow's `concurrency` group serializes only this
  workflow. External Jenkins, EC2, and other independent workflows
  can still modify the same DNS zone; operators must coordinate
  those actors independently.
- Github-hosted jobs are separate machines. The existence of a
  common shared GitHub Actions service does not imply shared
  runner filesystem state.

## Alternatives considered

**Activate the product importer first and see whether it works**
was rejected because ADR-037 explicitly requires prior staging
evidence and failure atomicity.

**Continue expanding synthetic local fixtures** was rejected as
insufficient to prove a real account registration and renewal.

**Run real ACME staging on every pull request** was rejected due
to untrusted code paths, credential exposure, nontrivial DNS
side effects, CA rate limits, and fork-origin ambiguity.

**Transmit plaintext account and TLS private keys via artifacts**
was rejected because collaborator and artifact access would then
expose secrets beyond the immediate runner.

**Use one persistent runner for all phases** was rejected because
it would not test account and renewal portability.

**Give all runners the AWS DNS role** was rejected because the
no-op and final validation stages should demonstrate operation
without DNS mutation authority.

**Store staging state in production S3 keys** was rejected to
preserve ADR-030 environment isolation and ADR-022's publication
safety requirements.

## Threats, mitigations, and residual risks

Assets include the ACME account private key, domain TLS private
keys, scoped AWS role credentials, staging CA trust anchors, and
the DNS zone's integrity. The trust boundaries are workflow
dispatch and authorization, GitHub protected environment approval,
OIDC credential issuance, real ACME/DNS requests, GPG-encrypted
artifact transport, and test-only active Certbot file installation.

The wrapper fails closed on absent consent, missing secrets,
incorrect ACME environment, malformed hostnames, and mismatched
account fingerprints. It captures Certbot stdout/stderr only in
private runner logs and does not upload those logs. Product
issuance still exits status 69.

Residual risks include malicious modifications to workflow
source on `main`, compromise of GitHub-hosted runners or
actions, compromised or overscoped AWS IAM, GitHub artifact
access to ciphertext, exposure of the passphrase to processes
with runner privileges, and staging CA or API availability
changes. Required reviewers, code review, pinned actions,
ephemeral OIDC, short artifact retention, private filesystem
modes, and no fallback to production mitigate but do not
eliminate those risks.

## Verification and acceptance

The normal all-artifact test matrix must exercise a credential-free
guard suite that proves invalid base/SAN inputs, missing consent,
unknown phase, absent encryption credentials, and a multiline
secret cannot reach a fake Certbot executable. No real ACME/DNS
operations occur on regular CI runs.

The manually initiated workflow is expected to produce separate
successful evidence for all four runner stages. A successful A or
B alone is not enough for product import acceptance, nor is
merely merging this workflow evidence that staging continuity
has passed. If any phase fails, preserve only sanitized
diagnostic facts, review the observed real Certbot output
privately, update the relevant ADR/validator, and rerun with
operator consent. Never loosen the renewal allowlist only
because a test fixture was rejected.

Before changing the public issuer, review the evidence for
multiple independently selected lineages, failure-atomic
active import, first-run vs existing-account selection, and
the future crash-safe remote publication/rollback contract.
This ADR alone does not satisfy those broader release gates.

## Related decisions

ADR-018 governs SAN identity, ADR-019 split state, ADR-021 and
ADR-041 encrypted archive handling, ADR-022 serialization,
ADR-025 approved Certbot issuance options, ADR-029 and ADR-036
certificate verification, ADR-030 environment isolation,
ADR-031 and ADR-038 restored identity and renewal grammar,
ADR-032 non-activating path previews, ADR-033 through ADR-035
synthetic Certbot compatibility, ADR-037 active-import gating,
and ADR-042 / ADR-043 publication readiness and recovery.
