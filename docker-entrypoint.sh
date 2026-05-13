#!/bin/sh
set -e

# Ensure host.docker.internal resolves (needed on Linux; macOS/Windows Docker Desktop handles this)
if ! getent hosts host.docker.internal >/dev/null 2>&1; then
    GATEWAY=$(ip route | grep default | awk '{print $3}')
    if [ -n "$GATEWAY" ]; then
        echo "[openpixie] Adding host.docker.internal -> $GATEWAY to /etc/hosts"
        echo "$GATEWAY host.docker.internal" >> /etc/hosts
    fi
fi

WS="${OPENPIXIE_WORKSPACE:-/data/workspace}"
PIXIE="${OPENPIXIE_DIR:-/data/pixie}"

# Create required directories
mkdir -p "$PIXIE"
mkdir -p "$WS"
mkdir -p "$PIXIE/memories"
mkdir -p "$PIXIE/topics"
mkdir -p "$PIXIE/channels"
mkdir -p "$PIXIE/skills"
mkdir -p "$PIXIE/archive"
mkdir -p /opt/openpixie/log

# Smart sync: only copy release source to workspace if no baseline marker exists.
# This preserves agent self-modifications across container restarts.
if [ -f "$WS/.pixie_baseline" ]; then
    echo "[openpixie] Workspace has existing baseline — skipping source sync"
else
    echo "[openpixie] Syncing source code to workspace"
    mkdir -p "$WS/src" "$WS/priv/dashboard" "$WS/docs" "$WS/ebin"
    cp -a /opt/openpixie/src/. "$WS/src/" 2>/dev/null || true
    cp -a /opt/openpixie/priv/. "$WS/priv/" 2>/dev/null || true
    cp -a /opt/openpixie/docs/. "$WS/docs/" 2>/dev/null || true
    # Record which release this baseline came from
    RELEASE_HASH="unknown"
    if [ -d /opt/openpixie/.git ]; then
        RELEASE_HASH=$(cd /opt/openpixie && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    fi
    echo "$RELEASE_HASH" > "$WS/.pixie_baseline"
fi

# Clear stale beams from ebin so next compile_and_reload uses fresh source
rm -f "$WS/ebin/"*.beam 2>/dev/null || true

# Write .gitignore if not present
if [ ! -f "$WS/.gitignore" ]; then
    cat > "$WS/.gitignore" << 'EOF'
ebin/
*.beam
hello.py
*.swp
*.swo
*~
EOF
fi

# Initialize git repo if needed
cd "$WS"
if [ ! -d .git ]; then
    git init 2>/dev/null || true
fi
git config user.name "OpenPixie" 2>/dev/null || true
git config user.email "pixie@openpixie" 2>/dev/null || true
git add -A 2>/dev/null || true
git diff --cached --quiet 2>/dev/null || git commit -m "Baseline: synced from release" 2>/dev/null || true

# Set env vars for the Erlang release
export OPENPIXIE_DIR="$PIXIE"
export OPENPIXIE_WORKSPACE="$WS"

exec /opt/openpixie/bin/openpixie "$@"