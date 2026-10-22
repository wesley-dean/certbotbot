# MVP Durable Certbot Archive Contract

Status: proposed implementation and verification contract for approved tasks
#31, #33, #34, #36, and #37; governed by ADR-020, ADR-021, and ADR-022.
Implementation of the validator and runtime adapter remains outstanding.

## Archive layout

A plain `.tar.gz` contains the *contents* of the logical
`/etc/letsencrypt` configuration root, with relative member names.
An initial account-only archive is valid. An example complete layout is:

```text
accounts/acme-v02.api.letsencrypt.org/directory/<account-id>/
    private_key.json
    regr.json
    meta.json
archive/example.com/
    cert1.pem
    chain1.pem
    fullchain1.pem
    privkey1.pem
live/example.com/
    README
    cert.pem -> ../../archive/example.com/cert1.pem
    chain.pem -> ../../archive/example.com/chain1.pem
    fullchain.pem -> ../../archive/example.com/fullchain1.pem
    privkey.pem -> ../../archive/example.com/privkey1.pem
renewal/example.com.conf
```

The example names are illustrative; account identifier and PEM version
numbers are determined by Certbot. Preserve Certbot-written account
and renewal metadata, authorized durable auxiliary files, existing
lineage history, and exact relative symlink relationships. Additional
root entries, hooks, and historical file patterns must be evaluated by
the validator compatibility matrix, not trusted by default. Do not
invent or overwrite arbitrary account JSON structures to satisfy fixtures.

Do not include `/etc/`, an absolute `/etc/letsencrypt` tar prefix,
temporary workspace paths, independent Certbot work/log trees, or AWS
credentials. This is one object, not a set of per-lineage archives.

## Workspace and lifecycle ownership

An invocation owns a fresh mode-0700 directory with isolated
`config/`, `work/`, and `logs/` trees. S3 downloads initially create
an *untrusted* `downloaded.tar.gz` adjacent to, not inside, active
Certbot configuration. After comprehensive validation, extraction
must occur only into an inactive controlled tree. The selected lineage
and its ACME account must then be checked before passing the tree to
Certbot with explicit directory flags.

The archive must remain directly installable under the standard
`/etc/letsencrypt` root. Renewal metadata may contain canonical
absolute paths. An isolated runtime cannot blindly reuse those paths.
The eventual adapter must parse and confirm supported path-bearing
fields, map them to the private workspace for runtime use, then convert
only proven supported fields back to canonical persisted paths before
any candidate upload. Any unexpected field, unknown hook, stale runner
path, or mismatch fails closed. No host path is used as a fallback.

## Security and trust review

| Trust boundary | Allowed inputs | Required refusal |
| --- | --- | --- |
| Operator configuration | One selected bucket, key and DNS identity | Invalid, missing, or shell-evaluated input |
| AWS object read | Existing S3 object bytes | Missing object, denied/ambiguous read |
| Archive preflight | Bounded gzip tar, regular files and verified dirs/links | Traversal, unsafe symlink, hardlink, special/sparse, duplicate or oversized members |
| Private workspace | Fresh owned 0700 tree | Host path reuse, external cleanup, secret echo |
| Account/lineage | Restored registered account and one selected lineage | Absent/mismatched account, hidden extra issuance |
| Certbot invocation | Selected-only Route53 operation, no archived executable hooks | Global renew-all, unknown hook commands, automatic account registration |
| Candidate publication | Validated, normalized, complete candidate | Failure in Certbot, remapping, compression or validation |
| Remote write | One existing S3 key, externally serialized | Local failure, unintended extra keys |

A positive format result is not a positive trust result. Separate stages
must confirm account and certificate identity, accepted ACME server and
Route53 settings, ordinary files behind relative links, and an acceptable
selected-lineage state. All failures must block upload.

## Required verification fixtures

1. Seeded account-only tree and archive; restore under two unrelated absolute
   paths and compare registered-account files.
2. Complete lineage tree containing `archive`, `live`, `renewal`, and an
   existing account; verify symlink targets and renewal references.
3. Canonical absolute-path renewal configuration illustrating the
   difference between link portability and functional renewal portability.
4. Malicious members for absolute paths, `..` traversal, hardlinks,
   special files, symlink-then-child extraction, chained escapes,
   gzip truncation, archive size amplification, and duplicate paths.
5. A previously issued lineage replayed on a distinct clean runner with
   matching account identity, no local `/etc/letsencrypt` dependency,
   and no unintended Certbot operation.
6. Three artifact-flavor tests using mocked cloud/Certbot boundaries and
   real local tar/gzip.

The fixture tests in this PR establish the *layout* and expose the
path-normalization requirement. They do not implement the security
validator, restore an actual Certbot account, exercise real Certbot, or
authorize the public CLI to report lifecycle success.

## External compatibility guidance

Certbot stores keys and certificates under
`/etc/letsencrypt/live/<cert-name>` and records certificate-specific
settings in `renewal/*.conf`. Its `--config-dir`,
`--work-dir`, and `--logs-dir` are separately configurable. The
live symlinks and renewal configuration paths must both be accounted
for, including when installed under a new absolute workspace path.

Reference: https://eff-certbot.readthedocs.io/en/stable/using.html
