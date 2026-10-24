# Multi-Lineage Selected-Only Acceptance Evidence

Status: **task #62 verification plan and PR evidence map**.
Governing [ADR-030](adr/ADR-030-shared-archive-multiple-lineages.md)
and [shared archive contract](multi-lineage-contract.md). All checks must
be verified on the **final PR head** before acceptance and story closure.

## Local Public-Executable Evidence

The `tests/public-lifecycle.bats` suite runs the generated
`certbotbot.dev.bash`, `certbotbot.bash`, and `certbotbot.min.bash`
through the same Bats scenarios. The tests use true local GNU tar/gzip,
OpenSSL-generated certificates, real private file mode/symlink operations,
and **mock** `aws`/`certbot` executables. They do not contact Route53,
Let's Encrypt or S3.

| Acceptance contract | Focused public-executable test |
| --- | --- |
| Single already seeded archive upgraded from account-only and one-lineage state | `second independent selected lineage retains first key and renewal state` |
| Two independent non-overlapping certificates persist across five fresh workspaces | `five clean runners preserve two unrelated lineages, account and same archive` |
| No-op for B does not touch A, then A renews and B remains unchanged | Five-runner test, with separate selected-only renew/no-op and publication assertions |
| Unselected PEM, private-key bytes/modes, renewal file, version history and links remain unchanged | `snapshot_shared_lineage` and `assert_shared_lineage_unchanged` |
| The same DNS SAN set can appear on two separately named certificates | `two explicitly distinct lineages may share exact DNS SANs` |
| Invalid selected name refuses a provider and cloud operations | `invalid selected identity cannot mutate two archived lineages` |
| Incomplete unselected state cannot be ignored to operate on another | `corrupt unselected lineage blocks selected operation before Certbot and PutObject` |
| Missing original ACME account prevents renewal and upload | `missing existing account in a two-lineage archive never registers or publishes` |
| Failed selected Certbot renewal cannot write or drop unrelated state | `failed selected renewal preserves both lineages and last S3 bytes` |
| Failed remote write is reported without a false publication claim | `two-lineage PutObject refusal preserves mocked remote but reports uncertainty` |
| Corrupt GetObject data fails before provider and publication | `bad GetObject on two-lineage archive does not invoke provider or PutObject` |

A regression in `tests/archive-restore.bats` also asserts that safe public
certificate modes (0644) remain unchanged while private key modes (0600)
and private staging ownership persist after a validated restore. This
protects the permission-preservation guarantee across repackaging.

Preexisting focused suites also cover archive header/path/link validation,
account uniqueness, canonical renewal metadata, unsafe hooks, selected-only
Certbot flags, and the one-object publication policy.

## Required CI Evidence

Review requires passing `make check`, `make build`, `make test` or
`make test-report` (including each of the three generated artifacts),
matching release `.sha256` companions, Bash 4.3 compatibility, and the
repository's applicable lint/security checks. A passing run against an
older PR revision is not acceptance evidence for a new head.

The remote mock copies the candidate to a fixture file only when its
simulated PutObject accepts it. A failed PutObject may already have been
accepted by real S3: this suite does **not** guarantee rollback.
Five **sequential** clean runners demonstrate portability, not concurrent
writers or locking. The operator still serializes writes to one shared
S3 key. The archive includes plaintext certificate private keys and
account secrets; Milestone #3 covers client-side encryption. Production
runbooks and operational deployment guidance remain deferred to
Milestone #13. Live provider/account validation belongs to the
separately approved end-to-end milestone.
