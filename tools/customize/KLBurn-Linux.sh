#!/bin/sh
set -eu
cd "$(dirname "$0")"
if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' '请先安装 Python 3.10 或更新版本；ISO 后端须为 x86_64 Ubuntu 24.04。'
  exit 1
fi
exec python3 ./klburn-builder.py "$@"
