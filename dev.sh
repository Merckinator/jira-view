#!/usr/bin/env bash
# Run the server with secrets from .env (gitignored).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

exec gleam run