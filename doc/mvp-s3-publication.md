# MVP Single-Key S3 Publication Adapter

This component implements the local-to-remote publication boundary
approved in task #39, governed by ADR-028. The public lifecycle in
ADR-029 now invokes it only after successful selected-certificate
processing and independent certificate/key consistency checks.

## Interface

`certbotbot_s3_publish WORKSPACE CERT_NAME BUCKET KEY CHANGED OVERRIDE`

WORKSPACE must be an owned, private, canonical mode-0700 directory
holding a complete, verified selected Certbot lineage in `config/`.
CERT_NAME is the already selected stable, non-wildcard lineage name.
BUCKET and KEY are the **same resolved values previously used for
retrieval** (default key `latest.tar.gz`); the caller must enforce
that continuity. CHANGED is the provider's verified
`CERTBOTBOT_DURABLE_CHANGED`, not a guess from Certbot exit
status. OVERRIDE is the resolved `UPLOAD_NO_RENEWAL` Boolean.

This function may be invoked **only after successful Certbot
processing and independent certificate/key verification**. It
checks local preconditions, but cannot prove upstream success.

## Results

- `CHANGED=false`, `OVERRIDE=false`: no AWS call, no candidate
  created, result `CERTBOTBOT_S3_PUBLISHED=false`, success.
- Any other true value: locally build and revalidate the complete
  `candidate.tar.gz`, then do one `s3api put-object` with
  `--bucket`, `--key`, `--body`, `--checksum-algorithm SHA256`,
  `--content-type application/gzip`; result
  `CERTBOTBOT_S3_PUBLISHED=true` only if AWS CLI returns zero.
- An invalid input/local workspace returns 64; an invalid selected
  lineage/candidate returns 65; missing AWS CLI returns 69;
  local serialization or upload failure returns 74. Failure clears
  result state, and static diagnostics never print AWS stderr or
  secrets. Remote object status is **indeterminate** after a failed
  PutObject request.

The caller retains ownership of workspace and candidate cleanup.

## Guardrails

No bucket creation, ACL adjustment, AWS credential manipulation,
new S3 key, backup object, remote deletion, account registration,
or Certbot invocation occurs. An unchanged no-op cannot trigger
a remote write except through the explicit override. This
adapter has no authority to assert that the remote object existed
or was the exact one read earlier; public orchestration must call
the read adapter first. The operation is not a distributed lock
or transaction and assumes one externally serialized writer.

## Verification

`tests/s3-publish.bats` uses a mock AWS CLI that records
`s3api put-object` arguments and writes to a local fake remote
object. Real tar/gzip and the shared validator are used on
the candidate. Tests cover every no-op truth-table row, explicit
key selection, byte identity, invalid/missing source, malformed
candidate refusal, upload denial, disappearing CLI and the
absence of AWS calls on local failure. All three artifacts run
the same tests without live AWS or Let's Encrypt accounts.
