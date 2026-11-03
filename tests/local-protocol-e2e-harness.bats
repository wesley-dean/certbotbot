#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "$BATS_TEST_DIRNAME/.." && pwd -P)"
  HARNESS="$REPO_ROOT/tests/e2e-local/run.bash"
  TOPOLOGY="$REPO_ROOT/tests/e2e-local/compose.yml"
  S3_CREDS="$REPO_ROOT/tests/e2e-local/s3.json"
  PROVIDER="$REPO_ROOT/tests/e2e-local/provider-env.bash"
  GATEWAY="$REPO_ROOT/tests/e2e-local/gateway.Caddyfile"
  PEBBLE_CA="$REPO_ROOT/tests/e2e-local/pebble-upstream.pem"
  ROUTE53_STUB_TEST="$REPO_ROOT/tests/e2e-local/route53_bridge_test.py"
  FIRST_ISSUE="$REPO_ROOT/tests/e2e-local/first-issue.bash"
  FIRST_HOST="$REPO_ROOT/tests/e2e-local/first-issue-host.bash"
  RUNNER_DOCKERFILE="$REPO_ROOT/tests/e2e-local/runner.Dockerfile"
  PEBBLE_CONFIG="$REPO_ROOT/tests/e2e-local/pebble-config.json"
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
  run grep -F 'AWS_ENDPOINT_URL_ROUTE53="http://$ROUTE53_IP:8056"' "$PROVIDER"
  [ "$status" -eq 0 ]
  run grep -F 'AWS_EC2_METADATA_DISABLED=true' "$PROVIDER"
  [ "$status" -eq 0 ]
  run grep -F 'REQUESTS_CA_BUNDLE="$TRUST_FILE"' "$PROVIDER"
  [ "$status" -eq 0 ]
}

@test "local Route53 test double passes offline protocol contract checks" {
  run python3 -B "$ROUTE53_STUB_TEST"
  [ "$status" -eq 0 ]
}

@test "isolated Pebble bypasses DNS validation and mock has no real DNS client" {
  run grep -F 'PEBBLE_VA_ALWAYS_VALID: "1"' "$TOPOLOGY"
  [ "$status" -eq 0 ]
  run grep -F 'CHALL_IP=' "$HARNESS"
  [ "$status" -ne 0 ]
  run grep -F 'CHALLENGE_HOST' "$REPO_ROOT/tests/e2e-local/route53_bridge.py"
  [ "$status" -ne 0 ]
  run grep -F 'route53-bridge' "$TOPOLOGY"
  [ "$status" -eq 0 ]
}

@test "first issuance runner has valid Bash and rejects unknown scenario before providers" {
  run bash -n "$FIRST_ISSUE"
  [ "$status" -eq 0 ]
  run bash -n "$FIRST_HOST"
  [ "$status" -eq 0 ]

  run bash "$FIRST_ISSUE" unexpected-mode
  [ "$status" -eq 64 ]
  [[ "$output" == *'usage: first-issue.bash'* ]]

  run bash "$FIRST_HOST" unexpected-mode
  [ "$status" -eq 64 ]
  [[ "$output" == *'usage: first-issue-host.bash'* ]]
}

@test "first issuance uses real public producer and bounded real providers" {
  run grep -F 'provider ordinary register' "$FIRST_ISSUE"
  [ "$status" -eq 0 ]
  run grep -F 'if issuer' "$FIRST_ISSUE"
  [ "$status" -eq 0 ]
  run grep -F 'if ! issuer' "$FIRST_ISSUE"
  [ "$status" -eq 0 ]
  run grep -F 'fetch_archive "$workspace/verified.tar.gz"' "$FIRST_ISSUE"
  [ "$status" -eq 0 ]
  run grep -F 'openssl x509 -in "$workspace/leaf.pem" -outform DER' "$FIRST_ISSUE"
  [ "$status" -eq 0 ]
  run grep -F 'AWS_ENDPOINT_URL_S3=http://172.31.248.4:8333' "$FIRST_ISSUE"
  [ "$status" -eq 0 ]
}

@test "local executable runner installs real Certbot and verifies supplied artifact" {
  run grep -E '^FROM alpine:[^ ]+@sha256:[a-f0-9]{64}$' "$RUNNER_DOCKERFILE"
  [ "$status" -eq 0 ]
  run grep -F "'certbot-dns-route53=~5'" "$RUNNER_DOCKERFILE"
  [ "$status" -eq 0 ]
  run grep -F 'sha256sum -c "$flavor.sha256"' "$RUNNER_DOCKERFILE"
  [ "$status" -eq 0 ]
  run grep -F 'USER 65532:65532' "$RUNNER_DOCKERFILE"
  [ "$status" -eq 0 ]
}

@test "first issuance is restricted to a disposable internal runner context" {
  for feature in '--network "$NETWORK"' '--dns 127.0.0.1' '--read-only' '--cap-drop ALL' \
    '--security-opt no-new-privileges:true' '--mount "type=bind,source=$ca_file'; do
    run grep -F -- "$feature" "$FIRST_HOST"
    [ "$status" -eq 0 ]
  done
  run grep -F 'timeout --signal=TERM --kill-after=15s 420s' "$FIRST_HOST"
  [ "$status" -eq 0 ]
}

@test "Pebble has one deterministic non-due certificate profile" {
  run jq -e '
    (.pebble.profiles | keys == ["default"])
    and (.pebble.profiles.default.validityPeriod == 7776000)
  ' "$PEBBLE_CONFIG"
  [ "$status" -eq 0 ]
  run grep -F './pebble-config.json:/opt/local-e2e-pebble.json:ro' "$TOPOLOGY"
  [ "$status" -eq 0 ]
}

@test "all three public producer flavors are checksum-verified by the runner" {
  for name in certbotbot.dev.bash certbotbot.bash certbotbot.min.bash; do
    run grep -F "$name.sha256" "$RUNNER_DOCKERFILE"
    [ "$status" -eq 0 ]
  done
  run grep -F 'for flavor in certbotbot.dev.bash certbotbot.bash certbotbot.min.bash' "$RUNNER_DOCKERFILE"
  [ "$status" -eq 0 ]
}

@test "fresh-runner no-op rejects unsupported flavors and invalid digests" {
  run bash "$FIRST_ISSUE" noop stranger "$(printf '%064d' 0)"
  [ "$status" -eq 64 ]
  run bash "$FIRST_ISSUE" noop ordinary malformed-digest
  [ "$status" -eq 64 ]
  run bash "$FIRST_ISSUE" noop ordinary
  [ "$status" -eq 64 ]
}

@test "fresh-runner normal no-op enforces S3 and ACME unchanged evidence" {
  run grep -F 'published=false' "$FIRST_ISSUE"
  [ "$status" -eq 0 ]
  run grep -F 'cmp -s "$workspace/before.meta" "$workspace/after.meta"' "$FIRST_ISSUE"
  [ "$status" -eq 0 ]
  run grep -F 'fetch_archive "$workspace/after.tar.gz"' "$FIRST_ISSUE"
  [ "$status" -eq 0 ]
  run grep -F 'pebble_order_count' "$FIRST_HOST"
  [ "$status" -eq 0 ]
  run grep -F 'There are now ([0-9]+) orders in the db' "$FIRST_HOST"
  [ "$status" -eq 0 ]
  run grep -F '[[ "$count_after" == "$count_before" ]]' "$FIRST_HOST"
  [ "$status" -eq 0 ]
  run grep -F 'for flavor in development ordinary minified; do' "$FIRST_HOST"
  [ "$status" -eq 0 ]
}
