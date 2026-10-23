# ADR-029: Public Selected-Certificate Lifecycle and Prepublication Assertions

Date: 2026-10-23

## Status

Accepted

## Decision

The public Certbotbot command executes one complete, ordered, selected-certificate
MVP lifecycle using **one newly allocated private mode-0700 workspace** per
invocation. After CLI/env/.env/default configuration and SAN selection succeed,
the lifecycle:

1. Creates its own disposable private workspace.
2. Retrieves **the existing selected S3 bucket/key** through
   `certbotbot_s3_fetch`. No remote object means failure, never initialization.
3. Pre-validates and restores that precise archive under
   `WORKSPACE/config`, then requires a single suitable existing
   Let's Encrypt production ACME account and absent or exactly selected lineage.
4. If the selected lineage is absent, calls the first-issuance provider with
   the existing account and exact SAN set; otherwise calls the selected-lineage
   renewal/reconciliation dispatcher. It never calls global renew, creates
   an account, chooses a different cert name, or touches a second lineage.
5. For first issuance only, canonicalizes the newly generated selected
   renewal metadata from private paths to `/etc/letsencrypt`. Existing
   lineage adapters already perform their own canonicalization.
6. Requires post-Certbot state preflight, read-only canonical renewal metadata
   verification, **exact requested DNS SANs**, a non-expired and currently
   effective X.509 leaf, a syntactically readable private key matching the leaf
   public key, a parseable chain, and the leaf matching the first certificate
   in fullchain. A failure at any gate forbids PutObject.
7. Delegates the verified durable-change/no-op decision to
   `certbotbot_s3_publish` with the exact same resolved bucket/key.
   An actual first issuance sets `CHANGED=true`. A verified existing-lineage
   operation supplies its observed `CERTBOTBOT_DURABLE_CHANGED`;
   `UPLOAD_NO_RENEWAL` retains the ADR-028 policy.

The orchestrator never directly assembles a tarball, calls AWS PutObject, or
forwards raw Certbot/AWS/OpenSSL output. The existing modules continue to own
their respective trust boundaries.

## Certificate acceptance gate

OpenSSL is a separately installed trusted runtime dependency. The verifier
consumes only the selected private configuration root, selected cert name,
and the exact desired SAN list; it never reads host-global Certbot state.

It enforces:

- A complete selected lineage and account preflight, with canonical persisted
  renewal metadata (the existing read-only parser).
- A valid X.509 leaf, valid current date window (notBefore <= now < notAfter),
  and exact one- or two-name DNS SAN set, with no unrecognized SAN types.
- A valid private key that can be loaded non-interactively.
- Equality of the normalized public key from the leaf and from the private key,
  regardless of RSA/EC key type.
- Parseable PEM chain and fullchain, and equality of the first fullchain
  leaf's DER bytes with the selected cert's DER bytes.
- An unreadable, missing, unmatched, future, expired or unexpected certificate
  fails closed with fixed, non-secret diagnostics.

This gate establishes **local cryptographic/key and content consistency**,
not remote ACME registration, certificate revocation status, trustworthy root
CA path validation, or actual AWS/Route53 availability. Certbot's issued
certificate is trusted for its issuer validation path; fully live chain,
DNS/ACME and S3 compatibility is deferred to the designated later
end-to-end milestone. The public command may not imply those untested
guarantees.

## Workspace and cleanup

The orchestrator obtains its own random absolute workspace from the
existing `certbotbot_workspace_create` helper and executes the entire
lifecycle in a child Bash subshell. The child establishes an EXIT trap to
remove **only that newly allocated workspace**, plus signal traps that
exit nonzero. No archive or temporary account keys are kept after return.
The parent shell does not install global traps, change current directory,
or remove user-selected paths. All stored certificate material remains
inside that owned workspace or the single existing S3 object.

A successful no-op does not cause upload unless
`UPLOAD_NO_RENEWAL=true`; in that case the publisher independently builds
and validates a new candidate before one PutObject. Public stdout reports
only the resolved object and whether an upload was accepted or skipped.
Diagnostics contain fixed wording and non-secret status, not private keys,
AWS credentials, account JSON or Certbot/OpenSSL output.

## Rationale and boundaries

ADRs 020–028 establish identity, archive format, account trust, provider
behavior, private path mapping, and verified one-object publication, but
their previous independent components were deliberately not reachable
from the public CLI. Calling them in the wrong order could run Certbot
against invalid data, upload before post-Certbot verification, or silently
write the wrong object. The public workflow must now enforce the
end-to-end order and all prerequisite gates before reporting success.

## Alternatives considered

**Make the public command call Certbot directly:** rejected; bypasses
provider account selection, scoped lineage, and explicit hook policy.

**Trust successful Certbot exit and publish immediately:** rejected;
it could persist the wrong DNS SAN, broken symlink, expired leaf, invalid
private key, mismatched PEMs, or private runner-local path references.

**Source archived renewal metadata into the shell:** rejected; the
archive is untrusted data, not executable configuration.

**Persist/reuse one workspace across runs:** rejected; violates
clean-runner portability and increases risk of accidental host state
fallback and secret retention.

**Trap cleanup directly in the main shell:** rejected; could overwrite
caller EXIT/signal traps when sourced or unexpectedly remove caller data.

**Create an empty S3 archive when HeadObject reports missing:** rejected
under ADR-020; a registered account must be seeded by the operator.

**Use a special test mode to bypass provider commands:** rejected. Tests
inject executable `aws` and `certbot` mocks through PATH and use
actual GNU tar/gzip and OpenSSL for leaf verification.

**Always upload after Certbot returns zero:** rejected because Certbot
return zero can represent a successful unchanged no-op (ADR-025).
Account/metadata changes are classified separately.

## Compatibility, limitations, and failure modes

All three standalone Bash artifacts now take the same public CLI options
as prior preflight-only releases and may perform real ACME/DNS/S3 calls on
valid invocation. Operators must therefore provide tested provider
versions and properly scoped IAM/Route53 rights. The old status 69
placeholder is replaced by honest status from failing stages; --help
and --version remain offline.

External writers remain serialized by the operator. If a PutObject
returns nonzero, remote state is **uncertain**; no transactional rollback
or distributed lock is claimed. A successful CLI response from AWS
does not by itself prove independent download/recovery; mock-system
roundtrips establish only the tested local behavior. Tests against
real AWS, Let's Encrypt, and Route53 remain for milestone #4.

The existing strict renewal metadata parser can reject legitimate
Certbot versions/options that fall outside its recorded compatibility
subset. That is a fail-closed compatibility gap, not permission to
strip options or bypass validation.

## Verification

Bats executes the actual public artifacts with mocked AWS CLI and
Certbot/Route53 plugin behavior, seeded account-only S3 fixture, real
OpenSSL-generated certificates and real GNU tar/gzip. Tests cover
first issuance, a separate runner's no-op, forced no-op republish,
renewal and unchanged SAN policy, missing remote archive, malformed
archive, missing account, provider errors, bad/mismatched/expired
leaf/key, private path failures, packaging failure, upload failure,
and no extra keys or unexpected Certbot commands. Tests inspect
the complete persisted archive and account/lineage identity rather
than relying on mock exit status alone.

## Related decisions

ADRs 020–028 and task #27 govern the component order and public
behavior. Tasks #23/#25/#26/#29/#30/#31/#32/#34/#38/#39/#40
represent related acceptance criteria, each closed only when its
specific evidence and parent-story acceptance gates are satisfied.
