# Test-only executable runner. ADR-047 / milestone 16 task #244.
# Build and fetch dependencies before beginning the sealed Docker run.
# This never changes the public producer or published OCI image.
FROM alpine:3.24.3@sha256:c26612752c78b18faacd63c7d50f4592c2e7b0f25e0e20e82bd74e465c57ab0d

COPY oci/alpine-repositories /etc/apk/repositories

# hadolint ignore=DL3018
RUN set -eu; \
    test "$(apk --print-arch)" = x86_64; \
    apk add --no-cache \
      bash 'aws-cli=~2' 'certbot=~5' 'certbot-dns-route53=~5' \
      ca-certificates openssl curl jq coreutils findutils tar gzip gawk sed grep; \
    certbot --version >/dev/null; \
    certbot plugins --text 2>&1 | grep -F 'dns-route53' >/dev/null; \
    aws --version >/dev/null 2>&1; \
    mkdir -p /run/certbotbot-e2e /usr/local/share/certbotbot-e2e /usr/local/libexec/certbotbot-e2e; \
    addgroup -S -g 65532 local-e2e; \
    adduser -S -D -H -u 65532 -G local-e2e -h /tmp local-e2e; \
    printf '' > /usr/local/share/certbotbot-e2e/empty.env

# The exact public output of 'make build'; Docker builds fail if absent.
COPY dist/certbotbot.dev.bash dist/certbotbot.dev.bash.sha256 dist/certbotbot.bash dist/certbotbot.bash.sha256 dist/certbotbot.min.bash dist/certbotbot.min.bash.sha256 /usr/local/bin/
COPY tests/e2e-local/provider-env.bash tests/e2e-local/first-issue.bash /usr/local/libexec/certbotbot-e2e/
# The test-only argv adapter is never part of release image or public artifact.
COPY tests/e2e-local/certbot-force-renewal.bash /usr/local/bin/certbot

RUN set -eu; \
    cd /usr/local/bin; \
    for flavor in certbotbot.dev.bash certbotbot.bash certbotbot.min.bash; do \
      sha256sum -c "$flavor.sha256"; \
      bash -n "$flavor"; \
      chmod 0755 "$flavor"; \
      chmod 0644 "$flavor.sha256"; \
    done; \
    bash -n /usr/local/libexec/certbotbot-e2e/provider-env.bash; \
    bash -n /usr/local/libexec/certbotbot-e2e/first-issue.bash; \
    test -x /usr/bin/certbot; \
    bash -n /usr/local/bin/certbot; \
    chmod 0555 /usr/local/bin/certbot; \
    chmod 0555 /usr/local/libexec/certbotbot-e2e/*.bash

ENV HOME=/tmp TMPDIR=/tmp XDG_CACHE_HOME=/tmp/cache
USER 65532:65532
WORKDIR /tmp
ENTRYPOINT ["/bin/bash", "/usr/local/libexec/certbotbot-e2e/first-issue.bash"]
CMD ["--help"]
