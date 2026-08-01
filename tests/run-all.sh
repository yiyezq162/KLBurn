#!/usr/bin/env bash
#
# 跑全部回归测试。都不需要真实服务器硬件，在 WSL 里随时可跑：
#
#     ./tests/run-all.sh
#
# test-disk-exclusion.sh 要 root（要造 loop + dm 设备），非 root 时自动跳过；
# 它守的是整个项目最危险的一条路径（U 盘反查排除），出盘前请单独跑一次：
#
#     sudo ./tests/test-disk-exclusion.sh
#
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SUITES=(
  lint
  test-log-parsing
  test-hw-checks
  test-screen-render
  test-report-render
  test-internal-report
  test-capture
  test-concurrent-burn
)

total_pass=0; total_fail=0; failed_suites=()

for s in "${SUITES[@]}"; do
  printf '\n\033[1;36m===== %s =====\033[0m\n' "$s"
  out="$(./tests/"$s".sh 2>&1)"
  rc=$?
  printf '%s\n' "$out" | tail -3
  # 每个脚本最后一行都是"通过 N 项，失败 M 项"
  line="$(printf '%s\n' "$out" | grep -E '^通过 [0-9]+ 项' | tail -1)"
  p="$(printf '%s' "$line" | grep -oE '通过 [0-9]+' | grep -oE '[0-9]+' || true)"
  f="$(printf '%s' "$line" | grep -oE '失败 [0-9]+' | grep -oE '[0-9]+' || true)"
  total_pass=$(( total_pass + ${p:-0} ))
  total_fail=$(( total_fail + ${f:-0} ))
  (( rc != 0 )) && failed_suites+=("$s")
done

if (( EUID == 0 )); then
  printf '\n\033[1;36m===== test-disk-exclusion =====\033[0m\n'
  ./tests/test-disk-exclusion.sh 2>&1 | tail -3 || failed_suites+=("test-disk-exclusion")
else
  printf '\n\033[0;33m跳过 test-disk-exclusion.sh（需要 root）\033[0m\n'
fi

printf '\n========================================\n'
printf '合计通过 %d 项，失败 %d 项\n' "$total_pass" "$total_fail"
if (( ${#failed_suites[@]} )); then
  printf '\033[1;31m失败的测试：%s\033[0m\n' "${failed_suites[*]}"
  exit 1
fi
printf '\033[1;32m全部通过\033[0m\n'
