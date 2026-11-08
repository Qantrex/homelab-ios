# Homelab Bridge: the reference server with its sources, as a small container image.
# Built and pushed by hand with scripts/build-bridge-image (ghcr.io/qantrex/homelab-bridge); CI only builds and tests
# it, it never pushes. Run it with server/compose.yaml (Tailscale sidecar): docs/SERVER-SETUP.md#docker.
#
# Build context: server/ (server/.dockerignore lets in only what is copied below).
#   docker build -t homelab-bridge server
#
# The server listens on 127.0.0.1:8791 inside the container and is never published as a port: `tailscale serve` in the
# sidecar, which shares this network namespace, is the only way in. Config: /config/config.json (mount it read-only).
# Keys: env variables (HOMELAB_TOKENS, and the ones the sources' *_env keys name), from an env file.

# Python 3.14 on Alpine 3.24, pinned by the multi-arch index digest (amd64 and arm64). To bump: pull the new tag,
# put its digest here and in features.toml (dependency bridge-base-image), and pick PyYAML wheels for that Python.
FROM python:3.14.10-alpine3.24@sha256:a18b20ad69e74df6cf6d2e1b1a260d7a1ecf5380fd83b310f83ba88c461cf894

# PyYAML only in the image (owner, 2026-11-07), for the Homepage import (M1.8). The server itself stays stdlib-only.
# Wheels only, each checked against its SHA-256 in requirements-image.txt.
COPY requirements-image.txt /tmp/requirements-image.txt
RUN pip install --no-cache-dir --disable-pip-version-check --no-compile --only-binary=:all: --require-hashes \
        -r /tmp/requirements-image.txt \
    && rm /tmp/requirements-image.txt \
    && addgroup -S -g 10001 bridge \
    && adduser -S -D -H -u 10001 -G bridge -h /var/lib/homelab-bridge -s /sbin/nologin bridge \
    && install -d -o bridge -g bridge -m 700 /var/lib/homelab-bridge

# Code owned by root, so the server can't change itself.
COPY reference_server.py /app/reference_server.py
COPY sources/ /app/sources/

# HOME is where the server keeps state (chat history in ~/.local/state/homelab-companion); a volume in compose.yaml.
# HOMELAB_BRIDGE_IMAGE: with a trusted Tailscale-User-Login the server refuses TS_USERSPACE=true and warns when the
# shared namespace has no tailscale0 (userspace mode would open 127.0.0.1:8791 to the whole tailnet; SERVER-SETUP.md#docker).
ENV HOME=/var/lib/homelab-bridge \
    HOMELAB_BRIDGE_IMAGE=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
WORKDIR /var/lib/homelab-bridge
USER 10001:10001

# Any HTTP answer (401 without a token is fine) means the server runs. One log line per check, once a minute.
# HEALTHCHECK_PORT: only when you start it with another --port.
HEALTHCHECK --interval=60s --timeout=5s --start-period=30s --retries=3 \
    CMD ["python3", "-c", "import http.client as h, os, sys; c = h.HTTPConnection('127.0.0.1', int(os.environ.get('HEALTHCHECK_PORT', '8791')), timeout=4); c.request('GET', '/api/v1/info'); sys.exit(0 if c.getresponse().status < 500 else 1)"]

ENTRYPOINT ["python3", "/app/reference_server.py"]
CMD ["--config", "/config/config.json"]

LABEL org.opencontainers.image.title="Homelab Bridge" \
      org.opencontainers.image.description="Companion API v1 server for the Homelab iOS app, with sources for other homelab services" \
      org.opencontainers.image.source="https://github.com/Qantrex/homelab-ios" \
      org.opencontainers.image.documentation="https://github.com/Qantrex/homelab-ios/blob/main/docs/SERVER-SETUP.md#docker" \
      org.opencontainers.image.licenses="PolyForm-Noncommercial-1.0.0"
