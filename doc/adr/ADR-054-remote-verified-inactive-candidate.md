# ADR-054: Compose Remote Split Archives into a Fully Verified Inactive Candidate

Date: 2026-10-17

## Status

Accepted

## Decision

Add an **internal read-only S3-to-candidate preflight** for an existing, complete
collection of one ACME common account archive and up to 32 separately
named domain archives. The coordinator retrieves the selected latest
objects using the existing ADR-039/041 typed and optionally encrypted
S3 staging operation, requires the common archive and **every** selected
lineage to be present, and passes those exact downloaded plaintext
archives to the ADR-045 complete multi-lineage candidate assembler.
No remote bytes may be interpreted as first-run state merely because
the network request failed, and no partially assembled candidate may
escape after a failure.

The coordinator is split into two explicit boundaries:

1. `certbotbot_remote_candidate_prepare BUCKET NAME...` retrieves all
   required objects, rejects any absent selected lineage (return 65),
   distinguishes an entirely absent collection (return 10), validates
   and assembles exactly those lineages into a private **inactive**
   candidate, then unconditionally discards the downloaded S3 stage.
   On any failure it discards both the stage and any candidate it owns.
   A successful result retains only the ADR-045 candidate and an
   ordered list of its approved lineage identities.
2. `certbotbot_remote_candidate_verify CA_BUNDLE NAME "SAN ..." ...`
   verifies **all and only** the requested prepared lineages before
   marking the candidate verified. Every certificate must pass the
   existing ADR-029 chain, key, validity, and combined-PEM gate and
   ADR-036 exact requested SAN gate. Each SAN set must contain
   the lineage base and its wildcard, just as the public input
   normalization requires. For staging, an explicit CA bundle is
   mandatory; production may use the platform trust store under
   ADR-029. Verification failure destroys the candidate instead of
   leaving an apparently valid but unverified tree behind.
   `certbotbot_remote_candidate_discard` owns cleanup and clears
   the coordinator's recorded names and success flag.

Successful preparation, even successful cryptographic verification,
**does not make the candidate active**. No new public CLI option,
Certbot invocation, DNS challenge, account registration, S3 write,
copy into active `CERTBOTBOT_WORKSPACE_CONFIG`, or enablement of
ordinary certificate issuance is permitted under this ADR. The
public issuer must continue to return 69. The verified candidate
may be inspected and explicitly discarded only by internal
callers until ADR-037's real staging evidence and a separate
activating ADR are accepted.

This completes the internal integration seam from remote durable
archive bytes to a verified multi-lineage tree, reducing work
required after the distinct live release gates are satisfied.
It does not authorize the missing-new-lineage issuance path.

## Context and drivers

The repository already implements individually strong but
unintegrated pieces: ADR-039/041 S3 typed retrieval and decryption;
ADR-037/038 account and renewal-policy assessment; ADR-045
failure-atomic, nonactivating multi-lineage assembly; ADR-029/036
chain/key/SAN verification; and ADR-050 conditional publication
and backup. The public CLI currently performs input validation
but returns 69 for ordinary issuance.

The next product orchestration must be able to restart on a fresh
Jenkins, GitHub Actions, or EC2 runner, retrieve only durable
remote state, and never accept mixed-version or corrupt archives.
A single internal coordinator exercises those existing interfaces
and exposes any integration defects without obtaining AWS/ACME
authority or weakening ADR-037.

## Assumptions

- The process is already in an exclusively owned, freshly created
  0700 producer workspace. The active Certbot configuration tree
  must remain empty. Only the current configured AWS credentials
  and selected namespace may be used.
- The caller has validated and externally serialized the overall
  writer scope. This operation is read-only and does not create a
  distributed lock or multi-key consistent S3 snapshot.
- Input lineages are canonical, lowercase, unique names matching
  separate complete existing domain archives. New lineages and
  truly empty collections require a later separately reviewed
  initialization/issuance path.
- For staging, trusted staging CA certificates are furnished by
  the operator. Trusting arbitrary downloaded archive content as
  a CA would violate this decision.
- The existing modules continue to be bundled into all three
  standalone artifacts and support Bash 4.3.

## Alternatives considered

**Activate the candidate immediately after assembly:** rejected
because ADR-037 explicitly withholds this action until verified
real staging continuity and a separately accepted activation
decision. Passing synthetic tests cannot satisfy that gate.

**Download archives twice, once for assessment and once for
assembly:** rejected because another writer may replace them
between reads. The ADR-045 assembler already freezes the exact
files accepted from a single staged collection.

**Treat missing selected domain objects as implicit issuance:**
rejected. An absence may be a legitimate request for a new
lineage, but authorization and first-run registration belong in a
separate, carefully reviewed path. Existing-state preflight must
not silently turn a read operation into registration or mutation.

**Continue calling low-level modules manually in examples:**
rejected as inadequate end-to-end integration evidence. It makes
cleanup order, typed status propagation, and full-batch validation
caller responsibilities in every future workflow.

**Run real Let's Encrypt staging or use real AWS credentials in
normal CI:** rejected by ADR-037 and ADR-044. Unit tests use a
synthetic GetObject responder and do not acquire network secrets.

**Relax cryptographic gates for synthetically signed certificates:**
rejected. The coordinator reuses ADR-029/036; tests explicitly
use a reviewed generated CA and assert rejection of mismatched
SANs or untrusted certs, without changing product trust policy.

## Consequences and verification

The extra integration helper introduces state variables recording
the candidate's exact selected names and verified state. They
must be cleared on retry, failure, and explicit disposal; a failed
attempt cannot grant a later call an old success token. Archive
staging must be destroyed after assembly, while an approved
candidate remains under its own separate 0700 directory until
the caller discards it.

Tests must exercise all artifact flavors, complete one/two
lineages, first-run absence, missing selected lineage, mixed
encryption mode, denied/unknown storage errors, corrupted
second archive, cleanup, exact CA/SAN checks, and explicit
disposal. They must prove no Certbot, Route53, or S3 write
is invoked and no active config changes. Failure cleanup errors
must take precedence over apparent success.

Residual risks include stale S3 reads, uncoordinated concurrent
writers, compromised local users, tampered system roots, and
real Certbot metadata incompatibilities not observable with
synthetic state. Future actual issuance needs real authorized
staging evidence, checked import activation, account
registration/renewal sequencing, publication and rollback,
external serialization, and a final release verification.

## Related decisions

ADR-019 (split state), ADR-021 (encryption), ADR-022
(serialization), ADR-029 (certificate verification),
ADR-030 (environment isolation), ADR-036 (SAN identity),
ADR-037/038 (active import withheld and renewal policy),
ADR-039/041 (typed S3 retrieval), ADR-044/053 (live staging
evidence), ADR-045 (inactive candidate), ADR-050
(conditional publication), and ADR-052 (AWS CLI formatting).
