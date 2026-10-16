# ADR-019: Composable Common and Per-Certificate State Archives

Date: 2026-10-15

## Status

Accepted

## Intent and Documentation Posture

Preserve full Certbot state for renewal while publishing domain archives that are immediately usable by ordinary TLS servers after extraction.  The producer and consumer have separate responsibilities and software dependencies.

## Context

The predecessor persisted a monolithic `/etc/letsencrypt` tarball.  Multiple unrelated certificates on one web server then required sharing one renewal state and made isolation difficult.  Certbot keeps shared ACME account information separately from lineage-specific `archive/`, `live/`, and `renewal/` files.  The web server does not run Certbot and should not need to download ACME account material.

## Producer portability requirement

The common archive is the producer's authoritative portable account-state
checkpoint.  It must allow later runs on fresh Jenkins, GitHub Actions, and
EC2 workers using the same object-store namespace to reuse the original
registration without access to the previous runner's filesystem.  Domain
archives supply lineage-specific renewal state.  Test this through complete
fresh-run integration, not archive-shape inspection alone.

## Decision Drivers

- Renew independent certificate groups without restoring unrelated lineage state.
- Allow a consuming host to install `foo.com` and `bar.com` side-by-side.
- Preserve Certbot's relative symlinks and historical versioned files.
- Generate HAProxy-compatible combined PEM files before publication.
- Avoid requiring Certbot, GPG, or certbotbot itself beyond what the consumer's chosen encrypted/unencrypted extraction workflow requires.
- Minimize exposure of ACME account keys to deployment-only hosts.

## Decision

Publish `common-latest.tar.gz` holding shared account/configuration state, plus one `<certificate-name>-latest.tar.gz` per lineage.  The common archive contains the ACME account material required to restore a renewal-capable producer; the per-certificate archive contains `archive/<name>/`, `live/<name>/`, `renewal/<name>.conf`, and `combined/<name>.pem`.  The `live/<name>/combined.pem` file is also generated.

Combined PEM content is `fullchain.pem` followed by `privkey.pem`, matching the predecessor's ordering.  Combined files are regenerated only for the actively processed lineage; omitted domains remain untouched.  Files must be produced with appropriate restrictive private-key permissions.

Archive paths are relative to the logical `/etc/letsencrypt` root.  Each domain archive must be independently extractable into an empty directory and must preserve its own required relative symlink targets.  Two distinct certificate archives must not contain overlapping member paths other than harmless parent directory entries.  Consumer hosts may extract any combination of certificate archives directly into `/etc/letsencrypt` and immediately reference `live/<name>/fullchain.pem`, `privkey.pem`, or `combined/<name>.pem`.  Consumers do **not** need to retrieve the common archive or have Certbot, ACME tooling, or certbotbot installed.  They own post-install hooks and service reloads.

The producer restores shared state once, then for each selected group restores that group's archive, creates/renews the certificate, writes combined files, prepares the domain archive, and removes the per-lineage working state before the next group.  The shared archive is prepared once after processing all groups.  Publishing cannot claim cross-object atomicity and must preserve the last known good remote state on failed local operations.

## Promises

- Per-domain archives can be composed without post-extraction rewriting or certificate management software.
- Combined PEMs and versioned Certbot files are already present.
- Shared account secrets are not a mandatory download for ordinary TLS-serving consumers.
- Missing objects are valid first-run conditions only after distinguishing a confirmed not-found condition from authorization/network failures.

## Non-Promises

- Extraction alone does not restart or reload HAProxy, Apache, nginx, or other services.
- Raw tar extraction does not safely deploy into an untrusted or concurrently modified filesystem; operator-side staging and validation are recommended.
- Cross-object S3 writes are not atomic.
- The common archive is not needed on a consumer, but it is required by producers restoring the relevant account.

## Adversary and Failure Model

Unexpected archive members can escape the target directory, malicious symlinks can redirect extraction or reads, two lineages can collide on disk, or a failed upload can leave mismatched versions.  Producers must validate archive member paths, types, ownership, symlinks, and lineage scope before extraction; reject nonconforming archives; test restoration from independently produced archives; and avoid unsafe tar defaults for ownership/permissions.

## Operational Constraints

- Every per-certificate archive MUST be self-contained for its declared lineage.
- Consumers MUST NOT need the common archive for certificate use.
- Release-time tests MUST verify symlink resolution, expected PEM contents, and disjoint archive member paths.
- `combined.pem` MUST contain fullchain followed by private key.
- Archives MUST NOT include unrelated lineages or absolute/traversal paths.
- Post-install scripts belong entirely to the consuming host.

## Considered Alternatives

A monolithic tarball was rejected for coupling unrelated certificate sets.  Publishing regular-file-only deploy bundles in addition to management archives was rejected for doubling artifacts and introducing synchronization risk.  Flattening live links was rejected because the same archives must also restore Certbot lineage history.  Requiring deployment hosts to fetch common state was rejected for unnecessary exposure of account credentials.

## Consequences

The format is inspectable and supports common web server configurations, but exact directory layouts and archive names become compatibility commitments.  The producer must validate split-state restore and enforce archive boundaries before the first production release.

## Related Decisions

ADR-018 defines lineage identity.  ADR-021 defines optional archive encryption.  ADR-022 defines publication consistency.
