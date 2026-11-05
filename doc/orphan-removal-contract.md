# REMOVE_ORPHANS: Explicit Desired-Lineage Reconciliation Contract

**Status:** ADR-059 accepted through merged PR #287. The public
`--remove-orphans`, `--desired-cert-name`, and
`DESIRED_CERT_NAMES` inputs are implemented by task #96;
review, CI and merge must complete before claiming released support.
Task #97 adds independent public-executable acceptance tests and
fresh-runner/fault-mode evidence; the implementation was merged under PR #288.
The complete acceptance matrix and evidence limits are documented in
[Testing](testing.md).

## Why an extra desired-set input is mandatory

The existing selected `DOMAIN`, `CERT_NAME` and repeatable `--san`
configure **one selected certificate**. SANs are not independent lineages:
different stored certificates can share identical SANs. The storage
inventory cannot reliably infer a complete desired set from the current
selected certificate. Declaring `REMOVE_ORPHANS=true` alone therefore
must never mean "keep the selected certificate and delete everything else."

The proposed dedicated input is:

```text
--remove-orphans true|false             # default false
--desired-cert-name NAME                # repeatable, one wanted lineage
DESIRED_CERT_NAMES=example.com,other.org # exported environment or literal file
```

One full set wins, without merging: CLI `--desired-cert-name` occurrences,
then exported `DESIRED_CERT_NAMES`, then literal file. CLI, environment,
and file `REMOVE_ORPHANS` are an independent strict scalar using existing
precedence. An explicit `--no-env` suppresses application environment
and file values, **not** CLI selections. Neither these options nor
pruning are available to `register` or the read-only client.

All desired identities must be valid *lowercase ASCII non-wildcard stable
lineage names*. Reject empty values, empty comma components, duplicates,
whitespace, control characters, wildcard names, unknown aliases and
more than 100 desired identities. Match exact case-sensitive stored
lineage identity, not SAN equality, suffix matching, basename guessing or
untrusted symlink targets.

## Behavioral matrix

| Resolved request | Desired set | Selected certificate | Outcome |
| --- | --- | --- | --- |
| Default `REMOVE_ORPHANS=false` | Absent | Valid | Normal selected-only behavior; all unrelated lineages preserved |
| `REMOVE_ORPHANS=false` | Supplied | Valid | No pruning authority; existing selected-only behavior |
| `REMOVE_ORPHANS=true` | Absent/empty/invalid | Any | Reject before S3/provider or local mutation |
| `REMOVE_ORPHANS=true` | Valid nonempty | Missing DNS / partial selected inputs | Reject before S3/provider |
| `REMOVE_ORPHANS=true` | Valid, excludes selected lineage | Valid | Reject before S3/provider |
| `REMOVE_ORPHANS=true` | Valid, includes selected and all existing lineages | Valid | Ordinary selected operation, no prune; unchanged upload policy applies |
| `REMOVE_ORPHANS=true` | Valid proper subset, all retained names known | Valid | Selected action then prune only excluded original complete lineages, validate and publish one complete replacement |
| `REMOVE_ORPHANS=true` | Valid, with absent nonselected desired lineage | Valid | Reject before provider mutation; do not silently skip missing desired identities |
| `REMOVE_ORPHANS=true` | Valid, selected name absent from archive | Proper explicit selected issuance | Issue selected name once, then prune only after its success; name must be in desired set |
| `REMOVE_ORPHANS=true` | Valid | Invalid, incomplete or ambiguous stored lineage | Reject; corrupt state cannot be treated as an orphan |
| Both `REMOVE_ORPHANS=true` and `RENEW_ALL=true` | Any | Any | Reject before S3/provider, preserving ADR-058 |

`--desired-cert-name example.com` is **not** the same as the current
`--cert-name example.com`. The latter selects the ONE certificate
eligible for issuance or renewal. The former is a member of the COMPLETE
set the administrator explicitly wants to preserve; it does not request
issuance or renewal for that member. The ordinary selected name, explicit
or derived, must occur in that complete set.

## Concrete example

Suppose the restored archive contains three complete independent lineages:

```text
example.com  (SANs example.com and *.example.com)
other.org    (SANs other.org and *.other.org)
alias.net    (SANs example.com and *.example.com; overlap is permitted)
```

An operator wants to retain both `example.com` and `alias.net`, and
deliberately remove only `other.org`.

```bash
# Illustrative CLI contract: requires a build containing task #96:
certbotbot --s3-bucket existing-private-bucket \
  --remove-orphans true \
  --desired-cert-name example.com \
  --desired-cert-name alias.net \
  --cert-name example.com example.com
```

The exact original `other.org` lineage is a confirmed orphan, even
though a SAN is irrelevant to that decision. The selected
`example.com` lineage performs its existing ordinary action.
`alias.net` survives unchanged, even though it shares its SANs
with the selected lineage. The resulting archive must contain exactly
`example.com` and `alias.net` under the original account and single
S3 object key. If the named selected certificate fails verification,
no pruning or publication follows.

**Dangerous omitted-member example:** if the operator omits
`--desired-cert-name alias.net`, that explicitly excludes
`alias.net`. This is why both the full desired-set input and an
independent deliberate `REMOVE_ORPHANS=true` are mandatory. Preview,
recovery and independent operator review are advisable before enabling
such a command in unattended automation; no unapproved interactive
confirmation or automatic rollback is promised by this feature.

## Exact deletion boundary

Only three namespaces may be pruned for each **validated**
confirmed-orphan identity `N`, and only under the owned isolated
restored `WORKSPACE/config` root:

```text
renewal/N.conf       canonical renewal metadata
live/N/              owned intra-lineage relative PEM links
archive/N/           versioned certificate, chain and key material
```

All original members, canonical mappings, account/CA identity,
link targets, permissions and runtime context must pass safe preflight
before deletion. An invalid lineage is NOT an orphan that may be
deleted. Delete literal names, never a shell glob, root directory or
host-global `/etc/letsencrypt`. Surviving *unselected* lineages and
their history must remain unchanged at file-byte and metadata level;
the selected lineage alone may have ordinary provider changes.

The prune is applied to an invocation-owned disposable workspace,
followed by an exact desired-membership check, full canonical state
validation, cryptographic selected/retained lineage checks, and
complete candidate archive validation. A positive prune count is a
durable change and requires same-key S3 publication, even if selected
Certbot reported no certificate renewal. No publication of a partially
pruned candidate is intentional, even if local deletion or packaging
fails.

Current-key PutObject failure is still potentially **remote-uncertain**.
Current S3 object versions, separate dated backups, and already
distributed copies of private keys are not erased by orphan removal.
Backup publication and retention remain independent opt-ins, and
shared-key writers still require operator-level serialization.

## Downstream implementation and acceptance

**Task #96** must implement strict CLI/env/file resolution, exact desired
identity comparison, archive membership proof, selected-only provider
execution, bounded deletion, post-state checks and one-key publication.
The public reference and help must be updated **only with working**
syntax. Implementation must not weaken ADR-030's default preservation
or ADR-058's explicit bulk-renewal exclusion.

**Task #97** must verify all shipped producer variants and checksum
companions, with Bats across independent runners: all table rows,
different SANs and overlapping SANs, account-only selected issuance,
source precedence and `--no-env`, duplicates/invalid/missing names,
malformed and symlinked archive state, safe path restrictions,
failure-after-selected-renewal, no partial publication, retained
permissions/keys/account, `UPLOAD_NO_RENEWAL`, encrypted archives,
and uncertainty of remote PutObject.

Those local tests cannot prove live AWS IAM, Route53 propagation,
Let's Encrypt account recognition, absolute erasure of backups,
or distributed locking. Such claims are outside this feature.
