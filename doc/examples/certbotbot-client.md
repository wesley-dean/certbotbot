# Standalone Certificate Client Examples

The separately distributed `certbotbot-client.bash` consumes **one current**
certificate-state archive from an existing S3 bucket/key. It does not
issue, renew, decrypt, install, or upload certificates.

These examples require Bash 4.3 or newer, AWS CLI v2 with appropriate
read-only credentials, GNU tar, gzip, and ordinary GNU core utilities.
Download the client and `certbotbot-client.bash.sha256` from the **same
verified release** before running:

```bash
sha256sum -c certbotbot-client.bash.sha256
chmod 0755 certbotbot-client.bash
./certbotbot-client.bash --help
./certbotbot-client.bash --version
```

## Retrieve the current literal key

Prepare an owned, private parent (once), choose an **absent** destination,
and execute the client:

```bash
mkdir -m 700 "$HOME/certificate-states"
./certbotbot-client.bash \
  --s3-bucket existing-certificates \
  --s3-key latest.tar.gz \
  --destination "$HOME/certificate-states/2026-10-25"
```

The command writes the **canonical absolute destination pathname only**
on success. A successful result contains the complete supported account
and certificate archive tree. The operator separately decides which
lineages to use and how to deploy them. An existing destination cannot
be reused or overwritten; choose a new absent path for each retrieval.

## Share nonsecret publisher configuration

An optional literal `.env` in the current working directory can select
the same bucket/key as the issuer:

```dotenv
S3_BUCKET=existing-certificates
S3_KEY=latest.tar.gz
```

Then run:

```bash
./certbotbot-client.bash \
  --destination "$HOME/certificate-states/next"
```

A named config file can be selected with `--config FILE`.
CLI values override exported environment values, which override the
literal config file. The current key defaults to `latest.tar.gz`.
`GPG_SYMMETRIC_KEY` is **not** an accepted client configuration field.

To resolve a date-based current key using one UTC snapshot:

```bash
./certbotbot-client.bash \
  --s3-bucket existing-certificates \
  --s3-key-template 'archive-{YEAR}{MONTH}{DOM}.tar.gz' \
  --destination "$HOME/certificate-states/date-based"
```

No backup enumeration or S3 object-version discovery occurs.

## Operational and security boundaries

Supply a preexisting bucket and IAM identity authorized to retrieve the
selected object. `s3:GetObject` on that key and appropriate bucket-level
read permissions for the absence check are the intended capabilities;
the tool never needs `s3:PutObject`, `s3:DeleteObject`, Route53, or ACME
credentials. Avoid configuring broader AWS authority than required.

Do not point the destination at `/etc/letsencrypt` or a server's live
certificate directory. Instead stage into an absent path under a
trusted, caller-owned, non-group/world-writable parent, then perform
service-specific installation and reload separately. Private PEM and
account data are stored with restrictive permissions. The client
rejects unknown or encrypted content rather than guessing a decryption
method or retrieving another object.

The client uses GNU tar/gzip and Linux-style GNU tools and assumes
the operator serializes cooperating processes running as the same
user against a destination. It does not establish archive authorship,
ACME registration, certificate-chain trust, or transactional deployment.

For failure code details and format constraints, read
[the client contract](../separate-client-contract.md),
[extraction security boundaries](../client-extraction.md), and
[release integrity verification](../release-verification.md).
