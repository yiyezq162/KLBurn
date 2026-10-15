#!/usr/bin/env bash
# Shared entry for mutation runner; run-all directly supports the Python suite.
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/test-e2e-log-wait.py"
