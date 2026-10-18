#!/usr/bin/env bash
# mutate.sh 的 Bash 套件入口。
set -eu
exec python3 "$(dirname "$0")/test-disk-console.py"
