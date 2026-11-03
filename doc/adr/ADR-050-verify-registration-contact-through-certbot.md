# ADR-050: Verify ACME Registration Contact Through Certbot's Authoritative Account Query

Date: 2026-11-03

## Status

Accepted

**Implementation convention:** Accepted is the repository's status for an ADR submitted as part of merge-intended work. Review and merge constitute acceptance. This ADR accompanies approved milestone #16 issue #261.

## Decision

When verifying a newly registered or restored account for the explicit `certbotbot register` operation, require **both** a safe, unique native account on disk and an authenticated, successful `certbot show_account` query against the **exact selected ACME directory**. The server-returned contact displayed by installed Certbot must be exactly the single requested email address. Missing contact, additional contacts, a different contact, ambiguous output, an unavailable authority, and any Certbot failure all refuse registration or account reuse before publication.

Do not demand a literal `mailto:` address in the on-disk `regr.json` file. Certbot 5.8 serializes `RegistrationResource(body={}, uri=...)` there, deliberately retaining account identity but not a complete cached registration/contact body. The native `regr.json` must still exist, be nonempty, regular, owned by the caller, readable and not writable by other users. The same applies to `meta.json`; `private_key.json` retains its stronger permission rule. The existing selected CA path, unique account ID, archival member allowlist, no-hooks rules, private configuration and exact selected server are unchanged.

Do not print, persist separately, or include in ordinary CI evidence the private account, server response or contact query output. Capture only this particular Certbot command's stdout in a private shell variable, suppress raw stderr, and verify its **exact singular contact display line**, without accepting substring matches or plural contacts. A successful command without the precise expected contact line is a failure. The matching account ID must be explicitly passed to Certbot; never select an arbitrary first account or derive server identity from archived metadata.

This mechanism may query the selected ACME server during registration and account-reuse verification. That is consistent with the existing `show_account` invocation, which already performs the query. Existing commands still fail closed when the selected CA is unavailable: there is no cached-contact success fallback. The selected authority is limited to the previously approved production/staging identities. Local protocol acceptance continues to use only challenge-validation-bypassed Pebble through the sealed canonical staging gateway.

## Context and Why This Decision Is Necessary

Milestone #16 PR #260 successfully passed its active isolation probe after correcting Bash EXIT-trap scope. It then failed in the *final registration preflight* after a genuine successful Certbot `register`. GitHub Actions [run 41700696434](https://github.com/wesley-dean/certbotbot/actions/runs/41700696434) classified the initial blocker; [run 41702368459](https://github.com/wesley-dean/certbotbot/actions/runs/41702368459) subsequently exercised the same stage. Approved bug #261 authorizes investigation and a bounded correction.

The original `certbotbot_register_account_check()` required the literal string `"mailto:<requested-email>"` in native `regr.json`. Mocked Certbot tests synthesized this format and therefore could not detect a difference from installed Certbot. Certbot 5.8's published `AccountFileStorage._update_regr()` writes a `RegistrationResource` with `body={}`, so this assumption is not a durable native account-storage contract. Real `certbot show_account` queries the account registration from the selected ACME server and displays the current contact. This supplies the independent server-side contact evidence the local JSON file no longer represents.

This is a narrowly scoped clarification to ADR-041's *how to verify matching contact identity*. It preserves its requirement that each explicit registration invocation supplies a valid email and affirmatively consents to the selected CA's terms. It also preserves ADR-042's bounded CA selector, ADR-023's structural preflight, ADR-047's offline test boundary, and conditional S3 publication.

## Assumptions and Constraints

- The installed supported Certbot displays exactly `  Email contact: <email>` for one contact. A change in Certbot's textual presentation fails closed and requires re-review, rather than broadening the parser based on guesses. Captured output remains private.
- The selected ACME server answers the real Certbot `show_account` request successfully and supplies the current contact. This must be verified by the isolated Pebble protocol CI; mocked tests alone cannot establish interoperability.
- The native account has one ID under one selected production/staging directory, with three required owned/permission-constrained files.
- In all failure paths, no S3 PutObject occurs; existing remote state is not assumed rolled back if a previous external write became uncertain.
- The producer adds no new public options, no additional CA authority, no insecure TLS bypass, no separate account data file, and no host-global Certbot configuration.

## Alternatives Considered

1. **Keep the literal `mailto:` check in `regr.json`:** Rejected because the installed Certbot persists an empty registration body, causing false rejection of genuine accounts.
2. **Delete contact verification entirely:** Rejected because a valid-looking native account and successful Certbot exit would not establish the caller's expected email and could silently reuse a differently configured account.
3. **Read the email from `meta.json` or an auxiliary cache:** Rejected because the native metadata does not establish the current server-side contact and a generated cache can be stale or forged.
4. **Rewrite or synthesize native `regr.json` to embed the email:** Rejected because certbotbot must preserve native Certbot account bytes and not counterfeit an ACME registration response.
5. **Accept any account if `show_account` exits zero:** Rejected because identity verification, not merely account existence, is required by ADR-041.
6. **Parse arbitrary server JSON or call the ACME API directly from Bash:** Rejected because it adds a second ACME protocol implementation and trust path beyond installed Certbot.
7. **Use a permissive substring match on `show_account` output:** Rejected because multiple contacts, suffixes, or unrelated text could be misclassified as a unique exact match.
8. **Use real Let's Encrypt production or Route53 in CI:** Rejected by the strict milestone #16 isolation boundary.

## Consequences, Risks and Verification

The implementation keeps the current private account-directory and file checks and replaces exactly one stale literal-contact check with captured real Certbot output. A real accepted account with the requested singular contact can now proceed to account-only packaging; a different/multiple/missing contact still fails before publication. Format changes in a future Certbot release can cause a conservative refusal even for legitimate accounts, which is safer than accepting unverifiable identity. Querying the selected CA remains a potential network-failure surface; no offline cached fallback is allowed.

Tests must simulate current URI-only `regr.json` with no stored contact and a separate realistic Certbot `show_account` response. Test both new registration and existing-account reuse with exact and wrong contacts, no contact, more than one contact and failed query; verify failures do not execute PutObject. The producer's three artifact flavors must meet the same contract. The isolated protocol suite must then verify real Pebble registration and native state as an independent gate, without misrepresenting test doubles as live AWS/Route53/Let's Encrypt evidence.

## Relationship to Earlier ADRs

This ADR refines ADR-041's registration contact verification method, without changing its consent, identity, publishing or privacy requirements. ADR-042 controls exact CA selection, ADR-023 protects restored ACME state, ADR-047 controls isolated Pebble/Route53/S3 protocol evidence, and ADR-019 governs issue approval. No earlier decision is superseded outside this specific native-contact representation assumption.
