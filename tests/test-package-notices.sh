#!/usr/bin/env bash
# Mutation runner entry; use the same Python suite as run-all.sh.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec python3 tests/test-package-notices.py
