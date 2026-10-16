# ADR-018: Certificate Identity, SAN Groups, and DNS-Only Issuance

Date: 2026-10-15

## Status

Accepted

## Intent and Documentation Posture

Define a predictable, non-destructive certificate identity and issuance contract for a standalone Bash tool.  A caller controls which certificate lineages are processed.  The ACME client, rather than certbotbot, owns certificate renewal timing.

## Context

The predecessor kdaweb/certbotbot inferred an apex-plus-wildcard pair from every command-line base domain and treated omitted arguments as a request to renew every known lineage.  That made certificate management and deletion difficult to reason about.  The replacement must support distinct certificate groups, each with an explicit primary name and additional SANs, without touching unrelated groups.

Let's Encrypt is reducing default certificate validity from 90 to 64 days in February 2027 and to 45 days in February 2028.  A fixed day-count inside the wrapper would be an incorrect contract.  ACME account registration and acceptance of terms must be explicit configuration, even if convenient defaults are enabled.

## Decision Drivers

- One stable certificate lineage and archive identity per group.
- Easy invocation with either quoted or separate domain arguments.
- No destructive changes to omitted certificates.
- DNS-01 support, including wildcards, without HTTP-01 challenges.
- Backend-neutral certificate intent that can later support more DNS providers.
- Let Certbot decide renewal eligibility, avoiding hard-coded expiry periods.

## Decision

Each logical input line describes exactly one certificate lineage.  The first token establishes its archive and Certbot `--cert-name` identity.  A leading `*.` on that first token is removed for identity purposes; the resulting base name and its `*.` wildcard are always included as SANs.  Subsequent tokens are included literally as additional SANs after validation and duplicate elimination.  No implicit wildcard is generated for those subsequent tokens.  The SAN list is authoritative, so removing an additional name means the next qualifying issuance should replace the lineage SAN set instead of retaining the removed name.

A single certificate may be invoked as `certbotbot.bash foo.com www.foo.com` or `certbotbot.bash "foo.com www.foo.com"`.  A multi-line `CERTIFICATES` input or a certificate-list file may name multiple independent certificates.  Jenkins and GitHub Actions use the same line-oriented input without shell evaluation.  An empty list is invalid; it does not imply global `certbot renew`.

The initial DNS implementation is AWS Route53 using Certbot's DNS-01 plugin.  No HTTP or TLS-ALPN challenge mechanism is supported.  The Route53 plugin and ACME client are runtime system dependencies of certificate issuance, not consumer-server requirements.  Registration is controlled by `REGISTER_ACCOUNT` and `AGREE_TOS` (both default true); `EMAIL` is required when registration is performed.

Certbot SHALL determine whether an unchanged lineage needs renewal.  A changed requested SAN set SHALL be handled deliberately with Certbot-supported options, subject to validation and rate-limit concerns; it must not be silently ignored.  Certbot selection and any changed-domain flags must be integration tested against an appropriately supported Certbot version before release.

## Promises

- Exactly one named lineage is addressed per input group.
- Omitted lineages are neither renewed nor deleted.
- The first base name, even when supplied as only `*.foo.com`, produces both `foo.com` and `*.foo.com` coverage.
- No wrapper-defined renewal day count exists.
- A failed issuance does not authorize publishing incomplete certificate state.

## Non-Promises

- Wildcards do not match the apex automatically at the TLS protocol level; the tool requests both explicitly.
- No general-purpose deletion or revocation interface is established.
- No runtime support for arbitrary Certbot authenticators, HTTP challenge modes, or every DNS provider is promised.
- Expired certificates are not automatically deployed or services reloaded by this tool.

## Adversary and Failure Model

Invalid or injection-shaped hostnames, wildcard placement, shell glob expansion, malformed multi-line input, duplicate lineages, DNS authorization failures, Let’s Encrypt rate limits, and stale renewal metadata can all cause unwanted behavior.  Domain tokens must be validated and supplied to Certbot through arrays, never `eval` or unquoted expansion.  Duplicate certificate identities in a batch must fail before any publication.

## Operational Constraints

- One input line MUST map to one lineage; the first hostname MUST map to a safe archive component.
- The first hostname's apex and wildcard MUST both be requested.
- Secondary SANs MUST NOT be expanded implicitly.
- An omitted lineage MUST NOT be modified.
- Certbot MUST own renewal timing, with no hard-coded day threshold.
- Only DNS-01 validation MAY be used.

## Considered Alternatives

The old "no args renew everything" mode was rejected as violating explicit scope.  Separate certificates for every SAN were rejected as needlessly fragmenting deployment.  Implicit wildcard expansion for every SAN was rejected because `www.foo.com` would unexpectedly request `*.www.foo.com`.  A configurable arbitrary `--cert-name` was deferred to keep archive identity stable and predictable.

## Consequences

The first hostname has compatibility significance and should not be casually reordered.  A narrower authoritative SAN list may trigger reissuance when a name is removed.  The implementation needs deterministic normalization, validation, and negative tests for accidental global renewal.

## Source Lineage

Rebuild of kdaweb/certbotbot's Route53 and apex-plus-wildcard conventions; refines the derived project's inherited ADR-004 and ADR-014 implementation choices.

## Related Decisions

ADR-019 defines archive composition.  ADR-020 defines bundled backends.  ADR-022 governs parallel writers.
