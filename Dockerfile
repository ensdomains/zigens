# Multi-stage Dockerfile for ENSv2 Indexer + API
# Builds V1+V2 indexer and GraphQL API server
# Rainbow table is downloaded automatically on first startup

# Stage 1: Build Zig applications
FROM alpine:3.22 AS builder

# Install build dependencies
RUN apk add --no-cache \
    curl \
    xz \
    sqlite-dev \
    openssl-dev \
    musl-dev \
    gcc \
    g++ \
    python3

# Install Zig (must match build.zig.zon's minimum_zig_version — the pinned deps
# target this std API and fail to compile under older toolchains)
# Note: Zig 0.15+ uses new naming convention: zig-{arch}-linux instead of zig-linux-{arch}
ARG ZIG_VERSION=0.16.0
ARG TARGETARCH
RUN ARCH=$(case ${TARGETARCH:-$(uname -m)} in \
        amd64|x86_64) echo "x86_64" ;; \
        arm64|aarch64) echo "aarch64" ;; \
        *) echo "x86_64" ;; \
    esac) && \
    echo "Downloading Zig for architecture: $ARCH" && \
    curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz" | tar -xJ && \
    mv zig-${ARCH}-linux-${ZIG_VERSION} /usr/local/zig && \
    ln -s /usr/local/zig/zig /usr/local/bin/zig

# Set working directory
WORKDIR /app

# Fetch the dependency tree straight from the manifest (single source of truth,
# nothing duplicated here) before sources are copied, so the layer stays cached
# until build.zig/build.zig.zon change. Retried in the shell because zig's
# fetcher has none (ziglang/zig#25120) and reports any transient non-200 from a
# git host as a hard ProtocolError — which broke deploys fetching translate-c
# (transitive via pg.zig) from codeberg.org.
COPY build.zig build.zig.zon ./
RUN ok=0; \
    for i in 1 2 3 4 5; do \
      zig build --fetch && ok=1 && break; \
      echo "dependency fetch attempt $i failed; retrying in 5s"; sleep 5; \
    done; \
    [ "$ok" = 1 ]

# Copy source code
COPY . .

# Build all applications (generates introspection.json, builds indexer + API).
# ReleaseSafe keeps bounds/overflow/optional-unwrap checks active in production —
# the indexer parses untrusted RPC/ABI bytes, so safety checks are worth the cost.
# -Dtools=false skips test-db-reader and rainbow-backfill, which the image never ships.
# -j2 bounds concurrent compiles: peak build memory stays ~3.3GB (the api compile
# alone needs ~2GB+ on Zig 0.16) so the build can't starve the host it shares
# with the deployment platform.
RUN zig build -Doptimize=ReleaseSafe -Dpg-tls=true -Dtools=false -j2

# Stage 2: Runtime
FROM alpine:3.22

# Install runtime dependencies (including tools for rainbow download)
RUN apk add --no-cache \
    sqlite-libs \
    sqlite \
    libssl3 \
    libcrypto3 \
    ca-certificates \
    python3 \
    py3-pip \
    curl \
    bash

# Install Python packages for rainbow table parsing
RUN pip3 install --break-system-packages eth-hash[pycryptodome]

# Install Google Cloud SDK for gsutil (needed for rainbow table download)
RUN curl -sSL https://sdk.cloud.google.com | bash -s -- --disable-prompts --install-dir=/opt
ENV PATH="/opt/google-cloud-sdk/bin:${PATH}"

# Create app user
RUN addgroup -g 1000 ens && \
    adduser -D -u 1000 -G ens ens

# Set working directory
WORKDIR /app

# Copy binaries from builder
COPY --from=builder /app/zig-out/bin/ensv2-indexer /app/ensv2-indexer
COPY --from=builder /app/zig-out/bin/ensv2-indexer-v1 /app/ensv2-indexer-v1
COPY --from=builder /app/zig-out/bin/ensv2-indexer-v2 /app/ensv2-indexer-v2
COPY --from=builder /app/zig-out/bin/ensv2-api /app/ensv2-api

# Copy schema files (needed for database initialization)
COPY --from=builder /app/schema /app/schema

# Copy GraphQL schema
COPY --from=builder /app/schema.graphql /app/schema.graphql

# Copy rainbow build tools
COPY --from=builder /app/tools/parse_rainbow.py /app/tools/parse_rainbow.py

# Copy entrypoint and healthcheck scripts
COPY --from=builder /app/docker-entrypoint.sh /app/docker-entrypoint.sh
COPY --from=builder /app/api-entrypoint.sh /app/api-entrypoint.sh
COPY --from=builder /app/healthcheck.sh /app/healthcheck.sh

# Create data directories and make scripts executable
RUN mkdir -p /app/data /app/rainbow_data /app/webhooks && \
    chmod +x /app/docker-entrypoint.sh /app/api-entrypoint.sh /app/healthcheck.sh && \
    chown -R ens:ens /app

# Switch to app user
USER ens

# Expose ports (API=5655, Status=3001)
EXPOSE 5655 3001

# Set default environment variables
ENV DATABASE_PATH=/app/data/ens.db
ENV RAINBOW_PATH=/app/data/ens_rainbow.db
ENV API_PORT=5655
ENV STATUS_PORT=3001
ENV DOWNLOAD_RAINBOW=true

# Use entrypoint script to handle rainbow download
ENTRYPOINT ["/app/docker-entrypoint.sh"]

# Default command (can be overridden in docker-compose)
CMD ["/app/ensv2-indexer"]
