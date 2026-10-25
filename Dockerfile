# OCI producer only. See ADR-038 and ci/prepare-oci-context.bash.
# Debian 13.7 slim, linux/amd64 manifest published 2026-10-20.
# https://github.com/docker-library/repo-info/blob/master/repos/debian/remote/13-slim.md
FROM --platform=linux/amd64 debian:13.7-slim@sha256:4876fdea29cac1a33a3195f1eb1952feb1fca7dd6dd00be3e2f1879cf20d34d2

ARG SOURCE_COMMIT
ARG RELEASE_VERSION
ARG PRODUCER_SHA256

# Debian and Debian-security archives fixed to the same dated snapshot.
COPY oci/debian.sources /etc/apt/sources.list.d/debian.sources
RUN set -eu; \
    test "$(dpkg --print-architecture)" = amd64; \
    rm -f /etc/apt/sources.list; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
      bash awscli certbot python3-certbot-dns-route53 \
      gnupg ca-certificates openssl \
      coreutils findutils tar gzip gawk sed grep; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Verify the real dependencies, including authenticated OCB operation.
# The fixed probe string is public test data, NEVER a production key.
RUN set -euo pipefail; \
    [[ "$(dpkg --print-architecture)" == amd64 ]]; \
    bash --version | head -n 1 | grep -Eq 'version (4\.[3-9]|[5-9]\.|[1-9][0-9])'; \
    aws --version 2>&1 | grep -Eq '^aws-cli/2\.'; \
    certbot --version >/dev/null; \
    certbot plugins --text 2>&1 | grep -Fq 'dns-route53'; \
    openssl version >/dev/null; \
    for tool in tar gzip stat mktemp realpath find od tail awk sed grep sha256sum cmp; do \
      command -v "$tool" >/dev/null || exit 69; \
    done; \
    version="$(gpg --version | head -n 1)"; \
    [[ "$version" =~ gpg\ \(GnuPG\)\ ([0-9]+\.[0-9]+\.[0-9]+) ]]; \
    dpkg --compare-versions "${BASH_REMATCH[1]}" ge 2.4.7; \
    probe="$(mktemp -d)"; \
    trap 'rm -rf -- "$probe"' EXIT; \
    mkdir -m 0700 "$probe/gnupg"; \
    printf '%s\n' 'public-OCB-capability-test' > "$probe/plain"; \
    gpg --no-options --homedir "$probe/gnupg" --batch --yes --no-tty \
      --pinentry-mode loopback --no-symkey-cache --passphrase-fd 3 \
      --symmetric --force-ocb --cipher-algo AES256 --s2k-mode 3 \
      --s2k-digest-algo SHA512 --s2k-count 16777216 \
      --output "$probe/cipher" "$probe/plain" \
      3<<<'public-OCB-test-only-not-a-secret' >/dev/null 2>&1; \
    packets="$(gpg --no-options --homedir "$probe/gnupg" --batch \
      --no-tty --list-packets "$probe/cipher" 2>/dev/null || :)"; \
    [[ "$packets" == *':symkey enc packet: version 5, cipher 9, aead 2, s2k 3, hash 10,'* ]]; \
    [[ "$packets" == *':aead encrypted packet: cipher=9 aead=2'* ]]; \
    [[ "$packets" == *'count 16777216'* ]]; \
    gpg --no-options --homedir "$probe/gnupg" --batch --yes --no-tty \
      --pinentry-mode loopback --no-symkey-cache --passphrase-fd 3 \
      --decrypt --output "$probe/restored" "$probe/cipher" \
      3<<<'public-OCB-test-only-not-a-secret' >/dev/null 2>&1; \
    cmp -s "$probe/plain" "$probe/restored"

# Prepared producer bytes were checked against a complete 8-file handoff.
# Re-verify the copied checksum, provenance and expected source/version.
COPY oci/producer/certbotbot.bash oci/producer/certbotbot.bash.sha256 oci/producer/provenance.txt /opt/certbotbot/
RUN set -euo pipefail; \
    [[ "${SOURCE_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]]; \
    [[ "${RELEASE_VERSION:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9.+_-]*$ ]]; \
    [[ "${PRODUCER_SHA256:-}" =~ ^[0-9a-f]{64}$ ]]; \
    cd /opt/certbotbot; \
    sha256sum -c certbotbot.bash.sha256; \
    actual="$(sha256sum certbotbot.bash | awk '{print $1}')"; \
    [[ "$actual" == "$PRODUCER_SHA256" ]]; \
    grep -Fqx -- "source_sha=$SOURCE_COMMIT" provenance.txt; \
    grep -Fqx -- "version=$RELEASE_VERSION" provenance.txt; \
    grep -Fqx -- "producer_sha256=$PRODUCER_SHA256" provenance.txt; \
    grep -Fqx -- "BASH_STARTER_VERSION=$RELEASE_VERSION" certbotbot.bash; \
    grep -Fqx -- "BASH_STARTER_BUILD_COMMIT=${SOURCE_COMMIT:0:12}" certbotbot.bash; \
    bash -n certbotbot.bash; \
    install -m 0755 certbotbot.bash /usr/local/bin/certbotbot.bash; \
    install -d -m 0755 /usr/local/share/certbotbot; \
    install -m 0644 certbotbot.bash.sha256 provenance.txt /usr/local/share/certbotbot/; \
    rm -rf /opt/certbotbot

# Static UID/GID avoids introducing a runtime account manager.
# The operator mounts a mode-0700 owned tmpfs here under --read-only.
RUN set -euo pipefail; \
    ! grep -Eq '(^certbotbot:|:65532:)' /etc/passwd; \
    ! grep -Eq '(^certbotbot:|:65532:)' /etc/group; \
    printf '%s\n' 'certbotbot:x:65532:' >> /etc/group; \
    printf '%s\n' 'certbotbot:x:65532:65532:certbotbot OCI producer:/run/certbotbot:/usr/sbin/nologin' >> /etc/passwd; \
    install -d -m 0700 -o 65532 -g 65532 /run/certbotbot

LABEL org.opencontainers.image.title="certbotbot" \
      org.opencontainers.image.description="One-shot Certbot Route53 and S3 producer" \
      org.opencontainers.image.source="https://github.com/wesley-dean/certbotbot" \
      org.opencontainers.image.revision="${SOURCE_COMMIT}" \
      org.opencontainers.image.version="${RELEASE_VERSION}" \
      org.opencontainers.image.base.name="debian:13.7-slim" \
      org.opencontainers.image.base.digest="sha256:4876fdea29cac1a33a3195f1eb1952feb1fca7dd6dd00be3e2f1879cf20d34d2" \
      org.opencontainers.image.vendor="Wesley Dean" \
      io.certbotbot.producer.sha256="${PRODUCER_SHA256}" \
      io.certbotbot.apt.snapshot="20261020T213255Z"

ENV HOME=/run/certbotbot \
    TMPDIR=/run/certbotbot \
    XDG_CACHE_HOME=/run/certbotbot/.cache \
    XDG_CONFIG_HOME=/run/certbotbot/.config

USER 65532:65532
WORKDIR /run/certbotbot
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/certbotbot.bash"]
# Safe default: display help rather than contacting AWS or renewing.
CMD ["--help"]
