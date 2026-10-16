#!/usr/bin/env bash
# Mutation entry: execute the same Python suite as run-all.sh.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec python3 tests/test-customize.py
