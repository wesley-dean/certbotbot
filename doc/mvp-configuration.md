# Certbotbot MVP Configuration and Identity Contract

Status: implementation contract for approved milestone #1 tasks (#17, #20, #22, #92, #101).

## Invocation and source precedence

`certbotbot [options] DNS_NAME` operates on exactly one selected primary DNS
identity. `--help` and `--version` do not contact external services.
Exactly one primary identity is required for ordinary operation, supplied either
as one positional argument or with `--domain`.

Every setting resolves independently, in descending precedence:
command-line option, explicitly exported environment variable, optional .env
file, built-in default. An empty value is not a substitute for a valid
required value. CLI flags use `--kebab-case VALUE` or
`--kebab-case=VALUE` as documented below. Boolean options require an
explicit `true` or `false`; an explicit false overrides a true below it.
Names may be supplied as a single DNS_NAME position or as `--domain NAME`;
supplying both is an error. Use `--` to end option parsing.

| .env and environment | CLI | Default |
| --- | --- | --- |
| `DOMAIN` | `--domain` or one positional argument | required |
| `INCLUDE_SUBDOMAINS` | `--include-subdomains` | `true` |
| `CERT_NAME` | `--cert-name` | derived below |
| `S3_BUCKET` | `--s3-bucket` | required |
| `S3_KEY` | `--s3-key` | `latest.tar.gz` |
| `UPLOAD_NO_RENEWAL` | `--upload-no-renewal` | `false` |

`--config FILE` selects a mandatory explicit configuration file instead
of automatically reading `./.env`. An absent implicit `.env` is normal;
an absent explicit file is an error. `--config` is CLI-only.

The .env file is **data, not shell code**. Empty lines and lines beginning
with `#` (after optional leading spaces) are ignored. Each other line must
be exactly `KEY=VALUE` with a supported uppercase key and no whitespace
around the key or assignment operator. Values may be unquoted, single-quoted,
or double-quoted; outer quotes are removed without interpolation or escape
processing. Unquoted values may not have leading/trailing whitespace.
Embedded quote characters and shell expansion operators (`$`, backticks)
are rejected rather than evaluated. Duplicate and unknown keys are errors.
No secrets or whole invalid input values appear in error messages. Actual
AWS credentials are inherited through the normal AWS CLI credential chain,
not stored by this schema.

## Identity and naming

Names are lowercase ASCII DNS names with two or more labels. An optional
leading `*.` represents the only accepted wildcard form. Each label is
1-63 characters, begins/ends with an alphanumeric character, and contains
only lowercase letters, digits, and hyphens; the full ordinary name is
at most 253 characters. Uppercase input is converted to lowercase; trailing
dots and other noncanonical forms are rejected. IDNs must be supplied as
valid ASCII A-labels. No shell evaluation occurs.

With `INCLUDE_SUBDOMAINS=true`, add exactly the complementary name:
`example.com` becomes `example.com` and `*.example.com`; selecting
`*.example.com` produces the same pair. With false, use only the selected
literal name. Deduplicate names, and produce deterministic argument order.

An explicit `CERT_NAME` must be a valid lowercase non-wildcard identifier composed
of DNS-like ASCII labels. When omitted, choose the shortest textual SAN
name; break equal-length ties using ASCII lexical order. The chosen name
is the Certbot lineage identifier, **not** the S3 object key. An existing
lineage with a different established identity must not be renamed or given
a Certbot numeric suffix silently. See the full [certificate naming
contract](mvp-certificate-naming.md) for the explicit-name, legacy-lineage,
wildcard-only and SAN-policy transition behavior table. Archive restoration and lineage-conflict
validation precede issuance. Changing SAN policy must target the same
intended lineage or fail closed.

## Archive and publication prerequisites

The existing configured S3 object must contain the durable contents of
`/etc/letsencrypt` with an already registered suitable ACME account.
Missing object, invalid archive, missing account, and mismatched account
are failures; local host account state must not be imported.

One invocation reads and, when warranted, updates the same configured
S3 bucket/key. No backup object, template name, new bucket or global
renew-all operation is implied.

| Successful operation | Durable state changed? | UPLOAD_NO_RENEWAL=false | UPLOAD_NO_RENEWAL=true |
| --- | --- | --- | --- |
| First certificate issuance | Yes | Upload | Upload |
| Renewal or SAN update | Yes | Upload | Upload |
| Certbot no-op, metadata changed | Yes | Upload | Upload |
| Certbot no-op | No | Skip upload | Upload |
| Any failed stage | Any | Never intentionally upload | Never intentionally upload |

Candidate archives must pass local validation before publication. The
remote archive is protected against failures before the upload begins.
An S3 upload failure cannot guarantee that remote bytes remained unchanged;
the operator must externally serialize writers and arrange recovery for
partial or concurrent remote writes. Live AWS/ACME verification belongs
to milestone #4.

## Public lifecycle integration and evidence

The assembled public executable now resolves its selected identity and
one bucket/key, retrieves the mandatory seeded archive, restores the
private Certbot account/lineage state, and dispatches selected issuance,
renewal or approved bounded SAN reconciliation. Successful provider work
is insufficient for publication until the selected certificate/key and
canonical metadata have independently passed verification. Publication
uses the same selected S3 key and follows the changed-state/no-op truth
table above, including `UPLOAD_NO_RENEWAL`.

[Public lifecycle](mvp-public-lifecycle.md),
[fresh-runner continuity](mvp-fresh-runner-continuity.md), and
[S3 roundtrip verification](mvp-s3-roundtrip-validation.md) record the
mocked end-to-end behavior. AWS, Route53 and Certbot are simulated by
controlled test executables; live service interoperability belongs to
milestone #4. The full naming and conflict matrix is documented in the
[certificate naming contract](mvp-certificate-naming.md).
