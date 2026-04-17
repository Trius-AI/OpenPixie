#!/bin/sh
set -e

# Create required directories
mkdir -p "${OPENPIXIE_DIR:-/data/pixie}"
mkdir -p "${OPENPIXIE_WORKSPACE:-/data/workspace}"
mkdir -p "${OPENPIXIE_DIR:-/data/pixie}/memories"
mkdir -p "${OPENPIXIE_DIR:-/data/pixie}/topics"
mkdir -p "${OPENPIXIE_DIR:-/data/pixie}/channels"
mkdir -p "${OPENPIXIE_DIR:-/data/pixie}/skills"
mkdir -p "${OPENPIXIE_DIR:-/data/pixie}/archive"
mkdir -p /opt/openpixie/log

# Copy source code to workspace for self-modification
SRC_COUNT=$(ls -1A /opt/openpixie/src/ 2>/dev/null | wc -l)
WS_SRC_COUNT=$(ls -1A "${OPENPIXIE_WORKSPACE:-/data/workspace}/src/" 2>/dev/null | wc -l)
if [ "$WS_SRC_COUNT" -eq 0 ] || [ "$WS_SRC_COUNT" -lt "$SRC_COUNT" ]; then
    echo "[openpixie] Syncing source code to workspace"
    cp -a /opt/openpixie/src/. "${OPENPIXIE_WORKSPACE:-/data/workspace}/src/" 2>/dev/null || true
    cp -a /opt/openpixie/priv/. "${OPENPIXIE_WORKSPACE:-/data/workspace}/priv/" 2>/dev/null || true
fi
mkdir -p "${OPENPIXIE_WORKSPACE:-/data/workspace}/ebin"

# Initialize git repo if needed
if [ ! -d "${OPENPIXIE_WORKSPACE:-/data/workspace}/.git" ]; then
    git init "${OPENPIXIE_WORKSPACE:-/data/workspace}" 2>/dev/null || true
fi

# Set env vars for the Erlang release
export OPENPIXIE_DIR="${OPENPIXIE_DIR:-/data/pixie}"
export OPENPIXIE_WORKSPACE="${OPENPIXIE_WORKSPACE:=/data/workspace}"

exec /opt/openpixie/bin/openpixie "$@"