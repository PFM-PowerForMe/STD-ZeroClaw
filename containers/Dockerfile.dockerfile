FROM ghcr.io/pfm-powerforme/s6:latest AS s6

# ── Stage 0: Build Frontend ───────────
FROM node:lts-trixie-slim AS frontend-builder
WORKDIR /frontend
COPY source-src/web/package*.json ./
RUN npm ci --ignore-scripts 2>/dev/null || npm install --ignore-scripts
COPY source-src/web/ ./
RUN npm run build

# ── Stage 1: Build Backend ────────────
# FROM rust:1.94-slim@sha256:da9dab7a6b8dd428e71718402e97207bb3e54167d37b5708616050b1e8f60ed6 AS builder
FROM rust:slim-trixie AS builder
ARG IMAGE_VERSION
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
RUN sed -i 's/members = \[".", "crates\/robot-kit"\]/members = ["."]/' Cargo.toml

RUN mkdir -p src benches \
    && echo "fn main() {}" > src/main.rs \
    && echo "" > src/lib.rs \
    && echo "fn main() {}" > benches/agent_benchmarks.rs
RUN --mount=type=cache,id=zeroclaw-cargo-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=zeroclaw-cargo-git,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,id=zeroclaw-target,target=/app/target,sharing=locked \
    cargo build --release --features "hardware channel-lark memory-postgres observability-otel peripheral-rpi browser-native fantoccini sandbox-landlock sandbox-bubblewrap landlock metrics probe rag-pdf plugins-wasm"
RUN rm -rf src benches

# Build actual binary
COPY source-src/src/ src/
COPY source-src/benches/ benches/
COPY source-src/web/ web/
COPY source-src/*.rs .
COPY --from=frontend-builder /frontend/dist/ web/dist/

# RUN find . -name "*.rs" -exec touch {} +
RUN touch src/main.rs

RUN --mount=type=cache,id=zeroclaw-cargo-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=zeroclaw-cargo-git,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,id=zeroclaw-target,target=/app/target,sharing=locked \
    rm -rf target/release/.fingerprint/zeroclawlabs-* \
           target/release/deps/zeroclawlabs-* \
           target/release/incremental/zeroclawlabs-* && \
    cargo build --release --features "hardware channel-lark memory-postgres observability-otel peripheral-rpi browser-native fantoccini sandbox-landlock sandbox-bubblewrap landlock metrics probe rag-pdf plugins-wasm" && \
    cp target/release/zeroclaw /app/zeroclaw && \
    strip /app/zeroclaw
RUN size=$(stat -c%s /app/zeroclaw 2>/dev/null || stat -f%z /app/zeroclaw) && \
    if [ "$size" -lt 1000000 ]; then echo "ERROR: binary too small (${size} bytes), likely dummy build artifact" && exit 1; fi

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

RUN echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99sandbox

# Create user and install multi-language toolchains & CLI tools
RUN groupadd -g 2000 zeroclaw && \
    useradd -u 2000 -g 2000 -d /zeroclaw-data -m -s /bin/bash zeroclaw

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates bash curl wget git gh openssh-client gnupg less tmux neovim \
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
COPY --from=builder /app/zeroclaw /usr/local/sbin/zeroclaw
COPY --from=builder --chown=2000:2000 /zeroclaw-data /zeroclaw-data
COPY source-src/dev/config.template.toml /zeroclaw-data/.zeroclaw/config.toml

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
    XDG_CONFIG_HOME="/zeroclaw-data/.config" \
    XDG_CACHE_HOME="/zeroclaw-data/.cache" \
    XDG_DATA_HOME="/zeroclaw-data/.local/share" \
    XDG_STATE_HOME="/zeroclaw-data/.local/state" \
    ZEROCLAW_GATEWAY_PORT="8080" \
    PIP_CACHE_DIR="/zeroclaw-data/.cache/pip" \
    npm_config_cache="/zeroclaw-data/.cache/npm" \
    GOPATH="/zeroclaw-data/.go" \
    GOCACHE="/zeroclaw-data/.cache/go-build" \
    GOMODCACHE="/zeroclaw-data/.cache/go-mod" \
    CARGO_HOME="/zeroclaw-data/.cargo"

COPY --from=s6 / /
COPY rootfs/ /

# Initialize cache directories with correct permissions
RUN mkdir -pv \
        ${XDG_CONFIG_HOME} \
        ${XDG_CACHE_HOME} \
        ${XDG_DATA_HOME} \
        ${XDG_STATE_HOME} \
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

ENTRYPOINT ["/init"]