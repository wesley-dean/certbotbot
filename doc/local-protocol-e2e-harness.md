# Local Protocol E2E Service Harness (Milestone 16)

**Scope:** approved task #242, governed by [ADR-046](adr/ADR-046-isolated-pebble-seaweedfs-protocol-e2e.md).  This document describes a **service-only** container topology; it is neither a complete ACME/DNS/S3 test nor evidence that it has run.

## Prerequisites and security boundary

The initial implementation targets a **native Linux Docker Engine with Docker Compose v2**, Bash 4.3+, curl, jq, and access to the upstream registries **only during explicit image provisioning**.  Docker's default local context must be selected, and no `AWS_*` or `GPG_SYMMETRIC_KEY` environment variables may be exported when provisioning or starting.  The script rejects a configured remote Docker host/context.  Podman, Docker Desktop, rootless engine, non-amd64 support, and arbitrary custom subnets have **not** been verified.  Do not infer compatibility from Compose syntax.

The Compose project is named `certbotbot-local-e2e`.  A Docker `internal: true` bridge on `172.31.248.0/24` holds three pinned upstream containers:

| Service | Pinned upstream image | Address | Role |
| --- | --- | --- | --- |
| Pebble | `ghcr.io/letsencrypt/pebble:sha-b1e1ca4@sha256:5080492187bea12909c053d7a2b90a9e95104ef1c82381828e7823db71ce7e54` | `172.31.248.2` | ACME directory on 14000, management on 15000 |
| Pebble challenge server | `ghcr.io/letsencrypt/pebble-challtestsrv:sha-b1e1ca4@sha256:1994a326ec60e0de5e8051aa192269c1aaeff0969a4b703d11fa51370f3dc1a8` | `172.31.248.3` | Internal DNS on 8053, management on 8055 |
| SeaweedFS | `docker.io/chrislusf/seaweedfs:4.01@sha256:d91cdf769018b143f1c944085b36d29893d9af199e656b2537367c35744fc221` | `172.31.248.4` | S3-compatible API on 8333, ephemeral local data |

Each reference includes an immutable manifest SHA-256 and a readable release/revision identity. The Pebble linux/amd64 digests were obtained from the corresponding [upstream Pebble](https://github.com/letsencrypt/pebble/pkgs/container/pebble/810013152?tag=2.10.1) and [upstream challenge server](https://github.com/letsencrypt/pebble/pkgs/container/pebble-challtestsrv) GitHub package listings (v2.10.1, revision `b1e1ca4`).  The SeaweedFS 4.01 `RepoDigests` reference was reported by [a public image metadata inventory](https://docker.aityp.com/image/docker.io/chrislusf/seaweedfs%3A4.01) and **has not been independently pulled, authenticated or matched against the official Docker Hub tag in this environment**. Image inventory data is not a security audit. All three image references must pass the runtime pull/inspection gate before a harness operation can be qualified as working; SeaweedFS 4.01's age/security posture also warrants explicit review before its use in trusted CI.

There are no `ports` mappings, production network destinations, host Certbot directories, host AWS credentials, or privileged containers.  SeaweedFS uses an in-memory Docker tmpfs at `/data`. The only mounted file is a repository-owned, read-only `s3.json` containing visibly **synthetic, nonfunctional** access and secret keys. Never substitute actual AWS or S3 credentials into that fixture. The challenge server management endpoint is unauthenticated by upstream design and must remain internal.

The project reserves a fixed bridge subnet to give Pebble a deterministic, private DNS server (`172.31.248.3:8053`). If the subnet overlaps any host/VPN/Docker network, fail and resolve that network conflict through a separately reviewed narrow change. Do not modify host DNS, publish bridge ports, allow a public route, or silently select a different network.

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

On startup, the script validates Docker Compose's resolved topology, verifies the pinned images exist locally, starts only the three upstream services, checks the *actual* network is an internal bridge and no host port is published, and probes the ACME directory, challenge management request history, and S3 HTTP endpoint using bounded timeouts. If any check fails, startup fails and invokes project-scoped teardown. `down` deletes the project's containers, network, and disposable volumes; it never removes cached upstream images. No local server compilation, host server binary installation, or upstream-image build is performed.

**Important:** The readiness probes run from the **Linux Docker host** to bridge addresses; they do not expose management ports or configure the production certificate tool. The Pebble *readiness probe only* uses `curl -k` because upstream Pebble's local test certificate is self-signed. **Actual Certbot/producer TLS validation must remain enabled.** A listening endpoint does not prove CA identity continuity, the DNS-01 provider bridge, SeaweedFS conditional writes or true certificate renewal. Those are explicit acceptance gates for tasks #241 and #243-#248.

## Future integration boundaries

Task #241 must establish an approved test-only CA/S3 endpoint mediation path without changing the producer's public `production|staging` authority model. Task #243 provides bounded Route53 API translation into Pebble's challenge-server TXT management. Task #244 creates a synthetic bucket and uses the real built producer to register and issue. Subsequent tasks verify fresh-runner restore, no-op, second real ACME renewal order, negative isolation and CI. Do **not** mix those capabilities into this harness PR or substitute mocked protocol responses for acceptance evidence.

Do not point ordinary `certbotbot` at this network without the approved mediation layer. Neither a valid image digest nor an HTTP readiness result guarantees interoperability with the installed Certbot, Route53 plugin, AWS CLI or SeaweedFS conditional S3 operations. Milestone #4's separately authorized live Let's Encrypt staging/AWS workflow remains untouched.

## Limits and evidence still required

This development environment has no Docker or Podman engine and cannot reach the container registries. The author can perform syntax and static policy checks but **cannot claim a successful `fetch`, `up`, live readiness, S3 conditional compatibility, Docker/Podman parity, or offline egress probe** from here. Actual engine-backed evidence should record the engine version, each pulled manifest digest, all service states, the network's `Internal=true` property, host-port map absence, HTTP readiness, cleanup after failure and non-interference with ordinary CI. Unverified items are explicit outstanding validation, not assumed passes.

An internal Docker network limits container routing, but the host and privileged engine operator remain outside its security boundary; complete egress-negative tests are a later milestone requirement. These fixtures are never to be promoted to real environment credentials, and Pebble-issued accounts are **not** Let's Encrypt staging accounts.
