# ADR-026: Controlled SAN Reconciliation on an Existing Certbot Lineage

Date: 2026-10-22

## Status

Accepted

## Decision

An existing selected certificate lineage may be updated when the desired
DNS subject-alternative-name (SAN) set differs from the restored leaf
certificate, but only when both sets represent the **same apex identity**
and differ within the MVP-supported apex/wildcard policy. The selected
`--cert-name` is never changed or inferred again from the new SAN set.

The existing-lineage dispatcher invokes the ordinary named renewal
provider when the exact DNS SAN set already matches. This remains governed
by ADR-025 and never forces issuance for an unchanged no-op.

When supported SAN drift is proven, the reconciliation adapter calls
`certbot certonly --cert-name NAME --renew-with-new-domains
--dns-route53 -d SAN ...`, supplying the exact requested SANs, the
previously restored and explicitly selected ACME account, the production
ACME endpoint, and private config/work/log directories. The operation is
non-interactive and refuses directory hooks. It must never use
`--duplicate`, `--expand`, implicit account registration, global renew,
or an unqualified Certbot certificate operation.

The accepted existing and desired SAN sets are each exactly one of
`apex.example`, `*.apex.example`, or the two-name pair containing both,
where `apex.example` here represents the same validated apex DNS identity
rather than a literal hostname. This permits the approved
INCLUDE_SUBDOMAINS transitions in either direction; unrelated domains,
unexpected SANs, duplicate SANs, unsupported SAN extensions, and malformed
certificate material are rejected **before any Certbot subprocess**.

Before execution the adapter validates the complete existing selected
lineage, the single registered account, the existing leaf's actual DNS
SANs, and canonical path mapping. It snapshots selected certificate
bytes/symlink target and the durable configuration. Certbot's plugin
listing and account recognition probes must succeed before issuance.

The selected renewal metadata is mapped into the private workspace before
Certbot and returned to canonical `/etc/letsencrypt` paths only after
the operation succeeds and the resulting local account, selected lineage,
and *exact desired SAN set* are verified. On failure the adapter clears
both reported outcome variables; its caller must discard the private
candidate rather than upload a damaged archive. Existing authoritative
S3 state is never modified by this adapter.

The adapter reports `CERTBOTBOT_RENEWAL_OCCURRED=true|false` and
`CERTBOTBOT_DURABLE_CHANGED=true|false` on verified success using
the existing ADR-025 digest/leaf comparison contract. A successful SAN
change must actually replace the selected certificate and change durable
state: unchanged bytes and unchanged symlink target despite reported
Certbot success constitute a failure, even when a test/mock process exits
zero.

## Relationship to ADR-025

**ADR-026 supersedes only ADR-025's interim prohibition on SAN drift.**
ADR-025 remains authoritative for matching-SAN due renewal, no-op
classification, stable selection, local fingerprints, security checks,
and absence of remote-publication authority. The existing
`certbotbot_provider_renew` function continues to reject mismatches
when called directly; the newly documented existing-lineage dispatcher
chooses renewal or controlled reconciliation explicitly.

## Conditions, alternatives, and tradeoffs

- The S3 archive and registered ACME account already exist. A missing
  remote archive is fatal under ADR-020.
- One selected lineage is restored privately; the host
  `/etc/letsencrypt` is never a fallback.
- The desired name set is resolved from one primary DNS identity and the
  INCLUDE_SUBDOMAINS policy. Domain order is irrelevant but contents
  and identity are authoritative.
- Certbot and certbot-dns-route53 are installed and trusted by the
  operator. Testing for this MVP uses deterministic executable mocks;
  no live ACME or AWS access is needed.

**Always invoke certonly with `--force-renewal`:** rejected. This
would spend ACME issuance authority even for unchanged SAN sets and
does not express the intended domain-change condition.

**Use `--expand`:** rejected. Expansion cannot remove wildcard coverage,
so would not satisfy the symmetric policy transition.

**Use `--duplicate`, infer a new cert name, or delete/recreate:**
rejected. This changes lineage identity or discards durable history.

**Permit arbitrary new SANs:** deferred. The MVP accepts only the same
apex/wildcard combination, not general multi-domain identity changes.

**Trust the exit code or certonly's prose:** rejected. A successful command
can still produce an unexpected or unusable result. Exact post-operation
SAN and lineage checks are required; actual issuance is further verified
by the later candidate-verification and publishing gates.

**Rollback local mutation in place:** rejected. Certbot may update multiple
files before failing. The private workspace is disposable; authoritative
rollback is achieved by *not publishing* a failed candidate. No guarantee
of ACME issuance rollback or remote DNS side-effect rollback is made.

## Threat model and failure outcomes

Inputs cross from the restored archive and operator configuration into
an installed Certbot executable that holds ACME credentials and Route53
authority. All names are individually validated and passed as quoted
arguments, never assembled as shell command text. No archived hook is
executed. External output is suppressed to avoid disclosing account or
certificate data, while static diagnostics indicate the failing gate.

A request for unrelated SANs, missing account, unknown existing SANs,
unsafe workspace, or incomplete certificate lineage causes no Certbot
subprocess. A plugin/account probe failure causes no certonly request.
A failed certonly, unexpected post-state, changed ACME account identity,
or failed canonical-path finalization causes a nonzero return with no
success state and no S3 upload.

The adapter is not a distributed lock, transaction, certificate
cryptography auditor, or independent Certbot sandbox. Any remote
issuance-side effects before a failed local operation cannot be undone
merely by deleting the private workspace. S3 publication and its
concurrency/rollback constraints remain governed by ADR-020 and later
implementation.

## Verification and expected outcomes

Each generated release flavor must prove both directions of wildcard
policy change, preserved `--cert-name`, no-change idempotence via the
ordinary renewal path, exact `-d` arguments and
`--renew-with-new-domains`, refusal of unrelated/duplicate SANs,
failed Certbot and zero-but-unchanged Certbot behavior, unexpected
post-SANs, archived hooks, broken lineages, and canonical-path
roundtrip. All tests mock Certbot/OpenSSL and assert that no S3
publication occurs.

## References

- Certbot certificate name and changing domains:
  https://eff-certbot.readthedocs.io/en/stable/using.html
- Certbot automation flag `--renew-with-new-domains`:
  https://eff-certbot.readthedocs.io/en/stable/man/certbot.html
