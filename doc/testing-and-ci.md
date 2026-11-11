# Testing and Continuous Integration

certbotbot uses source checks, artifact-flavor behavior tests, OCI runtime
acceptance, a credential-free local protocol harness, and a separate
operator-authorized staging gate. Each verifies a different boundary;
passing local tests is not evidence of live cloud integration.

## Testing regimen

Our testing regimen combines fast source checks with behavior and integration
acceptance. `make check` validates maintained Bash syntax and ShellCheck;
`make test` runs the full Bats behavior inventory against each of the three
checksum-verified producer flavors (development, ordinary, and minified),
including fixture-based positive and fail-closed negative cases. CI also
verifies artifact integrity, compatibility, OCI runtime behavior, and
security and lint findings. The independent shipped certificate client has
its own behavior and authenticated-decryption qualification gates.

The separate [local protocol E2E workflow](../.github/workflows/local-protocol-e2e.yml)
uses real Certbot, Pebble ACME, and SeaweedFS on an isolated Docker network.
It requires initial issuance, independent archive readback, one verified
post-issuance renewal-metadata stabilization, strict no-republish no-ops
across all three producer flavors, a second real ACME order and replacement,
seven negative scenarios, isolation probes, and cleanup. Pebble bypasses
DNS challenge validation and Route53 is stubbed, so this is **not** proof
of interoperability with live Route53, Amazon S3, or Let's Encrypt.
That remains the separate, manually authorized milestone 4 staging gate.

The broad Test, OCI, and local protocol E2E workflows run on branch pushes;
MegaLinter runs on pull-request events, while other security and release
workflows follow their configured triggers. A green individual job does not
replace the complete required check set for the exact candidate commit.
See [testing guidance](testing.md) and the
[local E2E harness guide](local-protocol-e2e-harness.md) for details.
`make format` applies the repository's shfmt profile,
`make adr-index` generates temporary ADR navigation,
and `make docs` generates Doxygen reference output
without committing generated files.


## Cross-workflow test gate POC

The experimental [test-gate](test-gate-poc.md) GitHub Actions job polls the
GitHub Actions API to observe explicitly marked required workflows while
preserving the Test, OCI, local E2E, and MegaLinter workflows' existing
event triggers and parallel scheduling. The comment form is
`## test-gate:required=true`, with optional whitespace around its
punctuation and a default of `false`. Requirements from the protected
base and proposed revisions are combined, so a PR cannot exempt itself by
removing a required marker.

This gate is **not yet an enforced protection**. Its current implementation
is executed from the PR candidate revision, and therefore is not a trusted
authorization boundary. Existing required checks remain in effect. See
[ADR-060](adr/ADR-060-cross-workflow-required-test-gate-poc.md) for the
strict missing/disabled/skipped failure behavior and remaining hardening work.

## Credential-free local protocol E2E CI

The dedicated [local protocol E2E workflow](../.github/workflows/local-protocol-e2e.yml)
runs automatically on repository pushes and by manual dispatch. It builds
the actual public producer artifacts, uses real Certbot and containerized
Pebble/SeaweedFS, verifies independent S3 archive restoration and a
second authentic ACME renewal order, and executes seven isolated negative
scenarios. Real no-egress and private staging TLS checks are mandatory;
the job has no real cloud credentials or host-published service ports.

**This local mode intentionally bypasses DNS-01 challenge validation**
(`PEBBLE_VA_ALWAYS_VALID=1`) and mocks only the Route53 API. Its success
does not establish Amazon S3, Route53 DNS propagation, or Let's Encrypt
staging interoperability. The separately authorized live milestone 4
acceptance remains required. See the
[isolated E2E operations and evidence guide](local-protocol-e2e-harness.md)
and [ADR-047](adr/ADR-047-mocked-route53-local-lifecycle-e2e.md).
The CI workflow fails closed if a real Docker-backed lifecycle stage cannot
be proved; it does not silently skip a missing container engine.

## Manual staging E2E acceptance

Milestone 4's real Let's Encrypt staging acceptance is operator-controlled,
using the separate [manual staging workflow](milestone-4-live-staging-workflow.md)
and governing [ADR-043](adr/ADR-043-manual-staging-live-e2e-workflow.md).
The workflow is never invoked from a pull request. It requires a trusted
`main` dispatch, explicit staging selection, an independently seeded staging
account-only S3 key, and a deliberate operator authorization. It does not
register an account, contact Let's Encrypt production, or provide ordinary
release publication authority. The successful fixture-only Bats suite does
not constitute real staging evidence.

## Additional verification references

- [Detailed testing contracts](testing.md) and [release verification](release-verification.md)
- [Local protocol harness and evidence](local-protocol-e2e-harness.md)
- [OCI image publication verification](oci-image-publication.md)
- [Manual staging acceptance procedure](milestone-4-staging-acceptance.md)
