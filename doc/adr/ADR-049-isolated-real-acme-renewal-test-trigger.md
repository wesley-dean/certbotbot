# ADR-049: One-Shot Test-Only Forced Certbot Renewal for Local E2E

Date: 2026-11-03

## Status

Accepted

**Implementation convention:** The `Accepted` status is the repository's
convention for ADRs submitted with intended-for-merge work. This decision
becomes operative only after the associated technical-task PR is reviewed
and merged.

## Decision

The isolated local lifecycle E2E harness shall exercise **one additional real
Pebble ACME order** after first issuance, clean-runner restoration, and
verified normal non-due no-op. The public certbotbot producer remains
**byte-for-byte unchanged** and retains ADR-025's ordinary selected-only
`certbot renew --cert-name` behavior without a public force-renewal option.

Because the existing local certificate is deliberately not due, task #248
may use a **single-use, private-runner-only Certbot argv adapter** to pass
`--force-renewal` to the installed **real** Certbot binary when and only
when certbotbot executes exactly its selected staging renewal invocation.
This is a test mechanism, not a public product behavior or fake Certbot.
Its first-party wrapper lives solely under `tests/e2e-local/`; it is
included only in the separate test-runner image, never in any producer
distribution, released OCI image, standalone client, or host installation.

The wrapper normally delegates unchanged to the real installed Certbot.
In the designated *renew* runner only, a mode-0600 marker owned by the
unprivileged test process authorizes exactly one matching invocation.
The wrapper must validate the exact `renew` subcommand, selected
`--cert-name test.e2e.test`, canonical HTTPS staging `--server`,
explicit `--account`, private `--config-dir`, and `--non-interactive`
and `--no-directory-hooks` options before consuming the marker.
It rejects any attempted force on another command, another CA or
lineage, absent or malformed arguments, or replay. The wrapper calls
`/usr/bin/certbot` using an argv array and `exec`, adding
`--force-renewal`. It must not synthesize responses, bypass Certbot's
certificate checks, inject a foreign CA endpoint, or create external
network routes. Only the original program owns account, lineage, and
archive processing; the test wrapper has no AWS or ACME authority of
its own beyond what the sandboxed Certbot already receives.

The test must demonstrate all of the following before reporting success:

1. An independently fetched initial archive contains a valid native staging
   account, complete selected lineage, matching certificate/key, and
   verifiable pre-renewal certificate DER fingerprint.
2. A separate runner with empty private state invokes the **unchanged,
   checksum-verified public certbotbot producer**. The producer restores
   the archive from genuine SeaweedFS, selects the one existing lineage,
   runs real Certbot through the single-use test adapter, and republishes
   through its existing verification and S3 conditional-write gates.
3. The adapter reports a nonsecret, private one-time receipt and the
   authorization marker is consumed; no second unguarded force request
   is silently accepted.
4. The pinned Pebble WFE's added-order counter advances by exactly one
   during that run, demonstrating a second **actual ACME order** rather
   than a no-op or mock certificate.
5. A **different leaf DER SHA-256** is present after renewal; requested
   SANs, the existing ACME account key/identity and selected lineage name
   remain stable. No unrelated lineage appears, and account private key
   bytes are never emitted.
6. The actual SeaweedFS current object's independently observed ETag
   and archive digest change. A completely separate verifier runner
   retrieves the new object, checks its SHA-256 and native account,
   archive/renewal structure, requested SANs, and matching private key.
7. The post-renewal archive does not store a permanent force-renewal
   switch. A separate normal no-op check after renewal remains the
   ordinary selected behavior.
8. On every failure, no success is reported, sensitive provider output
   stays private, temporary marker/receipt and runner state are destroyed,
   and remote write state is never assumed to have rolled back.

This local test still uses Pebble with `PEBBLE_VA_ALWAYS_VALID=1`, the
bounded synthetic Route53 API stub, and real SeaweedFS. It **does not**
test DNS-01 challenge validation, AWS, Let's Encrypt, or the passage of
real time until a certificate legitimately becomes due.

## Context and Constraints

ADR-025 explicitly rejects forced renewal in certbotbot's public runtime
because ordinary non-due checks must not create new orders or exhaust
public ACME rate limits. ADR-042 bounds the CA choice to production or
staging. ADR-046 as superseded by ADR-047 requires a real second ACME
transaction in the isolated local test suite. Task #245 already verifies
the normal non-due no-op across three public flavors, using a deterministic
90-day Pebble certificate profile. Merely changing the Pebble validity
profile **after issuance** would not make that existing 90-day certificate
due. Waiting weeks is incompatible with deterministic CI.

Certbot itself supports the explicit CLI option `renew --force-renewal`.
That option belongs to the installed third-party client, not the
certbotbot public CLI. The single-use argument adapter is authorized as a
**test-only mechanism** after the normal no-op is independently verified.
The exact installed Certbot and its CLI compatibility still require
container-backed verification. The test need not claim that the *ordinary*
renewal scheduling threshold was reached; it is testing the product's
**post-renewal detection, validation, serialization and publication path**
with a real second ACME exchange.

The existing sealed-test boundaries remain mandatory: private internal
Docker network, no published ports, test-only CA root, canonical staging
hostname, no default public route or public DNS, synthetic AWS credentials,
no host AWS/Certbot/GnuPG mounts, no Docker socket in the runner, no
production or cloud endpoints, and no modifications to the shipped
public artifacts.

## Alternatives Considered

1. **Wait for a genuine expiry window:** rejected for CI determinism and
   cost. It would require a long delay or out-of-band coordination.
2. **Temporarily use Pebble's 6-day profile:** rejected because a newly
   minted short-lived certificate is not necessarily due immediately,
   and it would conflict with #245's deterministic normal no-op.
3. **Change host/container clocks or LD_PRELOAD fake time:** rejected.
   It modifies TLS, time checks, expiry validation, and potentially AWS
   signatures across a wider boundary than one Certbot renewal option.
4. **Edit restored certificate validity, renewal configuration or private
   archive to induce due status:** rejected because it tampers with
   issuer-authenticated state and could invalidate archive/lineage
   security evidence. Never forge or manually rewrite PEM, account
   metadata or serialized renewal state.
5. **Add a force-renewal flag or dynamic ACME URL to certbotbot:** rejected
   by ADR-025/042 and product compatibility. No new public API is needed.
6. **Mock Certbot responses or synthesize a replacement certificate:**
   rejected by ADR-047, because it cannot prove a second real ACME order.
7. **Execute Certbot separately outside the producer and manually upload
   a prepared archive:** rejected. It would bypass precisely the
   certbotbot renewal, candidate-verification and S3 publication logic
   under test.
8. **A single-use argv adapter delegating to real Certbot:** accepted.
   It is narrowly scoped to one local staging renewal with a fixed
   selected lineage, and its activation is observable and test-only.

## Failure Model and Residual Risks

- **Wrapper substitution:** The local runner uses a fixed built-in
  `/usr/bin/certbot`; wrapper dispatch is limited by a private marker,
  fixed command contract and read-only image. Replacing that real binary
  would invalidate the test.
- **Authorized force during the wrong phase:** No-op, registration,
  initial issuance, and independent verification runners do not create
  the marker. An unexpected invocation with a marker fails closed.
- **False renewal reporting:** Both a changed certificate DER hash and
  exactly one additional Pebble order are mandatory; an unchanged object
  or an unreadable order log fails.
- **Identity drift:** The native ACME private account key and its
  canonical directory are compared across independently downloaded
  archives. The selected renewal name and exact SAN are required.
- **Hidden persistence of a test flag:** Inspect serialized renewal
  configuration for prohibited force-renewal options, and retain the
  regular no-op profile for subsequent invocations.
- **Concurrent writers:** The synthetic test alone owns its one
  bucket/key; real S3 semantics and rollback after uncertain failures
  are not guaranteed by a local provider.
- **Permanent test escape hatch:** The wrapper is not installed in
  standard OCI or public artifacts; the marker and receipt are
  ephemeral in the sealed runner's private tmpfs.
- **External provider fallbacks:** The existing provider gate and
  container isolation must reject real provider egress, even if a
  third-party client ignores synthetic endpoint configuration.
- **False proof of due-renewal policy:** A forced test renewal does
  not prove expiry window scheduling. ADR-025's normal non-due branch
  is verified separately by #245. Live provider interoperability is
  governed independently by milestone #4.

## Acceptance, Compatibility, and Consequences

Task #248 shall extend the **existing one-PR-per-task** local E2E harness
without changing `src/`, `lib/`, `dist/`, release `Dockerfile`,
or other operator-facing certificate commands. The positive scenario
and negative markers/tests remain under `tests/e2e-local/`. Only
test-only Dockerfile, runner orchestration, focused Bats assertions,
documentation and this ADR are within scope. A separate #246 task
will provide broader fault injection; #247 owns the dedicated CI
runtime gate.

Review the exact new Certbot argument vector, marker ownership,
failure/cleanup semantics, archive/account comparisons, and
the observed second Pebble order in a real isolated engine run.
Static tests and GitHub PR checks are not sufficient to claim real
protocol-level success.

ADR-025's **public** prohibition on force renewal remains fully
operative. ADR-046/047's unchanged public producer, genuine
certificate replacement and no-live-provider boundaries remain
operative. No migration or new public configuration is introduced.

## Related Decisions

ADR-015/016, ADR-020/022/023/024/025/027/028,
ADR-041/042/043, ADR-046/047 and ADR-048.
