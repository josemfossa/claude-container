# syntax=docker/dockerfile:1
#
# Adapt: base image (one that already has your runtime), user name/uid, and the
# toolchain section. Keep one small build stage per downloaded tool.

ARG HELIX_VERSION=25.07.1


# Download Helix in a disposable build stage. To verify the archive, add a
# per-arch sha256 and `sha256sum --check --strict` (optional, see SKILL.md).
FROM docker.io/debian:bookworm-slim AS helix

ARG TARGETARCH
ARG HELIX_VERSION

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      xz-utils \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) helix_arch="x86_64-linux" ;; \
        arm64) helix_arch="aarch64-linux" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    archive="helix-${HELIX_VERSION}-${helix_arch}.tar.xz"; \
    curl --fail --show-error --location \
        --output "/tmp/${archive}" \
        "https://github.com/helix-editor/helix/releases/download/${HELIX_VERSION}/${archive}"; \
    mkdir -p /opt/helix; \
    tar --extract --xz --file "/tmp/${archive}" \
        --directory /opt/helix --strip-components=1; \
    test -x /opt/helix/hx; \
    test -d /opt/helix/runtime


# Base image with your runtime, pinned rather than "latest".
# Replace with e.g. docker.io/denoland/deno:<ver>, docker.io/library/node:<ver>,
# docker.io/library/python:<ver>, docker.io/library/rust:<ver>, ...
FROM docker.io/library/debian:bookworm-slim

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      git \
      less \
 && rm -rf /var/lib/apt/lists/*

COPY --from=helix /opt/helix/hx /usr/local/bin/hx
COPY --from=helix /opt/helix/runtime /usr/local/lib/helix/runtime

ENV HELIX_RUNTIME=/usr/local/lib/helix/runtime

# --- Toolchain: add runtimes, package managers and LSP binaries here. ---
# Point caches at volume paths and create/chown them below, e.g.:
#   ENV SOME_CACHE_DIR=/cache
# Install LSPs the project needs (typescript-language-server, ruff, ty,
# pyright, rust-analyzer, ...). Python: ty is a separate tool from uv.

# Create the non-root user (skip if the base image already has one).
RUN useradd --create-home --uid 1000 dev \
 && mkdir -p /workspace \
 && chown -R dev:dev /workspace
# For every cache/venv volume, also: mkdir -p /path && chown -R dev:dev /path

USER dev
WORKDIR /workspace

# Long-lived process for subsequent `podman exec` sessions.
CMD ["sleep", "infinity"]
