#!/usr/bin/env bash
# tests/helpers/mock_llm_server.sh — Simple HTTP mock server for LLM API testing
# Usage: bash mock_llm_server.sh [PORT] [RESPONSE_FILE]
# Serves one POST request with the given JSON response, then exits.
# Requires python3.

set -euo pipefail

HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$(cd "$HELPERS_DIR/../fixtures/llm-responses" && pwd)"

PORT="${1:-18080}"
RESPONSE_FILE="${2:-$FIXTURES_DIR/distill-response.json}"

if [[ ! -f "$RESPONSE_FILE" ]]; then
  echo "Error: Response file not found: $RESPONSE_FILE" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 required for mock server" >&2
  exit 1
fi

# Start a single-request HTTP server that returns the fixture JSON for any POST
python3 - "$PORT" "$RESPONSE_FILE" << 'PYEOF'
import sys
import http.server
import os

port = int(sys.argv[1])
response_file = sys.argv[2]


class MockLLMHandler(http.server.BaseHTTPRequestHandler):
    """Handles POST requests by returning a canned JSON response."""

    def do_POST(self):
        # Read and discard request body
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length > 0:
            self.rfile.read(content_length)

        # Send the fixture response
        with open(response_file, "rb") as f:
            body = f.read()

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        """Health check endpoint."""
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"OK")

    def log_message(self, format, *args):
        """Suppress default logging."""
        pass


try:
    httpd = http.server.HTTPServer(("127.0.0.1", port), MockLLMHandler)
    # Write port to stdout so the caller knows we're ready
    print(f"MOCK_SERVER_READY:{port}", flush=True)
    # Handle requests until killed
    httpd.serve_forever()
except KeyboardInterrupt:
    pass
except OSError as e:
    print(f"Error: Cannot bind to port {port}: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
