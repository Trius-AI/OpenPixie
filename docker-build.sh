#!/bin/sh
set -e

docker build -t openpixie:0.1.0 . "$@"

echo ""
echo "Run with:"
echo "  docker run -p 8080:8080 --add-host=host.docker.internal:host-gateway \\"
echo "    -v openpixie-data:/data openpixie:0.1.0"
echo ""
echo "Ollama on the host is accessible via host.docker.internal:11434 by default."
echo "Override with: -e OLLAMA_HOST=http://your-ollama-host:11434"