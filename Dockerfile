# Multi-stage Dockerfile for ENSv2 Indexer + API
# Builds V1+V2 indexer and GraphQL API server
# Rainbow table is downloaded automatically on first startup

# Stage 1: Build Zig applications
FROM alpine:3.19 AS builder

# Install build dependencies
RUN apk add --no-cache \
    curl \
    xz \
    sqlite-dev \
    musl-dev \
    gcc \
    g++ \
    python3

# Install Zig 0.15.x (latest stable)
# Note: Zig 0.15+ uses new naming convention: zig-{arch}-linux instead of zig-linux-{arch}
# 0.15.2 is a stdlib patch release with std.http.Client + std.crypto.tls fixes;
# 0.15.1 produced 90s+ TLS/HTTP hangs in deployment that manifested as 408s from
# the RPC provider, while 0.15.2 (matching local dev) works fine.
ARG ZIG_VERSION=0.15.2
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

# Copy source code
COPY . .

# Build all applications (generates introspection.json, builds indexer + API).
# ReleaseSafe keeps bounds/overflow/optional-unwrap checks active in production —
# the indexer parses untrusted RPC/ABI bytes, so safety checks are worth the cost.
RUN zig build -Doptimize=ReleaseSafe

# Stage 2: Runtime
FROM alpine:3.19

# Install runtime dependencies (including tools for rainbow download)
RUN apk add --no-cache \
    sqlite-libs \
    sqlite \
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
