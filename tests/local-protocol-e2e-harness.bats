#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "$BATS_TEST_DIRNAME/.." && pwd -P)"
  HARNESS="$REPO_ROOT/tests/e2e-local/run.bash"
  TOPOLOGY="$REPO_ROOT/tests/e2e-local/compose.yml"
  S3_CREDS="$REPO_ROOT/tests/e2e-local/s3.json"
  PROVIDER="$REPO_ROOT/tests/e2e-local/provider-env.bash"
  GATEWAY="$REPO_ROOT/tests/e2e-local/gateway.Caddyfile"
  PEBBLE_CA="$REPO_ROOT/tests/e2e-local/pebble-upstream.pem"
}

@test "local harness Bash syntax is valid without Docker" {
  run bash -n "$HARNESS"
  [ "$status" -eq 0 ]
}

@test "invalid local harness invocation fails before invoking Docker" {
  run bash "$HARNESS" no-such-mode
  [ "$status" -eq 64 ]
  [[ "$output" == *'usage: run.bash fetch|up|status|down'* ]]

  run bash "$HARNESS"
  [ "$status" -eq 64 ]
  [[ "$output" == *'usage: run.bash fetch|up|status|down'* ]]

  run bash "$HARNESS" up unexpected-extra-argument
  [ "$status" -eq 64 ]
  [[ "$output" == *'usage: run.bash fetch|up|status|down'* ]]
}

@test "all upstream images are pinned to full immutable digests" {
  run grep -Ec '^[[:space:]]+image: [^[:space:]]+@sha256:[0-9a-f]{64}$' "$TOPOLOGY"
  [ "$status" -eq 0 ]
  [ "$output" = 4 ]
  run grep -Ec '^[[:space:]]+platform: linux/amd64$' "$TOPOLOGY"
  [ "$status" -eq 0 ]
  [ "$output" = 4 ]
}

@test "no published ports, host networking, Docker socket or privileged services" {
  run grep -En '^[[:space:]]*(ports:|network_mode:|privileged:|build:|network_mode: host)' "$TOPOLOGY"
  [ "$status" -ne 0 ]
  run grep -En '/var/run/docker.sock|/etc/letsencrypt|/root/.aws' "$TOPOLOGY"
  [ "$status" -ne 0 ]
  run grep -E '^[[:space:]]+internal: true$' "$TOPOLOGY"
  [ "$status" -eq 0 ]
}

@test "test-only SeaweedFS credentials are literal and not host secrets" {
  run jq -e '(.identities | length) == 1 and (.identities[0].credentials | length) == 1' "$S3_CREDS"
  [ "$status" -eq 0 ]
  run grep -F 'CBOTBOT_LOCAL_TEST_ACCESS_ONLY' "$S3_CREDS"
  [ "$status" -eq 0 ]
  run grep -F 'CBOTBOT_LOCAL_TEST_SECRET_NOT_A_CLOUD_KEY' "$S3_CREDS"
  [ "$status" -eq 0 ]
}

@test "harness provides project-scoped teardown and cached-only startup" {
  run grep -F 'compose down --volumes --remove-orphans --timeout 10' "$HARNESS"
  [ "$status" -eq 0 ]
  run grep -F 'compose up --no-build --pull never --detach' "$HARNESS"
  [ "$status" -eq 0 ]
  run grep -F 'docker network inspect' "$HARNESS"
  [ "$status" -eq 0 ]
}

@test "test-only ACME gateway has bounded upstream TLS trust and canonical Host" {
  run grep -F 'acme-staging-v02.api.letsencrypt.org {' "$GATEWAY"
  [ "$status" -eq 0 ]
  run grep -F 'rewrite @directory /dir' "$GATEWAY"
  [ "$status" -eq 0 ]
  run grep -F 'header_up Host acme-staging-v02.api.letsencrypt.org' "$GATEWAY"
  [ "$status" -eq 0 ]
  run grep -F 'tls_trust_pool file /etc/caddy/pebble-upstream.pem' "$GATEWAY"
  [ "$status" -eq 0 ]
  run grep -E 'tls_insecure_skip_verify|https?://acme-v02.api.letsencrypt.org' "$GATEWAY"
  [ "$status" -ne 0 ]
  run openssl x509 -in "$PEBBLE_CA" -noout -subject
  [ "$status" -eq 0 ]
}

@test "provider gate is valid Bash and rejects missing or foreign selectors" {
  run bash -n "$PROVIDER"
  [ "$status" -eq 0 ]
  run bash "$PROVIDER" -- /bin/sh --acme-environment production
  [ "$status" -eq 64 ]
  run bash "$PROVIDER" -- /bin/sh --acme-environment arbitrary
  [ "$status" -eq 64 ]
  run bash "$PROVIDER" -- /bin/sh --acme-environment staging --acme-environment staging
  [ "$status" -eq 64 ]
  run bash "$PROVIDER" -- /bin/sh --acme-environment staging --server https://example.com/acme
  [ "$status" -eq 64 ]
  run bash "$PROVIDER" -- /bin/sh
  [ "$status" -eq 64 ]

  # Valid staging cannot bypass the artifact check; a missing producer
  # is still rejected with data/status 65 before network verification.
  run bash "$PROVIDER" -- "$BATS_TEST_TMPDIR/nonexistent-producer" --acme-environment staging
  [ "$status" -eq 65 ]
  [[ "$output" == *'invalid public artifact'* ]]
}

@test "provider gate never treats host environment as a runnable E2E network" {
  run bash "$PROVIDER" --check extra
  [ "$status" -eq 64 ]
  run bash "$PROVIDER" --check
  [ "$status" -ne 0 ]
  [[ "$output" == *'local-provider:'* ]]
}

@test "provider gate runs child through empty environment with only local AWS endpoints" {
  run grep -F 'env -i PATH=' "$PROVIDER"
  [ "$status" -eq 0 ]
  run grep -F 'AWS_ENDPOINT_URL_S3="http://$S3_IP:8333"' "$PROVIDER"
  [ "$status" -eq 0 ]
  run grep -F 'AWS_ENDPOINT_URL_ROUTE53=http://127.0.0.1:9' "$PROVIDER"
  [ "$status" -eq 0 ]
  run grep -F 'AWS_EC2_METADATA_DISABLED=true' "$PROVIDER"
  [ "$status" -eq 0 ]
  run grep -F 'REQUESTS_CA_BUNDLE="$TRUST_FILE"' "$PROVIDER"
  [ "$status" -eq 0 ]
}
