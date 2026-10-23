# Certbotbot MVP Configuration and Identity Contract

Status: implementation contract for approved milestone #1 tasks (#17, #20, #22, #92, #101).

## Invocation and source precedence

`certbotbot [options] DNS_NAME` operates on exactly one selected primary DNS
identity. `--help` and `--version` do not contact external services.
Exactly one primary identity is required for ordinary operation, supplied either\nas one positional argument or with `--domain`.

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
a Certbot numeric suffix silently. Archive restoration and lineage-conflict
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

## Integration boundary

This configuration-and-identity PR deliberately stops after validating and
selecting the requested identity. Successful preflight reaches an explicit
nonzero (69) lifecycle-unavailable result. The later archive/lifecycle PR must
integrate the selected values with restored Certbot state, detect established
lineage conflicts, preserve the intended certificate name across SAN changes,
and supply mocked end-to-end evidence before any certificate-operation success
can be reported. A preflight-only test is not evidence that S3 or Certbot works.


## Publisher implementation boundary

The independently testable `certbotbot_s3_publish` adapter defined
under ADR-028 applies the truth table above to the already selected
bucket/key and complete private account/lineage state. Its caller
must still establish successful Certbot processing and independent
certificate/key usability before calling it, and task #27 must
prove that public retrieval and publication resolve to the exact
same key. A provider or packaging failure cannot authorize a
PutObject. The public entrypoint remains fail-closed until this
integration and mocked cross-runner evidence are in place.
