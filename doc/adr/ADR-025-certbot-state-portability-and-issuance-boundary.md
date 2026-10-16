# ADR-025: Certbot State Portability and the Staged Issuance Boundary

Date: 2026-10-15

## Status

Accepted

## Intent and Documentation Posture

Establish strict preconditions for calling Certbot on restored state without
pretending that a successful `certbot certonly` invocation alone proves an
independently restorable certificate lineage or publishable archive.

## Context

certbotbot operates on shared ACME account state and one named certificate
lineage at a time, and intentionally produces standalone archives that
consumers may extract into `/etc/letsencrypt`.  Its producer runs can use a
transient private workspace instead of a persistent system Certbot installation.
Certbot's `renewal/<lineage>.conf` file may contain absolute paths to live,
archive, and other configuration locations.  Consequently, archiving a
lineage created under one temporary `--config-dir` and blindly restoring it
under another directory can break future renewal even when the `live/`
symlinks themselves resolve.

The underlying challenge plugin is Certbot's supported Route53 DNS-01
authenticator.  Certbot's documented `--cert-name` flag names a specific
lineage, `--keep-until-expiring` avoids forced reissuance for an unchanged
lineage, and `--renew-with-new-domains` permits the requested SAN set to
replace a different existing set without applying an unconditional
`--force-renewal`.

Relevant upstream documentation:
- https://eff-certbot.readthedocs.io/en/stable/using.html
- https://certbot-dns-route53.readthedocs.io/en/stable/

## Decision Drivers

- Respect Certbot's renewal timing and avoid unnecessary ACME rate-limit use.
- Preserve exactly one certificate lineage and its authoritative SAN set.
- Prevent unexpected HTTP challenges or web-server installation.
- Keep the certificate issuer runnable on native and transient CI hosts.
- Never publish broken restored state merely because Certbot returned zero.
- Provide argument-preserving, mockable external-command integration points.

## Decision

The built-in Route53 provider uses `certbot certonly` with a fixed DNS-01
authenticator option vector, `--non-interactive`, explicit `--cert-name`,
`--keep-until-expiring`, and `--renew-with-new-domains`.  Each requested SAN
is passed separately via `-d`.  The producer supplies three separate, owned
private directories for Certbot configuration, working files, and logs.  Input
and directory validation complete before a Certbot subprocess is created.
An unsuccessful Certbot process propagates its status and cannot authorize
storage publication.

An initial internal adapter may construct and execute that command against a
mocked Certbot process, but it MUST NOT be connected to the public issuance
entrypoint until the surrounding producer workflow implements safe restoration,
ACME account handling, serial execution, private workspace ownership, and
validation of all outputs.  In particular, account reuse with
`REGISTER_ACCOUNT=false` is unsupported at the command-adapter stage and
MUST fail closed until explicit restored-account selection is available.

Before releasing an operational producer, tests MUST establish a portable
renewal-config strategy with real Certbot state and verify creation, restoration
into a different transient workspace, a no-op renewal, an intended SAN set
change, and continued access to correct certificate and key files.  That
strategy may use stable logical paths, explicit supported Certbot facilities,
or rigorously validated path normalization, but MUST NOT perform an
unreviewed text replacement of renewal metadata.  Any consequential choice
among those mechanisms requires a follow-up ADR and test evidence.

The consumer archive contract in ADR-019 remains separate: consumers extract
their chosen per-domain archive directly into `/etc/letsencrypt`, require no
Certbot installation, and do not retrieve common account state.  The issuer
does not execute consumer deployment or reload hooks.

## Promises

- Backend command arguments are represented as separate Bash array elements.
- Only DNS-01 authentication is selected.
- Ordinary unchanged lineages follow Certbot's renewal decision.
- A changed requested SAN set is explicitly addressed instead of silently
  retaining previous names.
- No certificate state is published until restore and output validation pass.

## Non-Promises

- This ADR does not claim a command-adapter unit test proves live issuance.
- A Certbot zero exit status does not prove that the archive is portable.
- `--config-dir` does not, by itself, rewrite stale absolute paths in an
  imported renewal configuration.
- Private directory checks alone do not neutralize hostile restored hooks,
  symlinks, or path references.
- No general-purpose Certbot option or third-party DNS plugin injection is
  supported.

## Adversary and Failure Model

Threats include shell argument injection, malicious archived renewal hooks,
unexpected paths outside a producer workspace, symlink escapes, missing or
corrupt ACME accounts, issuance failures after TXT writes, CA rate limits,
incorrect SAN replacement, and premature publication.  Tests must assert
negative side effects and preservation of the last known good archive.

## Operational Constraints

- Certbot MUST use a named lineage and explicit DNS-only option vector.
- SAN values MUST be separately validated and passed using quoted Bash arrays.
- No HTTP challenge or server-installing Certbot invocation MAY be used.
- The producer MUST validate restored paths before Certbot and publication.
- Certbot state portability MUST be demonstrated across producer workspaces.
- The initial isolated adapter MUST NOT enable public issuance by itself.

## Considered Alternatives

Global `certbot renew` was rejected because it would operate on omitted
lineages.  Unconditional `--force-renewal` was rejected due to unnecessary CA
rate-limit consumption.  Publishing Certbot's transient `--config-dir` output
without restoring it was rejected for path portability and integrity reasons.
A generic caller-supplied list of Certbot flags was rejected because it allows
unsupported challenge methods and trust-boundary changes.

## Consequences

Implementing issuance safely requires integration work beyond command
construction.  The first reviewable adapter can be tested under fake
executables while live operations remain unreachable from the public CLI.
A subsequent change must resolve renewal-configuration portability and capture
the final approach in a governing ADR before archive publication is enabled.

## Related Decisions

ADR-018 defines certificate inputs and SAN identity.  ADR-019 defines archives
and the consumer boundary.  ADR-020 defines statically bundled providers.
ADR-022 defines serialization and publication constraints.  ADR-023 governs
the executable flavors and required testing.
