# ADR-051: Remove Only Verified Ephemeral Certbot Directory Options During Finalization

Date: 2026-11-03

## Status

Accepted

## Decision

The five canonical certificate and archive path fields governed by ADR-022 remain the **only reversible persisted path mappings**.  Certbot 5.8 may additionally write `config_dir`, `work_dir`, and `logs_dir` in the `[renewalparams]` section when an invocation explicitly specifies its private directories.  These fields describe one invocation's scratch execution environment rather than a certificate's durable state.  They are not portable between fresh runners.

The `certbotbot_renewal_map` **finalize** operation alone may recognize those three additional fields.  It must verify the exact values correspond to the currently selected private workspace: `config_dir` must equal the provided canonical `config` root, `work_dir` must equal its sibling `work` directory, and `logs_dir` must equal its sibling `logs` directory.  The caller's validated `config` root must be an absolute mode-0700 owned, physical (non-symlinked) directory, and must be the child named `config` of the workspace for the exception to apply.  Each ephemeral field is optional because Certbot may not persist every explicit argument.  Any duplicate, differently located, empty, relative, foreign, alternative-looking, or malformed field fails closed before a mutation.

When values match exactly, **finalize omits those lines** from the candidate persisted renewal file and performs the normal five-field path canonicalization as a single same-directory validated replacement.  It does not persist or rewrite the ephemeral settings.  The read-only **verify** and reverse **prepare** operations continue to reject any occurrence of those three keys in archived input.  Neither operation interprets a remembered runtime path or tries to relocate it.  A clean canonical archive therefore contains no private invocation path and can be restored on an independent runner.  Existing supported renewal metadata without those fields retains byte-for-byte prepare/finalize compatibility.

The exception does not authorize any other Certbot renewal key, section, hook, plugin, ACME URL, account, filename, or path.  All existing unsupported content, embedded control characters, hook text, extra sections, and unexpected private paths remain hard failures without partial rewrite or S3 publication.  Values must not be logged or written to CI reports.

## Context

Issue #264 is an approved compatibility bug uncovered by the local milestone-16 E2E harness.  PR #260 reaches genuine Certbot/Pebble issuance, successful sealed Route53 update and change-status polling, but reports `certbotbot: unsupported renewal configuration` from the post-issuance renewal-path adapter, so the candidate archive cannot be published.  This outcome does **not** independently identify a rejected key.  Inspecting Certbot v5.8's `storage.relevant_values()` and `renewal.CONFIG_ITEMS` shows that its renewal data may include explicitly supplied `config_dir`, `work_dir` and `logs_dir`.  The current certbotbot provider explicitly sets all three arguments, and its parser rejects them.  Tests must verify this format assumption against the real integrated Certbot, not merely mocks.

ADR-022 requires that durable archives be directly installable under conventional `/etc/letsencrypt`, that five lineage paths be reversibly mapped for a private runner, and that unknown path-bearing metadata be refused.  Its statement that the independent work/log directories are ephemeral and unarchived takes precedence over keeping these three command-line echoes in renewal files.  This ADR narrows and clarifies **only** the metadata parser's handling of known transient options produced by the selected, trusted Certbot call.  It does not supersede ADR-022's five-field reversible mapping.

## Assumptions and Security Boundaries

- The producer constructs one newly owned private workspace with sibling `config`, `work` and `logs` directories for selected issuance and renewal.  This directory topology is already used by the producer; no caller-chosen alternative root is authorized.
- The string equality check is against the **exact invocation-specific paths**; no shell evaluation, environment expansion, globbing, relative path interpretation, prefix matching, or generic '/tmp'-path allowlist is permitted.
- A path value is untrusted configuration content even when it follows a real Certbot command.  Only allowlisted exact matches may be stripped on finalization.
- All other Certbot-generated settings are subject to the previously accepted conservative parser.  Further incompatibilities require separate evidence and review rather than catch-all whitelisting.
- Failure preserves the original renewal file and S3 object's prior state, subject to the already documented remote uncertainty of an attempted write.  This adapter itself performs no provider network activity.
- The test harness uses Pebble, challenge-validation bypass, a private Route53 stub and SeaweedFS; it does not prove real Let's Encrypt, Route53, or AWS behavior.

## Alternatives

1. **Persist ephemeral paths verbatim:** Rejected because they point into a destroyed runner and violate independent-runner portability.
2. **Re-map ephemeral paths to `/etc/letsencrypt`:** Rejected because those directories are not part of the canonical certificate archive and would overwrite Certbot's explicit private work/log isolation on restoration.
3. **Relax the parser to allow these keys in all mapping modes:** Rejected because untrusted archives could inject host paths used by future Certbot invocations.
4. **Drop all keys starting with `config_`, `work_`, or `logs_`:** Rejected; prefixes are not a bounded schema and could conceal execution-relevant values.
5. **Edit newly created renewal metadata externally in the test harness:** Rejected because it would conceal a real producer defect and the shipped producer would still fail.
6. **Run Certbot without explicit private directory flags:** Rejected because the private-workspace boundary is an accepted security requirement.
7. **Accept only all three keys together:** Rejected because Certbot's persistence varies with the arguments recorded as user-set.  The same exact-value checks apply individually.
8. **Add a second general configuration parser or a new runtime dependency:** Rejected because the existing fail-closed single-pass parser is sufficiently bounded and the extra trusted code would enlarge the attack surface.

## Consequences

A legitimate Certbot-generated renewal file containing verified invocation-only directory options can be finalized and published as a conventional portable archive.  The original five path fields remain canonical, the account and server continue to be verified, and the existing clean archive format is not migrated.  A later change in Certbot's renewal format can cause a safe failure; compatibility with arbitrary versions is not promised.  No new public CLI flag or archive format version is introduced.

The code must keep parse/validate and mutation separate, retain atomic same-directory replacement, and avoid printing private path values.  A successful finalize may deliberately remove at most these verified transient lines, so byte identity is promised only for files without these options.

## Verification

- Verify the producer's exact three directory flags and Certbot v5.8's explicitly saved option behavior from upstream implementation and integration evidence.
- Test canonical `verify` and `prepare` refuse each ephemeral field before mutation; `finalize` accepts exact individual and combined fields, removes only those lines, and retains the canonical five mapped path fields.
- Test malformed, duplicate, foreign/sibling-confused, empty, relative, prefix/suffix-spoofed and extra keys; show failure leaves bytes unchanged.
- Test request/account/ACME, hook, and other unrelated security refusals remain enforced; archive creation never uses caller-controlled absolute paths.
- Run the three shipped artifact flavors' Bats suites.  After merge, integrate into #260 and prove genuine first issuance, independent fresh-runner archive restoration, ordinary no-ops, second genuine Pebble order, all seven negative gates and project cleanup.
- Do not claim local mocked Route53/validation evidence as live provider interoperability.

## Related Decisions

ADR-022 remains authoritative for archive portability, five canonical mappings and untrusted renewal metadata.  ADR-023 controls restored account and lineage safety; ADR-024 and ADR-025 control selected issuance and renewal; ADR-042 controls immutable selected CA; ADR-047 controls the challenge-validation-bypassed local protocol harness.  This ADR adds only a precise finalization exception for three verified invocation-private directory settings.  A later change to the storage contract requires another explicit ADR.
