#!/usr/bin/env bash
# build-linux.sh - build the UDAW macOS executable with Lazarus/FPC.
# Requires lazbuild on PATH (package: lazarus / lazarus-ide).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/bin
echo "==> lazbuild udaw.lpi"
lazbuild --build-mode=Release udaw.lpi
echo "==> OK: build/bin/udaw"
