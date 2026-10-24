# Multiple Certificate Lineages: Shared Archive and Selection Contract

Status: **design-only specification for task #60**. It is the target for
implementation task #61 and the comprehensive cross-runner verification
task #62. Governing decision:
[ADR-030](adr/ADR-030-shared-archive-multiple-lineages.md).
This extends the [MVP archive layout](mvp-archive-layout.md) and
[restored state preflight](mvp-state-preflight.md) rather than replacing
their existing security requirements.

## One selected certificate, multiple stored certificates

One CLI invocation uses one validated, stable `CERT_NAME` selected by
the operator or the existing shortest requested SAN rule. It does
**not** target all certificates whose SAN names resemble or overlap
the requested DNS names. The selected certificate may contain multiple
unrelated SANs as defined by ADR-029, while independent certificates
may have overlapping or entirely unrelated name sets.

The preexisting S3 bucket/key, default `latest.tar.gz`, remains the
**single authoritative object**. A failed or ambiguous remote lookup
never means permission to create an unseeded object.

A supported durable state is either account-only, one complete
lineage, or two or more complete lineages. In all cases the supported
archive contains one existing production ACME account identity.
No new top-level format is introduced.

## Logical portable tar.gz layout

```text
accounts/acme-v02.api.letsencrypt.org/directory/<account-id>/...
renewal/example.com.conf
live/example.com/
    cert.pem -> ../../archive/example.com/cert1.pem
    chain.pem -> ../../archive/example.com/chain1.pem
    fullchain.pem -> ../../archive/example.com/fullchain1.pem
    privkey.pem -> ../../archive/example.com/privkey1.pem
archive/example.com/
    cert1.pem, chain1.pem, fullchain1.pem, privkey1.pem
renewal/unrelated.org.conf
live/unrelated.org/
    cert.pem -> ../../archive/unrelated.org/cert1.pem
    chain.pem -> ../../archive/unrelated.org/chain1.pem
    fullchain.pem -> ../../archive/unrelated.org/fullchain1.pem
    privkey.pem -> ../../archive/unrelated.org/privkey1.pem
archive/unrelated.org/
    cert1.pem, chain1.pem, fullchain1.pem, privkey1.pem
```

The archive stores the **contents** of `/etc/letsencrypt`, never an
absolute host path. Every lineage name is an exact validated literal
key represented by its `renewal` file and both matching directories.
All links remain canonical relative links to the **same lineage** and
versioned certificate material. Renewal configuration paths remain
canonical `/etc/letsencrypt` paths while persisted, not temporary
runner paths. Normal GNU tar/gzip format, existing ustar/member bounds
and rejection of unsupported member/header/link types remain binding.

This contract does not require identical **compressed archive bytes**
after repackaging: headers/serialization can change. Instead, compare
unselected **file bytes** and supported metadata, key permissions,
history and symlink destinations. No credentials may appear in public
diagnostics. Additional lineages are not automatically generated
from SAN inputs and are never one shared certificate.

## Dispatch and fail-closed cases

| Restored configuration | Selected name | Expected operation |
| --- | --- | --- |
| Existing account, zero lineages | Not present | Selected-only first issue |
| Existing account, lineage A | A | Selected-only renew/no-op or SAN reconcile |
| Existing account, lineage A | B | Selected-only new issue for B, preserving A |
| Existing account, A and B | B | Named renew/no-op or SAN reconcile B, preserving A |
| Existing account, A and B | A | Named renew/no-op or SAN reconcile A, preserving B |
| Existing account, A and B | C | Selected-only new issue for C, preserving A and B |
| Missing or competing account identities | Any | Fail before Certbot/PutObject |
| Incomplete/foreign/cross-linked lineage, including an unselected one | Any | Fail before Certbot/PutObject |
| Stale/unsafe/noncanonical unselected renewal metadata | Any | Fail before Certbot/PutObject |
| Selection derived to an unsafe wildcard lineage | Any | Reject before AWS/Certbot |
| Selected issuance/renewal/verification fails | Any | No candidate publication |

The selected literal name, not a SAN scan, determines whether the
operation is `absent` or `present`. No `-0001` auto-suffix,
`--duplicate`, `--expand`, global `renew`, unselected path mapping,
or implicit account registration is allowed.

Before Certbot, read-only validation inventories and checks **every**
restored lineage, including unselected ones. The existing
`prepare`/`finalize` renewal mapper runs only on the selected
lineage. Selected post-state must have exact desired SANs and pass the
normal certificate/key and canonical metadata gates; all other lineages
must still be complete and unchanged before publication.

On verified successful change, package the **entire configuration
tree**, validate candidate tar bytes and upload exactly to the
original bucket/key. If neither selected nor account state changed,
the existing no-op policy skips upload unless
`UPLOAD_NO_RENEWAL=true`. That override never bypasses validation.

## Migration and non-promises

Preexisting account-only and valid one-lineage MVP archives remain
compatible without a special conversion or filename change. The first
ordinary successful invocation that selects a new lineage adds its
files within the same archive alongside already stored lineages.

An archive with two certificates necessarily contains secrets for
both. Whoever can read the unencrypted S3 archive can read both
private keys and the ACME account. Client-side encryption belongs
to Milestone #3; runbooks and production access guidance belong
to Milestone #13.

The archive has no distributed lock, compare-and-swap guarantee,
in-place S3 rollback, implicit bulk renewal, default orphan deletion,
or per-lineage S3 isolation. Operator-controlled external serialization
remains required. The `RENEW_ALL` and `REMOVE_ORPHANS` opt-ins
are reserved for separately approved stories #88 and #89.

## Required implementation and verification

**Task #60:** ADR-030 and this public/design contract, plus decision
summary. No runtime behavior changes and no premature release
documentation are authorized by the design-only PR.

**Task #61:** Write focused Bats contracts first, then extend
`certbotbot_state_lineage`/`certbotbot_state_preflight`,
selected provider routing, canonical metadata validation and
candidate packaging. Enumerate all lineages safely; require exact
matching triplets, validated unselected canonical metadata and no
cross-lineage symlinks; preserve existing private S3/archive gates.
Never rewrite unselected renewal files or use global Certbot actions.

**Task #62:** Use mock AWS/Certbot with actual local tar/gzip/OpenSSL to
prove a one-lineage archive can add another lineage and survive
fresh-runner restore, selected renewal/no-op on either lineage, and
continued preservation of unselected bytes and metadata. Cover
overlapping SANs with explicit different lineage names, account
identity, absent/invalid selection, malicious/partial nonselected
trees, failed Certbot, invalid candidate, one-key positive and
negative PutObject paths. Test `make check`, `make test` across all
three generated artifacts and the Bash 4.3 compatibility floor.
Do not claim live Let's Encrypt/Route53/S3 validation from mocks.
