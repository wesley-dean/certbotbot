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

Task #241 adds a bounded, test-only gateway and provider invocation gate, without changing the producer's public `production|staging` authority model. The actual engine-backed provider exchange remains unverified. Task #243 provides a minimal Route53 API stub that deliberately does **not** modify Pebble DNS, together with Pebble's always-valid challenge mode. Issue #252 adds explicit ID-first local zone selection, without changing the shipped producer or real DNS acceptance boundary. Task #244 creates a synthetic bucket and uses the real built producer to register and issue. Subsequent tasks verify fresh-runner restore, no-op, second real ACME renewal order, negative isolation and CI. Do **not** mix those capabilities into this harness PR or substitute mocked protocol responses for acceptance evidence.

Do not direct ordinary `certbotbot` at this network except through a disposable, guarded test runner. Pebble accounts are **not** real Let's Encrypt staging accounts. Neither a valid image digest nor an HTTP readiness result guarantees interoperability with the installed Certbot, Route53 plugin, AWS CLI or SeaweedFS conditional S3 operations. Milestone #4's separately authorized live Let's Encrypt staging/AWS workflow remains untouched.

## Test-only ACME gateway and provider boundary

Task #241 adds a fourth service, the digest-pinned official Caddy v2.10.2 image, as an isolated TLS gateway. Its executable is new test-only trusted code under ADR-015; the image digest is a reproducibility claim, not a security assessment. Caddy runs as numeric user 10001 with a read-only root, ephemeral in-container PKI data, disabled admin and automatic host trust installation, and only NET_BIND_SERVICE for internal port 443. No gateway ports are published. Qualify image provenance, actual runtime behavior, and relevant CVEs before trusting this service in release CI.

The maintained [gateway configuration](../tests/e2e-local/gateway.Caddyfile) accepts only the canonical staging hostname and maps `/directory` to Pebble's `/dir`; all ACME traffic is forwarded only to `https://pebble:14000`. Pebble receives the original staging Host and the explicit forwarded HTTPS scheme. Pebble source at revision `b1e1ca4` constructs absolute resource URLs from those fields, so this *may* retain signed ACME URL integrity without altering the shipped producer or rewriting JWS bodies. That interoperability is still **unproven** until actual Certbot runs against the stack.

Gateway-to-Pebble transport verifies the pinned upstream's `pebble` TLS hostname using the [upstream public PEM fixture](../tests/e2e-local/pebble-upstream.pem) copied from revision `b1e1ca4`. The gateway creates its own ephemeral test certificate for the exact public staging hostname with `tls internal`. Startup reads only the gateway's **public root certificate** as the unprivileged Caddy container user, writing it into a temporary host file for strict certificate-verified readiness, then deletes it. Docker's archive-copy API is not used for this mode-0600, container-owned tmpfs file. Nothing installs the test root into the host trust store; all gateway private keys remain container-local tmpfs state.

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
still be verified to honor `AWS_ENDPOINT_URL_ROUTE_53` (Botocore's
Route 53 service identifier is `route-53`); a public fallback is
forbidden. The synthetic Route53 stub uses a fixed test fixture and requires one explicit,
test-only selector before accepting provider requests:
`LOCAL_E2E_ROUTE53_HOSTED_ZONE_ID` (preferred) or
`LOCAL_E2E_ROUTE53_HOSTED_ZONE_NAME` (secondary). The sealed Compose profile
supplies the fixed local ID. With only the name, the stub resolves an exact
case-insensitive, terminal-dot-normalized match to its one authorized synthetic
zone and permits a bounded `ListHostedZonesByName` API response. An explicit ID
always takes precedence over a valid name; malformed or unknown IDs never fall
back, and empty, malformed or missing configuration fails before HTTP startup.
The upstream Certbot plugin still uses its own `ListHostedZones` request.
Neither variable is a public certbotbot option, AWS zone lookup, or authorization
to discover arbitrary domains. See [ADR-055](adr/ADR-055-explicit-id-first-local-route53-zone.md).

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
`AWS_ENDPOINT_URL_ROUTE_53`; an ignored override cannot be replaced by
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

## Exactly one second real ACME order (task #248; ADR-049)

After the initial real Pebble issuance, independent verification, and three
distinct, non-due `development`/`ordinary`/`minified` no-op runners, the
existing `first-issue-host.bash run` scenario performs one additional
**real Certbot renewal** through the unchanged, verified ordinary public
producer. The same documented `build`, `fetch`, `up`, `run`, `down`
commands exercise this phase automatically. No new public CLI flags or
production service identities are introduced.

The existing Pebble config intentionally issues a 90-day certificate to
ensure the normal no-op phase is meaningful. Such a certificate is not
naturally due just minutes later. Instead, the task #248 runner image contains
a **test-only, single-use Certbot argv adapter**
[`certbot-force-renewal.bash`](../tests/e2e-local/certbot-force-renewal.bash).
All normal commands delegate to the real installed `/usr/bin/certbot`
unchanged. Only the separate `renew` runner creates a private mode-0700
authorization directory and mode-0600 marker in its **own** disposable tmpfs.
The adapter validates the exact selected `renew --cert-name test.e2e.test`,
canonical staging `--server`, real account, private configuration directory
and noninteractive no-hooks flags, then deletes the marker and executes
the installed real Certbot **once** with `--force-renewal`. It leaves a
nonsecret private receipt. The marker and receipt are destroyed with the
container; the adapter is absent from the shipped producer, release OCI image
and client.

This does **not** prove the scheduling window of naturally due certificates.
It proves that the unchanged producer correctly recognizes and validates a
genuine replacement certificate, serializes the selected state, and makes
its normal conditional SeaweedFS publication decision **after** real
Certbot completes a second ACME transaction. The normal non-due behavior
is verified independently before and after the forced event.

The runtime gates require **all** of the following before the second order
can be reported as successfully tested:

1. The initial archive is independently downloaded into the renew runner,
   has the correct native staging account, sole selected lineage and
   leaf/private-key match, and its SHA-256 equals the verified pre-renewal
   object digest.
2. The real public producer itself restores the S3 state and calls real
   Certbot. The private one-shot adapter receipt proves the intended
   argument modification happened and was consumed.
3. The producer reports `checked; published=true` and the remote S3
   ETag and independently downloaded object SHA-256 both change.
4. The **new certificate DER fingerprint differs** from the old; the
   requested SAN, native Certbot account identity/private key and selected
   renewal lineage remain stable. No other lineage is introduced.
5. The serialized renewal configuration contains no persistent test-only
   force setting, and the new archive passes the independent account,
   certificate, private-key and lineage checks.
6. Pebble's own nonsecret order counter advances by **exactly one**, then
   stops. An unreadable counter is failure rather than assumed success.
7. Yet another new runner independently downloads the new S3 object and
   verifies its exact digest and certificate fingerprint. A final normal
   unchanged-producer no-op in another fresh runner leaves the order count
   and object unchanged.

The runner never prints ACME account IDs, certificate private keys, raw
provider output, or archived secrets. If the real Certbot plugin, Pebble
gateway, conditional S3 write or forced-renewal option is incompatible,
the scenario **fails closed**. No local source inspection or GitHub unit
test run is evidence that these real protocols have already succeeded.

This test relies on the two-namespaced E2E boundaries in ADR-047:
`PEBBLE_VA_ALWAYS_VALID=1` and the simulated Route53 API, with no public
provider access. It is not a test of DNS-01 propagation or AWS/Let's
Encrypt interoperability. Broader negative fault injections are #246, and
a dedicated runtime CI gate is #247. The real-provider staging workflow
in milestone #4 remains separate and operator authorized.

**Evidence still required:** The authoring runtime has no Docker/Podman
engine. A native isolated Docker host must execute the documented flow
and retain bounded results (second Pebble order count, old/new DER and
archive digests, private adapter receipt validation, selected lineage and
account equality, changed SeaweedFS ETag, no further no-op order). Static
Bats and CI checks alone do not justify claiming successful real renewal.


## Bounded local negative lifecycle suite (task #246)

The additional, **test-only** `run-faults` action of
`tests/e2e-local/first-issue-host.bash` verifies that the real public
producer fails closed when external dependencies or archived state become
unusable. It is deliberately **separate from the positive run**, and
requires the same *already-running*, internally networked Docker Compose
project **after** its successful `run` has stored a genuine certificate:

```bash
make build
bash tests/e2e-local/first-issue-host.bash build
bash tests/e2e-local/run.bash fetch
bash tests/e2e-local/run.bash up
bash tests/e2e-local/first-issue-host.bash run
bash tests/e2e-local/first-issue-host.bash run-faults
bash tests/e2e-local/run.bash down
```

Always run the final `down`, including on failure. The fault suite does
**not** construct a synthetic success or replace real account, certificate
or SeaweedFS readback behavior. It uses distinct clean runners and one
verified, checksum-valid public producer with explicit staging selection.
The normal issued synthetic identity is `test.e2e.test`. A new
`fault.e2e.test` selected lineage is requested for faults that otherwise
would be skipped by the already-issued, non-due certificate. No live AWS
credentials, public Route53, public ACME endpoint, metadata service or
external DNS is required or authorized.

Each scenario obtains a verified baseline of the *real* SeaweedFS current
object (the `latest.tar.gz` key in the synthetic bucket), then requires
the original object's independently observed SHA-256, S3 ETag,
LastModified, ContentLength, canonical staging account, selected leaf
certificate SAN and matching private key to remain unchanged after
the failed invocation. The host obtains an **additional** independent
readback in a new runner after each scenario. Neither a nonzero exit
alone nor the absence of a terminal success line is sufficient proof.
If an actual S3 write returns an uncertain outcome, this harness must
fail rather than assert rollback or unobserved preservation.

| Literal scenario | Injected boundary | What passing means | Not demonstrated |
| --- | --- | --- | --- |
| `ca-production` | Existing staging-only provider guard rejects explicit production before invoking the producer | Production cannot be selected inside this local run | Public CA connectivity or real CA authorization |
| `s3-unavailable` | Public producer's S3 endpoint is forced to a closed **loopback** port; independent readbacks still use real SeaweedFS | Inaccessible S3 is never treated as missing, registration is not implicit, and original object is not rewritten | Real IAM denial response |
| `corrupt-archive` | Real SeaweedFS holds a second key with invalid gzip bytes | The public producer rejects the corrupt archive; the corrupt fixture remains unchanged; current valid object is unaffected | All possible malformed tar/PEM structures |
| `acme-order-rejected` | Pebble's pinned `domainBlocklist` rejects the exact synthetic `blocked.e2e.test` identifier during `newOrder` | The real producer's new order fails, with no publication to the current object | Live Let's Encrypt issuance policy or rate limits |
| `route53-unavailable` | Public producer's Route53 endpoint is a closed **loopback** port, while real Pebble and SeaweedFS remain available | A fresh issuance cannot silently publish a candidate when the simulated external DNS API is unavailable | Real AWS Route53 semantics or DNS propagation |
| `s3-put-reject` | A runner-only AWS CLI adapter lets the real installed CLI handle every other operation but refuses a bounded `s3api put-object` against the one current synthetic key | The unchanged public producer reaches its publish boundary, reports failure, and leaves the previous real SeaweedFS object unchanged | SeaweedFS's actual rejected-PUT response and real AWS authorization semantics |
| `acme-unavailable` | The host pauses only the internal Pebble container during one runner invocation; an EXIT trap ensures it is unpaused | The canonical staging gateway refuses unavailable ACME service before a misleading successful publish; current S3 object is stable | A mid-order ACME failure; order-policy rejection is tested separately above |

The private `provider-env.bash` accepts only literal fault modes. The
only altered endpoint addresses are fixed local test IPs or the closed
`127.0.0.1:9` loopback endpoint, never caller-supplied URLs. The test-only
`aws-put-reject.bash` adapter lives in the **isolated runner image**, not
the shipped producer or release image, and delegates every nonfaulted call
unchanged to the **real** `/usr/bin/aws`. It emits a nonsecret private
receipt only for the exact synthetic bucket/current-object PutObject
attempt; it never invents an accepted write. The real installed Certbot,
private Pebble authority and native Certbot registration/lineage remain
the positive test dependencies.

The host runs the failure modes sequentially, without concurrent writers,
stores all raw provider output only in ephemeral mode-0700 workspace files,
and emits only literal scenario names and bounded success/failure
identifiers. The corrupt fixture is stored under a separate synthetic key
and disappears when the disposable project volume is torn down; reusing
the same running project for another identical corrupt-fixture injection
will fail safely rather than silently overwrite it. The ACME outage is
introduced by `docker pause` only for the owned Pebble container and is
undone by a scoped EXIT trap; other application and host Docker state are
not touched. The runner's `internal: true` network, exact
staging-name mapping, synthetic AWS credentials, no default route, and
production name-resolution refusal remain mandatory. A successful
preflight establishes these bounds at the tested moment, **not** complete
packet-capture proof of all possible egress.

**Required runtime evidence:** For each literal scenario, preserve a
bounded nonsecret status attesting the expected refusal, the unchanged
S3 object and independent readback. A successful local suite demonstrates
failure *handling* under these controlled faults; it is not evidence that
the genuine AWS/Let's Encrypt services behave identically. The authoring
runtime has no Docker Engine, so this branch adds runnable negative
protocol tests but **does not claim that a Docker-backed negative
sequence has passed**. The dedicated, fully gated CI invocation remains
task #247. Milestone #4's manually authorized real-provider staging
acceptance remains separately necessary.


## Automatic isolated protocol acceptance in CI (task #247)

The **Local protocol E2E (challenge validation bypassed)** workflow
(`.github/workflows/local-protocol-e2e.yml`) provides the dedicated CI
acceptance gate. It runs on same-repository `push` and parameterless
`workflow_dispatch` only, following ADR-048's decision to avoid duplicate
pull-request-triggered Test runs. The workflow is separate from the normal
three-flavor Bats/OCI suites and the owner-authorized, secret-bearing
live milestone #4 staging workflow.

The job uses a disposable `ubuntu-24.04` hosted Linux runner with native
Docker and Compose v2, checkout fixed to the commit under test, read-only
repository permissions, no GitHub/AWS/OIDC secrets, no pushed images, and no
Docker socket in the test containers. A concurrency group cancels older
runs for the same branch, and the job has a fixed timeout. No workflow
artifacts containing certificates, archives, provider responses, or other
sensitive runtime state are uploaded.

The private runner Dockerfile has its own deny-by-default
[`runner.Dockerfile.dockerignore`](../tests/e2e-local/runner.Dockerfile.dockerignore).
It allowlists only the three checksum-verified public producer flavors and
their checksum files, the pinned Alpine repositories file, and the
five required local runner helpers. The repository's production
`.dockerignore` remains unchanged and continues to exclude test code
from normal published OCI build contexts.

The exact entry point is:

```bash
bash tests/e2e-local/ci-local-e2e.bash
```

It takes **no user-controlled arguments, CA URLs, credentials or bucket
values**. Its mandatory execution order is:

1. Refuse inherited cloud credential environment variables, remote Docker
   contexts, and root execution; verify required local tools.
2. Acquire and check pinned repository build dependencies (`make deps`,
   `make deps-check`), assemble all public producers with
   `make build VERSION=0.0.0-dev`, verify their checksum companions,
   build the exact runner containing real Certbot/AWS CLI, and pull the
   four immutable-digest service images. All **acquisition precedes**
   the sealed service phase.
3. Start the existing fixed Docker Compose project with cached images,
   verify the actual `internal: true` bridge, no published host ports,
   no unexpected privilege, and check private service readiness.
4. Run `first-issue-host.bash probe` using the same ephemeral nonroot,
   read-only, no-default-route runner flags as normal issuance. Assert
   trusted canonical staging-name HTTPS works locally. Try connecting
   only to the three reserved documentation IPv4 addresses
   `192.0.2.1`, `198.51.100.1` and `203.0.113.1`, and resolving
   only reserved `.invalid` DNS names; they must all fail. No probe
   intentionally connects to a public AWS, Let's Encrypt or metadata host.
5. Run `first-issue-host.bash run`: explicit real Pebble registration,
   first ACME order, SeaweedFS publication, independent clean-runner
   verification, three public producer no-ops, exactly one second real
   ACME order using the one-shot test-only Certbot force trigger,
   changed DER/remote object, another independent fetch and a final
   ordinary no-op. Every bounded attestation is required.
6. Run `first-issue-host.bash run-faults`: all **seven** literal failure
   modes, including a real Pebble `newOrder` rejection, synthetic Route53
   outage, unavailable/rejected S3, corrupt archive, production-CA
   refusal and Pebble outage. Each checks the real SeaweedFS current
   object remains unchanged, with another independent readback.
7. Repeat the active no-egress probe, then tear down only the disposable
   Compose containers, private network and anonymous volumes. An EXIT
   trap attempts to unpause Pebble before teardown, even on error. The
   workflow has a separate unconditional defensive cleanup step. Any
   failed or incomplete cleanup is a failed job.

**Fail-closed policy:** A skipped stage, absent receipt, public route,
bad checksum, wrong image, missing Docker, failed real protocol call,
unparseable evidence, or service cleanup error is a CI failure. Private
runner logs and gateway public root files are temporary and removed.
Only exact, nonsecret status identifiers and verified lifecycle outcomes
are printed. The scenario reports its mode as
`challenge-validation-bypassed`, and explicitly marks
`aws_route53_dns01_live_ca=not_tested`.

**Important nonclaims:** Docker's `internal: true` network and actual
no-route/reserved-IP probes provide meaningful local isolation evidence,
but are not full packet capture or proof against a compromised Docker
engine, kernel or host. Pebble's `PEBBLE_VA_ALWAYS_VALID=1` still
**bypasses DNS-01 challenge verification**, and the Route53 API is an
allowlisted test double. Genuine Let's Encrypt staging, AWS Route53 DNS
propagation and Amazon S3 IAM/interoperability remain the separate
milestone #4 manual staging acceptance, under ADR-043.

## Negative timing evidence and parallelism boundary (ADR-057)

The seven required negative cases continue to run serially against the
existing one-service, one-authoritative-object fixture. Each completed
case emits one bounded elapsed-seconds receipt **after** the expected
refusal and an independent SeaweedFS readback. The CI host accepts exactly
one properly shaped receipt per case and prints only a fixed scenario name,
the integer duration, and `status=pass`. Missing, duplicate, malformed or
oversized receipts fail closed. In partial debug mode, exactly the selected
case's duration is reported, without a full acceptance claim.

Historical successful [run 41875100822](https://github.com/wesley-dean/certbotbot/actions/runs/41875100822)
measured 128 seconds across the seven negatives; its positive lifecycle
alone cost 171 seconds and private startup 24 seconds. Repeating both to
seed independent Compose workers would exceed the entire serial negative
stage. This *estimate* does not prove all forms of concurrency unprofitable;
it establishes that the naive full-fixture-per-worker approach cannot
justify itself against this run. Running the existing seven cases
concurrently against one shared Pebble/SeaweedFS project is unsafe,
especially while the `acme-unavailable` test pauses the shared CA.

The [benchmark report](e2e-negative-parallelism-benchmark.md) separates
real CI timings from estimates. A later opt-in concurrency mode would
need a new approved task, isolated project names/networks/Pebble/SeaweedFS
and object state, cancellation recovery, per-case receipts and a
measured *full-suite* improvement; mandatory serial fallback and
push-triggered full coverage must be preserved. See ADR-057.

## Native Post-Issuance Metadata Stabilization (ADR-054)

The real challenge-validation-bypassed Pebble/Certbot [run
41780291675](https://github.com/wesley-dean/certbotbot/actions/runs/41780291675)
showed a successful non-due certificate check with `published=true`:
the genuine SeaweedFS object's bytes changed, the selected renewal
configuration changed, and no new ACME order appeared.  A disposable
unchanged-producer replay [run
41781308764](https://github.com/wesley-dean/certbotbot/actions/runs/41781308764)
then returned `checked; published=false`, with both archive and renewal
configuration unchanged.  These observations support one native
metadata-only stabilization immediately following real first issuance.

Under ADR-054 the local positive workflow first verifies the initial issued
object independently, then runs exactly one **separate real producer
stabilization**, with `UPLOAD_NO_RENEWAL=false`.  It permits that *single*
durable renewal-metadata publication only after independently checking that
the ACME account identity, selected lineage, and matching certificate/key
are unchanged.  The host must independently show no extra Pebble ACME
order. A *new* verifier runner then checks the exact replacement SeaweedFS
object and the original certificate DER before updating its expected
archive digest.

Only after that setup does the workflow count the three required strict
fresh-runner non-due no-ops (development, ordinary, and minified).
**Each of those three must still avoid all S3 rewrites and all new ACME
orders**, preserve exact object identity, and pass independent certificate
checks.  The genuine second order, separate replacement readback, ordinary
post-renewal no-op, seven negative scenarios, pre/post no-egress proofs,
and complete private-network cleanup remain mandatory. The local test
still does not validate actual DNS-01 propagation, AWS Route53, Amazon S3,
or Let's Encrypt. Do not simulate normalization, forge renewal metadata,
suppress legitimate producer publication, or bypass negative assertions.

For a first no-op failure, the same confidentiality boundary applies at the
runner's individual subchecks: an exact finite checkpoint identifies before-
and after-archive readback, private account and leaf validation, producer
invocation and its success receipt, remote object metadata, and digest
comparisons. When the unchanged producer exits unsuccessfully, only a short
allowlisted category corresponding to a literal self-authored product error
may be relayed. If the producer exits successfully but its no-op receipt fails,
the harness classifies the public status as `checked`, `issued`, or `other`,
and publication as `true`, `false`, or `absent`. On a rejected
completion it may independently reread the selected remote object and compare
only opaque bytes and the selected renewal configuration, reporting
`changed`, `unchanged`, or `unreadable`. The host also compares Pebble's
nonsecret order counter to its previous value, reporting `unchanged`,
`increased`, or `unavailable`. No diagnostic makes a previously failing
no-op successful, and none reports Certbot stdout/stderr, actual SAN values,
private paths, account material or complete logs. An unknown error remains
`noop-producer=unclassified`. These receipts describe the last attempted
operation and never turn an otherwise failing no-op into acceptance.

The local E2E failure reporter also recognizes literal, host-owned lifecycle
checkpoints covering first issuance, independent first readback, each of the
three producer no-ops, the second ACME order, renewed archive readback, and
the final post-renewal no-op. On failure it reports only the last recognized
checkpoint as `bounded local lifecycle stage=...`; if none is observed,
the fixed category is `not-reported`. These labels diagnose where the
harness last made progress. They do **not** establish that a stage succeeded,
replace a receipt, disclose untrusted provider or runner output, or relax
any ACME/S3/no-egress/negative/cleanup acceptance criterion. The previously
allowlisted bootstrap rejection reasons remain separately reported.

If the Test workflow or static linters pass but this dedicated protocol
gate fails, milestone #16 does **not** have positive protocol execution
acceptance. If this workflow's own steps have not run successfully on a
qualified GitHub-hosted Docker engine, do not represent its committed
source as evidence of a passing full E2E test.
