# ADR-020: Build-Time Discoverable, Bundled DNS and Storage Backends

Date: 2026-10-15

## Status

Accepted

## Intent and Documentation Posture

Use the modular and discoverable plugin pattern for maintainable provider separation without creating an arbitrary consumer plugin interface.

## Context

The initial release supports only AWS Route53 for DNS-01 authentication and AWS S3 for persistent archive storage.  Future providers are plausible, but making a consumer-side plugin installation or dynamic loading mechanism would expose additional code execution and trust boundaries that the project does not need.  The inherited template ADR-004 demonstrates lexical discovery and registration; ADR-014 distinguishes this from a universal runtime extension architecture.

## Decision Drivers

- Add a provider by adding a reviewed, in-tree source module instead of editing a central enumeration.
- Keep provider selection explicit and failure messages unambiguous.
- Retain deterministic source assembly and three standalone release artifacts.
- Avoid sourcing arbitrary files after installation.
- Keep storage and DNS interfaces separate because they have different authority and dependencies.

## Decision

Maintain explicit ordered core modules and separate build-time discoverable source directories, provisionally `lib/plugins/dns/*.bash` and `lib/plugins/storage/*.bash`.  Make discovers and concatenates their maintained Bash files deterministically.  Each included module registers a fixed provider identifier, capabilities, and implementing functions through a small internal registry.  The initial DNS provider is `route53`, and the initial storage provider is `s3`.  Additional source modules may be developed later and become usable only when reviewed, built, tested, and shipped in an official artifact.

The runtime artifact contains all provider implementations.  It MUST NOT scan directories, source external plugin files, download code, or accept arbitrary plugin paths.  Provider identifiers are an internal distribution capability, not a public third-party plugin ABI.  Unknown providers fail closed.  A future change to shipped providers requires repository review, an update to the dependency/security assessment, and tests.

The DNS interface supplies supported Certbot DNS-01 authentication options without constructing shell command strings.  The storage interface supplies authenticated object download, confirmed object existence/missing distinction, upload, and (in a later revision) shared-lock operations.  For S3-compatible storage, an optional `S3_ENDPOINT_URL` configures the AWS CLI endpoint; MinIO is the same S3-compatible backend, not a distinct implementation by default.  Neither interface handles arbitrary HTTP-01 challenges.

Only the `s3` backend uses AWS S3 semantics initially; `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and optional session tokens follow the normal AWS credential chain.  Provider dependencies are system/runtime tools and must not be installed implicitly by `make build`.

## Promises

- Source discovery is deterministic and happens at build time only.
- Every shipped flavor includes the same reviewed provider set and dispatch behavior.
- S3-compatible endpoints are parameterized without claiming every S3 implementation has identical semantics.
- Storage and DNS adapters remain separately testable through explicit function contracts.

## Non-Promises

- Consumers cannot add or hot-load provider implementations into released scripts.
- A configured S3-compatible endpoint is not automatically validated as MinIO-compatible.
- The initial release is not a general ACME client or universal cloud provider SDK.
- Module registration does not isolate plugins from process credentials; included Bash runs with the same authority.

## Adversary and Failure Model

Runtime loading of untrusted code, provider-name injection, mixed storage identities, accidental use of the wrong endpoint, credential leakage, and unsupported endpoint semantics can compromise certificates.  Provider names and endpoints must be validated; credentials must not be logged; production artifacts must not source untrusted paths.  Storage backend extensions must be reviewed as increases to the trusted computing base.

## Operational Constraints

- Provider discovery MUST be deterministic and restricted to maintained build input.
- Runtime loading, third-party plugins, and dynamically sourced provider files MUST NOT be supported.
- The first release MUST include only `route53` and `s3` implementations.
- The storage provider MUST support a configurable S3-compatible endpoint URL.
- Provider selection MUST be explicit and fail on unknown values.
- No HTTP-01 or TLS-ALPN-01 providers MAY be added under this decision.

## Considered Alternatives

A monolithic AWS-specific script was rejected because it would obscure extension seams.  A fully dynamic runtime plugin API was rejected because it adds distribution, compatibility, and security obligations without an initial use case.  Separate MinIO handling was rejected because compatible S3 operations belong behind the same initial adapter unless empirical differences justify a specialized backend.

## Consequences

Adding providers becomes an ordinary repository change and release event.  The Bash registry adds modest internal machinery but does not require consumer setup.  This refines, rather than contradicts, inherited ADR-004 and ADR-014.

## Related Decisions

ADR-018 sets DNS challenge policy.  ADR-022 defines storage consistency and eventual locking.  ADR-023 governs build/release dependencies.
