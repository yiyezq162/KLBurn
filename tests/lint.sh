#!/usr/bin/env bash
#
# shellcheck 静态检查。和其它 tests/ 里的脚本一样，不需要任何硬件：
#
#     ./tests/lint.sh
#
# 为什么值得单独立一条：回归测试守的是"逻辑对不对"，守不住"这行 bash 会不会
# 在某个分支上炸"。项目里翻过的车有一半是 bash 陷阱（见 architecture.md §11），
# 而其中好几类 shellcheck 是能直接看出来的 —— 比如 `rm -rf "$dst/$rel"` 里
# $rel 可能为空、`cd ...` 失败之后照样往下跑。
#
# 没装 shellcheck 就跳过（判 0 项，不判失败）：它是构建机上的开发工具，
# 不是出盘的必要条件，不能因为谁的 WSL 里没装就让整套测试跑红。
#
#     sudo apt-get install -y shellcheck
#
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PASS=0; FAIL=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

if ! command -v shellcheck >/dev/null 2>&1; then
  printf '  \033[0;33m跳过：本机没装 shellcheck（apt-get install shellcheck）\033[0m\n'
  printf '通过 %d 项，失败 %d 项\n' 0 0
  exit 0
fi

printf '  shellcheck %s\n\n' "$(shellcheck --version | awk '/^version:/{print $2}')"

# ================================================================
# 两套豁免规则，因为两棵树的 bash 约定本来就不一样
# ================================================================
#
# 共同豁免：
#
#   SC2034  "变量没被用过"。config.sh / core.sh 是纯变量文件，值由**别的**
#           被 source 的脚本消费，shellcheck 跨不过 source 边界，全是误报。
#
# rootfs/ 和 tests/ 额外豁免：
#
#   SC2155  "declare 和赋值分开写，免得吃掉返回值"。这条只在 set -e 下才是
#           问题，而运行时脚本**故意不开 -e**（单项失败必须继续往下跑并落进
#           报告，见 factory-test.sh 顶部）。命中的 5 处全是
#           `local detail="...$(fmt_dur ...)..."` 这种拼中文文案的。
#           build/ 那边开了 -Eeuo pipefail，所以**不豁免**，那里是真问题。
#
#   SC2120  "函数声明里引用了参数，但从没有人传参"。几个纯函数留了
#           `${1:-默认}` 形式的可选入参，只有回归测试会传（正是为了喂样本），
#           生产路径走默认值。
#
EXCLUDE_BUILD="SC2034"
EXCLUDE_RUNTIME="SC2034,SC2155,SC2120"

run_group() {
  local label="$1" exclude="$2"; shift 2
  local out rc
  out="$(shellcheck -x -S warning -e "$exclude" -f gcc "$@" 2>&1)"; rc=$?
  if (( rc == 0 )) && [[ -z "$out" ]]; then
    ok "$label（$# 个文件）干净"
  else
    bad "$label 有 $(printf '%s\n' "$out" | grep -c .) 条告警"
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

mapfile -t BUILD_SH   < <(git ls-files 'build/*.sh')
mapfile -t RUNTIME_SH < <(git ls-files 'rootfs/*.sh' 'tests/*.sh')

run_group "build/（set -Eeuo pipefail，以 root 跑）" "$EXCLUDE_BUILD"   "${BUILD_SH[@]}"
run_group "rootfs/ + tests/（set -uo pipefail）"     "$EXCLUDE_RUNTIME" "${RUNTIME_SH[@]}"

# ================================================================
# 豁免清单本身也要有人守：豁免掉一整类检查很容易一路加下去，
# 加到最后这条 lint 就只是个摆钩子的地方了。上限拍在这儿，
# 想再加一条就得先在上面写清楚为什么。
check_count() {
  local label="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then ok "$label"; else
    bad "$label（期望 $want，实际 $got）"; fi
}
check_count "build/ 的豁免不超过 1 类" 1 \
            "$(printf '%s' "$EXCLUDE_BUILD"   | tr ',' '\n' | grep -c .)"
check_count "runtime 的豁免不超过 3 类" 3 \
            "$(printf '%s' "$EXCLUDE_RUNTIME" | tr ',' '\n' | grep -c .)"

# ================================================================
printf '\n'
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
