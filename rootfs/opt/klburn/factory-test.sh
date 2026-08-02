#!/usr/bin/env bash
#
# KLBurn 出厂老化测试主流程
# 由 klburn.service 在 tty1 上自动拉起。
#
# 故意不用 set -e：单项测试失败必须继续往下跑并落进报告，
# 不能因为一条命令返回非零就整个中断，那样现场什么报告都拿不到。
#
set -uo pipefail

export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/opt/klburn/tools"
export LC_ALL=C

KLB_ROOT="/opt/klburn"

# shellcheck source=lib/core.sh
source "$KLB_ROOT/lib/core.sh"
[[ -f "$KLB_ROOT/klburn.conf" ]] && source "$KLB_ROOT/klburn.conf"
source "$KLB_ROOT/lib/ui.sh"
source "$KLB_ROOT/lib/storage.sh"
source "$KLB_ROOT/lib/collect.sh"
source "$KLB_ROOT/lib/network.sh"
source "$KLB_ROOT/lib/gpu.sh"
source "$KLB_ROOT/lib/stress.sh"
source "$KLB_ROOT/lib/verify.sh"

# ---------------------------------------------------------------- 初始化
# 长测两小时，别让屏幕休眠导致现场看不到进度
setterm -blank 0 -powersave off 2>/dev/null || true
setterm -cursor on 2>/dev/null || true

DISK_SKIP_REASON=""
IPMI_OK=0
DISK_CAND=(); DISK_INFO=(); DISK_EXCLUDED=(); DISK_SMART=()
BURN_PIDS=()

cleanup() {
  monitor_stop 2>/dev/null || true
  gpu_monitor_stop 2>/dev/null || true
  turbostat_stop 2>/dev/null || true
  # 异常退出时也要把内核消息放回控制台，否则收尾菜单那个 shell 是"聋"的
  console_quiet_off 2>/dev/null || true
  # CPU/内存/GPU 压测现在是并发子 shell（见下面的 BURN_PIDS），
  # 异常退出时把它们也收一遍，避免留下孤儿压测进程。
  #
  # 必须先 pkill -P 再 kill：真正干活的进程（stress-ng、stressapptest、gpu_burn）
  # 和采样器都是这些子 shell 的**子进程**，也就是本进程的孙进程。
  # 只 kill 子 shell 的话，孙进程会被 init 收养后继续跑 —— 采样器会一直每 5 秒
  # 往那个已经收尾了的 sys_metrics.csv 里追加，把一份已完成的报告数据搞脏。
  local p
  for p in "${BURN_PIDS[@]:-}"; do
    [[ -n "$p" ]] || continue
    pkill -P "$p" 2>/dev/null || true
    kill "$p"     2>/dev/null || true
  done
}
trap cleanup EXIT

banner
info "KLBurn v${KLBURN_VERSION:-?} (git ${GIT_COMMIT:-unknown})  built ${BUILD_DATE:-?}  base ${BASE_OS:-?}"
info "Kernel: $(uname -r)"

# ---------------------------------------------------------------- 报告落盘位置
section "STEP 1  LOCATE REPORT STORAGE"
if mount_data_partition; then
  :
else
  printf '\n'
  printf '%s' "$C_YEL$C_BLD"
  cat <<'EOF'
  ##############################################################
  #  WARNING: NO USB DATA PARTITION FOUND                      #
  #                                                            #
  #  The report will be written to /tmp only, and WILL BE LOST #
  #  when this machine powers off.                             #
  #                                                            #
  #  Expected: a second partition on the KLBurn USB stick,     #
  #            formatted exFAT, volume label  KLBURN           #
  #                                                            #
  #  To check from another console (Alt+F2, root, no password):#
  #      lsblk -o NAME,SIZE,FSTYPE,LABEL                       #
  #      blkid                                                 #
  #                                                            #
  #  You can still run the test - copy /tmp/klburn-out         #
  #  off the machine before powering down.                     #
  ##############################################################
EOF
  printf '%s\n' "$C_RST"
  sleep 8
fi

# ---------------------------------------------------------------- 联网校时
# 必须在算 RUN_STAMP 之前做：长期存放的机器常见纽扣电池没电，BIOS RTC 回退到
# 乱七八糟的日期，等目录名、meta.json 时间戳都写死了才发现就晚了。
# 连不上网（现场大多数情况本来就是离线的）就放弃，继续用现有 RTC 时间。
section "NETWORK TIME SYNC (best-effort)"
CLOCK_SYNCED=1
try_sync_clock_via_network || CLOCK_SYNCED=0

# ---------------------------------------------------------------- 建立本次运行目录
SERIAL="$(get_serial)"
RUN_STAMP="$(date '+%Y%m%d_%H%M%S')"
# 文件名格式：日期_时间_CPU_内存，例如
#   20260730_110512_2x-Intel-Xeon-Gold-6430_512GB
MACHINE_TAG="$(get_machine_tag "$RUN_STAMP")"
# 报告和原始数据全部放进同一个以 MACHINE_TAG 命名的文件夹里，
# out\ 根目录下不再直接堆 .html 文件——U 盘反复插不同机器测下来，
# 历史记录一多，散落的文件会很难找。

# 目录重名要避开，不能直接覆盖。
#
# 现场实证：那台机器纽扣电池没电，RTC 每次开机都回退到**完全相同**的时间点，
# 连测两次得到的 MACHINE_TAG 一模一样（20251126_021640_...），
# 第二次直接把第一次的报告和原始数据整个盖掉了 —— 对比两次结果时才发现少了一份。
# 时间戳不可靠的机器上这不是小概率事件，是必然。
RUN_DIR="$RESULT_ROOT/$MACHINE_TAG"
if [[ -e "$RUN_DIR" ]]; then
  dup=2
  while [[ -e "${RUN_DIR}_$(printf '%02d' "$dup")" ]] && (( dup < 100 )); do
    dup=$(( dup + 1 ))
  done
  MACHINE_TAG="${MACHINE_TAG}_$(printf '%02d' "$dup")"
  RUN_DIR="$RESULT_ROOT/$MACHINE_TAG"
  warn "A run folder with the same name already exists (RTC time may be stuck)."
  warn "Using $MACHINE_TAG instead - the previous run is NOT overwritten."
fi
RAW_DIR="$RUN_DIR/raw"
REPORT_HTML="$RUN_DIR/${MACHINE_TAG}.html"
mkdir -p "$RAW_DIR"
log_attach "$RUN_DIR/klburn.log"

# 校时那一步跑在 RUN_DIR 建立之前，日志只能先落 /tmp，现在搬进来存证。
# 以后再遇到"时间不对"，报告里直接就有 chronyd 的原话，不用靠猜。
if [[ -f /tmp/klburn-clocksync.log ]]; then
  mv /tmp/klburn-clocksync.log "$RAW_DIR/clock-sync.log" 2>/dev/null || true
fi

info "Serial      : $SERIAL"
info "Machine     : $MACHINE_TAG"
info "Report      : $REPORT_HTML"
if [[ "${DATA_OK:-0}" != "1" ]]; then
  warn "Report will NOT survive power-off (no USB data partition)."
fi

# 时钟没网络对时，写进报告让人知道时间可能不准。
#
# 只判"年份早于 2024"抓不到实际遇到的情况：现场机器 RTC 停在 2025-11，
# 而这张介质是 2026-07 构建的，报告抬头就写了个八个月前的日期，一眼就看出不对。
# 测试时间比介质的构建时间还早，一定是 RTC 不准 —— 这条判据比写死年份可靠。
CLOCK_SUSPECT=0
if [[ "$(date +%Y)" -lt 2024 ]]; then
  CLOCK_SUSPECT=1
  warn "System clock looks wrong ($(date)). Report timestamps may be off."
else
  build_epoch="$(date -d "${BUILD_DATE:-}" +%s 2>/dev/null || true)"
  if [[ "$build_epoch" =~ ^[0-9]+$ ]] && (( $(date +%s) < build_epoch )); then
    CLOCK_SUSPECT=1
    warn "System clock ($(date '+%F %T')) is EARLIER than this media's build date (${BUILD_DATE})."
    warn "Fix the date/time in BIOS - report timestamps will be wrong."
  fi
fi

# ---------------------------------------------------------------- 选时长
select_duration

# ---------------------------------------------------------------- 采集
scan_disks
collect_all

# ---------------------------------------------------------------- 配置核对
# 采集完、压测开始前，先让现场把"这台机器到底装了什么"过一遍。
#
# 以前这些只有出报告才看得到 —— 少一条内存、少一张网卡、少一块盘，
# 要等三十分钟压测跑完才发现，白等一轮。
#
# 60 秒倒计时、按任意键立即继续、超时自动继续。**绝不能卡住流程**：
# 现场最怕的就是插上去没反应，那会让人直接断电重来。
config_review 60

# ---------------------------------------------------------------- 破坏性写确认
DISK_CONFIRMED=0
if (( ${#DISK_CAND[@]} > 0 )); then
  if confirm_disk_write 120; then
    DISK_CONFIRMED=1
  fi
else
  DISK_SKIP_REASON="未发现可进行读写压力测试的本机硬盘（系统正在使用的磁盘不参与破坏性测试）"
fi

# ---------------------------------------------------------------- 时间分配
# CPU / 内存 / GPU 并发跑，各自独立压满对应子系统，互不抢这段时间——
# 三者都直接拿满用户选的总时长，不再按比例切开揉碎。以前"10 分钟"里 CPU
# 只分到 5 分钟，名不副实；并发之后选多长就该测多长。
#
# 硬盘单独测：fio 裸盘读写要是跟 CPU/内存满载凑在一起，出来的带宽/IOPS
# 数字会被 CPU 争用扭曲，没有参考价值，所以不拿来并发。它单独占一段时间，
# 跑在并发阶段结束之后，不从 CPU/内存/GPU 那份时间里扣。
gpu_will_run=0
if (( GPU_USABLE > 0 )) && [[ -x "$KLB_TOOLS/gpu_burn" ]]; then
  gpu_will_run=1
fi

CPU_SECS=$DURATION_SECONDS
MEM_SECS=$DURATION_SECONDS
if (( gpu_will_run )); then
  GPU_SECS=$DURATION_SECONDS
else
  GPU_SECS=0
fi
if (( DISK_CONFIRMED == 1 )); then
  DSK_SECS=$(( DURATION_SECONDS * 30 / 100 ))
else
  DSK_SECS=0
fi

TEST_START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
TEST_START_EPOCH="$(date +%s)"

burn_label="CPU + MEMORY"
(( gpu_will_run )) && burn_label="$burn_label + GPU"
info "Time budget: $burn_label concurrently for $(fmt_dur "$DURATION_SECONDS")$(
  (( DISK_CONFIRMED == 1 )) && printf '; DISK separately for %s' "$(fmt_dur "$DSK_SECS")")"

# ---------------------------------------------------------------- 压测：CPU / 内存 / GPU 并发
stress_init

# 仪表盘是"每 2 秒清屏 + 整屏重画"，前提是只有它一个人在往控制台上写。
# 压测子进程的输出早就全部重定向进日志文件了，剩下的写入源就是内核 ——
# PCIe AER / EDAC / nvme reset 这类消息会在压测期间随时插进来把面板顶花。
# 只压 console 的 loglevel，ring buffer 一个字都不少（dmesg 采集和 OOM
# 判定读的都是 ring buffer）。压测全部结束后原样恢复。
console_quiet_on

# 逐核频率/温度/功耗的采样。只留档不判定，起不来就当没有（见 stress.sh）。
turbostat_start

section "PHASE 2/4  BURN-IN: $burn_label CONCURRENTLY  ($(fmt_dur "$DURATION_SECONDS"))"

BURN_PIDS=()
( stress_cpu "$CPU_SECS" ) & BURN_PIDS+=("$!")
( stress_mem "$MEM_SECS" ) & BURN_PIDS+=("$!")
if (( gpu_will_run )); then
  ( gpu_stress "$GPU_SECS" ) & BURN_PIDS+=("$!")
fi

# 传的是"这一轮在压什么"（CPU + MEMORY + GPU），不是阶段名 ——
# 阶段名由 dash_burn 自己加，右上角放的是档位。
progress_bar_concurrent "$DURATION_SECONDS" "$burn_label" "${BURN_PIDS[@]}"
wait "${BURN_PIDS[@]}" 2>/dev/null || true

# ---------------------------------------------------------------- 压测：硬盘（单独跑，不并发）
if (( DISK_CONFIRMED == 1 )); then
  stress_disk "$DSK_SECS"
else
  stress_disk_skipped "${DISK_SKIP_REASON:-未确认}"
fi

# ---------------------------------------------------------------- 压测：GPU 缺工具的情况
# 驱动认得到卡、但这张盘里没带 gpu_burn 时，上面的并发批次里根本没有 GPU
# （gpu_will_run=0），必须在这里显式补一次调用，让 gpu_stress 把那条 SKIP 记下来。
# 否则报告里 "GPU 压力测试" 这一项会整个消失 —— 既不是 PASS 也不是 SKIP，
# 看报告的人根本不知道 GPU 到底测没测。
if (( gpu_will_run == 0 && GPU_USABLE > 0 )); then
  gpu_stress 0
fi

turbostat_stop
# 仪表盘到此为止，把内核消息放回控制台 —— 后面复查/出报告阶段本来就是
# 正常滚动输出，而且这时候真出了内核错误，现场应该第一时间看见。
console_quiet_off

TEST_END_TS="$(date '+%Y-%m-%d %H:%M:%S')"
TEST_ELAPSED=$(( $(date +%s) - TEST_START_EPOCH ))

# ---------------------------------------------------------------- 复查
verify_all

# ---------------------------------------------------------------- 元数据
# disk_tested 必须是"真的被 fio 写过的盘"，不是"候选盘"。
# 以前这里无条件写 DISK_CAND，结果现场明明跳过了硬盘压测，报告 1.4 表格里
# "本次压测"那一列还是显示"是"，和下面 stress_disk 的 SKIP 自相矛盾。
DISK_TESTED_LIST=""
if (( DISK_CONFIRMED == 1 )); then
  DISK_TESTED_LIST="$(printf '%s ' "${DISK_CAND[@]:-}" | sed 's/ $//')"
fi

cat > "$RUN_DIR/meta.json" <<EOF
{
  "klburn_version": "${KLBURN_VERSION:-}",
  "git_commit":     "${GIT_COMMIT:-unknown}",
  "company_name":   "${COMPANY_NAME:-}",
  "report_title":   "${REPORT_TITLE:-服务器出厂老化测试报告}",
  "product_name":   "${PRODUCT_NAME:-KLBurn}",
  "base_os":        "${BASE_OS:-}",
  "build_date":     "${BUILD_DATE:-}",
  "include_nvidia": "${INCLUDE_NVIDIA:-0}",
  "nvidia_version": "${NVIDIA_VERSION:-}",
  "gpu_present":    ${GPU_PRESENT:-0},
  "gpu_usable":     ${GPU_USABLE:-0},
  "gpu_mismatch":   ${GPU_MISMATCH:-0},
  "storcli_present": $( [[ -x "$KLB_TOOLS/storcli64" ]] && echo 1 || echo 0 ),
  "gpu_burn_present": $( [[ -x "$KLB_TOOLS/gpu_burn" ]] && echo 1 || echo 0 ),
  "serial":         "${SERIAL}",
  "run_stamp":      "${RUN_STAMP}",
  "machine_tag":    "${MACHINE_TAG}",
  "profile":        "${DURATION_PROFILE}",
  "planned_secs":   ${DURATION_SECONDS},
  "elapsed_secs":   ${TEST_ELAPSED},
  "start_time":     "${TEST_START_TS}",
  "end_time":       "${TEST_END_TS}",
  "kernel":         "$(uname -r)",
  "budget": {
    "cpu_secs": ${CPU_SECS}, "mem_secs": ${MEM_SECS},
    "disk_secs": ${DSK_SECS}, "gpu_secs": ${GPU_SECS}
  },
  "disk_tested":    "${DISK_TESTED_LIST}",
  "disk_confirmed": ${DISK_CONFIRMED},
  "thresholds": {
    "cpu_temp_warn":  ${CPU_TEMP_WARN},  "cpu_temp_fail":  ${CPU_TEMP_FAIL},
    "gpu_temp_warn":  ${GPU_TEMP_WARN},  "gpu_temp_fail":  ${GPU_TEMP_FAIL},
    "disk_temp_warn": ${DISK_TEMP_WARN}, "disk_temp_fail": ${DISK_TEMP_FAIL}
  },
  "data_partition": "${DATA_DEV:-none}",
  "clock_synced":   ${CLOCK_SYNCED},
  "clock_suspect":  ${CLOCK_SUSPECT}
}
EOF

# ---------------------------------------------------------------- 出报告
section "GENERATING REPORT"
# 报告 HTML 和原始数据现在都在同一个 MACHINE_TAG 文件夹里（out/ 根目录不再
# 直接堆散的 .html 文件），所以不需要再额外拷一份到子目录——它本来就在里面。
if python3 "$KLB_ROOT/report/generate_report.py" \
     --run-dir "$RUN_DIR" --out "$REPORT_HTML" 2>&1 | tee -a "$MAIN_LOG"; then
  ok "Report written: $REPORT_HTML"
else
  fail "Report generator failed - raw logs are still in $RUN_DIR/raw/"
fi

# 内部工程报告：落在 raw/ 里，**不交付**。
# 它比上面那份详细得多（硬盘通电时间、逐颗 CPU 温差、我们这轮采集的缺口、
# 源码 commit……），是我们自己复盘和日后追溯用的。
#
# 放 raw/ 里是防手滑：客户要的是那个和目录同名的 .html，raw/ 整个目录不外发。
#
# 它失败了绝不能影响上面已经生成好的客户报告，所以单独一条、只警告不中断。
INTERNAL_HTML="$RAW_DIR/INTERNAL_${MACHINE_TAG}.html"
if python3 "$KLB_ROOT/report/generate_internal.py" \
     --run-dir "$RUN_DIR" --out "$INTERNAL_HTML" 2>&1 | tee -a "$MAIN_LOG"; then
  ok "Internal engineering report: $INTERNAL_HTML"
else
  warn "Internal engineering report failed (customer report is unaffected)."
fi

sync

# ---------------------------------------------------------------- 总结
# 整机结论只看有没有 FAIL。
#
# 这里必须走 jq 解析，不能拿 grep 匹配 JSON 文本：一号不变量就是"不要用关键字
# 匹配做判定"，而这是全程最不该出错的一次判定 —— 判错方向就是把坏机器放出厂。
# 文本匹配依赖 jq -cn 的输出恰好没有空格（`"status":"FAIL"`），格式一变就永远
# 匹配不上，而且不会有任何报错，表现是每台机器都显示绿色 PASS。
# 报告生成器那边本来就是解析 JSON 判的，这里跟它走同一条路，两边不会打架。
OVERALL="PASS"
if jq -e -s 'any(.[]; .status == "FAIL")' "$RUN_DIR/results.jsonl" >/dev/null 2>&1; then
  OVERALL="FAIL"
fi

# 一条判定都没有 != 全都通过。
#
# results.jsonl 为空 / 读不出来 / 解析不了（采集阶段就崩了、U 盘写满了、
# 进程被收掉），上面那句 jq 会返回非零，OVERALL 就停在 PASS —— 一台什么都
# 没测过的机器打出绿色大字，现场没有任何理由怀疑它。判不出来就得说判不出来。
#
# 报告生成器那边是同一条规矩，两边不会打架。
if ! jq -e -s 'length > 0' "$RUN_DIR/results.jsonl" >/dev/null 2>&1; then
  OVERALL="FAIL"
  NO_RESULTS=1
  warn "No test results were recorded - this run is INVALID."
  warn "The machine was NOT evaluated. Re-test; do not ship on this report."
fi

verdict_banner "$OVERALL"

# 大字之后再说一次原因：这个 FAIL 说的是"这轮测试作废"，不是"这台机器坏了"。
# 只在上面 warn 一次的话，出报告那几行一滚就看不见了，现场会照着 FAIL 去查硬件。
if (( ${NO_RESULTS:-0} == 1 )); then
  printf '  %sThis FAIL means the RUN is invalid, not that the hardware is bad.%s\n' \
    "$C_YEL$C_BLD" "$C_RST"
  printf '  %sNothing was evaluated. Check %s/klburn.log, then run the test again ([t]).%s\n' \
    "$C_YEL" "$RUN_DIR" "$C_RST"
fi

hr
printf '  Serial      : %s\n' "$SERIAL"
printf '  Profile     : %s (%s)\n' "$DURATION_PROFILE" "$(fmt_dur "$TEST_ELAPSED")"
printf '  Report      : %s\n' "$REPORT_HTML"
printf '  Raw data    : %s/\n' "$RUN_DIR"
# 屏幕上明确区分这两份，免得现场把内部那份一起发出去
printf '  %sInternal    : raw/INTERNAL_%s.html  (engineering copy - do NOT send out)%s\n' \
  "$C_YEL" "$MACHINE_TAG" "$C_RST"
if [[ "${DATA_OK:-0}" == "1" ]]; then
  printf '  Storage     : %sUSB stick, folder  out\\  - safe to power off%s\n' "$C_GRN" "$C_RST"
else
  printf '  Storage     : %s/tmp ONLY - COPY IT OUT BEFORE POWER OFF%s\n' "$C_RED$C_BLD" "$C_RST"
fi
hr
printf '\n'
# 二十几行状态，黑白一片时要逐行读才找得到那条 FAIL。上色之后一眼就跳出来。
# 颜色码交给 jq 拼进去（--arg 传进去的是 core.sh 那几个变量，
# 不是 tty 的时候它们是空串，输出自动退回纯文本）。
printf '  Per-item results:\n'
jq -r --arg p "$C_GRN" --arg f "$C_RED$C_BLD" --arg w "$C_YEL" --arg s "$C_GRY" --arg r "$C_RST" \
   '"    " + (if   .status == "PASS" then $p + "[PASS]" + $r
              elif .status == "FAIL" then $f + "[FAIL]" + $r
              elif .status == "SKIP" then $s + "[SKIP]" + $r
              else                        $w + "[WARN]" + $r end) + " " + .id' \
   "$RUN_DIR/results.jsonl" 2>/dev/null || true
printf '\n'

unmount_data_partition

# ---------------------------------------------------------------- 收尾菜单
hr
printf '  %s[r]%s reboot    %s[p]%s power off    %s[s]%s shell (debug)    %s[t]%s run test again\n' \
  "$C_BLD" "$C_RST" "$C_BLD" "$C_RST" "$C_BLD" "$C_RST" "$C_BLD" "$C_RST"
hr
while :; do
  printf '  Choice > '
  read -r -n 1 key
  printf '\n'
  case "$key" in
    r|R) systemctl reboot; exit 0 ;;
    p|P) systemctl poweroff; exit 0 ;;
    s|S) printf '  Dropping to shell. Type "exit" to return.\n'; /bin/bash -i ;;
    t|T) exec "$0" ;;
    *)   printf '  Unknown option.\n' ;;
  esac
done
