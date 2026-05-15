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

# Always sync source code and frontend from release to workspace.
# This ensures the latest build is always available when developing.
echo "[openpixie] Syncing source code to workspace"
mkdir -p "$WS/src" "$WS/priv/dashboard" "$WS/docs" "$WS/ebin"
cp -a /opt/openpixie/src/. "$WS/src/" 2>/dev/null || true
cp -a /opt/openpixie/priv/. "$WS/priv/" 2>/dev/null || true
cp -a /opt/openpixie/docs/. "$WS/docs/" 2>/dev/null || true
# Record which release this came from
RELEASE_HASH="unknown"
if [ -d /opt/openpixie/.git ]; then
    RELEASE_HASH=$(cd /opt/openpixie && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
fi
echo "$RELEASE_HASH" > "$WS/.pixie_baseline"

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

# Override git name/email if configured
if [ -f "$PIXIE/git_name" ]; then
    GIT_NAME=$(cat "$PIXIE/git_name" | tr -d '\n')
    if [ -n "$GIT_NAME" ]; then
        git config user.name "$GIT_NAME" 2>/dev/null || true
    fi
fi
if [ -f "$PIXIE/git_email" ]; then
    GIT_EMAIL=$(cat "$PIXIE/git_email" | tr -d '\n')
    if [ -n "$GIT_EMAIL" ]; then
        git config user.email "$GIT_EMAIL" 2>/dev/null || true
    fi
fi

# Set up SSH if keys exist in pixie dir
mkdir -p "$HOME/.ssh"
if [ -f "$PIXIE/ssh_key" ]; then
    cp "$PIXIE/ssh_key" "$HOME/.ssh/id_ed25519" 2>/dev/null || true
    chmod 600 "$HOME/.ssh/id_ed25519" 2>/dev/null || true
fi
if [ -f "$PIXIE/known_hosts" ]; then
    cat "$PIXIE/known_hosts" > "$HOME/.ssh/known_hosts" 2>/dev/null || true
else
    ssh-keyscan -H github.com 2>/dev/null > "$HOME/.ssh/known_hosts" 2>/dev/null || true
    ssh-keyscan -H gitlab.com 2>/dev/null >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
fi
chmod 644 "$HOME/.ssh/known_hosts" 2>/dev/null || true

# Configure git remote if configured
if [ -f "$PIXIE/git_remote" ]; then
    REMOTE_URL=$(cat "$PIXIE/git_remote" | tr -d '\n')
    if [ -n "$REMOTE_URL" ]; then
        if git remote get-url origin 2>/dev/null; then
            git remote set-url origin "$REMOTE_URL" 2>/dev/null || true
        else
            git remote add origin "$REMOTE_URL" 2>/dev/null || true
        fi
    fi
fi

# Configure git branch if configured
if [ -f "$PIXIE/git_branch" ]; then
    BRANCH=$(cat "$PIXIE/git_branch" | tr -d '\n')
    if [ -n "$BRANCH" ]; then
        git checkout -B "$BRANCH" 2>/dev/null || true
        git branch --set-upstream-to="origin/$BRANCH" "$BRANCH" 2>/dev/null || true
    fi
fi

git add -A 2>/dev/null || true
git diff --cached --quiet 2>/dev/null || git commit -m "Baseline: synced from release" 2>/dev/null || true

# Set env vars for the Erlang release
export OPENPIXIE_DIR="$PIXIE"
export OPENPIXIE_WORKSPACE="$WS"

exec /opt/openpixie/bin/openpixie "$@"