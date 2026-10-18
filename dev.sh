#!/usr/bin/env bash
# Run the local server with secrets from .env (gitignored).
# The server serves the frontend bundle from assets/ — built on start.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

./build.sh
exec gleam run