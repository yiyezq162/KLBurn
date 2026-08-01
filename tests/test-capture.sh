#!/usr/bin/env bash
#
# capture() 的行为回归测试。不需要硬件：
#
#     ./tests/test-capture.sh
#
# 重点守两件事：
#   1. 采集命令超时被 SIGKILL 收掉时，**屏幕上不能冒出 bash 那行
#      "line NN: 1234 Killed timeout --kill-after=10s ..."**。
#      现场看到那行会以为整个测试崩了——实际只是一条留档命令超时，无关大局。
#   2. 超时了要在采集文件里留下 (TIMEOUT ...) 记录 + 屏幕上给一条人看得懂的
#      WARN，不能悄悄咽掉（否则事后根本不知道哪条采集没成）。
#
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../rootfs/opt/klburn/lib" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

RAW_DIR="$TMP/raw"; RUN_DIR="$TMP"
mkdir -p "$RAW_DIR"
# shellcheck source=/dev/null
source "$LIB/core.sh"

PASS=0; FAIL=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n     期望 [%s] 实际 [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }
check(){ [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$2" "$3"; }

# 断言函数名打错不能静悄悄地过去（§11-13"断言悄悄停止计数"的同款病）：
# 本脚本不开 set -e，`xxx: command not found` 只往 stderr 打一行就没了，
# PASS/FAIL 都不动 —— 屏幕照样"全部通过"，只是少跑了几条。实测踩到过一次。
command_not_found_handle() {
  # ⚠️ 这里**不能**写 FAIL=$((FAIL+1))。bash 是在 fork 出来的子进程里执行这个
  #    handler 的，加了也加不到父进程头上 —— 屏幕上红一条，最后那行汇总却还是
  #    "失败 0 项"，正好是本项目最恨的那种"屏幕全绿"。（实测踩过。）
  #    所以直接把整个套件干掉，让退出码非零、run-all 能看见。
  printf "  \033[31mFAIL\033[0m 调用了不存在的命令 %s —— 多半是断言函数名打错了，\n" "$1"
  printf "       这条断言根本没跑。中止本套件。\n"
  kill -TERM $$
  return 127
}

# ================================================================
echo "=== 正常采集 ==="

capture "hello.txt" echo "hello world" >/dev/null 2>&1
check "普通命令的输出应该落进采集文件" \
      "hello world" "$(cat "$RAW_DIR/hello.txt")"

capture "stderr.txt" bash -c 'echo out; echo err >&2' >/dev/null 2>&1
check "stderr 也应该一起收进采集文件（2>&1）" \
      "2" "$(grep -c . "$RAW_DIR/stderr.txt")"

capture "nonexistent.txt" this-command-does-not-exist-xyz >/dev/null 2>&1
rc=$?
check "命令不存在应返回 127" "127" "$rc"
check "命令不存在时文件里要写明原因" \
      "1" "$(grep -c 'command not found' "$RAW_DIR/nonexistent.txt")"

# ================================================================
echo
echo "=== 超时（这是真机上冒出 Killed 那行的场景）==="

# -t 1 + sleep 30：1 秒后 SIGTERM 就能收掉，走 124 分支（快，不用等 11 秒）。
#
# stdout 和 stderr 要分开收：warn() 是往 stdout 打的，而 bash 的子进程死亡报告
# ("... Killed ...") 是往它自己的 stderr 打的 —— 这次修的正是后者。
# 混在一起收就分不清哪条来自哪个流，也就守不住"只该有 WARN、不该有 Killed"。
capture -t 1 "timeout1.txt" sleep 30 >"$TMP/t1.out" 2>"$TMP/t1.err"
rc=$?

check "超时应返回 124（SIGTERM 生效）或 137（要靠 SIGKILL）" \
      "yes" "$(if (( rc == 124 || rc == 137 )); then echo yes; else echo no; fi)"

check "超时要在采集文件里留下 TIMEOUT 记录" \
      "1" "$(grep -c 'TIMEOUT after' "$RAW_DIR/timeout1.txt")"

check "超时要在屏幕上给一条人看得懂的 WARN" \
      "1" "$(grep -c 'capture timed out' "$TMP/t1.out")"

# 下面两条是本次改动的核心：bash 的子进程死亡报告不能漏到屏幕上
check "stderr 上不能出现 bash 的 'Killed' 子进程死亡报告" \
      "0" "$(grep -cE 'Killed|Terminated' "$TMP/t1.err")"
check "stderr 上不能出现 core.sh 的行号报错（那是 bash 报子进程死亡的格式）" \
      "0" "$(grep -c 'core.sh: line' "$TMP/t1.err")"

# ================================================================
echo
echo "=== 被 SIGKILL 收掉（--kill-after 真正生效的场景）==="

# 装个忽略 SIGTERM 的进程，强迫 timeout 走到 --kill-after 的 SIGKILL 那一步。
# capture() 里 --kill-after=10s 是写死的，所以这里要等 ~11 秒，慢但值得测——
# 真机上看到的那行 Killed 正是这条路径产生的。
cat > "$TMP/stubborn.sh" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
sleep 60
EOF
chmod +x "$TMP/stubborn.sh"

echo "  (这条要等约 11 秒，SIGKILL 的宽限期是写死的)"
capture -t 1 "timeout2.txt" "$TMP/stubborn.sh" >"$TMP/t2.out" 2>"$TMP/t2.err"
rc2=$?

check "忽略 SIGTERM 的进程最终应被 SIGKILL 收掉，返回 137" "137" "$rc2"
check "SIGKILL 路径也要留下 TIMEOUT 记录" \
      "1" "$(grep -c 'TIMEOUT after' "$RAW_DIR/timeout2.txt")"
check "SIGKILL 路径下 stderr 同样不能出现 'Killed'（这就是真机上那行的来源）" \
      "0" "$(grep -cE 'Killed|Terminated' "$TMP/t2.err")"
check "SIGKILL 路径下也要给出 WARN" \
      "1" "$(grep -c 'capture timed out' "$TMP/t2.out")"

# ================================================================
echo
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
