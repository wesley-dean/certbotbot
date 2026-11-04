# MVP Renewal Path Mapping Contract

This is the implementation boundary required by
[ADR-022](adr/ADR-022-portable-certbot-state-archives.md).  Certbot's
certificate-specific renewal configuration can contain absolute
`/etc/letsencrypt` paths that point outside an isolated runner.  A stored
archive must remain directly installable under conventional
`/etc/letsencrypt`, while the runtime uses a private `--config-dir`.

## Interface and sequence

`certbotbot_renewal_map CONFIG_DIR CERT_NAME prepare|finalize|verify` operates on
the selected `CONFIG_DIR/renewal/CERT_NAME.conf` only.  The caller has
already restored and locally validated one selected lineage with
`certbotbot_state_preflight`; an account-only archive with an absent
lineage does not yet have a renewal file and skips `prepare`.
After first issuance, Certbot creates its private renewal configuration,
which the caller passes through `finalize` prior to packaging.

`prepare` accepts exactly the **canonical** values and rewrites these
five keys into the supplied private configuration root:

| Key | Canonical archive value | Private runtime value |
| --- | --- | --- |
| `archive_dir` | `/etc/letsencrypt/archive/<name>` | `CONFIG_DIR/archive/<name>` |
| `cert` | `/etc/letsencrypt/live/<name>/cert.pem` | `CONFIG_DIR/live/<name>/cert.pem` |
| `privkey` | `/etc/letsencrypt/live/<name>/privkey.pem` | `CONFIG_DIR/live/<name>/privkey.pem` |
| `chain` | `/etc/letsencrypt/live/<name>/chain.pem` | `CONFIG_DIR/live/<name>/chain.pem` |
| `fullchain` | `/etc/letsencrypt/live/<name>/fullchain.pem` | `CONFIG_DIR/live/<name>/fullchain.pem` |

`finalize` requires the matching private values and rewrites them back
to canonical archive values.  A second `prepare` without `finalize`,
or vice versa, fails without modifying the file.  The file must contain
exactly one occurrence of each key outside the `[renewalparams]`
section.  The mappings preserve all supported non-path lines, comments, whitespace,
and ordering byte-for-byte for supported LF-terminated ASCII files.

Certbot 5.8 may emit three additional invocation-private keys under
`[renewalparams]`: `config_dir`, `work_dir`, and `logs_dir`.  These are
**not** durable archive paths.  Only `finalize` accepts them, and then
only as exact equalities to the selected private `CONFIG_DIR`, its sibling
`work` directory, and its sibling `logs` directory respectively.
Each is optional, but duplicates and unknown values fail.  The selected
`CONFIG_DIR` must be a `config` child of the private workspace.  A
validated finalize omits these lines atomically while mapping the same
five canonical certificate paths.  `prepare` and `verify` reject any
archived occurrence of these transient options.  Other fields and line
content remain unchanged.  See ADR-051.  Byte-for-byte round-tripping
remains guaranteed for supported files that lack these ephemeral keys.

The implementation rejects unsupported path references in other settings,
unrecognized renewal sections, duplicate or misplaced path keys, and hook
directives.  It requires the production Let's Encrypt endpoint and DNS
Route53 authenticator when explicitly specified in renewal parameters.
The supported settings are intentionally conservative and documented in the
tests; other Certbot configurations require explicit compatibility review.

Mapping is transactional at the file level: validate the complete input
and write a private same-directory temporary file before replacing the
selected renewal file.  On any parse/validation failure the input file is
unchanged.  No `sed -i` or unbounded substring replacement is used.

## Invariants and exclusions

- The root must be absolute, private (0700), owned by the caller, and
  resolve without symlink aliases.  The selected name is validated.
- Exactly the selected `renewal/<name>.conf` is affected, not other
  lineages, account JSON, private keys, or PEM symlinks.
- There are no host path writes, network requests, AWS CLI or Certbot
  invocations.  Mapping a file does not validate its Certbot semantics.
- Unexpected fields containing absolute local paths or unsupported commands
  must fail closed.  No hidden rewrite of future Certbot fields is permitted.
- These are local reversible mappings, **not** evidence that a specific
  Certbot version will accept the transformed renewal file.
- Account validation and selected-lineage verification must be repeated
  after Certbot activity before canonicalization and publication.
- The public executable continues its explicit status-69 lifecycle boundary
  until the approved Certbot adapter and complete mocked roundtrip exist.

## Verification

Each release-artifact flavor must prove exact `prepare` -> `finalize`
byte identity, reversible path values, unchanged account/PEM data, fail-closed
unknown/duplicate/misplaced path fields, refused foreign roots and hooks,
and no remote or host side effects.  No live ACME accounts are contacted.

Certbot's documentation discourages manual renewal-configuration changes:
https://eff-certbot.readthedocs.io/en/stable/using.html

## Read-only canonical check

`certbotbot_renewal_map CONFIG_DIR CERT_NAME verify` reuses the same strict
renewal configuration parser and requires its five canonical
`/etc/letsencrypt` values. It performs no file replacement, returns
zero only for the supported metadata dialect, and is required by the
candidate archive builder before packaging. See ADR-027. `prepare` and
`finalize` retain their existing mapping semantics.

## Certbot Singleton DNS-01 Challenge Representation

Certbot's renewal metadata may contain `pref_challs = dns-01,`. The
terminal comma represents a single-element challenge sequence, not a second
challenge. Under ADR-052, the renewal mapper accepts only exact `dns-01`
and `dns-01,` values for `pref_challs` and preserves the original bytes.
`preferred_challenges` continues to accept only `dns-01`. Any other
challenge, list, separator, whitespace variant, or malformed value fails
closed without modification or S3 publication. The exception does not
change the five canonical paths, invocation-private directory omission,
ACME account identity, DNS authenticator, or hook refusal.

