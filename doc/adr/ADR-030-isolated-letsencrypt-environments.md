# ADR-030: Production-Default Let's Encrypt Staging Selection and Storage Isolation

Date: 2026-10-16

## Status

Accepted

## Decision

certbotbot selects exactly one Let's Encrypt ACME environment per invocation.
`production` is the default and must behave as the project's originally
specified issuer.  `staging` is an explicit opt-in for nonproduction
issuance and end-to-end validation.  The public CLI accepts `--staging`
and `--acme-environment production|staging`, while the equivalent
`ACME_ENVIRONMENT` variable is useful for Jenkins and GitHub Actions.
Command-line selection overrides the environment variable, but conflicting
command-line mode options fail rather than silently choosing the last.
Unexpected values and missing option arguments fail before backend dispatch.

Only two ACME directory URLs are allowed:

- Production: `https://acme-v02.api.letsencrypt.org/directory`.
- Staging: `https://acme-staging-v02.api.letsencrypt.org/directory`.

The Route53 adapter must use an explicit `--server` argument containing the
selected fixed URL, supplied as a separate argv element.  It must not enable
`--dry-run`, silently switch CA endpoints, interpolate arbitrary URLs,
or permit an operator-supplied alternate server in this first release.
Staging operations request actual **test certificates** in the staging
environment; they are not a dry-run simulation and are not production trusted.

## Persistent object identity and compatibility

Production object keys remain exactly as specified by ADR-019:

- `common-latest.tar.gz` (or `.tar.gz.enc`).
- `<name>-latest.tar.gz` (or `.tar.gz.enc`).

Staging adds a fixed `staging/` key prefix to *both* the common archive and
each selected domain archive:

- `staging/common-latest.tar.gz` (or encrypted equivalent).
- `staging/<name>-latest.tar.gz` (or encrypted equivalent).

The object *contents* are unchanged, and the common/domain split remains
intact.  The producer must build and validate keys from the selected
environment, not concatenate or accept arbitrary operator-supplied
prefixes.  The S3 adapter must independently enforce that unprefixed
production keys cannot be used in staging mode, and staging keys cannot be
used in production mode.  This preserves existing production object names
while making a staging test incapable of overwriting production objects
through the reviewed storage adapter.

An operator may use a dedicated bucket or IAM policy for even stronger
environment isolation.  A key prefix is a logical namespace, not an IAM
security boundary against a principal holding unrestricted S3 access.
Consumers intended for production must fetch only production keys; staging
certificate archives are unsuitable as production TLS artifacts.

## Context and decision drivers

Issue #11 requests a testing/production selector without changing the
default ability to issue trusted certificates.  Ordinary ACME production
issuance has rate limits, making a separate staging mode essential for
safe integration testing.  Let's Encrypt's staging service requires its
own ACME account identity and signs with test roots not trusted by public
client trust stores.  Both ACME identities must be able to survive the
same independent-runner portability workflow, while test certificates
must never replace deployable production state.

ADR-018 governs SAN identity and renewal timing.  ADR-019 governs stable
archive names and direct consumption.  ADR-025 requires a safe restored
Certbot account and portable renewal configuration.  ADR-028 limits
the allowed archived account file layout, including staging identities.
ADR-029 requires cryptographic certificate verification before storage
publication, including explicit staging trust anchors.  This decision
refines the **storage namespace**, without changing those prior
constraints.

## Assumptions

- The initial ACME authority is Let's Encrypt; arbitrary CA endpoints
  are not an exposed user interface.
- The selected AWS/S3 credentials and DNS provider are supplied by each
  independently provisioned runner.
- Every successful run operates against exactly one selected object
  namespace, while production defaults remain unchanged.
- A staging certificate is cryptographically valid only under its
  appropriate staging trust roots, which must be supplied separately
  and must not contaminate a production trust store.
- Independent writers using the same storage collection remain externally
  serialized until the storage-backed lock backlog is implemented.

## Alternatives considered

Using a global `--dry-run` Certbot option was rejected because it is
not the same as persisting a usable staging-only lineage across fresh
producer workspaces.  An arbitrary `--server URL` option was rejected
because it expands the trust boundary and can direct ACME and account
data to an unexpected host.  Changing production keys to `production/`
was rejected to avoid breaking existing production archive identity and
consumer retrieval conventions.  Using identical S3 object keys while
selecting a different CA was rejected as it risks overwriting usable
production certificates with untrusted staging certificates.  A distinct
bucket for every mode was not required because a strictly enforced
prefix provides compatibility with existing bucket configuration,
although separate buckets are an acceptable operational hardening choice.

## Promises

- Default mode uses production ACME and existing storage object names.
- Staging explicitly selects the known Let's Encrypt staging ACME URL.
- A staging mode S3 get or put cannot address a production object key
  through the reviewed adapter.
- Neither mode accepts arbitrary ACME server URLs or unchecked key paths.
- All three standalone artifact flavors expose the same selector.
- Ordinary certificate issuance remains fail-closed until the complete
  persistence and verification workflow is reviewed and tested.

## Non-promises and remaining work

Mode selection does not yet register/select an account, restore or merge
Certbot state, issue a live certificate, or publish an archive from the
public CLI.  The current `--validate` command validates intent and mode
but does not verify an ACME server's reachability.  The active producer
must later verify that restored account metadata and each renewal
configuration refer to the selected ACME authority.  A missing or corrupt
common archive alongside an existing lineage must never be treated as a
fresh registration opportunity.  Test certificates require a separately
reviewed staging CA trust bundle for the ADR-029 verification gate, not
unconditional bypass of chain verification.

The per-host lock is not a distributed lock.  It must eventually cover
the actual environment-specific collection in the producer.  CI-level
and local locks do not coordinate independent Jenkins, Actions, and EC2
writers.

## Tests and operational consequences

Bats tests must cover default production selection, staging via the
CLI and environment, invalid/conflicting modes, both fixed ACME URLs,
unaltered production keys, staging common/domain key prefixes, S3
read/write attempts across environment boundaries, argument-preserving
Certbot `--server` selection, and unchanged fail-closed public issuance.
These tests run against all three generated release flavors and use
PATH-injected fake AWS/Certbot executables.

Before enabling production issuance, integration tests must perform
sequential multi-workspace runs in both environments, verify that a
staging run cannot mutate production objects, that corresponding ACME
accounts are distinct, that the correct renewal server is restored,
and that staging chain verification uses an explicit, isolated test
trust store.  Operator documentation must state that staging certificates
are not suitable for a real public-facing TLS service.

## Related decisions

ADR-018 defines certificate identity.  ADR-019 defines archive names.
ADR-020 governs reviewed provider boundaries.  ADR-022 governs
serialization/publication.  ADR-025 governs renewal portability.  ADR-028
governs common account records.  ADR-029 governs pre-publication
cryptographic checks.
