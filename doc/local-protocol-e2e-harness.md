# Local Protocol E2E Service Harness (Milestone 16)

**Scope:** tasks #241-#243. The canonical gateway remains governed by [ADR-046](adr/ADR-046-isolated-pebble-seaweedfs-protocol-e2e.md), while [ADR-047](adr/ADR-047-mocked-route53-local-lifecycle-e2e.md) supersedes real DNS-01 verification for milestone 16. This harness enables test-only services, not a completed end-to-end lifecycle.

## Prerequisites and security boundary

The initial implementation targets a **native Linux Docker Engine with Docker Compose v2**, Bash 4.3+, curl, jq, and access to the upstream registries **only during explicit image provisioning**.  Docker's default local context must be selected, and no `AWS_*` or `GPG_SYMMETRIC_KEY` environment variables may be exported when provisioning or starting.  The script rejects a configured remote Docker host/context.  Podman, Docker Desktop, rootless engine, non-amd64 support, and arbitrary custom subnets have **not** been verified.  Do not infer compatibility from Compose syntax.

The Compose project is named `certbotbot-local-e2e`.  A Docker `internal: true` bridge on `172.31.248.0/24` holds four digest-pinned prebuilt service containers:

| Service | Pinned upstream image | Address | Role |
| --- | --- | --- | --- |
| Pebble | `ghcr.io/letsencrypt/pebble:sha-b1e1ca4@sha256:5080492187bea12909c053d7a2b90a9e95104ef1c82381828e7823db71ce7e54` | `172.31.248.2` | ACME directory on 14000, management on 15000 |
| Route53 API stub | `docker.io/library/python:3.13.18-slim-trixie@sha256:aaf08c5490d52cd92bc27142a5215b1e47355a5eaf9adfad2a0fbc022d0b5490` | `172.31.248.6` | Non-DNS, synthetic XML API on 8056 |
| SeaweedFS | `docker.io/chrislusf/seaweedfs:4.01@sha256:d91cdf769018b143f1c944085b36d29893d9af199e656b2537367c35744fc221` | `172.31.248.4` | S3-compatible API on 8333, ephemeral local data |
| CA gateway | `docker.io/library/caddy:2.10.2@sha256:d8c17a862962def15cde69863a3a463f25a2664942eafd7bdbf050e9c3116b83` | `172.31.248.5` | Internal HTTPS :443, staging TLS and Pebble forwarding |

Each reference includes a manifest SHA-256 and a release/revision identity. Pebble's linux/amd64 digest was obtained from its [upstream GitHub package listing](https://github.com/letsencrypt/pebble/pkgs/container/pebble/810013152?tag=2.10.1) (revision `b1e1ca4`). The Python 3.13.18 runtime tag and digest are recorded in the Compose manifest but have **not** been independently pulled and verified against the official registry in this development session.  The SeaweedFS 4.01 `RepoDigests` reference was reported by [a public image metadata inventory](https://docker.aityp.com/image/docker.io/chrislusf/seaweedfs%3A4.01) and **has not been independently pulled, authenticated or matched against the official Docker Hub tag in this environment**. Image inventory data is not a security audit. All four image references must pass the runtime pull/inspection gate before a harness operation can be qualified as working; SeaweedFS 4.01's age/security posture also warrants explicit review before its use in trusted CI.

There are no `ports` mappings, production network destinations, host Certbot directories, host AWS credentials, or privileged containers.  SeaweedFS uses an in-memory Docker tmpfs at `/data`. Only four read-only test fixtures are mounted: synthetic `s3.json`, the Caddyfile, a pinned public Pebble TLS certificate, and the bounded `route53_bridge.py` stub source. Caddy's local CA key is generated inside ephemeral container tmpfs. Never substitute actual AWS or S3 credentials into that fixture. The Route53 test double accepts only synthetic key identities and authorized local challenge names; its HTTP endpoint remains internal and is **not** a realistic Route53 IAM/SigV4 test.

Pebble runs with `PEBBLE_VA_ALWAYS_VALID=1`: it still processes real ACME orders but does **not** query DNS or validate challenge tokens. The fixed bridge subnet exists for private service addressing, not DNS authorization. If the subnet overlaps any host/VPN/Docker network, fail and resolve that network conflict through a separately reviewed narrow change. Do not modify host DNS, publish bridge ports, allow a public route, or silently select a different network.

## Controlled lifecycle

From the repository root:

```bash
# One-time image retrieval; this operation requires registry network access.
bash tests/e2e-local/run.bash fetch

# All images must now already be cached. Docker Compose is forbidden to pull
# or build during startup, and the created bridge is internal.
bash tests/e2e-local/run.bash up

# Inspect the actual network/port/container state (service-level only).
bash tests/e2e-local/run.bash status

# Mandatory after each attempt, including failed tests.
bash tests/e2e-local/run.bash down
```

On startup, the script validates Docker Compose's resolved topology, verifies the pinned images exist locally, starts only the four pinned test services, checks the *actual* network is an internal bridge and no host port is published, and probes the real Pebble ACME directory, the bounded Route53 HTTP stub, and SeaweedFS S3 HTTP endpoint, then validates HTTPS staging-directory access using the ephemeral gateway's public root and strict TLS verification. If any check fails, startup fails and invokes project-scoped teardown. `down` deletes the project's containers, network, and disposable volumes; it never removes cached upstream images. No local server compilation, host server binary installation, or upstream-image build is performed.

**Important:** The readiness probes run from the **Linux Docker host** to bridge addresses; they do not expose management ports or configure the production certificate tool. The Pebble *readiness probe only* uses `curl -k` because upstream Pebble's local test certificate is self-signed. **Actual Certbot/producer TLS validation must remain enabled.** A listening endpoint does not prove CA identity continuity, Certbot plugin compatibility, SeaweedFS conditional writes, or true certificate renewal. Real DNS-01 validation is intentionally excluded by ADR-047. Those are explicit acceptance gates for tasks #241 and #243-#248.

## Future integration boundaries

Task #241 adds a bounded, test-only gateway and provider invocation gate, without changing the producer's public `production|staging` authority model. The actual engine-backed provider exchange remains unverified. Task #243 provides a minimal Route53 API stub that deliberately does **not** modify Pebble DNS, together with Pebble's always-valid challenge mode. The separate issue #252 proposes ID-preferred hosted-zone selection and remains open/unimplemented. Task #244 creates a synthetic bucket and uses the real built producer to register and issue. Subsequent tasks verify fresh-runner restore, no-op, second real ACME renewal order, negative isolation and CI. Do **not** mix those capabilities into this harness PR or substitute mocked protocol responses for acceptance evidence.

Do not direct ordinary `certbotbot` at this network except through a disposable, guarded test runner. Pebble accounts are **not** real Let's Encrypt staging accounts. Neither a valid image digest nor an HTTP readiness result guarantees interoperability with the installed Certbot, Route53 plugin, AWS CLI or SeaweedFS conditional S3 operations. Milestone #4's separately authorized live Let's Encrypt staging/AWS workflow remains untouched.

## Test-only ACME gateway and provider boundary

Task #241 adds a fourth service, the digest-pinned official Caddy v2.10.2 image, as an isolated TLS gateway. Its executable is new test-only trusted code under ADR-015; the image digest is a reproducibility claim, not a security assessment. Caddy runs as numeric user 10001 with a read-only root, ephemeral in-container PKI data, disabled admin and automatic host trust installation, and only NET_BIND_SERVICE for internal port 443. No gateway ports are published. Qualify image provenance, actual runtime behavior, and relevant CVEs before trusting this service in release CI.

The maintained [gateway configuration](../tests/e2e-local/gateway.Caddyfile) accepts only the canonical staging hostname and maps `/directory` to Pebble's `/dir`; all ACME traffic is forwarded only to `https://pebble:14000`. Pebble receives the original staging Host and the explicit forwarded HTTPS scheme. Pebble source at revision `b1e1ca4` constructs absolute resource URLs from those fields, so this *may* retain signed ACME URL integrity without altering the shipped producer or rewriting JWS bodies. That interoperability is still **unproven** until actual Certbot runs against the stack.

Gateway-to-Pebble transport verifies the pinned upstream's `pebble` TLS hostname using the [upstream public PEM fixture](../tests/e2e-local/pebble-upstream.pem) copied from revision `b1e1ca4`. The gateway creates its own ephemeral test certificate for the exact public staging hostname with `tls internal`. Startup copies only the gateway's **public root certificate** into a temporary host file for certificate-verified readiness, then deletes it. Nothing installs the test root into the host trust store; all gateway private keys remain container-local tmpfs state.

The future independent runner in task #244 must bind the staging hostname to `172.31.248.5` in **its own** namespace, mount a private copy of the gateway's public root at `/run/certbotbot-e2e/gateway-root.crt`, and have no default route. The test-only [provider process gate](../tests/e2e-local/provider-env.bash) requires those conditions, an unavailable production CA DNS name, and a certificate-verified staging directory with only same-origin ACME endpoints. It then runs an exact checksum-verified public producer under `env -i` with synthetic AWS keys, disabled metadata, empty shared AWS configuration, a local-only `AWS_ENDPOINT_URL_S3`, and per-process trust environment, including the bounded internal Route53 endpoint. Its CLI requires precisely one explicit staging selection; it never creates a new public ACME selector. Service-specific endpoint variables are supported by the [AWS CLI documentation](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html), but actual installed AWS CLI and Certbot plugin support must be verified.

**Route53 is directed to the internal stub at `http://172.31.248.6:8056`**. The test-only synthetic API responses let the installed plugin continue, while Pebble skips challenge validation. This exercises neither real Route53 behavior nor DNS propagation. An ignored endpoint override must be blocked by container isolation, not silently replaced with public Route53. Existing ordinary public artifacts, release workflow, and milestone #4 staging acceptance stay unchanged. Task #244 adds a genuine, isolated runner with account registration and first issuance; no such runtime test is claimed here.

Potential feasibility blockers include Caddy's low-port binding as nonroot, its certificate trust dialect, canonical ACME URL consistency across signed POST requests, Certbot account recognition, and SeaweedFS's S3 conditionals. Fail those gates explicitly rather than disabling TLS, editing signed JWS payloads, forging Certbot account material, or using real providers.

## Limits and evidence still required

This development environment has no Docker or Podman engine and cannot reach the container registries. The author can perform syntax and static policy checks but **cannot claim a successful `fetch`, `up`, live readiness, S3 conditional compatibility, Docker/Podman parity, or offline egress probe** from here. Actual engine-backed evidence should record the engine version, each pulled manifest digest, all service states, the network's `Internal=true` property, host-port map absence, HTTP readiness, cleanup after failure and non-interference with ordinary CI. Unverified items are explicit outstanding validation, not assumed passes.

An internal Docker network limits container routing, but the host and privileged engine operator remain outside its security boundary; complete egress-negative tests are a later milestone requirement. These fixtures are never to be promoted to real environment credentials, and Pebble-issued accounts are **not** Let's Encrypt staging accounts.

## Deliberate mock boundary (ADR-047)

The local stack uses real Certbot with `dns-route53`, but Route53 is an external
stub. It returns a synthetic hosted zone, acknowledges bounded TXT mutations,
and reports deterministic change status. No DNS responses are created. Pebble's
`PEBBLE_VA_ALWAYS_VALID=1` setting disables actual validation requests; a
successful local issuance **does not prove AWS Route53 or DNS-01 correctness**.
This reduces test complexity while retaining real ACME registration, orders,
certificate issuance, SeaweedFS persistence, and native Certbot state, once
those end-to-end tests are implemented and executed. The upstream plugin must
still be verified to honor `AWS_ENDPOINT_URL_ROUTE53`; a public fallback is
forbidden. The synthetic hosted zone currently uses a fixed test fixture; the
ID/name selection enhancement in issue #252 is separately tracked.

Run `python3 -B tests/e2e-local/route53_bridge_test.py` for offline mock
protocol checks. These are contract/unit tests only, not engine-backed
integration. The image pull and Docker startup gates remain outstanding.

## First real ACME registration and issuance (task #244)

The new, **test-only** `first-issue-host.bash` prepares a runner image
containing the real installed Certbot, `certbot-dns-route53`, AWS CLI, and
the exact `dist/certbotbot.bash` public executable with its SHA-256 companion.
This is distinct from compiling or installing Pebble or SeaweedFS on the host.
The runner is built from an immutable Alpine Linux base image and acquires
package dependencies **before** starting the private network. Installed
transitive package versions and actual interoperability must be recorded by
the operator; the pinned base does not pin every package patch.

From the repository root, after dependencies required by `make build`
have been prepared:

```bash
make build
# Image/package acquisition happens here, before test isolation:
bash tests/e2e-local/first-issue-host.bash build
bash tests/e2e-local/run.bash fetch

# No image pulls, package installation, or public provider access afterward:
bash tests/e2e-local/run.bash up
bash tests/e2e-local/first-issue-host.bash run
bash tests/e2e-local/run.bash down
```

Always invoke `down` after the attempt, whether it passes or fails.
The host-side orchestrator itself is not a cleanup replacement for the
Compose project's disposable services; it cleans its own temporary public
gateway root and two runner containers. The runner image can be reused only
when the verified producer digest is unchanged.

The scenario uses one fixed, nonproduction local identity:
`test.e2e.test`, bucket `certbotbot-local-e2e` and object
`latest.tar.gz`. It requires an **empty** SeaweedFS test bucket/object
state and refuses an existing object. It creates the bucket through the real
AWS CLI, verifies that ordinary certbotbot issuance refuses the missing
account archive without creating an object, then explicitly calls the real
public `certbotbot register` using `--acme-environment staging`,
`--agree-tos true` and synthetic contact `local-e2e@example.invalid`.
The registration must publish a genuine native account-only S3 archive.
The exact same public producer next requests a real Certbot ACME certificate
from Pebble, using the bounded Route53 stub and **Pebble's explicitly
bypassed challenge validation**. The test asserts a new published archive,
native selected account, selected renewal state, exact SAN, and a parseable
certificate with a DER fingerprint.

The first runner's writable state exists only on container-local tmpfs.
After that runner exits, an entirely fresh runner independently downloads
the current SeaweedFS object and verifies the expected archive SHA-256 and
leaf certificate. The only cross-run input is the nonsecret archive digest;
no private account files, PEM, or issuer workspace are shared. A full
fresh-runner certbotbot restore and normal no-op execution are intentionally
left to task #245. Real due renewal and independent republish belong to #248.

The test runner is nonroot, read-only, and has an isolated Docker
`internal: true` network, `--dns 127.0.0.1`, a single canonical
staging `--add-host` mapping, synthetic AWS credentials, explicit local
S3/Route53 endpoints, no capabilities, and **no** host Certbot/AWS mounts,
Docker socket, or published ports. Its only inbound file is the ephemeral
gateway **public** root certificate, mounted read-only; the gateway
private PKI stays in its own disposable container. The temporary root
file and runner logs are removed after each attempt. Production CA access
must fail from inside the runner. Actual on-host no-egress observations
remain necessary before reporting protocol-level acceptance.

Failures are fail-closed. In particular, SeaweedFS must genuinely support
`HeadBucket`, missing-object discrimination, `PutObject` with conditional
`If-None-Match` and `If-Match` as applicable, real ETag identity and
independent `GetObject`. A response fabricated by the harness cannot
establish these semantics. The installed Certbot plugin must respect
`AWS_ENDPOINT_URL_ROUTE53`; an ignored override cannot be replaced by
live Route53. A failing runtime probe is a compatibility blocker, not
permission to disable certificate validation or modify the producer.

**Execution evidence:** This feature branch contains the execution
procedure and offline Bats checks. Its authoring runtime has no Docker
engine, so no successful real Pebble registration, SeaweedFS publish,
Docker build, or independent readback is claimed until a qualified Linux
Docker host executes the above steps successfully and records its exact
image and artifact identities. Milestone #4's manual live-provider
acceptance remains separate.

## Fresh-runner selected renewal no-op (task #245)

After the first genuine account registration and certificate issuance, the
host-side first-issue runner launches **three additional separate, fresh
containers**, one for each checksum-verified public producer flavor:
`certbotbot.dev.bash`, `certbotbot.bash`, and
`certbotbot.min.bash`. They share **no** Certbot workspace, home state,
account files, client cache, or ephemeral files with the bootstrap container.
Each must independently fetch and validate the current SeaweedFS object,
then invoke the actual selected normal renewal/check command through the
existing `provider-env.bash` gate. The producer itself restores the native
Certbot account, selected renewal lineage and private key from the S3
archive; no host-state or copied account directory is provided.

The test compares both SeaweedFS `HeadObject` identity (ETag,
LastModified, ContentLength) and an independently downloaded archive's
SHA-256 **before and after each invocation**. It also requires the actual
producer to return `checked` with `published=false` under
`--upload-no-renewal false`. The archive must still contain the canonical
staging account, renewal metadata, matching selected certificate SAN, and
corresponding private key. Unchanged ETag or bytes *alone* cannot prove
zero S3 requests; these are independent observable checks paired with the
real producer's no-publication outcome, not packet-level instrumentation.

To establish that no ACME order was created, the host harness inspects
**only the nonsecret integer order count** emitted by the pinned upstream
Pebble WFE whenever its in-memory database adds a new order. The counter
must exist after initial issuance and must not advance during any no-op
runner. A missing or unparseable counter is an **evidence failure**, never
interpreted as zero new orders. Raw Pebble logs and account details are
not printed in a success report.

Pebble's upstream sample config offers a randomized short-lived profile.
Such an issuance could be due immediately even on the same test run, making
a no-op test flaky or semantically wrong. The local-only, read-only
[pebble-config.json](../tests/e2e-local/pebble-config.json) uses upstream's
90-day default profile as its **only** available profile. The harness
checks the profile's precise 7776000-second validity period, and rejects
unexpected configuration before startup. This changes no production
Certbot/client policy and does not shorten or force renewal. Genuine
due renewal remains task #248, governed by its own review.

The same documented commands for task #244 now cover task #245:

```bash
make build
bash tests/e2e-local/first-issue-host.bash build
bash tests/e2e-local/run.bash fetch
bash tests/e2e-local/run.bash up
bash tests/e2e-local/first-issue-host.bash run
bash tests/e2e-local/run.bash down
```

A successful run must report three explicit
`restored_noop=<flavor>; no_new_order=true; no_republish=true` results
and one independent certificate DER SHA-256. All of these claims depend on
running the actual pinned Docker service stack. Static Bats assertions,
source-level reasoning and passing ordinary PR CI do **not** substitute
for a real container-backed run. No successful engine-backed run is claimed
from this development environment.
