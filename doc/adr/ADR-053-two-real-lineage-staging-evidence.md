# ADR-053: Test Real Coexisting Certificate Lineages Without Activating Import

Date: 2026-10-17

## Status

Accepted

## Decision

Extend the existing **inactive**, manually installable real Let's Encrypt
staging evidence example from ADR-044 with two additional jobs:

1. A fifth fresh staging producer restores the encrypted common account and
   changed-SAN first lineage from the already validated earlier run. After
   matching the retained account-key digest and the first leaf certificate,
   it obtains **one separate second lineage** using the pinned Certbot
   Route53 DNS-01 authenticator against only the Let's Encrypt staging
   directory. Its selected second certificate has exactly one DNS name, a
   different lower-case concrete subdomain under the authorized base.
   The producer checks the first lineage has not changed, verifies the
   second chain, key, combined PEM, and exact SAN, and confirms the same
   ACME account private key.
2. A sixth, completely new, read-only runner downloads only **three
   separately encrypted archives**: one shared common account and one
   domain archive for each of the two distinct certificate lineages.
   It assembles a **non-activating** two-lineage ADR-045 import candidate
   with the existing complete batch validator, then cryptographically
   checks both distinct certificates and compares account/leaf digests
   against earlier independent stages. No Certbot invocation or AWS
   credentials are permitted in this last job.

This evidence extends ADR-044's four-runner test while preserving it.
The existing first-run issuance, true independent no-op renewal,
changed-SAN issuance, and read-only restored verification must continue
to succeed before the second-lineage runner is permitted to start.

Each domain archive MUST contain only its own lineage's approved
`archive/<name>`, `live/<name>`, `renewal/<name>.conf` and
`combined/<name>.pem` paths and their approved parents. The exporter
MUST individually validate both plaintext domain archives, validate
the common account archive, and then export ciphertext only. It must
exclude only optional Certbot-generated informational README files;
neither unexpected files nor a second lineage embedded in the first
archive may be permitted. Existing archive validator grammar, certificate
verification, private staging modes, optional encryption rules, and
release artifact contracts remain unchanged.

The additional operator input `second_name` must be a distinct,
lower-case, non-wildcard, concrete DNS hostname strictly below the
chosen owned `domain`; it must differ from `extra_name` and may not
change the authority boundary. The already approved protected
`acme-staging` environment and OIDC-limited Route53 role are reused
**only** for the second issuance job. The final verification runner
has neither AWS access nor an OIDC write grant.

The workflow **MUST remain under** `examples/github-actions/`. There
must be no normal CI trigger, no new executable workflow under
`.github/workflows/`, no automatic workflow installation, and no
action that enables normal issuer behavior. Genuine staging operation
still requires an operator to install, review, explicitly authorize,
and manually dispatch the example in a controlled repository.

The existing ADR-037 restriction continues to prohibit activation of
staged Certbot account or lineage state by the public product.
The fifth runner may restore credentials into its **disposable test-only**
Certbot configuration as already permitted in ADR-044. The sixth uses
the ADR-045 candidate strictly as an inactive validation artifact,
never passing it to Certbot and never moving it into active config.

## Context

ADR-037 requires genuine, independently restorable ACME account
continuity **and** coexistence of at least two selected domain archives.
ADR-044 covers real staging issuance, an independent no-op renewal,
a deliberate SAN change under the same account, and a final read-only
restoration, but its exported domain collection still contains one
lineage. ADR-045 proved structural two-lineage assembly using synthetic
account and certificate fixtures; those fixtures cannot prove real
multi-lineage Certbot metadata compatibility or cryptographic chain
validity.

PR #41 established that conditional S3 writes and rollback can work
against a real disposable S3-compatible service with a correct modern
AWS CLI parser. This independent test surface addresses the *different*
live ACME lineage portability gate. It does not attempt to conflate
S3 emulator evidence with real staging evidence.

## Preconditions and assumptions

- The operator owns the base zone, the additional SAN, and the chosen
  second certificate name and grants DNS-01 TXT changes only inside
  a dedicated staging Route53 zone.
- A trusted immutable source revision and separately reviewed installed
  example are available on `main` of the operator's controlled runner
  repository. No PR code is granted staging role access.
- Certbot and its Route53 plugin remain pinned at their existing
  reviewed versions. The validated common archive's single actual
  staging account remains authoritative through all runners.
- The first lineage's base/wildcard/extra-SAN certificate and the
  second single-name certificate can coexist without unexpectedly
  rewriting the first lineage's renewal state.
- A fresh runner receives no private filesystem from prior workers.
  Encrypted artifacts are retained for at most one day and protected
  by the environment-specific GPG passphrase, which must never appear
  in job arguments or diagnostic output.
- A passing simulated or source-level guard test does not demonstrate
  real staging issuance. A real manually authorized run must still be
  performed and reviewed before considering activation.

## Alternatives considered

**Treat the changed-SAN certificate as a second lineage:** rejected
because it replaces the first lineage's name and does not prove that
two distinct domain archives coexist.

**Change the production importer now:** rejected by ADR-037. The
live two-lineage test can expose compatibility problems but cannot
itself authorize failure-atomic installation into the public issuer.

**Export one domain archive containing both lineages:** rejected by
ADR-019, ADR-026, and ADR-045's disjoint-member and portable split-state
requirements. A consumer requests independent lineage archives.

**Install the staging workflow automatically:** rejected by ADR-044.
Explicit setup, protected environment review, staging credentials,
and deliberately scoped DNS authority are necessary safeguards.

**Make the second lineage an arbitrary zone:** rejected because it
broadens the role's DNS authority and creates another uncontrolled
external validation target. An owned distinct concrete subdomain
satisfies the evidence without expanding credential scope.

**Run real staging from normal pull-request CI:** rejected because
untrusted code must not receive Route53 authority or a staging GPG
passphrase. Unit/guard tests remain credential-free.

**Use locally signed synthetic certificates only:** retained for
negative and manifest tests but insufficient for the actual
multi-runner ACME account continuity evidence.

## Security, failure behavior, and verification

A rejected second hostname, absent consent, incorrect phase,
production ACME environment, missing/invalid CA bundle, missing
encryption passphrase, invalid standalone artifact, or untrusted
input directory must fail **before** any Certbot or AWS operation.
The test must not leak staging account files, certificate private
keys, GPG passphrases, or actual Certbot output into routine CI logs.

The second-lineage job must abort upon account drift, alteration of
the first lineage's certificate, failed Certbot issuance, failed chain
or SAN verification, or archive validation error. It must not upload
incomplete ciphertext archives and must never mutate S3.

The final verifier must reject missing, duplicate, overlapping,
tampered, or foreign-account lineage archives through the existing
ADR-045 validators, and fail if the first or second certificate
fingerprint or the common account key differs from expected
cross-runner evidence. Cleanup must discard private staging.
No active Certbot process, Route53 operation, or S3 write is permitted
in the last job.

Normal three-artifact Bats tests must cover the explicit consent and
identity restrictions, unchanged public status-69 issuer, and the
inactive workflow placement. The exact separated archive-member
schema must have synthetic tests preventing a second lineage from
leaking into the first archive. CI success for these tests is a
*preparation result*, not live ACME evidence.

Completion of the actual release gate requires the operator to
deliberately install and execute the example, review all six job
results and account/certificate digests, and record sanitized
supporting evidence. A separately Accepted ADR must still govern
active import, atomicity, rollback, external serialization, and
production activation.

## Related decisions

ADR-019 governs split archives; ADR-022 requires external
serialization; ADR-025 governs Certbot options; ADR-026-029 govern
archive and cryptographic verification; ADR-030-032 govern environment,
identity, and path rebasing; ADR-037 withholds active import;
ADR-038 controls renewal metadata; ADR-044 governs the operator
staging evidence example; ADR-045 defines the non-activating
multi-lineage candidate; ADR-050 governs guarded S3 publication.
