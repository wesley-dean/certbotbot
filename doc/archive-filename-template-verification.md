# Archive Filename Template Verification

Status: Maintained test contract for technical task #80 and ADR-032.
This document describes intended observable assertions. Passing CI on a
reviewed PR is the acceptance evidence; describing a test here is not a
claim that every CI job has passed or that live S3 was exercised.

## Coverage and authority

Task #79 implemented current-key filename resolution with a pinned build-time
mktext v0.0.17 library. Task #80 verifies that capability through the **public
command** and the existing safe, fully mocked Certbot/AWS lifecycle. The
authoritative object remains the selected current S3 bucket/key, default
`latest.tar.gz`. A backup template can resolve and collide but **cannot**
publish or delete anything until separately approved implementation tasks
#82 and #85. ADR-032 supplies the naming and compatibility contract, while
ADR-033 governs the future opt-in second publication.

`make test-report` repeats every `*.bats` file against each of the three
assembled development, stripped, and minified executables. CI also tests
Bash syntax, shellcheck, checksum companions, deterministic build output,
the offline bashdeps boundary, and a Bash 4.3 container. These are
complementary checks: a passing source syntax check cannot replace an
actual release-artifact behavior assertion.

## Public command and source-precedence matrix

| Property | Positive/negative scenario | Required observation |
| --- | --- | --- |
| Protected current default | No current-key flags or environment | S3 HeadObject addresses exact `latest.tar.gz` without a clock read |
| Legacy literal compatibility | `--s3-key 'literal-{YEAR}-{MISSING}.txt'` | HeadObject receives exactly those literal bytes; no macro rendering or extension rewrite |
| Current template | `current-{YEAR}{MONTH}{DOM}.tar.gz` on UTC 2026-10-20 | Exact `current-20261020.tar.gz` key, one clock snapshot |
| Named backup | `archive-{YEAR}{MONTH}{DOM}.tar.gz` on same date | Validated name `archive-20261020.tar.gz`, **no extra S3 write** |
| Configuration tiers | literal `.env` then exported environment then CLI | Effective highest-tier selection used in HeadObject |
| Paired choice | CLI literal masks lower-tier template, CLI template masks lower-tier literal | Correct one-key choice; no latent template evaluation |
| Same-tier conflict | Both current literal and current template in file or CLI | Exit 64 before AWS |
| Current/backup alias | Current key equals selected dated key after rendering | Exit 64 before AWS |
| Unknown/unsafe content | Unknown/lower-case/blank-padded/nested macros; shell substitutions, glob, percent escapes, non-ASCII, traversal | Exit 64; **zero AWS calls** and no execution side effect |
| Supported format boundary | Template ending in `.zip` or `.tar.bz2` | Exit 64 before AWS, not silent alternate-format support |
| Size bound | 255 ASCII bytes, then 256 ASCII bytes | First passes naming preflight, second exits 64 before AWS |
| Date consistency | Invalid calendar dates and valid leap day | Invalid dates rejected; 2024-02-29 renders `20240229` |

The lightweight negative AWS mock deliberately returns a service failure
after recording HeadObject. A valid argument case therefore yields the
defined *service unavailable* status (69) rather than claiming the full
certificate lifecycle succeeded. Invalid cases instead fail with status
64 and no cloud call.

## Full lifecycle and rollover matrix

The existing `tests/public-lifecycle.bats` fixture seeds one ordinary
account-only tar.gz, simulates selected Certbot operations, and provides
a private, inspectable local S3 object. Additional #80 tests assert:

1. A date mock returns 2026-10-20 on its **first** call and 2026-10-21
   on subsequent calls. A successful public first issuance with
   `--s3-key-template state-{YEAR}{MONTH}{DOM}.tar.gz` must call that
   clock exactly once, and mock HeadObject, GetObject, and PutObject
   must all use `state-20261020.tar.gz`. All stored account and
   certificate material remains a valid tar.gz archive.
2. A separate invocation/runner can restore the same templated key and
   make a verified no-op without a PutObject. With
   `UPLOAD_NO_RENEWAL=true`, a fresh successful invocation again uses
   that exact resolved key for HeadObject, GetObject, and PutObject.
   The test deliberately holds its UTC date constant between **separate**
   invocations; ADR-032 does not promise that different UTC days reuse
   the same date-derived key.
3. Explicitly selecting a valid backup template while the feature is
   disabled still produces only one authoritative PutObject.
4. With the approved GnuPG migration setting, an opt-in templated
   current key receives encrypted bytes under that **same exact**
   basename, without appending `.enc`. A subsequent clean invocation
   with the original secret reads the ciphertext under that key and
   performs a no-op. The AWS/Certbot mocks must not inherit the secret.

A separate `tests/compat-bash43.bash` assertion sources each shipped
artifact under the supported minimum Bash version, renders the same
UTC date into a current and a backup filename through bundled mktext,
and checks all frozen context values. An invocation that merely checks
`--help` would not establish the renderer's Bash 4.3 compatibility.

## Negative side effects and threat model

All malformed templates are treated as **data**. They are never sourced,
evaluated, passed to the shell as commands, transformed into filesystem
paths, or accepted as remote keys. Negative tests assert the absence of
all AWS requests, rather than checking only that PutObject was absent.
The expected stderr/exit status does not contain the untrusted input.
The date mock exercises clock drift and malformed results, not any
ability of certbotbot to correct a compromised/inaccurate host clock.

One private fixture is not equivalent to live S3, live Route53, or ACME
authorization. The mocked AWS adapter checks exact object identities,
but it cannot establish atomicity, remote durability, conditional
same-day overwrite or cross-writer synchronization.

## Deliberately deferred verification

- Task #82 adds **opt-in dated backup publication**. Task #83 must
  validate same-day S3 precondition handling, partial success, backup
  byte equality and manual recovery.
- Task #84 defines destructive ownership/retention policy. Tasks #85
  and #86 must test retention eligibility, safe enumeration, current-key
  preservation, failure isolation and deletion refusal.
- Storage backend story #63 and format backend story #65 remain open.
  No SFTP, ZIP, bzip2, alternate object namespace or extension mapping
  is represented as implemented. This task may test that unsupported
  combinations are refused but cannot claim live interoperability.
- Test-pass statements and final acceptance require reviewing
  **the final PR head**, including re-signed commits, and checking
  applicable build, Bats, Bash 4.3, GnuPG, lint and checksum gates.

Related: ADR-009, ADR-015, ADR-016, ADR-020, ADR-028, ADR-030,
ADR-031, ADR-032, ADR-033; story #66 and technical tasks #78–#80.
