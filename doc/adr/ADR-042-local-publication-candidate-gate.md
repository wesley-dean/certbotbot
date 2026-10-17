# ADR-042: Frozen, Cryptographically Verified Local Publication Candidates

Date: 2026-10-16

## Status

Accepted

## Decision

Permit a **non-publishing** local preparation step that freezes a complete
selected collection of Certbot state archives, validates all of the
archive and restored-account invariants already required by ADRs 019,
027, 028, 031, 032, 037, and 038, and then validates every selected
leaf certificate cryptographically with the exact requested DNS SAN set
under ADRs 029 and 036. Only after every check succeeds may the step
return one ordered private set of local object bodies and their fixed
environment-scoped S3 keys.

A candidate contains a common account archive followed by one or more
per-lineage archives. The caller explicitly supplies the selected bucket,
common tarball, optional trusted CA bundle (or empty to use OpenSSL host
trust), and a sequence of
`(canonical name, domain tarball, comma-separated canonical SANs)`
triples. The comma notation is a bounded internal argument convention,
never shell syntax or an untrusted command. This interface deliberately
does not infer requested SANs from a certificate it is supposed to
validate. The request is the authority; only its exact SAN set may
appear in each leaf certificate.

The complete request is checked before any snapshot, including duplicate
lineage names, repeated domain archive paths, unsupported key names,
invalid object destinations, missing archives, malformed SAN lists,
selected ACME environment, preexisting private stages, and populated
active Certbot configuration. The helper creates a mode-0700 directory
inside the current private producer workspace, copies the common
archive and all selected domain archives to new owner-only mode-0600
files, and validates **those frozen bytes**. It must never approve
a candidate by inspecting one version of an input path but preparing
another version after a caller replaces that file.

Before any candidate is returned:

1. Every frozen archive must pass structural validation and the
   multi-lineage, non-activating account/renewal assessment.
2. Each frozen domain archive must be restored **independently** to a
   disposable private staging tree. Its leaf certificate, issuer
   chain, private key, fullchain, and both combined PEM forms must
   pass `certbotbot_crypto_verify_lineage`, using host trust or
   the explicit trusted CA bundle.
3. `certbotbot_crypto_verify_sans` must confirm the leaf contains
   exactly the separately supplied canonical DNS SAN identities.
   A missing apex, missing wildcard, additional name, duplicated
   entry, or unsupported SAN encoding is a hard rejection.
4. All isolated account and domain staging must be cleaned.
5. If `GPG_PASSPHRASE` is nonempty, every frozen tarball must be
   transformed into private GPG AES-256 ciphertext through the
   already accepted ADR-041 helper. Only encrypted `.tar.gz.enc`
   object keys and bodies may be reported in that mode. Plaintext
   mode preserves the existing `.tar.gz` object names.
6. Any failure must discard the candidate and return a nonzero status.
   Cleanup errors take precedence. A successful caller receives the
   complete ordered `CERTBOTBOT_PUBLICATION_KEYS` and
   `CERTBOTBOT_PUBLICATION_FILES` arrays and explicitly owns
   `certbotbot_publication_discard`.

**This change does not call S3 PutObject.** It does not enable the
public issuance entrypoint, any Certbot invocation, or active import.
The existing S3 adapter remains a separate primitive, not a
publication coordinator. A later accepted decision must define
the remote write protocol, ordering, observable partial failures,
recovery, and integration with successfully issued state before any
public operation can upload. No one should treat this local candidate
as a remote transactional commit.

## Context

certbotbot's enduring requirement is independent-runner portability
across Jenkins, GitHub Actions, and EC2. The previous milestones
established remote reads, optional encrypted archives, account/lineage
identity, path previews, and strong certificate and SAN verification,
but those components had not yet been assembled into one complete
pre-publication boundary. In particular, a syntactically valid
certificate archive may contain a structurally valid but untrusted
chain, mismatched private key, or wrong SAN set.

ADR-022 forbids remote mutation before all requested local
certificate processing and validation succeed. ADR-029 requires
cryptographic X.509, trust, key, and combined-file verification.
ADR-036 requires exact, request-derived SAN verification. ADR-037
forbids active import and production use of previews without
genuine Let's Encrypt staging account continuity. Preparing
candidate files is allowed within those limits; publishing them
or invoking Certbot is not.

## Assumptions and compatibility

- Input tarballs are producer-local and owner-controlled, but their
  contents remain untrusted until the accepted validators pass.
- The selected environment is either production or staging under ADR-030.
  The specified bucket and keys are validated by the bundled S3
  adapter but no remote read or write occurs.
- OpenSSL certificate verification is required, and an operator
  supplying a staging CA bundle assumes responsibility for selecting
  the correct staging trust anchors; staging trust must not be used
  silently for production.
- The common archive and every selected domain archive reference
  a single consistent account/authority. They are checked together.
- SAN input is the normalized certificate request, including both
  apex and wildcard. The interface neither discovers additional
  names from archived files nor rewrites a request after verification.
- Private candidate bytes are owned by the current invocation and
  must be disposed on normal completion and under caller-managed
  exit/signal traps. This does not guarantee secure media erasure.
- Independently running producers remain externally serialized until
  distributed locking is reviewed under ADR-022.
- Real Let's Encrypt staging issuance and active state import have
  not yet been demonstrated or authorized.

## Alternatives considered

**Trust tar validation and Certbot exit zero** was rejected:
neither confirms an X.509 trust chain, private key match, or exact SAN
identity. **Take SANs from the leaf itself** was rejected because a
compromised or incorrect leaf would then define its own authorization.
**Validate the caller's original tar paths and read them again after
validation** was rejected because source files can change between
operations; frozen private snapshots avoid that class of race under
the trusted same-user process model. **Upload each verified lineage
immediately** was rejected because later failed validation would
cause avoidable partial remote publication. **Enable actual S3
writes from this module** was rejected because rollback/forward
recovery and cross-object consistency are not yet governed or tested.
**Merge all archives into a single long-lived active Certbot root**
was rejected by ADR-037 and would also obscure per-lineage isolation.
**Encrypt before structural and cryptographic validation** was
rejected because malformed candidates would become publishable
ciphertext with no proven usable content.

## Promises and limitations

A successful candidate has frozen owner-private bytes for all
requested objects, a deterministic common-first key list, a single
format across that list, independently checked certificate chains
and private keys, exact SAN sets, and no active Certbot installation.
No AWS command is invoked. The caller may inspect the plan but
cannot claim a certificate has been issued, an account validated
against Let's Encrypt, or state persisted remotely based on it.

The candidate is a local checkpoint only. Other than ordinary
owner-private modes, it does not protect against a malicious process
running as the same user, host compromise, memory/swap inspection,
or private files lost during a crash. The caller is responsible for
workspace lifetime, and no remote concurrency fencing is provided.
Even a verified archive may become stale between local preparation
and later publication if external writers are not serialized.

A subsequent publication coordinator must prevent upload until
certificate issuance or verified state-only renewal work has
succeeded, check that the selected objects are from the correct
generation, arrange common-before-dependent-domain writes, handle
partial S3 failures, and preserve previous recovery versions.
This ADR does not authorize bypassing ADR-037's live staging evidence.

## Verification

All three standalone artifacts require network-free tests with
locally CA-signed EC certificate fixtures and synthetic account JSON.
Positive cases include a common archive and one or two independently
verified lineages, exact apex/wildcard SANs, and encrypted AES-256
candidate objects. Negative cases must reject untrusted CAs,
unexpected SAN names, tampered certificates, malicious renewal hooks,
duplicated identity, malformed requested SANs, and preexisting
active Certbot files. Every test asserts no AWS PutObject call,
no retained staging, unchanged active state, and continued status
69 from normal public certificate invocation.

Before operational release, independently provisioned runners
must still prove genuine ACME registration continuity, creation,
no-op and due renewal, changed SANs, encrypted and plaintext S3
end-to-end compatibility, and safe partial-upload recovery.

## Related decisions

ADR-018: authoritative certificate names; ADR-019: split archive
format; ADR-021 and ADR-041: encryption; ADR-022: serialization
and remote publication; ADR-025: Certbot command boundary;
ADR-027, 028, 031, 032, 037, and 038: staged import rules;
ADR-029: cryptographic verification; ADR-030: environment isolation;
ADR-036: exact SAN authorization; ADR-039 and 040: remote state reads.
