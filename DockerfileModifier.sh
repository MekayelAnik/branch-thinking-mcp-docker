#!/bin/bash
set -euxo pipefail
# Set variables first
REPO_NAME='branch-thinking-mcp'
BASE_IMAGE=$(cat ./build_data/base-image 2>/dev/null || echo "node:trixie-slim")
HAPROXY_IMAGE=$(cat ./build_data/haproxy-image 2>/dev/null || echo "haproxy:lts")
BRANCH_THINKING_VERSION=$(cat ./build_data/version 2>/dev/null || exit 1)
BUILD_IN_DOCKER=$(cat ./build_data/build-in-docker 2>/dev/null || echo "false")
SUPERGATEWAY_PKG='supergateway@latest'
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
        # Common override injection and lodash move, plus removal of prepare script
        cat << 'EOF'
# Inject security overrides, remove prepare script, and move lodash
RUN node -e "\
const fs = require('fs'); \
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8')); \
\
/* Update direct dependencies to latest versions */ \
pkg.dependencies = Object.assign(pkg.dependencies || {}, { \
    '@modelcontextprotocol/sdk': '^1.26.0', \
    '@dagrejs/graphlib': '^3.0.4', \
    '@xenova/transformers': '^2.17.2', \
    'chalk': '^5.6.2', \
    'fs-extra': '^11.3.3', \
    'lru-cache': '^11.2.6', \
    'ml-kmeans': '^7.0.0', \
    'zod': '^4.3.6' \
}); \
\
/* Remove cross-spawn, body-parser, send from direct deps - they are transitive only */ \
['cross-spawn', 'body-parser', 'send'].forEach(function(name) { \
    if (pkg.dependencies && pkg.dependencies[name]) { \
        delete pkg.dependencies[name]; \
    } \
}); \
\
/* Inject overrides for transitive and peer dependency pinning */ \
pkg.pnpm = pkg.pnpm || {}; \
pkg.pnpm.overrides = Object.assign(pkg.pnpm.overrides || {}, { \
    '@modelcontextprotocol/sdk': '^1.26.0', \
    '@dagrejs/graphlib': '^3.0.4', \
    '@xenova/transformers': '^2.17.2', \
    'chalk': '^5.6.2', \
    'fs-extra': '^11.3.3', \
    'lru-cache': '^11.2.6', \
    'ml-kmeans': '^7.0.0', \
    'cross-spawn': '^7.0.6', \
    'lodash': '^4.17.23', \
    'body-parser': '^2.2.2', \
    'send': '^1.2.1', \
    'zod': '^4.3.6' \
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
RUN apt-get update && \\
    apt-get install -y --no-install-recommends \\
        netcat-openbsd \\
        wget \\
        gosu \\
        openssl \\
        libstdc++6 \\
        libssl3t64 \\
        libpcre2-8-0 && \\
    rm -rf /var/lib/apt/lists/*
EOF

        cat << 'EOF'

# Copy entrypoint scripts and make them executable
COPY ./resources/ /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/banner.sh && \
    chmod +r /usr/local/bin/build-timestamp.txt && \
    mkdir -p /etc/haproxy && \
    mv -vf /usr/local/bin/haproxy.cfg.template /etc/haproxy/haproxy.cfg.template

# Copy built application from builder stage - only runtime essentials
COPY --from=builder /app/dist /app/dist
COPY --from=builder /app/node_modules /app/node_modules
COPY --from=builder /app/package.json /app/

# Set working directory to /app so that any postinstall scripts (e.g., supergateway) can find package.json if needed
WORKDIR /app

# Install Supergateway globally (cache mount reuses npm downloads)
RUN --mount=type=cache,target=/root/.npm npm install -g ${SUPERGATEWAY_PKG}

# Runtime configuration
ARG PORT=8005
ARG API_KEY=""
ENV PORT=${PORT}
ENV API_KEY=${API_KEY}

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD sh -c 'wget -q --spider --no-check-certificate $([ "$ENABLE_HTTPS" = "true" ] && echo https || echo http)://127.0.0.1:${PORT:-8005}/healthz'

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
