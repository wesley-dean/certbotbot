# ADR-020: One Selected Certificate and One Durable Archive

Date: 2026-10-21

## Status

Accepted

## Decision

Milestone #1 exposes one DNS identity per invocation, expands it to its
apex/wildcard complement only when requested, and binds it to a stable
Certbot lineage name. The operator may override `CERT_NAME`; otherwise the
shortest textual SAN is chosen, breaking equal-length ties lexically.
An existing archived lineage is never silently renamed or suffix-numbered.

Settings resolve independently as CLI > environment > literal .env >
defaults. Configuration files are treated as data, never sourced as shell
code. The only authoritative durable object is the existing configured
S3 archive key, defaulting to `latest.tar.gz`. The archive represents
the relative contents of `/etc/letsencrypt`, with a preexisting ACME
account. Its absence is fatal. Certbot uses a private restored configuration
tree; the host's `/etc/letsencrypt` does not supply missing account state.

Publication follows durable-state change, except that
`UPLOAD_NO_RENEWAL=true` forces a validated republish of a successful
unchanged no-op. Any failure before upload forbids publication. Writers
are externally serialized; the MVP does not offer transactional S3 updates.

## Context, constraints, and assumptions

The tool must work across independent runners, without creating
Let's Encrypt accounts, cloud resources, or arbitrary new certificates.
The private key, ACME account and renewal metadata are durable state.
An archive can legitimately contain only registered account state before
the first issuance. The available operator AWS and Route53 rights are
limited to existing infrastructure, and external tools are mocked during
milestone #1 validation.

The Bash 4.3 baseline, standalone artifact model, source documentation,
threat modeling, and observable Bats testing requirements remain governing
under ADR-002, ADR-006, ADR-007, ADR-008, ADR-009, ADR-014, and ADR-016.

## Alternatives considered

- **Bootstrap missing archives:** rejected; could silently replace the
  existing ACME account and violate the seeded-object prerequisite.
- **Import local Certbot state:** rejected; independent runners would behave
  differently and could expose unrelated host material.
- **Let Certbot choose an automatic lineage name:** rejected; naming drift
  or numeric suffixes could create unintended lineages.
- **Use global `certbot renew`:** rejected; that could touch unrelated
  certificates. A selected-only operation is mandatory.
- **Source .env with Bash:** rejected; a configuration file would execute
  code with the tool's AWS and private-key authority.
- **Maintain multiple or date-versioned S3 objects:** deferred explicitly
  beyond the single-object MVP.
- **Introduce S3 distributed locking:** deferred; coordination and recovery
  remain operator responsibilities for this milestone.

## Consequences and security tradeoffs

A missing or unsuitable account fails before issuance. Archive extraction
must reject traversal, unsafe links, special members, and unexpected
ownership/permission changes. Parsing must reject shell syntax; diagnostics
must not leak secret input values. A private workspace and prepublication
validation reduce accidental disclosure/corruption but do not sandbox the
trusted external Certbot/AWS executables. With a single S3 key, concurrent
writers can overwrite each other's work and partial publication is possible.
These are explicit residual risks rather than guarantees of atomicity.

## Expected outcomes and compatibility

A validated account-only archive permits first issuance. A second independent
runner restores the same account/lineage and can no-op or renew without
renaming it. Existing archives with conflicting lineage state must fail
closed pending deliberate migration. Default unchanged no-ops avoid S3 writes;
the explicit Boolean override can republish the same validated key.

The config and behavior tables in
[the MVP contract](../mvp-configuration.md) are normative public details.
Live account and cloud interoperability will be assessed in milestone #4.

## Related decisions

ADR-001 determines documentation priority. ADR-014 permits replacing
starter runtime plugin examples with product-specific direct orchestration.
ADR-015 and ADR-016 govern external-tool authority and threat review.
ADR-019 governs approval by current issue labels.
