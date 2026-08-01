#!/usr/bin/env bash
#
# 验证 CPU / 内存 / GPU 并发压测这套编排机制本身是真的并发，而不是看起来
# 并发、实际还是排队跑。不需要真的 stress-ng / stressapptest / gpu_burn——
# 用几个只会睡觉的假函数模拟三个压测项，量实际墙钟时间：
#   - 排队跑 3 个各 2 秒的任务 = 6 秒
#   - 并发跑 3 个各 2 秒的任务 = 略高于 2 秒
# 这正是这次改动要验证的东西："10 分钟的测试项应该真的跑满 10 分钟"，
# 而不是被顺序拆分之后每项只分到一小段。
#
# 跑法和 factory-test.sh 里的编排完全一致：
#   ( func args ) & BURN_PIDS+=("$!")
#   progress_bar_concurrent "$total" "标签" "${BURN_PIDS[@]}"
#   wait "${BURN_PIDS[@]}"
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/rootfs/opt/klburn/lib"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

RAW_DIR="$TMP"; RUN_DIR="$TMP"
# shellcheck source=/dev/null
source "$LIB/core.sh"
# progress_bar_concurrent 依赖 $COLS，ui.sh 顶部会自己探测，这里不是真终端
# 也没关系，探测不到就退到默认 80
# shellcheck source=/dev/null
source "$LIB/ui.sh"

PASS=0; FAIL=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n     期望 [%s] 实际 [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }
check(){ [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$2" "$3"; }

# 断言函数名打错不能静悄悄地过去（§11-13"断言悄悄停止计数"的同款病）：
# 本脚本不开 set -e，`xxx: command not found` 只往 stderr 打一行就没了，
# PASS/FAIL 都不动 —— 屏幕照样"全部通过"，只是少跑了几条。实测踩到过一次。
command_not_found_handle() {
  bad "调用了不存在的命令 '$1'（多半是断言函数名打错，这条断言根本没跑）" "已定义的函数" "$1"
  return 127
}

# ================================================================
echo "=== 编排机制本身是否真并发 ==="

fake_stress() {
  local name="$1" secs="$2"
  sleep "$secs"
  touch "$TMP/${name}_done"
}

DURATION=2

start=$(date +%s)
BURN_PIDS=()
( fake_stress cpu "$DURATION" ) & BURN_PIDS+=("$!")
( fake_stress mem "$DURATION" ) & BURN_PIDS+=("$!")
( fake_stress gpu "$DURATION" ) & BURN_PIDS+=("$!")

progress_bar_concurrent "$DURATION" "TEST" "${BURN_PIDS[@]}" >/dev/null
wait "${BURN_PIDS[@]}" 2>/dev/null || true
elapsed=$(( $(date +%s) - start ))

check "cpu 任务确实跑完了" "1" "$([[ -f "$TMP/cpu_done" ]] && echo 1 || echo 0)"
check "mem 任务确实跑完了" "1" "$([[ -f "$TMP/mem_done" ]] && echo 1 || echo 0)"
check "gpu 任务确实跑完了" "1" "$([[ -f "$TMP/gpu_done" ]] && echo 1 || echo 0)"

# 3 个 2 秒任务：排队跑要 ~6 秒，并发跑应该在 2 秒多一点（给调度/进度条轮询
# 留够余量，卡在 5 秒这条线上——明显低于"排队"的 6 秒，明显高于"并发"的 2 秒，
# 用来分辨这两种情况足够了）
check "三个任务应该是并发跑的（墙钟时间明显小于顺序执行的 6 秒），而不是排队跑" \
      "concurrent" "$(if (( elapsed < 5 )); then echo concurrent; else echo sequential; fi)"

# ================================================================
echo
echo "=== progress_bar_concurrent 在任务提前结束时应立刻退出，不多等 ==="
start=$(date +%s)
BURN_PIDS=()
( sleep 1 ) & BURN_PIDS+=("$!")
# 声称总时长 10 秒，但实际 1 秒就跑完了——不该傻等到 10 秒
progress_bar_concurrent 10 "TEST" "${BURN_PIDS[@]}" >/dev/null
wait "${BURN_PIDS[@]}" 2>/dev/null || true
elapsed=$(( $(date +%s) - start ))
check "任务提前结束时进度条应该跟着提前退出（不死等声称的总时长）" \
      "1" "$(if (( elapsed < 5 )); then echo 1; else echo 0; fi)"

# ================================================================
echo
echo "=== 异常退出清理：cleanup() 风格的 kill 应该能打断还在跑的并发任务 ==="
BURN_PIDS=()
( sleep 30 ) & BURN_PIDS+=("$!")
( sleep 30 ) & BURN_PIDS+=("$!")
sleep 0.3
for p in "${BURN_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
sleep 0.3
alive=0
for p in "${BURN_PIDS[@]}"; do kill -0 "$p" 2>/dev/null && alive=$((alive+1)); done
check "kill 掉 BURN_PIDS 之后不该再有存活的子进程（对应 factory-test.sh 的 cleanup trap）" \
      "0" "$alive"

# ---- 孙进程也必须收掉 ----
# 真正干活的 stress-ng / stressapptest / gpu_burn 和采样器都是这些子 shell 的
# 子进程，也就是主脚本的孙进程。只 kill 子 shell 的话它们会被 init 收养继续跑，
# 采样器就一直往那份已经收尾了的 sys_metrics.csv 里追加。
# 这里照抄 factory-test.sh 的 cleanup 写法：先 pkill -P 收孙子，再 kill 儿子。
GRAND_MARK="$TMP/grandchild.pid"
BURN_PIDS=()
(
  ( while :; do sleep 0.2; done ) &          # 模拟采样器：子 shell 的子进程
  echo $! > "$GRAND_MARK"
  wait
) & BURN_PIDS+=("$!")

sleep 1
grand="$(cat "$GRAND_MARK" 2>/dev/null || echo '')"
check "孙进程确实起来了（前提成立，否则这条用例没意义）" \
      "1" "$(if [[ -n "$grand" ]] && kill -0 "$grand" 2>/dev/null; then echo 1; else echo 0; fi)"

for p in "${BURN_PIDS[@]}"; do
  pkill -P "$p" 2>/dev/null || true
  kill "$p"     2>/dev/null || true
done
sleep 1

check "cleanup 之后孙进程也必须死掉（只 kill 子 shell 是收不干净的）" \
      "0" "$(if [[ -n "$grand" ]] && kill -0 "$grand" 2>/dev/null; then echo 1; else echo 0; fi)"

# 守住 cleanup 本身的写法，别哪天又被简化回只 kill 子 shell。
# 要排掉注释行——上面那段解释里也写着 pkill -P，不排的话这条守卫会被
# 自己的文档绊倒（第一次跑就是这么红的）。
FT="$ROOT/rootfs/opt/klburn/factory-test.sh"
check "factory-test.sh 的 cleanup 里必须真的调用 pkill -P（不算注释）" \
      "1" "$(grep -n 'pkill -P' "$FT" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -c .)"

# ================================================================
echo
echo "=== 并发压测期间只能有一个采样器在写 sys_metrics.csv ==="
# 真实事故（0.3.0）：stress_cpu 和 stress_mem 各起一个 monitor_start，
# 两个后台采样进程同时往同一个 sys_metrics.csv 里写。600 秒的测试写出 239 行
# （cpu 120 + mem 119），同一时刻的温度/频率/负载被原样记两遍，
# 报告里的 CPU 曲线每个点都画两次；两个采样器还会抢"文件不存在就写表头"
# 那一步，撞上就是两行表头。而 mem 那份采样根本没人读 ——
# stress_mem 从头到尾没调过 phase_max_temp / phase_min_freq / phase_avg_freq。
#
# declare -f 打出来的函数体不含注释，所以下面数的是真的调用，不会被注释误伤。
# shellcheck source=/dev/null
source "$LIB/stress.sh"

check "stress_cpu 要留着采样器（并发那段的温度/频率靠它）" \
      "1" "$(declare -f stress_cpu | grep -c 'monitor_start')"
check "stress_mem 绝不能再起采样器（会和 CPU 那个撞车，而且没人读）" \
      "0" "$(declare -f stress_mem | grep -c 'monitor_start')"
check "stress_mem 也不该再有 monitor_stop（没起就没得停）" \
      "0" "$(declare -f stress_mem | grep -c 'monitor_stop')"
check "stress_disk 是单独跑的，保留它自己的采样器" \
      "1" "$(declare -f stress_disk | grep -c 'monitor_start')"

# 采样器本身的行为：一行表头、行都带对 phase、停了就真的不再写
RUN_DIR="$TMP/mon"; mkdir -p "$RUN_DIR"
CSV="$RUN_DIR/sys_metrics.csv"
monitor_start "burn"
sleep 3
monitor_stop
rows_after_stop="$(grep -c . "$CSV")"

check "只能有一行表头" "1" "$(grep -c '^time,phase' "$CSV")"
check "采样行的 phase 必须都是 burn" \
      "0" "$(awk -F, 'NR>1 && $2!="burn"' "$CSV" | grep -c .)"
check "至少采到了一行数据" \
      "yes" "$(if (( rows_after_stop > 1 )); then echo yes; else echo no; fi)"

sleep 6      # 采样间隔是 5 秒，停干净了这 6 秒里就不该再多出行
check "monitor_stop 之后采样进程要真的停掉，不能继续往 CSV 里写" \
      "$rows_after_stop" "$(grep -c . "$CSV")"

# ================================================================
echo
echo "=== 盘内没带 gpu_burn 时，GPU 压测结论不能凭空消失 ==="
# 0.3.0 的问题：factory-test.sh 只在 gpu_burn 存在时才把 GPU 放进并发批次，
# 而 gpu_stress 只在那个批次里被调用。于是"驱动认得到卡、但这张盘没带 gpu_burn"
# 时，gpu_stress 根本没被调用过——报告里连一条 stress_gpu 都没有，
# 既不是 PASS 也不是 SKIP，看报告的人根本不知道 GPU 到底测没测。
# shellcheck source=/dev/null
source "$LIB/gpu.sh"

LAST_ID=""; LAST_STATUS=""
result_add() { LAST_ID="$1"; LAST_STATUS="$3"; }
metric_add() { :; }

KLB_TOOLS="$TMP/tools-empty"; mkdir -p "$KLB_TOOLS"    # 故意不往里放 gpu_burn

GPU_USABLE=2
gpu_stress 0 >/dev/null
check "驱动认到卡、但盘内没有 gpu_burn -> 必须留下一条 SKIP" "SKIP" "$LAST_STATUS"
check "而且记的就是 stress_gpu 这一项" "stress_gpu" "$LAST_ID"

GPU_USABLE=0
LAST_ID=""; LAST_STATUS=""
gpu_stress 0 >/dev/null
check "压根没有可用显卡时不重复记结论（gpu_detect 已经记过了）" "" "$LAST_STATUS"

# ================================================================
echo
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
