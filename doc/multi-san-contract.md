# Multiple SANs: Selected-Lineage Input and Reconciliation Contract

Status: **approved design from task #44; implementation in task #45**.
Extended three-artifact, independent-runner acceptance remains task #46.
Parent story: #15. Governing decision: [ADR-029](adr/ADR-029-arbitrary-multi-san-selected-lineage.md).
This extends, but does not erase, [the MVP configuration contract](mvp-configuration.md).

## Intent and scope

A **single** Certbot certificate may contain DNS names from unrelated domains,
zones and apexes. One ordinary invocation still selects exactly **one**
certificate lineage by established `CERT_NAME` rules and one S3 archive key.
Story #56 will separately enable **multiple unrelated lineages within the
same archive**. Additional SAN input in this specification neither selects
nor operates on those other lineages.

## Input grammar

```text
certbotbot [options] [--san DNS_NAME ...] PRIMARY_DNS_NAME
certbotbot [options] --domain PRIMARY_DNS_NAME [--san DNS_NAME ...]
```

`--san NAME` and `--san=NAME` are repeatable CLI options. Each occurrence
contains exactly one DNS name; a comma is **not** a CLI separator.
CLI `--san` may appear before or after the single primary positional input,
subject to ordinary option parsing and `--` semantics. After `--`,
remaining operands are positional and still only one primary is accepted.

`ADDITIONAL_SANS=api.example.net,service.other.org` is the optional
exported-environment or literal `.env` form. Individual elements must
be literal DNS names, without token-level quotes, shell expansion,
backslash escaping, or whitespace separators. An empty whole value
means no extras; an empty element is invalid. The existing literal
`.env` outer quoting rule applies to the **whole value** only.

| Source selection | Additional names |
| --- | --- |
| At least one `--san` | All CLI `--san` values, in occurrence order |
| No `--san`, exported `ADDITIONAL_SANS` set | Entire environment list, even if empty |
| Neither above, literal `.env` key set | Entire file list, even if empty |
| No source | Empty list |

CLI additional SANs replace the lower-priority collection; they do not merge
with it. Other settings resolve independently with the existing
CLI > explicitly exported environment > literal `.env` > defaults rule.
Duplicate `--san` options are allowed; duplicate assignments of
`ADDITIONAL_SANS` in a literal file are not. Existing single-valued
CLI flags retain duplicate-option errors. A second positional primary
continues to fail, and `--domain` still conflicts with a positional
primary. An unknown option remains an error.

## Validation and derivation

Normalize each explicit DNS name to lowercase ASCII, validate the existing
DNS grammar (including only leading `*.` wildcard), and reject malformed
values before any AWS or Certbot call. The explicit input cap is **100
names including the primary**, and the final expanded unique cap is
**100 SANs**. These are engineering safety limits and do not promise
that a particular ACME CA will accept the resulting request.

For each explicit primary/additional name in input order, add its canonical
form. If `INCLUDE_SUBDOMAINS=true` add its single ordinary/wildcard
complement immediately afterward. Never expand derived names again.
Deduplicate globally, preserving first occurrence. Exact equality to a
certificate's issued SANs ignores ordering but rejects missing,
unexpected, duplicated, non-DNS, or malformed actual SAN extensions.

| Explicit names (primary first) | INCLUDE_SUBDOMAINS | Desired SANs in provider order |
| --- | --- | --- |
| `example.com`, `api.example.net` | true | `example.com`, `*.example.com`, `api.example.net`, `*.api.example.net` |
| `example.com`, `api.example.net` | false | `example.com`, `api.example.net` |
| `*.example.com`, `api.other.org`, `*.api.other.org` | true | `*.example.com`, `example.com`, `api.other.org`, `*.api.other.org` |
| `example.com`, `example.com`, `*.example.com` | true | `example.com`, `*.example.com` |
| `example.com`, `*.other.org` | false | `example.com`, `*.other.org` |

## Invocation examples

```bash
certbotbot --s3-bucket existing-bucket --san api.example.net \
  --san service.other.org example.com

ADDITIONAL_SANS='api.example.net,service.other.org' \
  certbotbot --s3-bucket existing-bucket example.com

# Literal .env:
# DOMAIN=example.com
# ADDITIONAL_SANS=api.example.net,service.other.org
# S3_BUCKET=existing-bucket
certbotbot

# CLI overrides the full file/environment SAN collection:
ADDITIONAL_SANS='old.example.net' certbotbot --s3-bucket existing-bucket \
  --san new.example.org example.com

# Preserve the established lineage when the set or shortest name changes:
certbotbot --s3-bucket existing-bucket --cert-name example.com \
  --san shorter.io example.com
```

The final example modifies certificate SAN membership while preserving the
original lineage identity, **not** creating a second certificate.

## Provider dispatch and negative outcomes

After the existing seeded-archive, account and exact selected-lineage
preflight, inspect the restored leaf's DNS SANs with strict structural
validation. If the valid set matches desired, call selected
`certbot renew --cert-name` with normal due-renewal/no-op semantics.
If a different **valid** set is present, call selected
`certbot certonly --cert-name ... --renew-with-new-domains`
with separate `-d` arguments for every desired SAN and the original
registered account. **No common-apex requirement remains.** With an absent
selected lineage in otherwise valid account-only archive, selected
issuance uses the expanded set.

Invalid present SAN encodings are not ordinary drift: reject before any
provider call. Likewise reject invalid inputs, unsafe archives, competing
lineages (until story #56), lineage name mismatch, missing accounts,
archived hooks, unexpected post-Certbot SANs, non-replaced certificates
after reconciliation, or failed key/certificate/canonical metadata checks.
Do not publish on these failures. Before PutObject, require the normal
validated complete candidate. A successful unchanged no-op skips upload
unless `UPLOAD_NO_RENEWAL=true`; durable changes still publish to
the **same S3 key**.

Do not run global renew, implicitly select/number a lineage, create an
ACME account, add a second S3 object, or operate on multiple lineages
in one invocation. Unrelated DNS zones require operator-provided AWS
Route53 authority; successful mock tests are not live DNS/ACME proof.

## Task separation and verification

**Task #44 (merged in PR #132):** Establish this interface/security specification,
ADR-029, and the matching decision summary. No public parser/provider
or release artifact is altered; existing MVP suites remain the current
executable contract.

**Task #45:** Update the resolver, bounded public parser, provider
SAN validation, strict actual SAN extraction and same-lineage
reconciliation; document affected Bash functions with the Doxygen
standard. Add focused provider/identity tests, maintain Bash 4.3, and
leave unrelated lineage storage to story #56.

**Task #46:** Exercise CLI/environment/.env precedence, cross-zone
wildcards, duplicates, caps, no-recursion, add/remove/no-op changes,
stable explicit lineage identity, fresh-runner one-key roundtrips,
invalid inputs, corrupted leaf SANs, provider failures, negative
PutObject checks and all three built artifacts. Tests use mocked
AWS/Certbot with no live credentials.
