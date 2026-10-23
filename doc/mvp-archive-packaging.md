# MVP Verified Candidate Archive Builder

Implements the local packaging boundary in ADR-027 (task #38).
This is **not** the public S3 publisher.

## Inputs and output

`certbotbot_archive_package WORKSPACE CERT_NAME`

The caller supplies a fresh canonical, owned, mode-0700 workspace,
with a verified successful Certbot operation and a complete selected
lineage beneath `WORKSPACE/config`. The selected certificate name
is the already-resolved non-wildcard Certbot lineage identity.

The destination is the fixed `WORKSPACE/candidate.tar.gz`; it must
not already exist (including as a symlink). On success that path
contains one mode-0600 gzip tar of *the contents* of `config/`,
with relative paths, exact selected-lineage symlinks, the original
account state, and canonical renewal metadata. The caller must
decide whether to upload the candidate, using the approved durable-
change / UPLOAD_NO_RENEWAL policy, and owns workspace cleanup.

The builder does not output the pathname or any account/private
material. It returns zero on successful candidate validation, 64
for invalid workspace, name or occupied output, 65 for invalid
source state/metadata or rejected candidate content, and 74 for
local staging or compression failures.

## Preflight and serialization

1. Reject aliases and unsafe/non-private workspace roots.
2. Require the existing selected ACME account and complete lineage
   through `certbotbot_state_preflight`, with state `present`.
3. Call `certbotbot_renewal_map CONFIG NAME verify`: a read-only
   application of the existing metadata schema, requiring exactly
   canonical `/etc/letsencrypt` renewal paths and the current
   account/Route53 values. No `prepare`/`finalize` changes are made.
4. Reject readable-by-group/other selected `privkeyN.pem` files.
5. Create a private, same-workspace staged file. Archive with GNU
   tar (ustar, sorted names, numeric owner/group 0), gzip, and
   only the configuration directory contents. Do not follow
   selected live PEM symlinks or include Certbot work/log paths.
6. Run the merged `certbotbot_archive_validate` against the exact
   staged bytes; reject unknown, oversized or unsafe content.
7. Recheck that the candidate path remains absent and rename the
   verified file to that final location.

## Security and scope

No shell evaluation of restored metadata, S3 calls, hook invocation,
host Certbot state access or remote mutation occurs. A successful
archive is not a substitute for later certificate/key cryptographic
assertions, a cross-runner mocked lifecycle, or proof of remote
publication. The public lifecycle (ADR-029) adds those local
certificate/key assertions before calling the publisher. Concurrent mutation of `config/` by another process
is unsupported; writers must be serialized by the orchestrator.

## Evidence

The new `tests/archive-package.bats` suite uses actual tar/gzip
roundtrips, private same-directory staging, forged/invalid files,
and three generated standalone artifacts. It also proves the
`verify` metadata check does not modify source files.

See [ADR-027](adr/ADR-027-validated-candidate-before-publication.md).
