# ADR-038: Strict, Non-Activating Restored Renewal-Option Policy

Date: 2026-10-16

## Status

Accepted

## Decision

Before preparing a portable renewal-path preview or assessing a restored lineage
as import-ready, certbotbot MUST check **every persisted renewal option** in
the restored `renewal/<name>.conf` against a small, explicitly accepted
Certbot 5.8.0 Route53 profile. The policy is implemented in an internal
Bash 4.3-compatible, read-only validator and invoked from the existing
ADR-037 non-activating import assessment. It does not authorize active
configuration import, Certbot invocation, or publication.

The accepted profile is:

| Section | Keys | Allowed values |
| --- | --- | --- |
| Top level | `version` | Numeric `major.minor` or `major.minor.patch` |
| Top level | `archive_dir`, `cert`, `chain`, `fullchain`, `privkey` | Nonempty absolute paths; ADR-032 independently verifies exact canonical same-lineage relationships |
| `[renewalparams]` | `account` | 32–64 lowercase hexadecimal characters, checked against the staged account under ADR-031 |
| `[renewalparams]` | `server` | Exact selected Let's Encrypt v2 production or staging directory URL |
| `[renewalparams]` | `authenticator` | `dns-route53` only |
| `[renewalparams]` | `key_type` | `ecdsa` or `rsa` |
| `[renewalparams]` | `dns_route53_propagation_seconds` | Optional decimal whole number from 0 through 3600 |
| `[renewalparams]` | `pref_challs` | Optional `dns-01` only |
| `[acme_renewal_info]` | `ari_retry_after` | Optional, syntactically fixed `YYYY-MM-DDTHH:MM:SS` UTC-like value as exercised in the existing Certbot 5.8.0 no-op test |

The six top-level fields and four core renewal parameters are mandatory.
An ARI section, if present, contains exactly one `ari_retry_after`.
Each accepted section appears at most once, and each key appears at most
once within its section. Blank lines and full-line hash comments are
permitted. An unsupported section, key, value, embedded carriage return,
duplicate, or malformed line fails the check. There is no permissive fallback.

The only supported first-release renewal profile is the producer's own
pinned Certbot/Route53 flow. Other Certbot versions, older renewal formats,
and additional useful options will require explicit inspection of real
supported Certbot output followed by a policy update and corresponding tests.
The narrow policy is not a general INI validator or a promise to import
arbitrary existing Let's Encrypt installations.

The new check runs after isolated common/domain restoration and structural
inspection, but **before** the renewal-path preview is created. The existing
ADR-031 identity checker runs as an independent prerequisite, and ADR-032
still governs the five historical paths. No byte in the source renewal file
is altered. A failed check must prevent a successful assessment and preserve
the empty active Certbot configuration. Archive-to-assessment orchestration
must dispose of its private staging trees on failure.

## Context and drivers

ADR-031 authenticates neither account JSON nor unrecognized renewal options.
ADR-032 validates the five path fields but deliberately does not approve
arbitrary non-path fields below `[renewalparams]`. Certbot persists
configuration that it will later honor during renewal, including options
capable of selecting hooks, authenticators, installers, credentials, and
paths. Allowing unsupported settings to pass a preflight would undermine
the production issuer's future trust boundary even if tar extraction and
account identity checks succeeded.

The current credential-free real-Certbot 5.8.0 integration exercise uses
`version`, the five paths, `account`, `server`, `authenticator`,
`key_type`, and an ARI scheduling extension. It uses locally signed
certificates and synthetic account JSON, so it cannot establish
authenticated Let's Encrypt account continuity. This narrow profile
protects the current preparation path while that wider evidence is gathered.

## Assumptions

- Certbot 5.8.0 is the pinned compatibility target for the current CI
  smoke tests; a future supported-version change receives renewed scrutiny.
- The producer is the only intended source of newly published lineage
  records; arbitrary third-party Certbot state is not promised.
- The input file was already extracted into an owned private stage using
  ADR-027 and paired with a complete staged account using ADR-028.
- All identical-rank standalone artifacts embed the same reviewed validator.
- CI can exercise the profile without importing a real account key or
  contacting Let's Encrypt.
- Bash processing is not a general-purpose schema validator, and the
  identity gate's NUL checks remain mandatory.

## Alternatives considered

**Trust Certbot to ignore unrecognized renewal values** was rejected
because some values can change executable behavior or plugin selection.
**Reject only keys with a `hook` suffix** was rejected because the
rest of the option namespace contains equally consequential settings.
**Allow any `[renewalparams]` key after validating its syntax** was
rejected because a syntactically correct value could still be a credential
path, installer directive, or alternative challenge configuration.
**Parse JSON/account state and renewal INI with a new runtime Python or jq
dependency** was deferred; a dependency and account-authenticity policy
requires separate scrutiny and does not replace real ACME confirmation.
**Install the staged account and run Certbot as the validation step** was
rejected by ADR-037 and ADR-032 before genuine staging portability evidence.

## Promises, non-promises, and failure behavior

The policy refuses unknown sections, unknown keys, duplicate fields,
unexpected executable/plugin directives, non-Route53 authenticators,
non-DNS preferences, inconsistent ACME environment, and unsupported
scheduling fields. It leaves source archives and the active configuration
untouched, and emits no secret values in its own diagnostics. The batch
import-assessment helper continues to dispose of its owned private stages
even when the policy rejects a later lineage.

It does **not** prove that accepted values are sufficient for every future
Certbot version, that the ARI timestamp denotes a real future time, that
the account JSON is valid or registered, that a private key matches a leaf
certificate, or that S3 publication is safe. A success does not authorize
renaming, installing, or using a preview with production Certbot.

The public certificate entrypoint continues to fail with status 69.
The release workflow remains gated. A real Let's Encrypt staging
registration, due renewal, changed SANs, complete account reuse, and
independently restorable publication remain release-blocking.

## Verification and operational consequences

Bats tests must cover accepted minimal and optional settings, duplicate
keys and sections, unknown fields and credential paths, injected hook
and installer directives, wrong authenticators, non-DNS challenge options,
invalid key types and propagation values, malformed ARI metadata, and
preservation of the active configuration on failure. Run the tests for
development, ordinary, and minified artifacts. The real-Certbot
three-workspace smoke test must also confirm that the profile accepts
a legitimate observed no-op ARI metadata update in the synthetic fixture.

Adding support for a future Certbot-generated option requires evidence
of its semantics and a focused amendment to this decision. Never expand
the allowlist merely to make a failing fixture pass.

## Related decisions

ADR-018 and ADR-019 define identity and state layout; ADR-025 addresses
Certbot portability; ADR-027 and ADR-028 enforce isolated restoration;
ADR-030 and ADR-031 control the authority and account reference;
ADR-032 governs non-activating path previews; ADR-034 and ADR-035
govern the synthetic real-Certbot ARI tests; and ADR-037 forbids active
state import before genuine account and renewal evidence.
