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

# Create required directories
mkdir -p "${OPENPIXIE_DIR:-/data/pixie}"
mkdir -p "${OPENPIXIE_WORKSPACE:-/data/workspace}"
mkdir -p "${OPENPIXIE_DIR:-/data/pixie}/memories"
mkdir -p "${OPENPIXIE_DIR:-/data/pixie}/topics"
mkdir -p "${OPENPIXIE_DIR:-/data/pixie}/channels"
mkdir -p "${OPENPIXIE_DIR:-/data/pixie}/skills"
mkdir -p "${OPENPIXIE_DIR:-/data/pixie}/archive"
mkdir -p /opt/openpixie/log

# Sync source code to workspace for self-modification
# Always sync to ensure workspace matches the running release version
echo "[openpixie] Syncing source code to workspace"
cp -a /opt/openpixie/src/. "${OPENPIXIE_WORKSPACE:-/data/workspace}/src/" 2>/dev/null || true
cp -a /opt/openpixie/priv/. "${OPENPIXIE_WORKSPACE:-/data/workspace}/priv/" 2>/dev/null || true
cp -a /opt/openpixie/docs/. "${OPENPIXIE_WORKSPACE:-/data/workspace}/docs/" 2>/dev/null || true
mkdir -p "${OPENPIXIE_WORKSPACE:-/data/workspace}/ebin"

# Clear stale beams from ebin so next compile_and_reload uses fresh source
rm -f "${OPENPIXIE_WORKSPACE:-/data/workspace}/ebin/"*.beam 2>/dev/null || true

# Write .gitignore if not present
if [ ! -f "${OPENPIXIE_WORKSPACE:-/data/workspace}/.gitignore" ]; then
    cat > "${OPENPIXIE_WORKSPACE:-/data/workspace}/.gitignore" << 'EOF'
ebin/
*.beam
hello.py
*.swp
*.swo
*~
EOF
fi

# Initialize git repo and make initial commit if needed
cd "${OPENPIXIE_WORKSPACE:-/data/workspace}"
if [ ! -d .git ]; then
    git init 2>/dev/null || true
fi
git config user.name "OpenPixie" 2>/dev/null || true
git config user.email "pixie@openpixie" 2>/dev/null || true
git add -A 2>/dev/null || true
git diff --cached --quiet 2>/dev/null || git commit -m "Baseline: synced from release" 2>/dev/null || true

# Set env vars for the Erlang release
export OPENPIXIE_DIR="${OPENPIXIE_DIR:-/data/pixie}"
export OPENPIXIE_WORKSPACE="${OPENPIXIE_WORKSPACE:=/data/workspace}"

exec /opt/openpixie/bin/openpixie "$@"