# ADR-030: Multiple Independent Certbot Lineages in One Durable S3 Archive

Date: 2026-10-23

## Status

Accepted

## Context

Approved story #56 extends the MVP from one selected Certbot lineage
stored in an existing S3 archive to multiple **independent lineages**
within that **same** archive. The lineages can belong to unrelated DNS
zones, may have overlapping SAN sets, and may change SAN membership
independently. Each ordinary invocation still operates on **one selected
lineage**. Story #15, completed under ADR-029, controls the SAN list
for that one selected certificate; it does not implement multiple
lineages.

Under the current MVP, ADR-023 deliberately rejects an archive with any
lineage other than the selected one, and ADR-027 authorizes packaging
only after selected-lineage checks. ADR-020, ADR-021, ADR-022 and
ADR-028 establish one existing authoritative S3 object, a safe,
portable Certbot layout and validated publication. Those boundaries
must not be lost when the allowed number of lineages increases.

Story #87, already accepted and completed, establishes an exact
non-wildcard `CERT_NAME` identity: use the explicit name when provided,
otherwise derive the shortest complete requested SAN string with the
existing ASCII lexical tie-break. A subsequent SAN change cannot
implicitly rename or choose a different restored lineage. Stories #88
and #89 will separately authorize opt-in `RENEW_ALL` and
`REMOVE_ORPHANS` behavior. Their names do not authorize bulk operations
in this ADR.

## Decision

### One archive, independent lineage identities

Retain **one preexisting bucket and one configured object key**,
default `latest.tar.gz`. The object remains a plain, bounded GNU
tar/gzip archive of the contents of an ordinary Certbot
`/etc/letsencrypt` configuration directory, with **no new manifest,
index, archive root or per-lineage S3 objects**.

Preserve the existing production Let's Encrypt ACME account model:
exactly **one unambiguous previously registered account** in
`accounts/acme-v02.api.letsencrypt.org/directory/<account-id>/`,
including the required registration/key/metadata files. All managed
lineages in this milestone use that account, the production endpoint,
and the approved DNS Route53 authenticator; account discovery,
registration or account switching is not implied.

A complete lineage named `N` is represented **together** by:

- `renewal/N.conf`, with the canonical validated
  `/etc/letsencrypt` paths to that same `N`;
- `live/N/`, containing exactly the supported Certbot live links to
  `../../archive/N/<part><version>.pem`; and
- `archive/N/`, containing the matching versioned certificate,
  chain and private-key material and permitted history.

All three representations must agree on the **same exact case-sensitive
lineage identifier**. A renewal file without both matching directories,
an orphan directory, a mixed-name live link, a noncanonical or
unrecognized renewal file, an unsafe private key or a hook-bearing
configuration is **invalid archive state**. Zero lineages remains a
supported seeded account-only archive. One complete lineage remains
the original MVP-compatible form. Two or more complete lineages form
the new supported shape, subject to the existing archive member,
byte-size, path, header, symlink and permissions limits. No separate
per-lineage metadata object is introduced.

Example (illustrative, not an additional format):

```text
accounts/acme-v02.api.letsencrypt.org/directory/account-id/...
renewal/example.com.conf
live/example.com/{cert,chain,fullchain,privkey}.pem
archive/example.com/{cert1,chain1,fullchain1,privkey1}.pem
renewal/unrelated.org.conf
live/unrelated.org/{cert,chain,fullchain,privkey}.pem
archive/unrelated.org/{cert1,chain1,fullchain1,privkey1}.pem
```

The `live/` members in this diagram are **relative symlinks**, not
regular PEM files or absolute references. Persisted renewal paths
remain canonical regardless of which ephemeral runner created them.
The existing pre-extraction tar validator must continue to reject
unsafe member names, links, modes, special types, duplicate paths,
unsupported extensions and oversized archives **before extraction**.

### Stable selected identity; overlapping names are legal

One runtime invocation resolves the desired SAN set using ADR-029,
then resolves one exact selected lineage identifier under ADR-020 and
story #87. `CERT_NAME` takes its usual CLI > exported environment >
literal `.env` precedence. With no explicit name, the deterministic
shortest textual SAN rule remains; the implementation **does not guess**
which restored lineage corresponds to current SAN content.

Lineage names are unique keys in the `renewal`, `live` and `archive`
namespaces. Two different lineages may contain the same or overlapping
DNS SANs without being merged, renamed, implicitly discovered, or
selected by SAN overlap. An exact selected name never falls back to
the first directory, a name-derived neighbor, a numbered Certbot
lineage, or a different stored certificate.

A selected name may be:

- **absent**, while zero or more other complete lineages are present:
  perform selected-only first issuance using the existing account and
  preserve every unselected lineage; or
- **present**, with other complete lineages also present: use selected
  named ordinary renewal/no-op or ADR-029 SAN reconciliation, preserving
  all unselected lineages.

Partial or ambiguous **selected or unselected** state fails closed,
including when the named selection is absent. Account-only original
MVP input must continue to work. A shorter new SAN on a preexisting
lineage requires the original `CERT_NAME` to be supplied explicitly
when shortest-name derivation would otherwise select a different name.
No automatic renaming, adoption, `--duplicate`, `--expand`, or
suffix-numbering is authorized.

### Preflight and operation boundaries

After the existing safe archive restoration and account preflight,
construct a bounded, deterministic inventory from the matched
`renewal/N.conf`, `live/N`, and `archive/N` trees. Validate
**all lineages**, including those the user did not select, for
structural completeness, file ownership/privacy, safe intra-lineage
links, supported canonical renewal mapping, expected account and
Route53/production identity and absence of executable hooks.
Reject unexpected or incomplete member paths; do not silently
prune malformed nonselected state to make the selected operation work.

Read-only validation of **unselected** metadata must not rewrite
their renewal files. The existing `prepare` and `finalize` mapping,
Certbot `certonly` or `renew --cert-name`, and leaf/key verification
are applied **only to the selected lineage**. The state adapter may
report selected `absent` or `present` after validating the whole
inventory. No global `certbot renew`, orphan removal, other-lineage
selection or implicit ACME registration can occur.

Before any publication, prove the selected post-state is valid **and**
revalidate the whole resulting archive inventory and all canonical
unselected renewal configurations. Retain unselected material
byte-for-byte at the extracted-file level: PEMs, private keys, renewal
metadata, archive-version history, permissions and symlink targets.
Because the gzip/tar candidate is rebuilt, the complete archive's
compressed bytes and header metadata may legitimately differ.
Tests must compare each preserved file's contents and appropriate
metadata, **not demand byte-for-byte identity of the whole tarball**.

The publication candidate must package **the entire validated
configuration tree**, not a selected-lineage subset. The existing
one-key publisher remains the only writer, and ADR-028's
`UPLOAD_NO_RENEWAL` and no-op policy remain unchanged. No-op
operations still verify restored state and skip PutObject when no
durable changes occurred and the override is false. A failure during
selected Certbot, postvalidation, serialization, S3 transfer or
unselected-state integrity checks never intentionally publishes an
incomplete candidate.

### Compatibility and migration

**No storage migration command is required.** A preexisting
account-only or valid one-lineage MVP tarball remains readable.
Adding a second lineage uses the already-seeded archive and existing
account. The first successful multi-lineage upload produces the same
layout with additional validated lineage subtrees under the same
bucket/key. An ordinary one-lineage archive must continue to
roundtrip without format changes. A later invocation on a fresh
runner may select either stored lineage by its stable exact name.

The previous ADR-023 **one-lineage count restriction**, and
corresponding selected-only *state-eligibility* restriction in ADR-027,
are superseded solely for valid **complete additional lineages**.
Their account, hook, private root, safe mapping, publication and
pre-extraction security checks remain binding. ADR-029's limitation
to **one selected lineage per invocation** and ADR-020/028's
**one authoritative S3 object** remain binding.

### Constraints for tasks #61 and #62

- MUST retain a literal single selected identity, never infer it from
  overlapping SANs, or silently renumber it.
- MUST validate the account and the **entire** multi-lineage inventory
  before Certbot and before publishing a candidate.
- MUST allow selected absent with other complete lineages present,
  and selected present with other complete lineages present.
- MUST preserve unselected lineage file bytes, supported metadata,
  symlink targets and key privacy across local operation and
  cross-runner publication/restore.
- MUST restrict Certbot and runtime renewal mapping to the selected
  lineage; MUST NOT globally renew or delete another lineage.
- MUST preserve the entire supported configuration in the same one-key
  tar.gz, and keep existing safe archive limits and format.
- MUST preserve account-only and one-lineage compatibility.
- MUST not create accounts, buckets, objects or distributed locks.
- MUST use mocked AWS/Certbot tests for the initial development
  acceptance, with local tar/gzip/OpenSSL where possible, and run
  all three shipped Bash artifacts including the Bash 4.3 floor.
- MUST not claim that independent multi-runner tests prove
  concurrent-write safety, live ACME authorization or S3 rollback.

## Decision Drivers and Assumptions

- Multiple independent certificates need different stable Certbot
  renewal identities even when DNS SANs overlap.
- Existing tarball and installed-Certbot compatibility matter more
  than an optimized per-lineage index or minimal upload size.
- Account reuse is valid because the story assumes the account exists;
  creation of new ACME accounts has a separate milestone.
- No production runbooks are required by this design task;
  production-readiness documentation belongs in Milestone #13.
- External orchestration serializes writers to the one S3 key.
- Trusted installed Certbot and AWS CLI are external tools, not
  sandboxed by Bash, and local simulated tests cannot establish
  live-service behavior.

## Alternatives Considered

**One S3 object per certificate:** rejected by story #56; it would
discard the common archive and multiply the durable state objects.

**Archive selected lineage only and recover others from another
source:** rejected; the selected invocation has no second authorized
durable source and would overwrite unrelated state.

**Allow unvalidated nonselected lineage trees to pass through
unchanged:** rejected; restored archive content remains untrusted,
and arbitrary renewal metadata, symlinks or executable hooks could
cross the authority boundary during future operations.

**Automatically identify a lineage by SAN intersection or certificate
common name:** rejected; overlaps and changing SANs cannot provide a
unique durable identity. Honor the selected literal `CERT_NAME`.

**Rename or allocate numbered lineages on collision:** rejected; it
hides identity errors and risks issuing the wrong private keys.

**Map all renewal paths to private runner paths for each invocation:**
rejected as unnecessary mutation of unselected state. Validate every
lineage canonically, and map only the selected lineage during work.

**Prune incomplete or unrelated lineages:** rejected; default
`REMOVE_ORPHANS=false` and scope exclusion forbid deletion,
and malformed state must fail before issuance.

**Renew every restored lineage as a safety check:** rejected as an
unapproved expansion of certificate authority. Future
`RENEW_ALL=true` is separate opt-in behavior, not the default.

**Introduce a manifest or new internal archive root:** rejected
because existing valid single-lineage archives should remain
directly usable without a migration step.

**Trust only a passing selected lineage check before publication:**
rejected because it could publish damaged unselected renewal state.

## Consequences, Threats, and Limits

The state preflight and candidate builder must inventory more than
one lineage, increasing local validation work and the number of files
whose integrity must be checked. The existing global tar member/size
limits still apply. Cross-lineage links, aliases, incomplete triplets,
unexpected account/renewal scope and unsafe hooks are rejected.
Operator-managed secrets from **all** lineages reside in the same
plaintext S3 object: access to one common archive is access to all
certificate keys. This is deliberate until the separately approved
client-side encryption milestone; it must be highlighted in future
production-readiness instructions.

A failed selected operation may have already made external DNS/ACME
requests; it must not publish a candidate that violates validation.
A failed PutObject can leave remote status uncertain, especially after
server acceptance. The design offers no transactional rollback,
cross-runner locking, concurrent-writer resolution, or promise of
per-lineage independent remote updates. Every successful upload
replaces the entire shared object; this increases the importance of
external writer serialization.

A second lineage in the same tarball is not necessarily a second
same-invocation issuance. All other lineages are unselected and must
remain untouched by ordinary selected-only work.

## Expected Outcomes and Acceptance Evidence

Task #61 should add focused state-inventory, publication, selected
issuance/renewal/no-op, and negative tests before changing runtime
adapters. Task #62 should prove public command operations on two
independent lineages through a fresh-runner roundtrip, unchanged
unselected state, malformed archive/selection negative cases,
verified no-op, failed selected issuance, and negative PutObject
checks across development, stripped and minified artifacts.

Passing mocked tests and CI establish only the specified local
behavior under test doubles. Live multi-lineage Certbot/Route53/S3
interoperability is not yet verified.

## Relationships

- ADR-019: live `approved` labels authorize distinct issues.
- ADR-020/021/022: stable selected certificate, one existing archive,
  safe S3 retrieval and validated portable tar state.
- ADR-023: original one-lineage eligibility count, partly superseded
  for complete unrelated lineages.
- ADR-024/025/026/029: selected provider, due renewal, SAN changes,
  and unrelated SANs within one certificate.
- ADR-027/028: candidate verification and single-key publication,
  with selected-only eligibility expanded to whole-inventory safety.
- Story #87: exact explicit or deterministic default selected name.
- Story #56 and tasks #60–#62: independent lineages in one archive.
- Stories #88 and #89: separately authorized bulk renew and orphan
  removal, excluded here.
