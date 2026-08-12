#!/usr/bin/env bash
#
# KLBurn 内存专用测试主流程（KLBURN_EDITION=mem 的盘由 klburn.service 拉起）
#
# 和整机盘 factory-test.sh 的关系：**共用全部 lib，不共用流程。**
# 判定四态、报告红线、日志判读那些规矩一条不改；砍掉的是"跑什么"。
#
# ================================================================
# 这张盘只干三件事，开机后**一个问题都不问**：
#
#   1. 读内存 —— 逐条的槽位 / 厂商 / 型号(PN) / **序列号** / 容量 / 类型 / 频率
#   2. 验内存 —— 一段固定时长的压测（默认 150 秒）+ ECC 计数 + 内核日志
#   3. 出报告 —— 一份只谈内存的 HTML/PDF + 一份能拼总表的 CSV
#
# 不选范围、不选时长、不问擦盘确认（它一个字节都不往硬盘上写）。
# 不采网卡/PCIe/硬盘/阵列卡/显卡/BMC —— 被测平台上这些可能压根没有。
# 网卡**只**用来联网校时，它的任何信息都不进报告。
#
# 故意不用 set -e，理由和 factory-test.sh 一样：单项失败必须继续往下跑
# 并落进报告，不能因为一条命令返回非零就什么报告都拿不到。
#
set -uo pipefail

export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/opt/klburn/tools"
export LC_ALL=C

KLB_ROOT="/opt/klburn"

# shellcheck source=lib/core.sh
source "$KLB_ROOT/lib/core.sh"
[[ -f "$KLB_ROOT/klburn.conf" ]] && source "$KLB_ROOT/klburn.conf"
# ⚠️ **必须在 source ui.sh 之前设。** ui.sh 里是 `: "${BRAND_TAGLINE:=...}"`，
#    设晚了就顶不掉它的默认值。
#
#    这一行是开机第一屏的抬头，而现场那块屏经常被拍照发群里。默认值是
#    「Server Factory Burn-in Test」—— 一张只测内存的盘顶着这句话，
#    就是在说一件它没做过的事（和"报告不许看起来像整机验收过了"同一条红线，
#    只是搬到了屏幕上）。1.10.0 第一次出盘就是这样，看截图才发现的。
BRAND_TAGLINE="Memory-Only Test"
source "$KLB_ROOT/lib/ui.sh"
source "$KLB_ROOT/lib/storage.sh"
# collect.sh：要的是 capture 之外的 check_memory_capacity / ecc_snapshot /
# collect_counters。整份 source 进来没有副作用（都是函数定义），
# 但**下面一条 collect_all 都不会调** —— 那才是砍掉一堆采集的地方。
source "$KLB_ROOT/lib/collect.sh"
# network.sh：只为了 try_sync_clock_via_network。
source "$KLB_ROOT/lib/network.sh"
# conformance.sh：只为了 dmi_dimm_field / check_dimm_uniform（内存条一致性）。
source "$KLB_ROOT/lib/conformance.sh"
source "$KLB_ROOT/lib/stress.sh"
source "$KLB_ROOT/lib/verify.sh"
source "$KLB_ROOT/lib/memcheck.sh"

# ---------------------------------------------------------------- 初始化
setterm -blank 0 -powersave off 2>/dev/null || true
setterm -cursor on 2>/dev/null || true

BURN_PID=""
cleanup() {
  # 压测进程是本进程的子进程，真正干活的 stressapptest 是它的孙进程 ——
  # 只 kill 子进程的话孙进程会被 init 收养后继续跑（factory-test.sh 里
  # BURN_PIDS 那段同款问题），所以先 pkill -P 再 kill。
  if [[ -n "$BURN_PID" ]]; then
    pkill -P "$BURN_PID" 2>/dev/null || true
    kill "$BURN_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

banner
info "KLBurn MEMORY EDITION v${KLBURN_VERSION:-?} (git ${GIT_COMMIT:-unknown})  built ${BUILD_DATE:-?}"
info "Kernel: $(uname -r)"
printf '  %sMemory-only test. No menus - the test starts by itself.%s\n' "$C_CYN" "$C_RST"
printf '  %sNothing is written to any hard disk.%s\n' "$C_CYN" "$C_RST"

# 压测时长：构建时钉进 klburn.conf，现场不问。
: "${MEM_BURN_SECONDS:=150}"
[[ "$MEM_BURN_SECONDS" =~ ^[0-9]+$ ]] && (( MEM_BURN_SECONDS > 0 )) || MEM_BURN_SECONDS=150

# ---------------------------------------------------------------- 报告落盘位置
section "STEP 1  LOCATE REPORT STORAGE"
if ! mount_data_partition; then
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
  #  You can still run the test - copy /tmp/klburn-out         #
  #  off the machine before powering down.                     #
  ##############################################################
EOF
  printf '%s\n' "$C_RST"
  sleep 6
fi

# ---------------------------------------------------------------- 联网校时
# 必须排在算目录名之前：目录名里带日期，等目录建好了才发现 RTC 不准就晚了。
# 接了网线就顺手校一下，没网就用 BIOS 的 RTC 继续跑 —— 校时**不影响任何判定**，
# 也不产生任何和网卡有关的结论行。
section "STEP 2  NETWORK TIME SYNC (best-effort, no network is fine)"
CLOCK_SYNCED=1
try_sync_clock_via_network || CLOCK_SYNCED=0

# ---------------------------------------------------------------- 建立运行目录
SERIAL="$(get_serial)"
RUN_STAMP="$(date '+%Y%m%d_%H%M%S')"
# 用户指定的格式：内存测试_日期_内存容量_CPU
MACHINE_TAG="$(mem_run_tag "$RUN_STAMP")"

# 目录重名要避开，绝不覆盖。纽扣电池没电的机器每次开机 RTC 都回退到同一个
# 时间点，连测两次会撞名 —— 整机盘上真实发生过，第二次把第一次整个盖掉了。
RUN_DIR="$RESULT_ROOT/$MACHINE_TAG"
if [[ -e "$RUN_DIR" ]]; then
  dup=2
  while [[ -e "${RUN_DIR}_$(printf '%02d' "$dup")" ]] && (( dup < 100 )); do
    dup=$(( dup + 1 ))
  done
  MACHINE_TAG="${MACHINE_TAG}_$(printf '%02d' "$dup")"
  RUN_DIR="$RESULT_ROOT/$MACHINE_TAG"
  warn "A run folder with the same name already exists (RTC time may be stuck)."
  warn "Using a numbered suffix instead - the previous run is NOT overwritten."
fi
RAW_DIR="$RUN_DIR/raw"
REPORT_HTML="$RUN_DIR/${MACHINE_TAG}.html"
mkdir -p "$RAW_DIR"
log_attach "$RUN_DIR/klburn.log"

if [[ -f /tmp/klburn-clocksync.log ]]; then
  mv /tmp/klburn-clocksync.log "$RAW_DIR/clock-sync.log" 2>/dev/null || true
fi

# ⚠️ 目录名带中文前缀，Linux 文本控制台打不出中文（会显示成方块）。
#    所以屏幕上打的是**过滤掉非 ASCII 之后**的那一段 —— 日期/容量/CPU 都在，
#    足以对上是哪一次；U 盘插到 Windows 上看到的是完整的中文目录名。
#    直接打原串的话，现场看到的是一行 ◆◆◆◆，反而更糊涂。
info "Serial   : $SERIAL"
info "Folder   : ...$(ascii_clean "$MACHINE_TAG")   (Chinese prefix shown correctly on Windows)"
info "Burn-in  : $(fmt_dur "$MEM_BURN_SECONDS") (fixed, set at build time)"
if [[ "${DATA_OK:-0}" != "1" ]]; then
  warn "Report will NOT survive power-off (no USB data partition)."
fi

# 时钟可信度。和整机盘同一条判据：测试时间比这张介质的构建时间还早，
# 一定是 RTC 不准（只判"年份早于 2024"抓不到实际遇到的情况）。
CLOCK_SUSPECT=0
if [[ "$(date +%Y)" -lt 2024 ]]; then
  CLOCK_SUSPECT=1
  warn "System clock looks wrong ($(date)). Report timestamps may be off."
else
  build_epoch="$(date -d "${BUILD_DATE:-}" +%s 2>/dev/null || true)"
  if [[ "$build_epoch" =~ ^[0-9]+$ ]] && (( $(date +%s) < build_epoch )); then
    CLOCK_SUSPECT=1
    warn "System clock ($(date '+%F %T')) is EARLIER than this media's build date."
    warn "Fix the date/time in BIOS - report timestamps will be wrong."
  fi
fi

# ---------------------------------------------------------------- 采集
section "PHASE 1/3  MEMORY INVENTORY"
mem_collect

# 一条内存都没读出来 = 这一轮什么都测不成，直接跳到出报告。
# （FAIL 的含义是"本轮作废"，不是"这台机器坏了"——文案里写死了这句话。）
MEM_ABORT=0
if ! mem_require_dimms; then
  MEM_ABORT=1
  printf '\n'
  printf '%s' "$C_RED$C_BLD"
  cat <<'EOF'
  ##############################################################
  #  NO MEMORY DETAIL COULD BE READ FROM THIS BOARD            #
  #                                                            #
  #  The BIOS did not report any populated memory slot, so     #
  #  there is nothing to test or to list.                      #
  #                                                            #
  #  The run STOPS here and is marked FAIL.                    #
  #  This does NOT mean the memory is faulty - it means we     #
  #  could not read it. Re-test, or try another machine.       #
  ##############################################################
EOF
  printf '%s\n' "$C_RST"
  sleep 5
fi

if (( MEM_ABORT == 0 )); then
  # 装机容量 vs 系统识别容量。少一条内存 = 少一份钱，而压测只会去压系统
  # 认到的那部分，压不出来 —— 这一条在内存专用盘上比在整机盘上还要紧。
  check_memory_capacity
  # 混插核对（厂商 / 颗粒型号 / 运行频率）。判 WARN，不判 FAIL：
  # 混插是配置问题，不是内存坏了。
  check_dimm_uniform
  # 序列号核对 —— 查假条子。**重复的序列号判 FAIL**，理由见 memcheck.sh
  # 里那一大段：序列号写在条子自己的芯片里、厂商唯一分配，
  # 两条正品撞不到一起。这条不用等压测就能判死。
  check_dimm_serial
  # SPD 整片比对 —— 比序列号重复还硬的一条：两条内存芯片里的出厂记录
  # 逐字节完全相同 = 整片被克隆过。读不到 SPD 的平台上判 SKIP，不影响结论。
  check_spd_clone

  # 压测前的基线。ECC 计数和内核日志都要"前后差值"才有意义。
  collect_counters "pre"
  capture -t 30 "dmesg-pre.txt" dmesg -T
  mem_verify_dmesg_boot
fi

# ---------------------------------------------------------------- 压测
TEST_START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
TEST_START_EPOCH="$(date +%s)"

if (( MEM_ABORT == 0 )); then
  section "PHASE 2/3  MEMORY BURN-IN  ($(fmt_dur "$MEM_BURN_SECONDS"))"
  stress_init
  # 压测跑在子 shell 里，前台每 10 秒追加打印一行进度。
  # stress_mem 自己会算测试容量、处理 OOM、把数字抠出来判定 ——
  # 整机盘用的是同一个函数，判定口径一模一样。
  ( stress_mem "$MEM_BURN_SECONDS" ) &
  BURN_PID=$!
  mem_progress "$BURN_PID" "$MEM_BURN_SECONDS"
  wait "$BURN_PID" 2>/dev/null || true
  BURN_PID=""
fi

TEST_END_TS="$(date '+%Y-%m-%d %H:%M:%S')"
TEST_ELAPSED=$(( $(date +%s) - TEST_START_EPOCH ))

# ---------------------------------------------------------------- 复查
if (( MEM_ABORT == 0 )); then
  section "PHASE 3/3  POST-TEST CHECK"
  collect_counters "post"
  capture -t 30 "dmesg-post.txt" dmesg -T
  # 压测前后的逐条 DIMM ECC 差值。这是"内存开始退化"最直接的证据，
  # 也是这张盘最有价值的一条判定。
  verify_ecc
  # 只看内存那一族的内核错误，不扫 PCIe/硬盘/显卡（这台机器上可能没有）。
  mem_verify_dmesg
fi

# ---------------------------------------------------------------- 元数据
cat > "$RUN_DIR/meta.json" <<EOF
{
  "klburn_version": "${KLBURN_VERSION:-}",
  "klburn_edition": "mem",
  "git_commit":     "${GIT_COMMIT:-unknown}",
  "company_name":   "${COMPANY_NAME:-}",
  "report_title":   "${REPORT_TITLE:-内存专用测试报告}",
  "product_name":   "${PRODUCT_NAME:-KLBurn-MEM}",
  "base_os":        "${BASE_OS:-}",
  "build_date":     "${BUILD_DATE:-}",
  "serial":         "${SERIAL}",
  "run_stamp":      "${RUN_STAMP}",
  "machine_tag":    "${MACHINE_TAG}",
  "planned_secs":   ${MEM_BURN_SECONDS},
  "elapsed_secs":   ${TEST_ELAPSED},
  "start_time":     "${TEST_START_TS}",
  "end_time":       "${TEST_END_TS}",
  "kernel":         "$(uname -r)",
  "data_partition": "${DATA_DEV:-none}",
  "clock_synced":   ${CLOCK_SYNCED},
  "clock_suspect":  ${CLOCK_SUSPECT},
  "clock_source":   "${CLOCK_SOURCE:-rtc}"
}
EOF

# ---------------------------------------------------------------- 出报告
section "GENERATING REPORT"
if python3 "$KLB_ROOT/report/generate_mem_report.py" \
     --run-dir "$RUN_DIR" --out "$REPORT_HTML" 2>&1 | tee -a "$MAIN_LOG"; then
  ok "Report written"
else
  fail "Report generator failed - raw data is still in the run folder"
fi

# 工程文件：一条内存一行的 CSV，主板信息在每行重复。
# 多台机器的 CSV 首尾相接就能拼成一张总表，按 SN 排序坏的那批立刻聚到一起。
MEM_CSV="$RUN_DIR/${MACHINE_TAG}.csv"
if mem_export_csv "$MEM_CSV" && [[ -s "$MEM_CSV" ]]; then
  ok "Memory list (CSV): $(ascii_clean "$(basename "$MEM_CSV")")"
else
  warn "CSV export failed (the HTML report is unaffected)."
fi

# PDF 是纯附加，失败绝不能影响已经生成好的 HTML。
if [[ -f "$REPORT_HTML" ]] && have weasyprint; then
  if timeout 300 weasyprint "$REPORT_HTML" "${REPORT_HTML%.html}.pdf" >/dev/null 2>&1 \
     && [[ -s "${REPORT_HTML%.html}.pdf" ]]; then
    ok "Report PDF written"
  else
    warn "PDF conversion failed - the HTML report is unaffected."
    rm -f "${REPORT_HTML%.html}.pdf" 2>/dev/null || true
  fi
fi

sync

# ---------------------------------------------------------------- 总结
#
# 整机结论只看有没有 FAIL，而且**一条判定都没有不算通过** ——
# 和整机盘同一条规矩，走 jq 解析 JSON，不做文本匹配（一号不变量）。
OVERALL="PASS"
if jq -e -s 'any(.[]; .status == "FAIL")' "$RUN_DIR/results.jsonl" >/dev/null 2>&1; then
  OVERALL="FAIL"
fi
if ! jq -e -s 'length > 0' "$RUN_DIR/results.jsonl" >/dev/null 2>&1; then
  OVERALL="FAIL"
  NO_RESULTS=1
  warn "No test results were recorded - this run is INVALID."
fi

brand_bar "$(panel_width)" "MEMORY TEST COMPLETE"
# 第二个参数传 mem：这不是"仅导出报告"那一档，真压过，所以该出 PASS 大字。
verdict_banner "$OVERALL" "mem"

if (( ${NO_RESULTS:-0} == 1 || MEM_ABORT == 1 )); then
  printf '  %sThis FAIL means the RUN is invalid, not that the memory is bad.%s\n' \
    "$C_YEL$C_BLD" "$C_RST"
fi

hr
printf '  Serial      : %s\n' "$SERIAL"
printf '  Modules     : %s installed\n' "$(mem_dimm_count)"
printf '  Burn-in     : %s\n' "$(fmt_dur "$TEST_ELAPSED")"
printf '  Folder      : %s\n' "$(ascii_clean "$MACHINE_TAG")"
printf '  Files       : .html  .pdf  .csv   (+ raw\\ )\n'
if [[ "${DATA_OK:-0}" == "1" ]]; then
  printf '  Storage     : %sUSB stick, folder  out\\  - safe to power off%s\n' "$C_GRN" "$C_RST"
else
  printf '  Storage     : %s/tmp ONLY - COPY IT OUT BEFORE POWER OFF%s\n' "$C_RED$C_BLD" "$C_RST"
fi
hr
printf '\n'
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
# 这张盘的典型用法是"一台接一台地插过去测"，所以 [t] 再测一次排在最前面说。
hr
printf '  %s[t]%s test again    %s[r]%s reboot    %s[p]%s power off    %s[s]%s shell (debug)\n' \
  "$C_BLD" "$C_RST" "$C_BLD" "$C_RST" "$C_BLD" "$C_RST" "$C_BLD" "$C_RST"
hr
while :; do
  printf '  Choice > '
  read -r -n 1 key
  printf '\n'
  case "$key" in
    t|T) exec "$0" ;;
    r|R) systemctl reboot; exit 0 ;;
    p|P) systemctl poweroff; exit 0 ;;
    s|S) printf '  Dropping to shell. Type "exit" to return.\n'; /bin/bash -i ;;
    *)   printf '  Unknown option.\n' ;;
  esac
done
