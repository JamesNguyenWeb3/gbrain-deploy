# syntax=docker/dockerfile:1.7
# ==============================================================================
# GBrain Production Dockerfile (Coolify / Linux x86_64 VM)
#
# Uses the official pre-compiled `gbrain-linux-x64` release binary published by
# `.github/workflows/release.yml` on GitHub Releases!
#
# What `gbrain-linux-x64` already embeds inside a single executable:
#   - Bun runtime (no Bun/Node or node_modules required in production)
#   - Freshly built `/admin` React SPA (`src/admin-embedded.ts`)
#   - All SQL migrations, seeds, and native writer locks
#
# Build time on Coolify: ~10-15 seconds (no npm/bun install or Vite build).
# Pin `GBRAIN_VERSION=latest` (tracks `releases/latest`) or a specific tag
# like `GBRAIN_VERSION=v0.60.613.0`.
# ==============================================================================

FROM debian:bookworm-slim

ARG GBRAIN_REPO=garrytan/gbrain
ARG GBRAIN_VERSION=latest

# Install runtime utilities required by GBrain:
# - git & openssh-client: managed brain checkout & `gbrain git commit-push`
# - postgresql-client: `pg_isready`, `psql`, `pg_dump` for entrypoint & backups
# - procps: `ps` required by `gbrain serve` parent-liveness watchdog (#591)
# - ca-certificates, curl, jq, tini: TLS, healthchecks, JSON parsing, PID 1 init
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    openssh-client \
    postgresql-client \
    procps \
    tini \
    tzdata \
  && rm -rf /var/lib/apt/lists/*

# Create unprivileged gbrain user & persistent state directories
# GBRAIN_HOME=/srv/gbrain -> state lives in /srv/gbrain/.gbrain
RUN groupadd --system --gid 10001 gbrain && \
    useradd --system --uid 10001 --gid gbrain --home-dir /srv/gbrain --create-home --shell /bin/bash gbrain && \
    mkdir -p /srv/gbrain/.gbrain /srv/gbrain/brain /srv/gbrain/backups && \
    chown -R gbrain:gbrain /srv/gbrain

# Download the official pre-compiled `gbrain-linux-x64` binary from GitHub Releases
# and smoke-test `--version` before finishing the layer.
RUN set -euo pipefail; \
    arch="$(uname -m)"; \
    if [ "$arch" != "x86_64" ]; then \
      echo "ERROR: Official prebuilt Linux binary (gbrain-linux-x64) requires x86_64 (detected: $arch)." >&2; \
      exit 1; \
    fi; \
    if [ "${GBRAIN_VERSION}" = "latest" ]; then \
      download_url="https://github.com/${GBRAIN_REPO}/releases/latest/download/gbrain-linux-x64"; \
    else \
      tag="${GBRAIN_VERSION#v}"; \
      download_url="https://github.com/${GBRAIN_REPO}/releases/download/v${tag}/gbrain-linux-x64"; \
    fi; \
    echo "Downloading ${download_url} ..."; \
    curl -fL --retry 3 --retry-delay 2 -o /usr/local/bin/gbrain "${download_url}"; \
    chmod 0755 /usr/local/bin/gbrain; \
    /usr/local/bin/gbrain --version

# Install operational scripts from ./scripts/ inside this folder
COPY --chmod=755 scripts/entrypoint.sh /usr/local/bin/gbrain-entrypoint
COPY --chmod=755 scripts/gbrain-run.sh /usr/local/bin/gbrain-run
COPY --chmod=755 scripts/configure-openrouter-jev.sh /usr/local/bin/gbrain-configure-openrouter
COPY --chmod=755 scripts/backup.sh /usr/local/bin/gbrain-backup
COPY --chmod=755 scripts/restore.sh /usr/local/bin/gbrain-restore

ENV GBRAIN_HOME=/srv/gbrain \
    GBRAIN_REPO_PATH=/srv/gbrain/brain \
    PORT=3131 \
    NODE_ENV=production

WORKDIR /srv/gbrain
USER gbrain

EXPOSE 3131

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/gbrain-entrypoint"]
CMD ["serve"]
