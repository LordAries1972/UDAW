#!/usr/bin/env bash
# test-linux.sh - build and run the Phase 1 test suite with FPC.
# Requires fpc on PATH. Exit code 0 only if every test passes.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/bin build/lib/tests
echo "==> fpc tests/udaw_tests.lpr"
fpc -MDelphi -O2 \
    -Fu"src/common" -Fu"src/audio" -Fu"src/audio/backend" -Fu"src/audio/dsp" -Fu"src/audio/graph" -Fu"src/codecs/pcm" -Fu"src/codecs/tracker" -Fu"src/timeline" -Fu"src/project" -Fu"src/recording" -Fi"src/common" \
    -FU"build/lib/tests" -o"build/bin/udaw_tests" tests/udaw_tests.lpr
echo "==> running tests"
./build/bin/udaw_tests
