FROM ghcr.io/pfm-powerforme/s6:latest AS s6

# ── Stage 0: Build Frontend ───────────
FROM node:22-slim AS frontend-builder
WORKDIR /frontend
COPY source-src/web/package*.json ./
RUN npm install
COPY source-src/web/ ./
RUN npm run build

# ── Stage 1: Build Backend ────────────
FROM rust:1.93-slim@sha256:9663b80a1621253d30b146454f903de48f0af925c967be48c84745537cd35d8b AS builder
ARG REPO
ARG ARCH
ARG CPU_ARCH
ENV REPO=$REPO \
    ARCH=$ARCH \
    CPU_ARCH=$CPU_ARCH \
    IMAGE_VERSION=$IMAGE_VERSION

WORKDIR /app

# Install build dependencies
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y pkg-config && rm -rf /var/lib/apt/lists/*

# Cache Cargo dependencies
COPY source-src/Cargo.toml source-src/Cargo.lock ./
COPY source-src/crates/robot-kit/Cargo.toml crates/robot-kit/Cargo.toml
RUN mkdir -p src benches crates/robot-kit/src \
    && echo "fn main() {}" > src/main.rs \
    && echo "fn main() {}" > benches/agent_benchmarks.rs \
    && echo "pub fn placeholder() {}" > crates/robot-kit/src/lib.rs
RUN --mount=type=cache,id=zeroclaw-cargo-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=zeroclaw-cargo-git,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,id=zeroclaw-target,target=/app/target,sharing=locked \
    cargo build --all-features --release --locked
RUN rm -rf src benches crates/robot-kit/src

# Build actual binary
COPY source-src/src/ src/
COPY source-src/benches/ benches/
COPY source-src/crates/ crates/
COPY source-src/firmware/ firmware/
COPY source-src/web/ web/
COPY --from=frontend-builder /frontend/dist/ web/dist/

RUN --mount=type=cache,id=zeroclaw-cargo-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=zeroclaw-cargo-git,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,id=zeroclaw-target,target=/app/target,sharing=locked \
    cargo build --release --all-features --locked && \
    cp target/release/zeroclaw /app/zeroclaw && \
    strip /app/zeroclaw

# Generate default configuration
RUN mkdir -p /zeroclaw-data/.zeroclaw /zeroclaw-data/workspace && \
    printf '%s\n' \
        'workspace_dir = "/zeroclaw-data/workspace"' \
        'config_path = "/zeroclaw-data/.zeroclaw/config.toml"' \
        'api_key = ""' \
        'default_provider = "openrouter"' \
        'default_model = "anthropic/claude-sonnet-4-20250514"' \
        'default_temperature = 0.7' \
        '' \
        '[gateway]' \
        'port = 8080' \
        'host = "[::]"' \
        'allow_public_bind = true' \
        > /zeroclaw-data/.zeroclaw/config.toml

# ── Stage 2: Runtime ──────────────────
FROM debian:trixie-slim AS runtime

COPY --from=s6 / /
COPY rootfs/ /

RUN echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99sandbox

# Create user and install multi-language toolchains & CLI tools
RUN groupadd -g 2000 zeroclaw && \
    useradd -u 2000 -g 2000 -d /zeroclaw-data -m -s /bin/bash zeroclaw

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates bash curl wget git gh openssh-client gnupg less neovim tmux neovim \
        jq ripgrep fd-find tree unzip tar strace lsof \
        build-essential make \
        python3 python3-pip python3-venv \
        nodejs npm \
        golang \
        cargo rustc \
        shellcheck \
        chromium chromium-driver \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @ast-grep/cli && \
    pip3 install ruff --break-system-packages

# Copy artifacts
COPY --from=builder /app/zeroclaw /usr/local/bin/zeroclaw
COPY --from=builder --chown=2000:2000 /zeroclaw-data /zeroclaw-data

# Set environments & redirect package manager caches
ENV PATH="/command:/pfm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    S6_LOGGING_SCRIPT="n2 s1000000 T" \
    DEBIAN_FRONTEND="noninteractive" \
    LC_ALL="C.UTF-8" \
    LANG="C.UTF-8" \
    TERM="xterm-256color" \
    COLORTERM="truecolor" \
    ZEROCLAW_WORKSPACE="/zeroclaw-data/workspace" \
    HOME="/zeroclaw-data" \
    ZEROCLAW_GATEWAY_PORT="8080" \
    PIP_CACHE_DIR="/zeroclaw-data/.cache/pip" \
    npm_config_cache="/zeroclaw-data/.cache/npm" \
    GOPATH="/zeroclaw-data/.go" \
    GOCACHE="/zeroclaw-data/.cache/go-build" \
    GOMODCACHE="/zeroclaw-data/.cache/go-mod" \
    CARGO_HOME="/zeroclaw-data/.cargo"

# Initialize cache directories with correct permissions
RUN mkdir -p \
        ${PIP_CACHE_DIR} \
        ${npm_config_cache} \
        ${GOCACHE} \
        ${GOMODCACHE} \
        ${GOPATH} \
        ${CARGO_HOME} \
        ${ZEROCLAW_WORKSPACE} \
    && chown -R 2000:2000 /zeroclaw-data

RUN bash /pfm/bin/fix_env

WORKDIR /zeroclaw-data
VOLUME /zeroclaw-data
EXPOSE 8080

ENTRYPOINT ["init"]