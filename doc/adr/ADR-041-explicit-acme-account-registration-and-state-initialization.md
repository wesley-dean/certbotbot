# ADR-041: Explicit Let's Encrypt Account Registration and Durable Initialization

Date: 2026-10-26

## Status

Accepted

## Decision

Milestone #7 adds an **explicit** `certbotbot register` operation to each of
the three existing standalone producer flavors.  It is a separate public
operation within the existing executable, not an option that ordinary
certificate issuance or renewal may invoke implicitly.  Registration does
not require a DNS name and must never request a certificate, change
selected lineages, install a certificate, or run a renewal operation.

Registration uses the installed Certbot `register` command in a fresh,
owned, mode-0700 workspace, with explicit `--config-dir`,
`--work-dir`, `--logs-dir`, `--non-interactive`, `--server`,
`--email`, `--agree-tos`, and exactly one EFF email preference.
The selected directory is restricted to the two documented Let's Encrypt
ACME v2 endpoints.  Production is the default; staging is an explicit
selection.  The endpoint must be bound to the account's durable directory,
never guessed from an arbitrary directory or account metadata.

A nonempty, syntactically valid contact email and an explicit
`AGREE_TOS=true` are required on every registration invocation.
`AGREE_TOS` defaults to `false`, which **refuses registration**;
consent is opt-in.  `EFF_EMAIL_SIGNUP` defaults to `false`, which
passes Certbot `--no-eff-email` to avoid sharing the address with EFF.
An explicit `true` passes `--eff-email`.  These values never depend on
Certbot's interactive default.  No `--register-unsafely-without-email`
or other bypass of the contact/consent contract is supported.

The operator chooses an existing S3 bucket and one current object key using
the established nonsecret configuration precedence, key validation, and
optional authenticated archive encryption rules.  An explicit registration
may create an **account-only archive** when the exact current object has been
*positively confirmed missing*.  This is a narrow exception to ADR-020/021's
ordinary-issuance seeded-object rule.  The ordinary issuer continues to
require an existing validated archive containing a suitable account.

When the selected object exists, registration must validate and restore the
complete archived Certbot configuration privately before making changes.
An existing, unambiguous, Certbot-recognized account for the selected CA is
**reused without re-registering or rewriting the object**; registration does
not silently change its email address or consent preferences.  Existing
complete certificate lineages and supported auxiliary state are retained
byte-for-byte on a no-op.  If no applicable account exists, creation may
occur only in an otherwise structurally valid, accountless archive with no
certificate lineage whose account association is unknown.  An archive
containing an unsupported CA, competing account, incompatible lineage,
unknown member, unsafe permission, or ambiguous contact/account identity
is rejected, never silently merged or replaced.

The initial implementation supports **one recognized ACME account context
per current archive**.  Registration of a staging account in a production
archive (or the reverse) fails closed, including when that archive contains
unrelated lineages.  Separate selected S3 keys are the supported staging
and production isolation mechanism; managing multiple CA accounts in the
same archive is out of scope.  An unchanged existing valid account is an
idempotent success, not proof that the supplied contact updated it.

New or changed account state is packaged as the same validated portable
gzip tar of the contents of Certbot's configuration directory, containing
the native Certbot-written `accounts/<CA-host>/directory/<id>/` files.
No separate account format, synthesized registration JSON, or private
work/log directory is introduced.  The registration path needs
registration-specific account-only preflight and candidate-packaging
gates; it **must not** weaken the certificate-required producer package
gate from ADR-027 or the selected-lineage publisher from ADR-028.

A verified new candidate is published only to the selected S3 key.  The
first write must be conditional on the object **still not existing**
(`If-None-Match: *`); updates to an existing accountless object must be
conditional on its verified observed generation or ETag
(`If-Match`, with the read bound to that same observation).
Conflicts fail; they do not trigger blind retries or fallback overwrites.
A failed or interrupted PutObject is remotely **uncertain**, never
reported as successful or guaranteed unchanged.  Existing archives
cannot be changed merely because an account registration operation was
requested.  A successful no-op requires no PutObject.

## Context and Decision Drivers

Approved story #55 and technical tasks #57-#59 require a deliberate
account-provisioning operation and persistence that an independent runner
can use.  The current production-only issuer has intentionally required an
existing registered account and a seeded S3 object from the start.
ADR-022 already admits an account-only archive; ADR-023 rejects staging
accounts for ordinary issuance; ADRs 024/025 hardcode the production CA;
ADRs 027/028 require a successfully issued selected lineage before the
normal archive packaging and publication paths may operate.

Registration therefore needs its own public command, consent and authority
contract, and local preparation/publication gates.  Reusing the ordinary
issuer's broad production-only assumptions would either prevent staging
registration or inadvertently authorize staging issuance without the
required CA-bound issuer decision.  Reusing its certificate-required
packager would incorrectly prevent account-only initialization.

Let's Encrypt's production and staging services have separate ACME account
identities.  Certbot documents both explicit EFF email preference switches;
the absence of either can require a prompt, which is unsuitable for the
required noninteractive operation.  An email-sharing preference must not
be inferred from agreement with Let's Encrypt's subscriber terms.

## Public Interface and Compatibility

The command and resolved values are defined in
[the registration contract](../acme-account-registration-contract.md).
The new registration selector is the first positional command word
`register`; existing `--help`/`--version` and ordinary positional
DNS behavior retain their current semantics.  There is no implicit mode
switch based on whether `EMAIL`, an account file, or an archive is present.

Registration-specific flags and variables follow the existing
`CLI > exported environment > selected literal .env > default`
contract.  A malformed or empty higher-tier input must fail rather than
fall back.  Production is the compatibility default; staging is a
deliberate opt-in selection, and arbitrary third-party CA URLs are not
accepted by this milestone.  Registration-specific unknown flags and
ordinary issuance-only domain/lineage flags are rejected.

Plaintext `.tar.gz` is the smallest initial registration scenario.
Where the selected archive is encrypted, existing ADR-031 authenticated
GnuPG handling must be preserved or the command must refuse to operate;
it must not silently downgrade to plaintext.  No encryption-format
migration, backup-retention action, new storage backend, domain
validation, or new cloud resource is authorized by registration.

Production-only issuance/renewal and state preflight remain in place
until a **separately reviewed** CA-bound issuer/staging decision explicitly
refines ADRs 023/024/025.  An account-only staging archive is useful for
milestone-7 verification but is **not currently eligible for ordinary
certificate issuance**.  Milestone #4 must not treat mock evidence or
Certbot's `--dry-run` as proof of a durable staging lifecycle.

## Operational Constraints

- Require an explicit `register` command, valid email, affirmative TOS
  choice, and a bounded CA selection before any Certbot or S3 write.
- Invoke installed Certbot with `register --non-interactive` and private
  directories; pass either `--eff-email` or `--no-eff-email` explicitly.
- Use exact production/staging endpoint identity and strict account-layout
  checks; never register or import an account from the host.
- Preserve all validated preexisting durable content; reject mixed CA,
  competing account identities, unsafe archives, and uncertain reads.
- Positively distinguish missing S3 object from access failure.  Protect
  initial creation and existing-object changes with S3 conditions.
- Validate the **final bytes** before the first attempted PutObject.
  Treat nonzero or interrupted remote write as uncertain.
- Do not permit the registration-specific account-only candidate gate to
  bypass ordinary issuance preflight or selected-lineage packaging rules.
- Keep private keys, registration JSON, contact details, AWS diagnostics,
  and raw subprocess output out of ordinary stdout/stderr and CI artifacts.
- Never introduce real CA/S3/Route53 calls into normal pull-request tests.
  Bats black-box tests use controlled Certbot/AWS process mocks and real
  local tar/gzip, with three-flavor parity and distinct evidence labels.

## Threat Boundaries and Residual Risks

| Boundary or asset | Required behavior | Residual limitation |
| --- | --- | --- |
| Operator contact and consent | Validate inputs; TOS must be affirmative; no EFF sharing by default | The program cannot attest that the operator read the external terms |
| ACME CA selection | Exact two-CA allowlist; isolated account selection; explicit private Certbot paths | Trusted Certbot and its dependencies retain network and filesystem authority |
| Existing S3 bytes | Confirmed identity/absence; bounded extraction; reject unsafe state | S3 and IAM availability are external |
| Account key and metadata | Retain native Certbot files privately; no logged secrets; no synthetic JSON | Host or runtime compromise is not contained by Bash |
| First-write and update authority | Local candidate validation then conditional single-key PutObject | No distributed lock, rollback, or transaction; uncertain failed writes |
| Consumer account reuse | Certbot account recognition, matching CA and no silent updates | A local account probe does not prove live CA recognition |
| CI evidence | No live credentials; mock external CLI boundaries | Mocks cannot establish real ACME, IAM or S3 interoperability |

The implementation must document and test failures of Certbot registration,
unexpected duplicate accounts, failed/misclassified AWS reads, conditional
write conflicts, invalid tar members, weak file permissions, and incomplete
post-registration state.  Error paths may remove only invocation-owned local
state and must not knowingly overwrite a validated remote archive.

## Considered Alternatives

**Keep registration outside certbotbot:** rejected for story #55 because the
project must provide a reproducible, explicitly invoked path that persists
the exact account into its existing archive.

**Make `certbotbot` automatically register when no account exists:** rejected;
ordinary issuance must fail before remote ACME calls when seeded state is
missing.  Silent account creation changes identity and consent authority.

**Use `--agree-tos` or EFF sharing implicitly:** rejected; TOS consent is
operator opt-in, and EFF sharing is an independent privacy choice.

**Expose arbitrary `--server URL` for new ACME CAs:** rejected for this
milestone; allowing arbitrary CA authorities creates a larger trust and
compatibility surface than approved Let's Encrypt staging/production.

**Add staging beside production within one archive:** deferred.  Existing
single-context preflight and renewal metadata cannot safely interpret mixed
account authority.  Separate selected keys avoid silent cross-environment
use without inventing multi-account behavior.

**Call the existing selected-lineage packager with a fake certificate:**
rejected; that would produce fabricated certificate state and defeat
the validation architecture.

**Unconditionally overwrite the selected S3 key:** rejected.  A positive
missing-object read must not authorize overwriting an object created
concurrently; a stale existing-object read must not authorize lost updates.

**Create an intermediate S3 key or service-side lock:** rejected for the
first implementation because story #55 requires one authoritative archive
and does not authorize a broader storage coordination service.

**Build a real fake ACME server for pull-request tests:** deferred.
Existing accepted test architecture mocks installed external CLI tools;
mocked registration verifies orchestration and preservation, not the
complete ACME protocol.  Real staging acceptance belongs to milestone #4.

## Expected Outcomes and Verification

Task #57 records this interface and trust contract, without implementing
or claiming executable functionality.  Task #58 will implement the narrow
public dispatch, account-only validation/persistence path and mockable
Certbot/S3 boundaries.  Task #59 will validate real producer artifact
behavior in independent clean workspaces, with deterministic negative
cases for consent, CA isolation, duplicate identity, missing archive,
conditional publication, mock failures and secret redaction.

All three distributed producer flavors must be covered.  Release asset
names and checksum companions are unchanged.  No live Let's Encrypt
account is created as part of this work.

## Relationship to Prior Decisions

This decision **narrowly refines ADR-020/021** to allow the explicit
registration mode alone to initialize a positively missing object.
It extends ADR-022's already permitted account-only archive format and
preserves ADR-031's encrypted archive requirements.  It does not change
the production-only ordinary-issuer constraints in ADR-023/024/025 or
remove ADR-027/028's selected certificate validation boundaries.
Those production-only constraints need a separate reviewed decision
before live staging issuance in milestone #4.

ADRs 001, 008, 009, 015, 016 and 019 govern documentation precedence,
document-first implementation, black-box evidence, dependency trust,
threat modeling and authorization.  Story #55 and tasks #57-#59 are the
backlog lineage for this decision.

## References

- Certbot CLI: https://eff-certbot.readthedocs.io/en/stable/man/certbot.html
- Let's Encrypt staging: https://letsencrypt.org/docs/staging-environment/
- S3 conditional writes: https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html
