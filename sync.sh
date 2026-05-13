#!/bin/sh
set -e

PROGNAME=$(basename "$0")
OPENPIXIE_HOST="${OPENPIXIE_HOST:-localhost:8080}"

usage() {
    echo "Usage: $PROGNAME <command>"
    echo ""
    echo "Commands:"
    echo "  export    Export instance-local changes as a git patch"
    echo "  import    Apply host repo changes into the running instance"
    echo "  diff      Show a summary of instance-local changes"
    echo ""
    echo "Environment:"
    echo "  OPENPIXIE_HOST  Host and port (default: localhost:8080)"
    echo "  OPENPIXIE_KEY    API key (or read from data/pixie/API_KEY)"
}

find_api_key() {
    if [ -n "$OPENPIXIE_KEY" ]; then
        echo "$OPENPIXIE_KEY"
        return
    fi
    # Try data/pixie/API_KEY relative to script or cwd
    for dir in "." "$(dirname "$0")/.." "$(dirname "$0")"; do
        keyfile="$dir/data/pixie/API_KEY"
        if [ -f "$keyfile" ]; then
            cat "$keyfile"
            return
        fi
    done
    echo ""
}

cmd_export() {
    KEY=$(find_api_key)
    if [ -z "$KEY" ]; then
        echo "Error: No API key found. Set OPENPIXIE_KEY or run from project root." >&2
        exit 1
    fi
    
    echo "Exporting instance-local changes..."
    PATCH=$(curl -sS -H "Authorization: Bearer $KEY" "http://$OPENPIXIE_HOST/api/v1/sync?action=export")
    
    # Check if it's JSON (empty or error) or a patch
    case "$PATCH" in
        '{'*)
            # JSON response
            echo "$PATCH" | python3 -m json.tool 2>/dev/null || echo "$PATCH"
            ;;
        diff\ ---*|---\ *)
            # It's a diff/patch — write to file
            OUTFILE="openpixie_export_$(date +%Y%m%d_%H%M%S).patch"
            echo "$PATCH" > "$OUTFILE"
            echo "Patch saved to $OUTFILE"
            echo "Apply with: git apply $OUTFILE"
            ;;
        *)
            # Write raw output to file
            OUTFILE="openpixie_export_$(date +%Y%m%d_%H%M%S).patch"
            printf '%s\n' "$PATCH" > "$OUTFILE"
            echo "Patch saved to $OUTFILE"
            echo "Apply with: git apply $OUTFILE"
            ;;
    esac
}

cmd_import() {
    KEY=$(find_api_key)
    if [ -z "$KEY" ]; then
        echo "Error: No API key found. Set OPENPIXIE_KEY or run from project root." >&2
        exit 1
    fi
    
    # Generate a diff of staged + unstaged changes in the host repo
    PATCH=$(git diff HEAD 2>/dev/null)
    if [ -z "$PATCH" ]; then
        # Try unstaged changes
        PATCH=$(git diff 2>/dev/null)
    fi
    
    if [ -z "$PATCH" ]; then
        echo "No changes to import."
        exit 0
    fi
    
    echo "Importing changes into running instance..."
    B64=$(printf '%s' "$PATCH" | base64 -w0)
    
    RESULT=$(curl -sS -X POST \
        -H "Authorization: Bearer $KEY" \
        -H "Content-Type: application/json" \
        -d "{\"action\":\"import\",\"patch\":\"$B64\"}" \
        "http://$OPENPIXIE_HOST/api/v1/sync")
    
    echo "$RESULT" | python3 -m json.tool 2>/dev/null || echo "$RESULT"
}

cmd_diff() {
    KEY=$(find_api_key)
    if [ -z "$KEY" ]; then
        echo "Error: No API key found. Set OPENPIXIE_KEY or run from project root." >&2
        exit 1
    fi
    
    curl -sS -H "Authorization: Bearer $KEY" "http://$OPENPIXIE_HOST/api/v1/sync?action=diff" | python3 -m json.tool 2>/dev/null || \
    curl -sS -H "Authorization: Bearer $KEY" "http://$OPENPIXIE_HOST/api/v1/sync?action=diff"
}

case "${1:-}" in
    export) cmd_export ;;
    import) cmd_import ;;
    diff)   cmd_diff ;;
    *)      usage ;;
esac