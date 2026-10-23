# MVP Existing-Lineage SAN Reconciliation

This contract implements the controlled SAN-policy transition in
approved task #23, under ADR-026. Full public lifecycle integration
and safe S3 publication remain separate pending approved tasks.

## API

`certbotbot_provider_existing WORKSPACE CERT_NAME SAN [SAN ...]`

This is the entrypoint for a **present** selected lineage. It verifies
the existing restored SAN set before dispatch. Matching requested SANs
are passed unchanged to `certbotbot_provider_renew` for normal due
renewal/no-op processing. A supported same-apex change is passed to
`certbotbot_provider_reconcile`.

`certbotbot_provider_reconcile WORKSPACE CERT_NAME SAN [SAN ...]`

This requires a complete selected existing lineage and a **different**
desired SAN set. Allowed existing and requested sets are apex-only,
wildcard-only, or apex+wildcard, all for the same apex. SAN comparison
is set-based. Unsupported SAN encodings or third names fail before any
provider invocation. Certificate identity is the explicit CERT_NAME,
never the first SAN or a new numbered lineage.

After verifying the original Certbot account and Route53 plugin,
the adapter prepares the selected renewal file to use private paths,
then calls:

```text
certbot certonly --dns-route53 --preferred-challenges dns-01
  --renew-with-new-domains --account ACCOUNT --cert-name NAME
  -d REQUESTED_SAN ...
  --config-dir WORKSPACE/config --work-dir WORKSPACE/work
  --logs-dir WORKSPACE/logs
  --server https://acme-v02.api.letsencrypt.org/directory
  --non-interactive --no-directory-hooks
```

Flags are passed as a Bash argument vector, never through shell
evaluation. On success the same account and lineage are checked again,
the leaf certificate must have the **exact desired DNS SAN set**, and
renewal paths are finalized back to canonical `/etc/letsencrypt`
references. A zero Certbot status with unchanged selected certificate
bytes and unchanged live symlink target is not accepted as an actual
SAN reconciliation.

On verified success, the dispatcher returns
`CERTBOTBOT_RENEWAL_OCCURRED=true` and
`CERTBOTBOT_DURABLE_CHANGED=true`. Failures clear both results and
must prevent the lifecycle from publishing the workspace.

## Critical exclusions

Neither this adapter nor the earlier renewal provider checks the
cryptographic relationship between issued private key and certificate,
validity period, or trust chain. These remain for the candidate
assertion and archival publication gates. This adapter performs no
S3 call and leaves public CLI dispatch fail-closed until the complete
five-step lifecycle is approved.

A prior Certbot failure can mutate local restored state or have remote
issuance effects. The caller must discard that private workspace, never
attempt in-place rollback of its partial files, and never upload.
