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
  RUNNER_IGNORE="$REPO_ROOT/tests/e2e-local/runner.Dockerfile.dockerignore"
  PEBBLE_CONFIG="$REPO_ROOT/tests/e2e-local/pebble-config.json"
  CERTBOT_RENEW_ADAPTER="$REPO_ROOT/tests/e2e-local/certbot-force-renewal.bash"
  S3_FAULT="$REPO_ROOT/tests/e2e-local/aws-put-reject.bash"
  NEGATIVE_SCENARIOS="$REPO_ROOT/tests/e2e-local/negative-scenarios.bash"
  CI_LOCAL_RUNNER="$REPO_ROOT/tests/e2e-local/ci-local-e2e.bash"
  LOCAL_E2E_WORKFLOW="$REPO_ROOT/.github/workflows/local-protocol-e2e.yml"
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

@test "local Caddy ACME gateway invokes the binary and requires canonical private command shape" {
  run grep -F 'command: ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]' "$TOPOLOGY"
  [ "$status" -eq 0 ]
  run grep -F '.services["acme-gateway"].command == ["caddy","run","--config","/etc/caddy/Caddyfile","--adapter","caddyfile"]' "$HARNESS"
  [ "$status" -eq 0 ]
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
  run grep -F 's3_endpoint="http://$S3_IP:8333"' "$PROVIDER"
  [ "$status" -eq 0 ]
  run grep -F 'AWS_ENDPOINT_URL_S3="$s3_endpoint"' "$PROVIDER"
  [ "$status" -eq 0 ]
  run grep -F 'route53_endpoint="http://$ROUTE53_IP:8056"' "$PROVIDER"
  [ "$status" -eq 0 ]
  run grep -F 'AWS_ENDPOINT_URL_ROUTE_53="$route53_endpoint"' "$PROVIDER"
  [ "$status" -eq 0 ]
  run grep -F 'AWS_ENDPOINT_URL_ROUTE53=' "$PROVIDER"
  [ "$status" -ne 0 ]
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
    and (.pebble.domainBlocklist == ["blocked-domain.example","blocked.e2e.test"])
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

@test "test-only Certbot adapter is syntax valid and confined to runner image" {
  run bash -n "$CERTBOT_RENEW_ADAPTER"
  [ "$status" -eq 0 ]
  run grep -F 'COPY tests/e2e-local/certbot-force-renewal.bash /usr/local/bin/certbot' "$RUNNER_DOCKERFILE"
  [ "$status" -eq 0 ]
  run grep -F 'test -x /usr/bin/certbot' "$RUNNER_DOCKERFILE"
  [ "$status" -eq 0 ]
  run grep -F '"$E2E/certbot-force-renewal.bash"' "$FIRST_HOST"
  [ "$status" -eq 0 ]
  run grep -F 'exec "$REAL_CERTBOT" "$@" --force-renewal' "$CERTBOT_RENEW_ADAPTER"
  [ "$status" -eq 0 ]
}

@test "single-use real renewal adapter selects one account and private staging lineage" {
  run grep -F '(( $# == 15 ))' "$CERTBOT_RENEW_ADAPTER"
  [ "$status" -eq 0 ]
  run grep -F 'readonly SELECTED=test.e2e.test' "$CERTBOT_RENEW_ADAPTER"
  [ "$status" -eq 0 ]
  run grep -F 'readonly STAGING=https://acme-staging-v02.api.letsencrypt.org/directory' "$CERTBOT_RENEW_ADAPTER"
  [ "$status" -eq 0 ]
  run grep -F '[[ ! -e "$RECEIPT"' "$CERTBOT_RENEW_ADAPTER"
  [ "$status" -eq 0 ]
  run grep -F 'rm -f -- "$INTENT"' "$CERTBOT_RENEW_ADAPTER"
  [ "$status" -eq 0 ]
  run grep -F 'real-certbot-selected-renewal-forced' "$CERTBOT_RENEW_ADAPTER"
  [ "$status" -eq 0 ]
}

@test "renew mode rejects unsupported inputs before any provider access" {
  run bash "$FIRST_ISSUE" renew
  [ "$status" -eq 64 ]
  run bash "$FIRST_ISSUE" renew incorrect-digest
  [ "$status" -eq 64 ]
  run bash "$FIRST_ISSUE" renew "$(printf '%064d' 0)" unexpected
  [ "$status" -eq 64 ]
}

@test "genuine renewal requires changed object, DER, stable account and independent verification" {
  run grep -F '[[ "$new_account" == "$original_account" ]]' "$FIRST_ISSUE"
  [ "$status" -eq 0 ]
  run grep -F '[[ "$new_etag" != "$old_etag" ]]' "$FIRST_ISSUE"
  [ "$status" -eq 0 ]
  run grep -F '[[ "$newcert" =~ ^[0-9a-f]{64}$ && "$newcert" != "$oldcert" ]]' "$FIRST_ISSUE"
  [ "$status" -eq 0 ]
  run grep -F 'verify_no_force_persistence "$workspace/after.tar.gz"' "$FIRST_ISSUE"
  [ "$status" -eq 0 ]
  run grep -F 'run_phase "$image" "$cert_ca" renew "$digest"' "$FIRST_HOST"
  [ "$status" -eq 0 ]
  run grep -F '"$count_after" -eq $((count_before + 1))' "$FIRST_HOST"
  [ "$status" -eq 0 ]
  run grep -F 'run_phase "$image" "$cert_ca" verify "$renewed_digest"' "$FIRST_HOST"
  [ "$status" -eq 0 ]
  run grep -F 'run_phase "$image" "$cert_ca" noop ordinary "$renewed_digest"' "$FIRST_HOST"
  [ "$status" -eq 0 ]
}

@test "one-shot adapter argv validator accepts exact staged selected renewal and rejects drift" {
  local workspace="$BATS_TEST_TMPDIR/force-contract"
  mkdir -m 700 -- "$workspace"
  mkdir -m 700 -- "$workspace/config"
  run bash -c '
    source "$1"
    authorized_selected_renew renew --cert-name test.e2e.test \
      --account LOCALACCOUNT --config-dir "$2/config" \
      --work-dir "$2/work" --logs-dir "$2/logs" \
      --server https://acme-staging-v02.api.letsencrypt.org/directory \
      --non-interactive --no-directory-hooks
  ' -- "$CERTBOT_RENEW_ADAPTER" "$workspace"
  [ "$status" -eq 0 ]

  run bash -c '
    source "$1"
    authorized_selected_renew renew --cert-name wrong.e2e.test \
      --account LOCALACCOUNT --config-dir "$2/config" \
      --work-dir "$2/work" --logs-dir "$2/logs" \
      --server https://acme-staging-v02.api.letsencrypt.org/directory \
      --non-interactive --no-directory-hooks
  ' -- "$CERTBOT_RENEW_ADAPTER" "$workspace"
  [ "$status" -eq 65 ]

  run bash -c '
    source "$1"
    authorized_selected_renew renew --cert-name test.e2e.test \
      --account LOCALACCOUNT --config-dir "$2/config" \
      --work-dir "$2/work" --logs-dir "$2/logs" \
      --server https://acme-v02.api.letsencrypt.org/directory \
      --non-interactive --no-directory-hooks
  ' -- "$CERTBOT_RENEW_ADAPTER" "$workspace"
  [ "$status" -eq 65 ]
}

@test "negative fault helpers parse and no provider is run for invalid selectors" {
  run bash -n "$NEGATIVE_SCENARIOS"
  [ "$status" -eq 0 ]
  run bash -n "$S3_FAULT"
  [ "$status" -eq 0 ]
  run bash -n "$FIRST_ISSUE"
  [ "$status" -eq 0 ]
  run bash -n "$FIRST_HOST"
  [ "$status" -eq 0 ]

  run bash "$FIRST_ISSUE" fault unexpected "$(printf '%064d' 0)"
  [ "$status" -eq 64 ]
  run bash "$FIRST_ISSUE" fault route53-unavailable invalid-digest
  [ "$status" -eq 64 ]
  run bash "$FIRST_ISSUE" baseline unexpected
  [ "$status" -eq 64 ]
  run env LOCAL_E2E_FAULT_MODE=unapproved bash "$PROVIDER" -- /bin/sh --acme-environment staging
  [ "$status" -eq 64 ]
}

@test "negative provider endpoints are fixed, synthetic, and cannot take arbitrary URLs" {
  run grep -F "s3_endpoint='http://127.0.0.1:9'" "$PROVIDER"
  [ "$status" -eq 0 ]
  run grep -F "route53_endpoint='http://127.0.0.1:9'" "$PROVIDER"
  [ "$status" -eq 0 ]
  run grep -F 'LOCAL_E2E_FAULT_MODE="$fault"' "$PROVIDER"
  [ "$status" -eq 0 ]
  run grep -F 'AWS_EC2_METADATA_DISABLED=true' "$PROVIDER"
  [ "$status" -eq 0 ]
  run grep -F 'REQUESTS_CA_BUNDLE="$TRUST_FILE"' "$PROVIDER"
  [ "$status" -eq 0 ]
}

@test "test-only S3 fault wrapper denies PUT while forwarding all other operations" {
  run grep -F 'COPY tests/e2e-local/aws-put-reject.bash /usr/local/bin/aws' "$RUNNER_DOCKERFILE"
  [ "$status" -eq 0 ]
  run grep -F 'test -x /usr/bin/aws' "$RUNNER_DOCKERFILE"
  [ "$status" -eq 0 ]
  run grep -F 'exec "$AWS_REAL" "$@"' "$S3_FAULT"
  [ "$status" -eq 0 ]
  run grep -F '[[ "$bucket" == certbotbot-local-e2e && "$key" == latest.tar.gz ]]' "$S3_FAULT"
  [ "$status" -eq 0 ]
  run grep -F 'synthetic-s3-put-rejected' "$S3_FAULT"
  [ "$status" -eq 0 ]
  run grep -F 'negative_issue_foreign_name' "$NEGATIVE_SCENARIOS"
  [ "$status" -eq 0 ]
}

@test "failure scenarios preserve current S3 bytes, metadata and selected account" {
  run grep -F 'negative_corrupt_archive' "$NEGATIVE_SCENARIOS"
  [ "$status" -eq 0 ]
  run grep -F "corrupt_key='latest-corrupt.tar.gz'" "$NEGATIVE_SCENARIOS"
  [ "$status" -eq 0 ]
  run grep -F 'cmp -s "$workspace/before.meta" "$workspace/after.meta"' "$NEGATIVE_SCENARIOS"
  [ "$status" -eq 0 ]
  run grep -F '[[ "$actual" == "$expected" ]]' "$NEGATIVE_SCENARIOS"
  [ "$status" -eq 0 ]
  run grep -F 'verify_account "$workspace/after.tar.gz"' "$NEGATIVE_SCENARIOS"
  [ "$status" -eq 0 ]
  run grep -F 'verify_certificate "$workspace/after.tar.gz" "$workspace"' "$NEGATIVE_SCENARIOS"
  [ "$status" -eq 0 ]
  run grep -F 'published=true' "$NEGATIVE_SCENARIOS"
  [ "$status" -eq 0 ]
}

@test "negative orchestration restores Pebble and independently rechecks each failure" {
  run grep -F 'run-faults) run_faults "$image"' "$FIRST_HOST"
  [ "$status" -eq 0 ]
  run grep -F 'docker pause "$pebble_id"' "$FIRST_HOST"
  [ "$status" -eq 0 ]
  run grep -F 'docker unpause "$pebble_id"' "$FIRST_HOST"
  [ "$status" -eq 0 ]
  run grep -F 'run_phase "$image" "$cert_ca" baseline' "$FIRST_HOST"
  [ "$status" -eq 0 ]
  run grep -F 'remote_unchanged=true; provider_success=false' "$FIRST_HOST"
  [ "$status" -eq 0 ]
  run grep -F 'all-negative-scenarios=passed; dns-validation=bypassed' "$FIRST_HOST"
  [ "$status" -eq 0 ]
}

@test "real Pebble WFE rejects the owned blocked name at newOrder" {
  run grep -F '"domainBlocklist": ["blocked-domain.example", "blocked.e2e.test"]' "$PEBBLE_CONFIG"
  [ "$status" -eq 0 ]
  run grep -F 'acme-order-rejected)' "$NEGATIVE_SCENARIOS"
  [ "$status" -eq 0 ]
  run grep -F 'negative_issue_foreign_name "$scenario" blocked.e2e.test' "$NEGATIVE_SCENARIOS"
  [ "$status" -eq 0 ]
  run grep -F 'for scenario in ca-production s3-unavailable corrupt-archive acme-order-rejected' "$FIRST_HOST"
  [ "$status" -eq 0 ]
}

@test "dedicated local E2E CI runner validates syntax and rejects arguments without Docker" {
  run bash -n "$CI_LOCAL_RUNNER"
  [ "$status" -eq 0 ]
  run bash "$CI_LOCAL_RUNNER" unexpected
  [ "$status" -eq 64 ]
  [[ "$output" == *'usage: ci-local-e2e.bash (no arguments)'* ]]
}

@test "local protocol acceptance runs only on push or manual dispatch without credentials" {
  run grep -F 'name: Local protocol E2E (challenge validation bypassed)' "$LOCAL_E2E_WORKFLOW"
  [ "$status" -eq 0 ]
  run grep -E '^  (push|workflow_dispatch):$' "$LOCAL_E2E_WORKFLOW"
  [ "$status" -eq 0 ]
  [[ "$output" == *'push:'* && "$output" == *'workflow_dispatch:'* ]]
  run grep -E '^  pull_request:|^  pull_request_target:|^  schedule:' "$LOCAL_E2E_WORKFLOW"
  [ "$status" -ne 0 ]
  run grep -E 'secrets\.|id-token:[[:space:]]*write' "$LOCAL_E2E_WORKFLOW"
  [ "$status" -ne 0 ]
  run grep -F 'permissions:' "$LOCAL_E2E_WORKFLOW"
  [ "$status" -eq 0 ]
  run grep -F 'contents: read' "$LOCAL_E2E_WORKFLOW"
  [ "$status" -eq 0 ]
}

@test "local E2E CI has fixed bounded runtimes, concurrency and defensive cleanup" {
  for evidence in 'runs-on: ubuntu-24.04' 'timeout-minutes: 90' \
    'cancel-in-progress: true' 'if: always()' '--remove-orphans' '--volumes' \
    'persist-credentials: false'; do
    run grep -F -- "$evidence" "$LOCAL_E2E_WORKFLOW"
    [ "$status" -eq 0 ]
  done
  run grep -F 'bash tests/e2e-local/ci-local-e2e.bash' "$LOCAL_E2E_WORKFLOW"
  [ "$status" -eq 0 ]
}

@test "local E2E CI fetches before starting sealed project and executes all positive and negative gates" {
  for stage in prepare start_private_project probe_no_egress run_positive run_negative cleanup; do
    run grep -F "$stage" "$CI_LOCAL_RUNNER"
    [ "$status" -eq 0 ]
  done
  run grep -F 'make deps && make deps-check' "$CI_LOCAL_RUNNER"
  [ "$status" -eq 0 ]
  run grep -F 'make build VERSION=0.0.0-dev' "$CI_LOCAL_RUNNER"
  [ "$status" -eq 0 ]
  run grep -F 'bash "$HOST" build' "$CI_LOCAL_RUNNER"
  [ "$status" -eq 0 ]
  run grep -F 'bash "$STACK" fetch' "$CI_LOCAL_RUNNER"
  [ "$status" -eq 0 ]
  run grep -F 'bash "$STACK" up' "$CI_LOCAL_RUNNER"
  [ "$status" -eq 0 ]
  run grep -F 'bash "$HOST" run-faults' "$CI_LOCAL_RUNNER"
  [ "$status" -eq 0 ]
  run grep -F 'second_real_pebble_order=true;' "$CI_LOCAL_RUNNER"
  [ "$status" -eq 0 ]
  run grep -F 'all-negative-scenarios=passed; dns-validation=bypassed' "$CI_LOCAL_RUNNER"
  [ "$status" -eq 0 ]
}

@test "local E2E probes actual no-route and local HTTPS without contacting real providers" {
  run bash -n "$FIRST_ISSUE"
  [ "$status" -eq 0 ]
  run bash -n "$FIRST_HOST"
  [ "$status" -eq 0 ]
  run bash "$FIRST_ISSUE" isolation extra
  [ "$status" -eq 64 ]
  run grep -F 'bash "$PROVIDER" --check' "$FIRST_ISSUE"
  [ "$status" -eq 0 ]
  run grep -F '192.0.2.1 198.51.100.1 203.0.113.1' "$FIRST_ISSUE"
  [ "$status" -eq 0 ]
  run grep -F 'for peer in acme.invalid aws.invalid route53.invalid' "$FIRST_ISSUE"
  [ "$status" -eq 0 ]
  run grep -F 'docker network inspect "$NETWORK"' "$CI_LOCAL_RUNNER"
  [ "$status" -eq 0 ]
  run grep -F 'run_phase "$image" "$ca_file" isolation' "$FIRST_HOST"
  [ "$status" -eq 0 ]
}

@test "local E2E evidence stays bounded and its real-provider nonclaim is explicit" {
  run grep -F 'no_egress_probe=%s; challenge_validation=bypassed' "$CI_LOCAL_RUNNER"
  [ "$status" -eq 0 ]
  run grep -F 'aws_route53_dns01_live_ca=not_tested' "$CI_LOCAL_RUNNER"
  [ "$status" -eq 0 ]
  run grep -F 'WORK="$(mktemp -d' "$CI_LOCAL_RUNNER"
  [ "$status" -eq 0 ]
  run grep -F 'rm -rf -- "$WORK"' "$CI_LOCAL_RUNNER"
  [ "$status" -eq 0 ]
  run grep -F 'cleanup "$?"' "$CI_LOCAL_RUNNER"
  [ "$status" -eq 0 ]
}

@test "private local runner context is explicitly allowlisted without weakening production Docker ignore" {
  run grep -Fx '**' "$REPO_ROOT/.dockerignore"
  [ "$status" -eq 0 ]
  run grep -Fx '**' "$RUNNER_IGNORE"
  [ "$status" -eq 0 ]
  for name in \
    oci/alpine-repositories \
    dist/certbotbot.dev.bash dist/certbotbot.dev.bash.sha256 \
    dist/certbotbot.bash dist/certbotbot.bash.sha256 \
    dist/certbotbot.min.bash dist/certbotbot.min.bash.sha256 \
    tests/e2e-local/first-issue.bash tests/e2e-local/provider-env.bash \
    tests/e2e-local/negative-scenarios.bash \
    tests/e2e-local/certbot-force-renewal.bash \
    tests/e2e-local/aws-put-reject.bash; do
    run grep -Fx "!$name" "$RUNNER_IGNORE"
    [ "$status" -eq 0 ]
  done
  run grep -E '^!src/|^!lib/|^!vendor/|^!.*secret|^!.*\.env' "$RUNNER_IGNORE"
  [ "$status" -ne 0 ]
}

@test "private Caddy public root is read by the container user not Docker copy" {
  # The root is mode 0600 and owned by Caddy's unprivileged user. Docker's
  # archive copy API cannot read this tmpfs path on the hosted Docker engine.
  # docker exec runs cat as the container owner, exporting only root.crt.
  for file in "$HARNESS" "$FIRST_HOST"; do
    run grep -F 'docker cp' "$file"
    [ "$status" -ne 0 ]
    run grep -F 'docker exec "$cid" cat /data/caddy/pki/authorities/local/root.crt' "$file"
    [ "$status" -eq 0 ]
  done
  run grep -F 'cat /data/caddy/pki/authorities/local/root.crt >"$ca_file"' "$HARNESS"
  [ "$status" -eq 0 ]
  run grep -F 'cat /data/caddy/pki/authorities/local/root.crt >"$cert_ca"' "$FIRST_HOST"
  [ "$status" -eq 0 ]
  run grep -F 'openssl x509 -in "$ca_file"' "$FIRST_HOST"
  [ "$status" -eq 0 ]
}
