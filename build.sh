#!/usr/bin/env bash
# Build the Lustre app into assets/app.js — one esbuild bundle of the
# gleam-compiled JS output (ui/build/dev/javascript/...). index.html only
# needs /assets/app.js, so the server serves the assets/ directory as-is.
set -euo pipefail
cd "$(dirname "$0")"

(cd ui && gleam build --target javascript)

mkdir -p assets
npx --yes esbuild \
  ui/build/dev/javascript/jira_view_ui/jira_view_ui.mjs \
  --bundle --format=esm --minify \
  --outfile=assets/app.js