# ADR-028: Verified Single-Key S3 Publication and No-Op Policy

Date: 2026-10-22

## Status

Accepted

## Decision

MVP publication is an explicit one-object `aws s3api put-object` call to the
operator-selected, preexisting Amazon S3 bucket and **the exact same key**
previously selected for archive retrieval. The default key remains
`latest.tar.gz` under ADR-020. No second key, dated filename,
retention generation, intermediate remote object, or bucket creation is
permitted.

The publisher receives the private workspace, selected certificate name,
resolved bucket and key, a successful operation's
`CERTBOTBOT_DURABLE_CHANGED` result, and the resolved
`UPLOAD_NO_RENEWAL` Boolean. Its entry point is:

`certbotbot_s3_publish WORKSPACE CERT_NAME BUCKET KEY CHANGED OVERRIDE`

The caller is responsible for executing and verifying the Certbot operation,
setting CHANGED from the verified provider's durable-state result, and
confirming the selected key is the key retrieved at the start of the
invocation. The publisher has no authority to infer that a failed or skipped
Certbot operation was successful. It must only be called on that
**post-success** path.

On entry the publisher requires a safe, owned, mode-0700 workspace,
complete selected account/lineage state, and canonical (not runner-local)
renewal metadata. It validates both Boolean arguments as literal
`true` or `false` and rejects missing/unsafe bucket/key inputs.

The upload truth table is:

| CHANGED | OVERRIDE | Result |
| --- | --- | --- |
| false | false | No S3 call; successful local no-op |
| false | true | Produce a validated candidate and upload |
| true | false | Produce a validated candidate and upload |
| true | true | Produce a validated candidate and upload |

For a no-op skip, no archive candidate is built and the publisher sets
the caller-visible `CERTBOTBOT_S3_PUBLISHED=false`. The source
preflight and canonical metadata checks still apply, so no-op success
cannot conceal obviously invalid local state.

When publication is required, the publisher calls the existing
`certbotbot_archive_package` builder **itself**, rather than trusting
an arbitrary path offered by a caller. That builder refuses an occupied
candidate pathname, validates the selected account/lineage and
canonical metadata, and validates the resulting gzip/tar bytes with
the shared format gate. Only after this complete local phase may AWS
CLI receive the candidate. A valid candidate is uploaded with:

`aws --no-cli-pager s3api put-object --bucket BUCKET --key KEY
--body WORKSPACE/candidate.tar.gz --checksum-algorithm SHA256
--content-type application/gzip --output json`

The flags are distinct quoted Bash arguments; the body is a file path,
not `file://`. AWS CLI and S3 perform transport/checksum validation.
Neither raw AWS output nor credentials are written to the terminal.
A successful subprocess return sets `CERTBOTBOT_S3_PUBLISHED=true`.

## Context, assumptions and trust boundaries

ADRs 020 and 021 establish one authoritative existing S3 object and
fail-closed retrieval; ADR-027 establishes a verified candidate
without any remote write authority. ADR-025/026 distinguish actual
certificate changes, durable metadata changes and unchanged no-ops.

The public orchestrator must have already read and verified the
existing S3 object, then completed Certbot and independent
post-Certbot certificate/key checks before calling this publisher.
The publisher is intentionally incapable of proving upstream
success or that the given `BUCKET KEY` was the earlier read target.
These are mandatory caller obligations under task #27.

AWS CLI v2, IAM credentials, and region are supplied by the operator.
A successful PutObject requires `s3:PutObject`; no IAM, account or S3
bucket is provisioned. The publisher does not forward AWS's output,
log private data or inspect unrelated account state. It does not run
certbot, hooks, or read host `/etc/letsencrypt`.

Existing writers are externally serialized, as required by ADR-020.
There is no S3 lock, compare-and-swap, generation precondition,
two-object transaction, or automatic rollback.

## Failure semantics and non-promises

- Invalid input, occupied candidate path, unsafe root, missing account
  or renewal metadata, failed tar/gzip, or candidate validation failure
  **prevents any PutObject call** and leaves the known-good remote
  object untouched.
- If AWS CLI is absent, the publisher returns an unavailable status
  without initiating publication.
- If PutObject returns nonzero, the publisher returns a nonzero transfer
  failure and clears `CERTBOTBOT_S3_PUBLISHED`.
  **A failed or interrupted AWS call does not prove the remote object is
  unchanged**. S3 may have received some or all of the request, and
  remote reconciliation/recovery belongs to operators.
- A successful CLI return reports accepted publication, not a
  roundtrip download, durable replication proof, or cryptographic
  certificate/key validity. The public end-to-end mocked cycle and
  later live interoperability testing remain separate.
- Local candidate bytes stay under the private workspace until the
  orchestrator's cleanup; the publisher never removes unrelated files.
- A successful skipped no-op means **no new upload**, not proof that
  the external archive was recently inspected or reverified.
- An explicit `true` override can republish a verified unchanged
  certificate without forcing Certbot to issue again.

## Alternatives

**High-level `aws s3 sync` or recursive upload:** rejected. It can
enumerate or write multiple keys and is unnecessary for one object.

**Always upload regardless of durable change:** rejected; violates the
default no-op policy in ADR-020 and story #90.

**Never upload after Certbot no-op:** rejected; account/renewal
metadata can change, and `UPLOAD_NO_RENEWAL=true` expressly forces
a verified republish.

**Use source archive bytes unchanged for forced no-op:** rejected;
the candidate must pass the same complete local validation as any
published state.

**Create a remote staging object and copy into place:** rejected from
this MVP because it introduces a second object key and different
remote cleanup/failure assumptions.

**Use ETag as proof of SHA-256 identity:** rejected. ETags are not
generally SHA-256 digests; AWS CLI v2 supports an explicit SHA256
checksum header for PutObject.

**Verify via a second S3 GET after PUT:** deferred to public mocked
cross-runner acceptance and post-publication verification design.
A second GET would not add a durable rollback guarantee and creates
additional network failure states.

## Expected outcomes, compatibility and evidence

Existing `certbotbot_s3_fetch` behavior and archive layout are
unchanged. The publisher uses the same caller-resolved bucket/key and
does not introduce new user-facing configuration. Tests use executable
mock AWS CLI plus real tar/gzip and verify exact upload arguments,
selected candidate bytes, no-op truth table, opaque errors,
verification failures before network access, and no extra S3 calls
across development, ordinary and minified artifacts.

The public CLI remains fail-closed until task #27 integrates
retrieve→Certbot→candidate→PutObject and task #40 exercises the
entire mocked path with two independent workspaces.

## Related decisions

ADR-020 governs identity and the one-key/no-op policy; ADR-021 the
read boundary; ADR-022 the portable layout; ADR-023 the restored
account; ADR-027 the candidate builder; ADR-025/026 the successful
provider outcomes. Task #39 authorizes this publisher. Story #90
provides the explicit no-renewal upload exception.

## References

- AWS CLI v2 `s3api put-object`:
  https://docs.aws.amazon.com/cli/latest/reference/s3api/put-object.html
- AWS CLI v2 S3 checksum behavior:
  https://awscli.amazonaws.com/v2/documentation/api/latest/topic/s3-faq.html
