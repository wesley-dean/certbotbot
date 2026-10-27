# Explicit ACME Account Registration Contract

**Status:** Accepted design under milestone #7 task #57, implemented
under task #58, with task #59 providing black-box mocked cross-runner
continuity and failure verification.  See
[the mocked-evidence boundary](acme-registration-mock-evidence.md).
Neither the document nor mocked evidence establishes live ACME
interoperability.  Governed by
[ADR-041](adr/ADR-041-explicit-acme-account-registration-and-state-initialization.md).

## Purpose and Scope

`certbotbot register` explicitly creates or reuses one supported
Let's Encrypt ACME account and persists the complete Certbot registration
state into the configured S3 archive.  It **never** issues a certificate.
Ordinary `certbotbot [options] DNS_NAME` still requires an existing
suitable production account and never attempts account registration.

There is one current S3 object for each invocation.  An account-only
archive contains the same relative Certbot configuration bytes used by
later certificate operations.  Registration must not use the host's
existing `/etc/letsencrypt` state as fallback.  It may initialize a
positively absent object; ordinary issuance may not.

This contract does not authorize a third-party CA, account deletion,
certificate issuance, new cloud resources, extra S3 keys, unrequested
backup cleanup, or automatic registration during renewal.

## Proposed CLI

```text
certbotbot register [registration options]
certbotbot [issuance options] DNS_NAME
```

`register` is a first-argument subcommand and does not consume a DNS
positional operand.  Registration-specific options require a value,
accept both `--name VALUE` and `--name=VALUE`, and may occur in any
order after `register`.  Unknown, duplicated scalar, empty and
mode-incompatible options return 64 before any remote operation.

| CLI | Environment / literal `.env` | Default | Registration behavior |
| --- | --- | --- | --- |
| `--email ADDRESS` | `EMAIL` | None | Required nonempty recovery/contact email passed via Certbot `--email` |
| `--agree-tos true\|false` | `AGREE_TOS` | `false` | Registration only if effectively `true` |
| `--eff-email-signup true\|false` | `EFF_EMAIL_SIGNUP` | `true` | `true` passes `--eff-email`; `false` passes `--no-eff-email` |
| `--acme-environment production\|staging` | `ACME_ENVIRONMENT` | `production` | Chooses one of the two supported Let's Encrypt directory URLs |
| `--s3-bucket BUCKET` | `S3_BUCKET` | None | Required existing authorized bucket |
| `--s3-key KEY` | `S3_KEY` | `latest.tar.gz` | Exact authoritative object key |
| `--s3-key-template TEMPLATE` | `S3_KEY_TEMPLATE` | None | Existing template rendering rules, mutually exclusive with literal key at the winning tier |
| `--archive-encryption MODE` | `ARCHIVE_ENCRYPTION` | `auto` | Reuse established plaintext or authenticated GPG policy without downgrades |
| `--config FILE` | CLI only | `./.env` if present | Select strict literal, non-evaluated configuration data |

As with ordinary producer configuration, precedence is **CLI > explicitly
exported environment > selected literal `.env` > built-in defaults**.
A higher-priority malformed value fails; it never falls back.  The
registrar must allow only keys relevant to registration in its selected
configuration file, or explicitly document a compatible common
configuration with strict rejection of irrelevant active settings.
Secrets follow existing environment-only GPG policy; neither the email
nor any key material is printed in ordinary output.

The supported CA mapping is exact:

| `ACME_ENVIRONMENT` | Certbot `--server` | Durable account directory |
| --- | --- | --- |
| `production` | `https://acme-v02.api.letsencrypt.org/directory` | `accounts/acme-v02.api.letsencrypt.org/directory/<id>/` |
| `staging` | `https://acme-staging-v02.api.letsencrypt.org/directory` | `accounts/acme-staging-v02.api.letsencrypt.org/directory/<id>/` |

No arbitrary URL, `--staging` synonym, hidden fallback, or automatic
environment selection based on downloaded archive contents is supported.
The operator should use separate S3 keys for staging and production.
Until a separate ADR authorizes CA selection in ordinary issuance, an
account-only **staging** archive is suitable for the **separately selected**
staging issuer under ADR-042 after its implementation and verification;
it remains unsuitable for a production-selected invocation.

## Certbot Invocation

After local input validation, verified archive discovery and private
workspace preparation, first-time registration invokes the installed
Certbot executable with **separate argv tokens**, schematically:

```text
certbot register
  --non-interactive
  --no-directory-hooks
  --config-dir <private-config>
  --work-dir <private-work>
  --logs-dir <private-logs>
  --server <exact-selected-directory-URL>
  --email <selected-email>
  --agree-tos
  --eff-email | --no-eff-email
```

The vertical-bar line means **exactly one** of the two EFF preferences,
not shell syntax.  The implementation must verify whether
`--no-directory-hooks` is valid for its installed Certbot registration
path and remove that flag **only if** registration itself cannot execute
directory hooks; it must never import host-global hook state.
No `certonly`, `run`, `renew`, `--force-renewal`, route53
plugin operation or DNS challenge is part of registration.

Actual external stdout/stderr remain private; the public command
emits bounded nonsecret success/no-op status and static failure messages.
If Certbot succeeds, independently verify that exactly one appropriate
native account identity was created, that its three required private
files exist, and that Certbot can recognize the account.  Do not
fabricate registration JSON.  Refuse unexpected new certificate state.

## State Transition and Publication Matrix

| Remote object | Local validated account | Required behavior | S3 publication |
| --- | --- | --- | --- |
| Positively missing | None | Explicit registration and account-only candidate | Conditional create, `If-None-Match: *` |
| Present, safe accountless archive | None; no unexplained lineages | Register and preserve all allowed existing content | Conditional update tied to observed ETag/generation |
| Present, same CA | Exactly one valid and recognized account | Reuse existing identity; do not silently update contact or preferences | None |
| Present, foreign or competing CA | Any | Reject; never combine CA identities implicitly | None |
| Present, certificates without associated valid account | Missing or ambiguous | Reject rather than reparent existing lineage | None |
| Present, malformed/unreadable/unsafe | Any | Reject before Certbot registration | None |
| Read missing/unauthorized/uncertain | Unknown | Abort; do not classify as new-object permission | None |
| Candidate invalid or Certbot failed | Any | Abort; destroy only invocation-owned local state | None |
| Write condition failed, timed out or returned error | Any | Report failure, remote state potentially uncertain | No automatic retry |

A `head-object` not-found response must be corroborated by the
existing `head-bucket` check (ADR-021).  A detected existing object
must be obtained and validated before changing it.  An existing-object
update requires binding the successful download to a known observed
ETag/version and using the same expectation at publication.  ETags
are used as **S3 concurrency predicates**, never as cryptographic
content digests.  This contract does not provide locks or rollback;
the operator still prevents competing writers.  No blind overwrite
follows a failed conditional request.

Restored account keys, `regr.json`, and `meta.json` must be native
Certbot content under a private, owned configuration root.  The
account-only packaging gate verifies structure, permissions, full
supported archive members and exact account environment.  It cannot
be implemented by bypassing the ordinary archive validator or by
passing dummy certificate material to the existing selected-lineage
packager.  Preserve other complete lineages where a single recognized
matching account governs the whole archive.

## Privacy and Operator Consent

`AGREE_TOS=false` means the user has not authorized agreement with
the ACME subscriber terms.  It must fail even when other inputs
are present.  Explicit `AGREE_TOS=true` does not imply EFF contact
sharing.  `EFF_EMAIL_SIGNUP=true` is the default and actively selects
Certbot `--eff-email` for EFF email signup.  Operators can opt out using
`EFF_EMAIL_SIGNUP=false`, which passes `--no-eff-email`.  Leaving both
EFF switches absent is **not** sufficient for noninteractive execution.
The default EFF preference has no effect until affirmative TOS consent
permits registration.

`--email` is a required contact input even when an existing account
will be reused.  On reuse it does not change the registered contact.
If the existing account's identity or contact is inconsistent with
the requested operation, refuse rather than silently re-registering,
overwriting metadata or claiming the supplied address was installed.
Fail closed when the implementation cannot establish the relevant
identity consistency with trusted Certbot state.

No host-global Certbot directory, unrelated ACME account, archived
hook, credential, private key or ACME registration JSON is a permitted
fallback.  Private data must not appear in stdout/stderr, CI test
fixtures shipped as artifacts, or failed-command diagnostics.

## Mock Acceptance Scope

Tasks #58/#59 should use deterministic mocked AWS CLI and Certbot
processes representing production and staging endpoints.  Use real
GNU tar/gzip, private workspaces, and the **actual generated** development,
ordinary and minified producer executables.  Ensure tests assert:

1. Required email, explicit TOS acceptance, noninteractive execution,
   default-on EFF signup and optional explicit opt-out.
2. Selected CA URL and account-directory identity; staging/production
   isolation without implicit fallback or third-party CA selection.
3. First registration from a positively missing S3 object, canonical
   account-only portable archive and conditional first write.
4. Existing safe account reuse with no duplicate registration or
   unnecessary S3 write, and preservation of other selected and
   unselected state.
5. Refusal of wrong CA, ambiguous/duplicate accounts, malformed archive,
   nonprivate key, incompatible lineage and unsupported metadata.
6. No registration during ordinary issue/renew, even with a missing
   archive, missing account or staging account-only archive.
7. No publication after failed registration, archive validation,
   conditional write mismatch, AWS authorization failure or uncertain
   transport outcome; no secret disclosure.
8. Independent workspace restore and actual account identity
   continuity, with checksums and producer flavor parity.

External Certbot mocks can verify exact argument construction and
account-state handling.  They do **not** establish that real Certbot
recognizes a staging or production registration, nor that S3
conditional behavior or actual ACME network interoperability works.
Milestone #4 records authorized real staging evidence separately.

## Relevant Decisions

- ADR-020/021: Ordinary issuance requires a seeded archive.  Explicit
  registration is the only sanctioned missing-object exception.
- ADR-022/023: Portable Certbot account directories and strict
  production-only ordinary preflight.
- ADR-024/025 as refined by ADR-042: ordinary issuance/renewal remains
  production by default and accepts explicit staging selection;
  never registers.
- ADR-027/028: Selected certificate package/publication gates remain
  mandatory for ordinary issuance, not bypassed for account-only state.
- ADR-030/031: Preserve other valid lineages and never downgrade
  authenticated encryption.
- ADR-041: Registration authorization, CA identity and first-write safety.
