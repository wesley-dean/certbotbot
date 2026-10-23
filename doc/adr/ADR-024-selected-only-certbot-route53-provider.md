# ADR-024: Selected-Only Certbot and Route53 Execution Boundary

Date: 2026-10-22

## Status

Accepted

## Decision

Milestone #1 uses the installed Certbot executable with its first-party
`dns-route53` authenticator, inherited AWS credentials, and an isolated
Certbot configuration, work, and log directory under a new mode-0700
workspace.  The project never provisions Route53, S3, IAM, or ACME
accounts.  No archived script is evaluated, no host Certbot configuration
is imported, and no executable renewal hooks are allowed.

This first provider increment supports **issuance only when the selected
certificate lineage is absent** from a verified, previously registered
production Let's Encrypt account archive.  The provider calls
`certbot plugins --authenticators` to confirm the Route53 authenticator
is visible and `certbot show_account --account <id>` to require that
Certbot itself can read the selected restored account.  Both probes use
private Certbot paths and the production ACME directory.  Only after
they succeed does the provider call `certbot certonly --dns-route53`
with `--account <id>`, `--cert-name <selected>`, the exact approved
one- or two-name SAN set, `--non-interactive`,
`--no-directory-hooks`, and `--preferred-challenges dns-01`.

The provider never calls `register`, `run`, `renew`, `--force-renewal`,
or a global certificate operation.  It rejects an already present lineage,
because renewal requires a separate decision on SAN drift and exact
selected-lineage continuity.  In particular, it must never call an
unscoped `certbot renew`.

## Context and constraints

ADRs 020, 022, and 023 require a seeded S3 archive, one stable
certificate name, a private restored configuration root, and an
unambiguous existing account.  A successful filesystem check alone
cannot prove that Certbot can load or use the account.  A Certbot
`show_account` success verifies local Certbot recognition but is
not proof of current remote account registration, DNS permissions, or
a completed ACME authorization.

The provider's caller is responsible for validating S3 bytes,
restoring them, checking account/lineage state, selecting SANs,
handling workspace cleanup, post-issuance assertions, converting
renewal paths to canonical form, packaging, and safe publication.
An exit-zero Certbot invocation is not itself an issuance-complete,
durable archive, or publication-success signal.

Certbot and certbot-dns-route53 are independently installed runtime
dependencies, not silently downloaded or bundled into Bash artifacts.
AWS credentials and region settings are inherited from the operator's
runtime environment; the program does not read or log them.

## Threat and authority boundaries

| Boundary | Required behavior on failure |
| --- | --- |
| Invalid identity, SAN combination, workspace, or existing lineage | No Certbot process |
| Missing local account or competing account identity | No Certbot process |
| Missing Certbot executable | Static unavailable diagnostic |
| Missing Route53 authenticator | No account probe or issuance |
| Failed `show_account` | No issuance |
| Failed `certonly` | Nonzero, no publication |
| Unexpected provider stdout/stderr | Captured/suppressed, never echoed |
| Invalid emitted certificate files | Subsequent validator rejects, no upload |

The provider does not promise that an external Certbot executable is
a sandbox.  Running Certbot with AWS credentials and access to ACME
private keys entrusts that executable and its Route53 plugin with
those authorities.  Explicit CLI paths reduce incidental host
state access but are not an isolation boundary against a compromised
Certbot binary or malicious Python plugin.

The local workspace owner must remove the temporary work and log
files on completion.  Certbot may modify restored account state,
create certificate state, and communicate with Let's Encrypt and
Route53, **only when the lifecycle intentionally invokes this
provider after all earlier gates**.  MVP tests use an executable
mock Certbot; no live AWS or ACME credentials are used.

## Alternatives considered

**Rely on file existence as account verification:** rejected; archive
files might be missing, malformed, or unsuitable for installed Certbot.

**Implicit Certbot account selection or registration:** rejected.
An explicit restored account ID is selected, passed to Certbot, and
a prior account probe must succeed.

**Use `certbot run` or webserver installers:** rejected because the
MVP obtains portable certificate material and installs nothing on
the execution runner.

**Renew an existing lineage with a broad Certbot command:** rejected:
without validated SAN-drift logic that could silently preserve the
wrong certificate names or affect unrelated lineages.

**Use a vendor-bundled Python/Certbot installation:** rejected as an
unrequested new runtime and supply-chain authority.  The operator
installs approved Certbot and Route53 plugin versions.

**Emit raw Certbot logs to standard error:** rejected; they may contain
account identity, DNS values, paths, or other sensitive material.
The adapter emits bounded, fixed messages.  Its workspace log
directory remains private and is later removed by the orchestrator.

## Compatibility and follow-up

This adapter uses supported Certbot CLI flags but has not been
interoperability-tested with live AWS, ACME, or an installed Certbot
binary.  It is explicitly not wired into the public CLI; the public
command remains fail-closed until a full safe lifecycle exists.

Future approved steps must provide selected-only renewal, exact SAN
reconciliation, post-Certbot certificate assertions, reversible
renewal-path mapping after issuance, state packaging, verified S3
publication, and end-to-end mock tests across clean runners.

## Relationships

ADR-020 governs selected identity and existing account.  ADR-022
governs portable paths and hooks.  ADR-023 governs local state
preflight.  ADRs 008, 015, and 016 govern test ordering, dependency
trust, and threat modeling.  Task #24 governs provider integration,
and #25/#26/#27 govern issuance, renewal, and public orchestration.

## References

- Certbot user guide: https://eff-certbot.readthedocs.io/en/stable/using.html
- Certbot CLI options: https://eff-certbot.readthedocs.io/en/stable/man/certbot.html
- Let's Encrypt account IDs: https://letsencrypt.org/docs/account-id/
