# MVP Fresh-Runner State Continuity Evidence

Task #32 (approved, parent story #9) verifies the public selected-certificate
lifecycle's independence from the original runner's private filesystem.
ADR-020, ADR-022, ADR-023, ADR-025, ADR-027, and ADR-028 govern this work.

## Contract and verification

The starting remote S3 object **already exists** and contains an existing
registered production Let's Encrypt ACME account, but no certificate lineage.
This task does not add account registration or missing-object bootstrap.

`tests/public-lifecycle.bats` runs each assembled release artifact as an
ordinary command with an instrumented mock AWS CLI and mock Certbot. Real
OpenSSL and GNU tar/gzip create and validate certificate fixtures.

1. Run the public command with `TMPDIR` pointing into a fresh private
   runner-A root. Observe selected `certonly` using the pre-existing account,
   and exactly one publication to the configured S3 archive object.
2. Verify runner-A's owned temporary workspace was removed, and the published
   archive contains the original account material, canonical renewal paths,
   the selected lineage and valid relative live-to-archive links.
3. Launch the same public artifact under a **different** runner-B `TMPDIR`,
   with no available runner-A configuration, work directory or logs.
   The public command restores the published archive, selects only
   `renew --cert-name` for the original lineage, and completes a no-op
   without reissuing the certificate or writing an unchanged archive.
4. Run under a third independent runner-C root, inject an ordinary selected
   certificate renewal, then confirm the durable S3 archive still contains
   the same ACME account identity and selected lineage while the leaf is
   updated. No host `/etc/letsencrypt` access or external network call is
   permitted by the mock harness.
5. Confirm runner-B/C workspaces are removed after the command and all
   observed Certbot config, work and logs paths fall under the intended
   invocation's private root. The S3 object remains the sole portable
   certificate-management state.

Comparing only matching SANs or a valid PEM is insufficient. The tests
assert exact account-file identity, stable selected certificate lineage,
canonical stored renewal metadata, all three private Certbot directory
arguments, and negative evidence that the second run did not issue again.

This is **mocked MVP acceptance**, not a real AWS/Route53/ACME service test.
Actual account registration, issuer compatibility, infrastructure permissions
and live staging acceptance remain assigned to milestone #4.
