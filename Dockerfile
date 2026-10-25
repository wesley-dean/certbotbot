# OCI producer only. ADR-038 as partially superseded by Alpine ADR-039.
# The published Alpine 3.24.3 linux/amd64 manifest is immutable:
# https://github.com/docker-library/repo-info/blob/master/repos/alpine/remote/3.24.3.md
FROM alpine:3.24.3@sha256:c26612752c78b18faacd63c7d50f4592c2e7b0f25e0e20e82bd74e465c57ab0d

ARG SOURCE_COMMIT
ARG RELEASE_VERSION
ARG PRODUCER_SHA256
ARG HANDOFF_MANIFEST_SHA256
ARG BUILD_KIND

# Only the supported Alpine v3.24 repositories, never edge/testing.
# APK verifies the repository indexes and signed package records.
COPY oci/alpine-repositories /etc/apk/repositories

# Fuzzy package constraints deliberately permit compatible v3.24 patches.
# Installed transitive versions are recorded in packages.lock below.
# hadolint ignore=DL3018
RUN set -eu; \
    test "$(apk --print-arch)" = x86_64; \
    apk add --no-cache \
      bash 'aws-cli=~2' 'certbot=~5' 'certbot-dns-route53=~5' \
      'gnupg=~2.4' ca-certificates openssl \
      coreutils findutils tar gzip gawk sed grep

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Record what the package solver *actually installed*, including transitive
# versions. This is provenance, not a promise of reproducible image bytes.
RUN set -euo pipefail; \
    install -d -m 0755 /usr/local/share/certbotbot; \
    apk info -vv | LC_ALL=C sort \
      > /usr/local/share/certbotbot/packages.lock; \
    test -s /usr/local/share/certbotbot/packages.lock; \
    grep -Eq '^aws-cli-2\.' /usr/local/share/certbotbot/packages.lock; \
    grep -Eq '^certbot-5\.' /usr/local/share/certbotbot/packages.lock; \
    grep -Eq '^certbot-dns-route53-5\.' /usr/local/share/certbotbot/packages.lock; \
    grep -Eq '^gnupg-2\.4\.' /usr/local/share/certbotbot/packages.lock

# These are real functional compatibility checks, not merely package names.
# The GnuPG probe string is fixed PUBLIC test data, not an operator secret.
RUN set -euo pipefail; \
    [[ "$(apk --print-arch)" == x86_64 ]]; \
    [[ "$(cat /etc/alpine-release)" == 3.24.* ]]; \
    bash --version | head -n 1 | grep -Eq 'version (4\.[3-9]|[5-9]\.|[1-9][0-9])'; \
    aws --version 2>&1 | grep -Eq '^aws-cli/2\.'; \
    certbot --version >/dev/null; \
    certbot plugins --text 2>&1 | grep -Fq 'dns-route53'; \
    openssl version >/dev/null; \
    for tool in tar gzip stat mktemp realpath find od tail awk sed grep sha256sum cmp; do \
      command -v "$tool" >/dev/null || exit 69; \
    done; \
    tar --version | head -n 1 | grep -Fq 'GNU tar'; \
    find --version | head -n 1 | grep -Fq 'GNU findutils'; \
    awk --version | head -n 1 | grep -Fq 'GNU Awk'; \
    version="$(gpg --version | head -n 1)"; \
    [[ "$version" =~ gpg\ \(GnuPG\)\ ([0-9]+\.[0-9]+\.[0-9]+) ]]; \
    major="${BASH_REMATCH[1]%%.*}"; \
    rest="${BASH_REMATCH[1]#*.}"; \
    minor="${rest%%.*}"; \
    patch="${rest##*.}"; \
    (( major > 2 || (major == 2 && \
      (minor > 4 || (minor == 4 && patch >= 7))) )); \
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

# Only the independently prepared/verified ordinary producer is accepted.
COPY oci/producer/certbotbot.bash oci/producer/certbotbot.bash.sha256 oci/producer/provenance.txt /opt/certbotbot/
WORKDIR /opt/certbotbot
RUN set -euo pipefail; \
    [[ "${SOURCE_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]]; \
    [[ "${RELEASE_VERSION:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9.+_-]*$ ]]; \
    [[ "${PRODUCER_SHA256:-}" =~ ^[0-9a-f]{64}$ ]]; \
    [[ "${HANDOFF_MANIFEST_SHA256:-}" =~ ^[0-9a-f]{64}$ ]]; \
    [[ "$BUILD_KIND" == local || "$BUILD_KIND" == release ]]; \
    sha256sum -c certbotbot.bash.sha256; \
    actual="$(sha256sum certbotbot.bash | awk '{print $1}')"; \
    [[ "$actual" == "$PRODUCER_SHA256" ]]; \
    grep -Fqx -- "source_sha=$SOURCE_COMMIT" provenance.txt; \
    grep -Fqx -- "version=$RELEASE_VERSION" provenance.txt; \
    grep -Fqx -- "producer_sha256=$PRODUCER_SHA256" provenance.txt; \
    grep -Fqx -- "handoff_manifest_sha256=$HANDOFF_MANIFEST_SHA256" provenance.txt; \
    grep -Fqx -- "build_kind=$BUILD_KIND" provenance.txt; \
    grep -Fqx -- "BASH_STARTER_VERSION=$RELEASE_VERSION" certbotbot.bash; \
    grep -Fqx -- "BASH_STARTER_BUILD_COMMIT=${SOURCE_COMMIT:0:12}" certbotbot.bash; \
    bash -n certbotbot.bash; \
    install -m 0755 certbotbot.bash /usr/local/bin/certbotbot.bash; \
    install -d -m 0755 /usr/local/share/certbotbot; \
    install -m 0644 certbotbot.bash.sha256 provenance.txt /usr/local/share/certbotbot/; \
    rm -rf /opt/certbotbot

WORKDIR /

# Static unprivileged user and private runtime directory.
RUN set -euo pipefail; \
    if grep -Eq '(^certbotbot:|:65532:)' /etc/passwd; then exit 1; fi; \
    if grep -Eq '(^certbotbot:|:65532:)' /etc/group; then exit 1; fi; \
    addgroup -S -g 65532 certbotbot; \
    adduser -S -D -H -u 65532 -G certbotbot -h /run/certbotbot certbotbot; \
    install -d -m 0700 -o 65532 -g 65532 /run/certbotbot

LABEL org.opencontainers.image.title="certbotbot" \
      org.opencontainers.image.description="One-shot Certbot Route53 and S3 producer" \
      org.opencontainers.image.source="https://github.com/wesley-dean/certbotbot" \
      org.opencontainers.image.revision="${SOURCE_COMMIT}" \
      org.opencontainers.image.version="${RELEASE_VERSION}" \
      org.opencontainers.image.base.name="alpine:3.24.3" \
      org.opencontainers.image.base.digest="sha256:c26612752c78b18faacd63c7d50f4592c2e7b0f25e0e20e82bd74e465c57ab0d" \
      org.opencontainers.image.vendor="Wesley Dean" \
      io.certbotbot.producer.sha256="${PRODUCER_SHA256}" \
      io.certbotbot.handoff.manifest.sha256="${HANDOFF_MANIFEST_SHA256}" \
      io.certbotbot.build.kind="${BUILD_KIND}" \
      io.certbotbot.apk.branch="v3.24"

ENV HOME=/run/certbotbot \
    TMPDIR=/run/certbotbot \
    XDG_CACHE_HOME=/run/certbotbot/.cache \
    XDG_CONFIG_HOME=/run/certbotbot/.config

USER 65532:65532
WORKDIR /run/certbotbot
STOPSIGNAL SIGTERM
# Finite one-shot CLI, not a long-lived service.
HEALTHCHECK NONE
ENTRYPOINT ["/usr/local/bin/certbotbot.bash"]
CMD ["--help"]
