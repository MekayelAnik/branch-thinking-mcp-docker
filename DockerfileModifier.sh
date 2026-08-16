#!/bin/bash
set -euxo pipefail
# Set variables first
REPO_NAME='branch-thinking-mcp'
BASE_IMAGE=$(cat ./build_data/base-image 2>/dev/null || echo "node:trixie-slim")
HAPROXY_IMAGE=$(cat ./build_data/haproxy-image 2>/dev/null || echo "haproxy:lts")
BRANCH_THINKING_VERSION=$(cat ./build_data/version 2>/dev/null || exit 1)
BUILD_IN_DOCKER=$(cat ./build_data/build-in-docker 2>/dev/null || echo "false")
# mcp-proxy: stdio<->StreamableHTTP/SSE bridge. Replaces supergateway.
# Stateful by default (one stdio child shared across all sessions) — avoids
# the spawn-per-request memory leak that affected supergateway in stateless
# mode (supercorp-ai/supergateway#108).
MCP_PROXY_PKG=$(cat ./build_data/mcp_proxy_version 2>/dev/null || echo "mcp-proxy")
DOCKERFILE_NAME="Dockerfile.$REPO_NAME"

# Create a temporary file safely
TEMP_FILE=$(mktemp "${DOCKERFILE_NAME}.XXXXXX") || {
    echo "Error creating temporary file" >&2
    exit 1
}

# Check if this is a publication build
if [ -e ./build_data/publication ]; then
    # For publication builds, create a minimal Dockerfile that just tags the existing image
    {
        echo "ARG BASE_IMAGE=$BASE_IMAGE"
        echo "ARG BRANCH_THINKING_VERSION=$BRANCH_THINKING_VERSION"
        echo "FROM $BASE_IMAGE"
    } > "$TEMP_FILE"
else
    # Write the multi-stage Dockerfile content
    {
        echo "ARG BASE_IMAGE=$BASE_IMAGE"
        echo "ARG BRANCH_THINKING_VERSION=$BRANCH_THINKING_VERSION"
        echo ""
        echo "# -------------------- BUILDER STAGE --------------------"
        echo "FROM \$BASE_IMAGE AS builder"
        echo ""
        echo "WORKDIR /app"
        echo ""
        echo "# Copy all source first (so we can modify package.json in place)"
        echo "COPY ./branch-thinking-mcp-src/ ./"
        echo ""
        echo "# Install pnpm (cache mount reuses npm downloads across builds)"
        echo "RUN --mount=type=cache,target=/root/.npm npm install -g pnpm"
        echo ""
        # Strip prepare script and ensure security overrides survive. Dep versions
        # are now canonical in the fork's package.json (graphlib4, TS6, HF
        # transformers, MCP SDK 1.29) — do NOT force-pin them here.
        cat << 'EOF'
RUN node -e "\
const fs = require('fs'); \
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8')); \
\
/* Strip top-level deps that should only be transitive */ \
['cross-spawn', 'body-parser', 'send'].forEach(function(name) { \
    if (pkg.dependencies && pkg.dependencies[name]) { \
        delete pkg.dependencies[name]; \
    } \
}); \
\
/* Security pins for transitive deps (CVE-driven) */ \
pkg.pnpm = pkg.pnpm || {}; \
pkg.pnpm.overrides = Object.assign(pkg.pnpm.overrides || {}, { \
    'cross-spawn': '^7.0.6', \
    'body-parser': '^2.2.2', \
    'send': '^1.2.1' \
}); \
\
/* Remove prepare script so it doesn't auto-run during install */ \
if (pkg.scripts && pkg.scripts.prepare) { \
    delete pkg.scripts.prepare; \
    console.log('Removed prepare script'); \
} \
\
/* Move lodash from devDependencies to dependencies if present */ \
if (pkg.devDependencies && pkg.devDependencies.lodash) { \
    pkg.dependencies = pkg.dependencies || {}; \
    pkg.dependencies.lodash = pkg.devDependencies.lodash; \
    delete pkg.devDependencies.lodash; \
    console.log('Moved lodash to dependencies'); \
} \
\
fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2)); \
console.log('Package.json modifications complete'); \
"
EOF

        if [[ "$BUILD_IN_DOCKER" == "true" ]]; then
            cat << 'EOF'

# Install all dependencies, build, then prune (cache mount reuses pnpm store across builds)
RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
    --mount=type=cache,target=/root/.npm \
    pnpm install --no-frozen-lockfile && \
    pnpm exec tsc && \
    pnpm exec shx chmod +x dist/index.js && \
    pnpm prune --prod
EOF
        else
            cat << 'EOF'

# Install only production dependencies (cache mount reuses pnpm store across builds)
RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
    --mount=type=cache,target=/root/.npm \
    pnpm install --prod --no-frozen-lockfile --ignore-scripts && \
    chmod +x dist/index.js
EOF
        fi

        # -------------------- RUNTIME STAGE --------------------
        cat << EOF

# -------------------- HAPROXY SOURCE STAGE --------------------
FROM $HAPROXY_IMAGE AS haproxy-src

# -------------------- RUNTIME STAGE --------------------
FROM \$BASE_IMAGE

# Copy HAProxy binary and its dependencies from official image
COPY --from=haproxy-src /usr/local/sbin/haproxy /usr/local/sbin/haproxy
RUN ln -sf /usr/local/sbin/haproxy /usr/sbin/haproxy

# Install runtime system packages (Debian/trixie-slim)
# python3 + pip stay at runtime to host the mcp-proxy stdio<->HTTP bridge.
RUN apt-get update && \\
    apt-get install -y --no-install-recommends \\
        netcat-openbsd \\
        curl \\
        wget \\
        gosu \\
        openssl \\
        ca-certificates \\
        libstdc++6 \\
        libssl3t64 \\
        libpcre2-8-0 \\
        python3 python3-pip python3-venv && \\
    rm -rf /var/lib/apt/lists/*

# Install mcp-proxy (replaces supergateway). Pure-Python, pip-installed.
RUN --mount=type=cache,target=/root/.cache/pip \\
    echo "Installing ${MCP_PROXY_PKG}..." && \\
    pip install --no-cache-dir --break-system-packages ${MCP_PROXY_PKG} && \\
    mcp-proxy --version
EOF

        cat << 'EOF'

# Copy entrypoint scripts and make them executable
COPY ./resources/ /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/banner.sh /usr/local/bin/healthcheck.sh && \
    chmod +r /usr/local/bin/build-timestamp.txt 2>/dev/null || true && \
    mkdir -p /etc/haproxy && \
    mv -vf /usr/local/bin/haproxy.cfg.template /etc/haproxy/haproxy.cfg.template

# Copy built application from builder stage - only runtime essentials
COPY --from=builder /app/dist /app/dist
COPY --from=builder /app/node_modules /app/node_modules
COPY --from=builder /app/package.json /app/

# Set working directory to /app
WORKDIR /app

# Runtime configuration
ARG PORT=8005
ARG API_KEY=""
ENV PORT=${PORT}
ENV API_KEY=${API_KEY}

# mcp-proxy and HAProxy concurrency defaults (overridable at runtime).
ENV MCP_PROXY_STATELESS=false
ENV BRANCH_THINKING_MAX_MEM_MB=4096
ENV HAPROXY_FRONTEND_MAXCONN=64
ENV HAPROXY_SERVER_MAXCONN=16

# HuggingFace transformers cache. Models (~275 MB total: MiniLM + DistilBART)
# download on first inference; mount /data/hf-cache as a volume to persist
# across container restarts.
ENV HF_HOME=/data/hf-cache
VOLUME ["/data/hf-cache"]

LABEL org.opencontainers.image.description="Branch Thinking MCP Server (mcp-proxy stdio<->HTTP bridge)"

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
EOF
    } > "$TEMP_FILE"
fi

# Atomically replace the target file with the temporary file
if mv -f "$TEMP_FILE" "$DOCKERFILE_NAME"; then
    echo "Multi-stage Dockerfile for $REPO_NAME created successfully."
else
    echo "Error: Failed to create Dockerfile for $REPO_NAME" >&2
    rm -f "$TEMP_FILE"
    exit 1
fi
chmod 0777 "Dockerfile.$REPO_NAME"
