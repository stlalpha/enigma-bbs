#!/usr/bin/env bash
# Wrapper to launch the distribution builder from the repo root
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/scripts/build"
exec ./build-dist.sh "$@"
