# RENEW_ALL: Archived-Lineage Bulk Renewal Design Contract

**Design status:** Accepted ADR-058 under merged PR #283 (task #98).
**Implementation status:** Task #99 implements the opt-in path; its branch
must pass review and tests before a release can claim this behavior.
The broader independent clean-runner acceptance matrix remains task #100.
See [ADR-058](adr/ADR-058-opt-in-archived-lineage-bulk-renewal.md).

## Intent and ordinary compatibility

Opt-in scheduled maintenance must check every *existing* validated Certbot
lineage in the one restored authoritative archive. It must not turn ordinary
one-selected-lineage operations into global operations, use SANs as lineage
identities, or create accounts. Two lineages can share SANs and must still be
treated as independent.

| Resolved mode | Effective explicit selected DNS identity | Archived lineages | Authorized action |
| --- | --- | --- | --- |
| `RENEW_ALL=false` (default) | Missing | Any | Reject before S3 access, as today |
| `RENEW_ALL=false` | Present | 0 or more valid | Existing selected issuance or selected renewal/SAN reconciliation only |
| `RENEW_ALL=true` | Missing, with no contradictory selected inputs | One or more valid | Check each archived lineage once; no issuance or SAN modification |
| `RENEW_ALL=true` | Missing | Account-only or missing/invalid archive | Reject, no successful empty bulk check |
| `RENEW_ALL=true` | Present, selected lineage already archived | One or more valid | Ordinary selected action once, then check each other original archived lineage once |
| `RENEW_ALL=true` | Present, selected lineage absent | 0 or more valid | Explicit selected issuance once, then check each originally archived lineage once |
| Both bulk feature flags true | Any | Any | Reject before S3 or provider work, until separately approved policy |
| Any mode | Partial/malformed selected inputs, invalid account, or partial/cross-linked lineage | Any | Reject without provider mutation or candidate publication |

A partial selected request includes `CERT_NAME` or `ADDITIONAL_SANS`
without a supplied `DOMAIN`; explicit invalid/empty `DOMAIN` is never
silently converted to domainless maintenance. Explicit non-default
`INCLUDE_SUBDOMAINS` without a selected identity is likewise invalid.
The ordinary derived `CERT_NAME` rule still applies when a selected
DNS identity exists.

## Proposed public configuration

`--renew-all true|false`, `RENEW_ALL=true|false` in the exported
environment or literal configuration file, and the existing parser's
`--renew-all=true|false` spelling. The default is `false`; resolve
presence independently with CLI > exported environment > literal file >
default. `--no-env` suppresses the latter two sources, not an explicit
command-line option. Reject unknown values; no implicit truthiness, silent
fallback, or unapproved abbreviation. Do not expose bulk behavior on
`register` or the read-only client.

An operator-supplied `DOMAIN`, `CERT_NAME` and `ADDITIONAL_SANS`
are a *single selected-certificate request*, not a list of archived
lineages. `RENEW_ALL` independently authorizes enumeration of all
verified existing lineages. `REMOVE_ORPHANS` is a different future
opt-in and must not infer a desired set from these arguments.

## Lifecycle sketch

1. Parse and validate inputs, including the conflicting-flags guard,
   before obtaining S3 or Certbot authority.
2. Restore the single configured S3 object into a fresh mode-0700
   workspace. Validate the existing account and CA, all archive
   structures, renewal configurations, hooks, links, and key permissions.
3. Capture the original unique lineage identities from complete
   `renewal/N.conf`, `live/N/`, and `archive/N/` triplets, sorted
   by exact case-sensitive name under `LC_ALL=C`. Never use SAN
   matching to infer membership. No untrusted archive value becomes
   shell source.
4. If an ordinary selected identity was explicitly requested, run its
   existing authorized selected action once. Any newly issued selected
   lineage is **not** added to the initial bulk enumeration.
5. Visit every name in the original snapshot exactly once, excluding an
   already processed selected archived name. Before each visit, verify
   the whole state and fingerprint unrelated lineages. Invoke only
   `certbot renew --cert-name NAME`, with that lineage's validated
   persisted SANs, restored account, selected CA, Route53 authenticator,
   private paths, and hook suppression. Verify the target, canonicalize
   its renewal metadata, and reject unexpected changes to other lineages.
6. If any local action fails, return nonzero and discard local state.
   Do not publish successfully renewed *subsets* of the archive.
7. On complete success, confirm all initial members survive, all
   lineages and account data remain valid, and all certificate/key/SAN
   contents pass post-operation checks. Compute one durable-change
   Boolean across all permitted modifications; do not infer change
   from Certbot exit zero.
8. Use the existing candidate validator and publisher once, to the
   exact retrieved S3 bucket/key. `UPLOAD_NO_RENEWAL=true` may
   republish an unchanged **validated** result; never after failure.
   Encryption, dated backup and retention retain their existing gates.

## Result categories

For each *successful existing lineage check*, record precisely one:
**renewed** (new certificate leaf bytes or selected link target),
**metadata-only** (no certificate replacement but durable validated
state changed), or **unchanged**. Report aggregated bounded counts
only after all checks succeed. An explicit first issuance is a separate
**issued** result and is not counted as an archived renewal.
A selected existing-lineage SAN reconciliation may change its certificate
and is counted once, not followed by an additional archived check.

A Certbot failure, unsafe mutation, verification failure, or
unrecoverable mapping error returns nonzero and no successful complete
summary. Such failure cannot authorize partial local publication.
On failure of a remote PutObject, the reported status is nonzero
**but the actual remote outcome is uncertain**; there is no guaranteed
rollback. S3 writers still require external serialization.

## Security and acceptance tests for tasks #99 and #100

Public-executable mocked AWS/Certbot tests must establish that false
mode never modifies an unrelated archived lineage, true mode checks
each exact name once, empty domainless mode fails, overlapping SANs
do not merge identities, no global Certbot call occurs, and unselected
SAN drift is refused. Positive tests must include mixed due/no-op,
metadata-only, selected-existing/selected-new, and unchanged with
both `UPLOAD_NO_RENEWAL` values. Negative tests must include
incomplete triplets, bad canonical metadata, wrong account or CA,
provider failure on the second lineage, cross-lineage mutation,
malformed settings, contradictory flags, and failed/uncertain S3
publication. A fresh independent runner must restore and check all
lineages after a successful complete publication.

Test the three shipped producer flavors and their adjacent SHA-256
checksums, minimum Bash 4.3 compatibility, literal-file/CLI/env
precedence and `--no-env`, account-only compatibility, and
retained privacy. Local Pebble/SeaweedFS challenge-bypassed results
do **not** prove live Route53, Amazon S3, or Let's Encrypt acceptance.
Milestone #4 owns separate live staging verification.

## Related work

- [Story #89](https://github.com/wesley-dean/certbotbot/issues/89):
  Product acceptance for `RENEW_ALL`.
- [Task #98](https://github.com/wesley-dean/certbotbot/issues/98):
  This design/architecture decision.
- [Task #99](https://github.com/wesley-dean/certbotbot/issues/99):
  Implement config/parser, inventory, provider routing and publisher
  integration against the approved contract.
- [Task #100](https://github.com/wesley-dean/certbotbot/issues/100):
  Independent black-box acceptance and fresh-runner evidence.
- [ADR-030](adr/ADR-030-shared-archive-multiple-lineages.md):
  Still governs ordinary selected-only behavior and complete-state safety.
- [ADR-058](adr/ADR-058-opt-in-archived-lineage-bulk-renewal.md):
  Deliberately narrow opt-in bulk exception to that rule.
