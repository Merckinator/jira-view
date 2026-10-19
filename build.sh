#!/usr/bin/env bash
# Build the Lustre app into assets/app.js — one esbuild bundle of the
# gleam-compiled JS output (ui/build/dev/javascript/...). index.html only
# needs /assets/app.js, so the server serves the assets/ directory as-is.
#
# esbuild is pinned in ui/package.json. Install it once with:
#   npm --prefix ui install
set -euo pipefail
cd "$(dirname "$0")"

sources=(
  ui/src
  shared/src
  ui/gleam.toml
  ui/manifest.toml
  shared/gleam.toml
  shared/manifest.toml
  ui/package.json
  ui/package-lock.json
  build.sh
)

# A fresh clone ships a working bundle. Skip the rebuild when nothing that
# feeds it has changed; git checkout timestamps can be close, so treat an
# unavailable esbuild as a reason to use the committed bundle, with a warning.
if [[ -f assets/app.js ]]; then
  newer=$(find "${sources[@]}" -newer assets/app.js -print -quit 2>/dev/null || true)
  if [[ -z "$newer" ]]; then
    echo "assets/app.js is up to date"
    exit 0
  fi
fi

if [[ ! -x ui/node_modules/.bin/esbuild ]]; then
  if [[ -f assets/app.js ]]; then
    echo "esbuild is not installed; using the existing assets/app.js." >&2
    echo "Run 'npm --prefix ui install' to rebuild after UI changes." >&2
    exit 0
  fi
  echo "esbuild is not installed. Run 'npm --prefix ui install' first." >&2
  exit 1
fi

(cd ui && gleam build --target javascript)

mkdir -p assets
ui/node_modules/.bin/esbuild \
  ui/build/dev/javascript/jira_view_ui/jira_view_ui.mjs \
  --bundle --format=esm --minify \
  --outfile=assets/app.js
