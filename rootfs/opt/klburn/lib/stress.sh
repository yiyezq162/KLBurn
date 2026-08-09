#!/usr/bin/env bash
# KLBurn 压力测试：CPU / 内存 / 硬盘
#
# 每一项都是：后台起压测进程 -> 前台画进度条 + 采样温度频率 -> 判定结果。

STRESS_LOG_DIR=""     # 由 stress_init 设置

stress_init() {
  STRESS_LOG_DIR="$RAW_DIR/stress"
  mkdir -p "$STRESS_LOG_DIR"
}

# ================================================================
# 压测日志判读
#
# 单独抽成纯函数，是为了能脱机做回归测试（tests/test-log-parsing.sh）。
#
# ⚠️ 血的教训：这些工具**正常跑完**的日志里照样含有
#      "Found 0 hardware incidents"  /  "errors: 0"  /  "failed: 0"
#    这些字样。用 grep -q '关键字' 判定的话，每一台好机器都会被判 FAIL。
#    一律把数字抠出来做数值比较。
# ================================================================

# 从日志里取最后一个匹配的数字，取不到返回 0
_last_num() {
  local pat="$1" file="$2" v
  v="$(grep -oE "$pat" "$file" 2>/dev/null | grep -oE '[0-9]+' | tail -1)"
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v" || printf '0'
}

# stressapptest 日志 -> "<硬件异常数> <校验错误数> <自检结论>"
mem_parse_stressapptest() {
  local log="$1"
  local inc err st
  inc="$(_last_num 'Found[[:space:]]+[0-9]+[[:space:]]+hardware incidents' "$log")"
  err="$(grep -oE '[0-9]+ hardware incidents, [0-9]+ errors' "$log" 2>/dev/null \
         | tail -1 | awk '{print $4}')"
  [[ "$err" =~ ^[0-9]+$ ]] || err=0
  st="$(grep -oE 'Status:[[:space:]]+(PASS|FAIL)' "$log" 2>/dev/null | tail -1 | awk '{print $2}')"
  printf '%s %s %s' "$inc" "$err" "${st:-UNKNOWN}"
}

# stress-ng 日志 -> 失败的压测项个数
ng_parse_failed() {
  _last_num 'failed:[[:space:]]+[0-9]+' "$1"
}

# 压测进程是不是被 OOM killer 干掉的。
#
# 退出码 137 = 128 + 9(SIGKILL)。在这个场景里 SIGKILL 几乎只有一个来源：
# 内核内存不足，挑了内存占用最大的进程（正好就是内存压测本身）杀掉。
#
# ⚠️ 这必须和"内存条坏了"严格分开。0.7.0 现场就是被 OOM 打死之后判了 FAIL，
# 一台好机器被拦在出货前 —— 这是本项目最忌讳的一类误判：
# **把好机器拦在出货前比漏判更糟**。
#
# 抽成纯函数以便脱机回归测试（见 tests/test-log-parsing.sh）。
# dmesg 文件参数只为测试用，现场传空就去读真的 dmesg。
oom_killed() {
  local rc="${1:-0}" dmesg_file="${2:-}"
  (( rc == 137 )) || return 1
  local txt
  if [[ -n "$dmesg_file" ]]; then
    [[ -f "$dmesg_file" ]] || return 0
    txt="$(tail -200 "$dmesg_file" 2>/dev/null)"
  else
    txt="$(dmesg 2>/dev/null | tail -200)"
  fi
  # dmesg 里能找到 OOM 记录当然最好；读不到 dmesg（权限/环境）时也按 OOM 处理 ——
  # 宁可少判一次，也绝不能把 SIGKILL 当成内存故障报给客户。
  [[ -z "$txt" ]] && return 0
  grep -qiE 'Out of memory: Killed process|oom-kill:' <<<"$txt" && return 0
  return 0
}

# ---------------------------------------------------------------- 后台采样
# monitor_start <phase标签>
MONITOR_PID=""
monitor_start() {
  local phase="$1"
  local csv="$RUN_DIR/sys_metrics.csv"
  # 新增的列一律往**末尾**加：报告生成器用 csv.DictReader 按列名取值，
  # 中间插一列会让老数据的列名和值错位。
  #
  # cpu_pkg_temps 是逐颗物理 CPU 的封装温度，分号分隔（"52;78"）——
  # 逗号是 CSV 的分隔符，不能用。加这一列是因为"双路机器一颗 52°C、
  # 另一颗 78°C"是典型的散热器没装好/风道偏，而这个信息以前只在屏幕上
  # 一闪而过，落不进任何文件，事后想查都查不到。只有内部工程报告读它。
  # ecc_ce / ecc_ue 是 1.7.0 加的，同样加在**末尾**。有了这一列，
  # 内部报告能画出"ECC 计数是从压测第几分钟开始涨的"——只有前后两个快照的话，
  # 只知道涨了，不知道是一上来就涨还是烤热之后才涨，而这两件事的含义完全不同。
  if [[ ! -f "$csv" ]]; then
    echo "time,phase,cpu_temp_c,cpu_freq_mhz,load1,mem_used_mb,mem_total_mb,cpu_power_w,cpu_pkg_temps,ecc_ce,ecc_ue" > "$csv"
  fi
  (
    # RAPL 是累计能量计数器，要两次采样求差。先在子 shell 里打一次基准，
    # 否则第一个采样点的功耗永远是空的。
    cpu_power_w >/dev/null 2>&1 || true
    while :; do
      local t f l used total p pk ce ue
      t="$(cpu_temp_max_c)"
      f="$(cpu_freq_avg_mhz)"
      p="$(cpu_power_w)"
      pk="$(cpu_temp_per_pkg | awk '{printf "%s%s", (NR>1 ? ";" : ""), $2}')"
      l="$(awk '{print $1}' /proc/loadavg 2>/dev/null)"
      read -r ce ue < <(mem_ecc_counts)
      # 读不到 EDAC 时 mem_ecc_counts 给的是 "-- --"，原样写进去 ——
      # 报告生成器按数字解析，解析不了就当这一点没有，绝不会当成 0。
      read -r total used < <(awk '/MemTotal/{tot=$2} /MemAvailable/{av=$2} END{printf "%d %d", tot/1024, (tot-av)/1024}' /proc/meminfo)
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(date '+%H:%M:%S')" "$phase" "${t:-}" "${f:-}" "${l:-}" "${used:-}" "${total:-}" "${p:-}" "${pk:-}" \
        "${ce:-}" "${ue:-}" >> "$csv"
      sleep 5
    done
  ) &
  MONITOR_PID=$!
  dbg "monitor started pid=$MONITOR_PID phase=$phase"
}

monitor_stop() {
  [[ -n "$MONITOR_PID" ]] || return 0
  kill "$MONITOR_PID" 2>/dev/null || true
  wait "$MONITOR_PID" 2>/dev/null || true
  MONITOR_PID=""
}

# ---------------------------------------------------------------- turbostat 采样
# sensors 只给"某个 hwmon 探头此刻多少度"。turbostat 给的是**逐核**的
# 实际运行频率、C-state 占比、封装功耗和温度 —— 复盘"这台机器满载时到底
# 有没有跑满、是哪几个核在拖后腿"时，只有它答得上来。
#
# 只留档，**不参与任何判定**：它在不同平台上的可用性差别很大（要 MSR、
# 要认识这代 CPU），拿它判定等于给自己埋一堆误判。
#
# 起不来一律无声跳过（老平台、虚拟机、内核禁了 msr 都会起不来）。
TURBOSTAT_PID=""
turbostat_start() {
  have turbostat || return 0
  modprobe msr >/dev/null 2>&1 || true
  local out="$STRESS_LOG_DIR/turbostat.txt"
  # --quiet 只留数值列；5 秒一次和 monitor_start 对齐，好按时间对照
  turbostat --quiet --interval 5 > "$out" 2>"$STRESS_LOG_DIR/turbostat-err.log" &
  TURBOSTAT_PID=$!
  # 给它一秒钟把不支持的情况暴露出来；死了就当没有这回事
  sleep 1
  if ! kill -0 "$TURBOSTAT_PID" 2>/dev/null; then
    dbg "turbostat exited immediately (platform not supported), skipping"
    TURBOSTAT_PID=""
    return 0
  fi
  dbg "turbostat sampling started pid=$TURBOSTAT_PID"
}

turbostat_stop() {
  [[ -n "$TURBOSTAT_PID" ]] || return 0
  kill "$TURBOSTAT_PID" 2>/dev/null || true
  wait "$TURBOSTAT_PID" 2>/dev/null || true
  TURBOSTAT_PID=""
}

# 从 sys_metrics.csv 里取某阶段的最高温度
phase_max_temp() {
  local phase="$1"
  awk -F, -v p="$phase" '$2==p && $3!="" {if($3+0>m) m=$3+0} END{if(m>0) printf "%d", m}' \
    "$RUN_DIR/sys_metrics.csv" 2>/dev/null
}
# phase_freq_stats <阶段> -> "<最低频率> <平均频率>"，没数据给 "- -"
#
# 要跳过每个阶段开头两个采样点（10 秒）：monitor_start 和压测进程是同一刻
# 起来的，头一两个点采到的还是空载降频后的频率（实测 1156MHz），算进去
# 报告里就凭空多出一个看着像降频的数字。
# 采样点不足 3 个时（超短阶段）就全都算，宁可粗糙也不要空值。
#
# ⚠️⚠️ **最低和平均必须取同一段样本，所以只能有一个取样口。**
#
# 1.9.2 之前是两个各自独立的函数：min 跳前两点、avg 从头算。两个数都没算错，
# 但它们是**两个口径**，凑在同一行上就出过这种事：
#     平均频率 2686MHz　　最低频率 2688MHz
# 最低的比平均的还高。客户不会去想"哦这是两个窗口"，他想的是"这报告算错了"，
# 而一份被怀疑算错了的报告，后面每一个数字都要重新解释一遍。
#
# 合成一个函数不是为了省代码：**只要两个数出自同一组样本，min <= avg 就是
# 结构上成立的**，不需要任何断言去兜，将来也没人能把它们改回两个窗口。
phase_freq_stats() {
  local phase="$1"
  awk -F, -v p="$phase" '
    $2==p && $4!="" { v[++n] = $4+0 }
    END {
      if (n == 0) { printf "- -"; exit }
      start = (n > 2 ? 3 : 1)
      mn = ""; s = 0; c = 0
      for (i = start; i <= n; i++) {
        if (mn == "" || v[i] < mn) mn = v[i]
        s += v[i]; c++
      }
      # 四舍五入，和 gpu.sh 的 gpu_load_stats 保持同一种取整
      printf "%d %d", mn, int(s / c + 0.5)
    }' "$RUN_DIR/sys_metrics.csv" 2>/dev/null
}

# 没数据时 phase_freq_stats 给的是 "-"，而老调用方等的是空串（`${fmin:-未知}`）
_freq_out() { [[ "${1:--}" == "-" ]] || printf '%s' "$1"; }

# 两个薄包装，保持老调用方式。**不要在这里各自重新算一遍。**
phase_min_freq() {
  local mn av; read -r mn av < <(phase_freq_stats "$1"); _freq_out "$mn"
}
phase_avg_freq() {
  local mn av; read -r mn av < <(phase_freq_stats "$1"); _freq_out "$av"
}

# ---------------------------------------------------------------- CPU
#
# 现在是从 factory-test.sh 里以 `( stress_cpu ... ) &` 的方式和内存/GPU
# 并发跑的（三个都是独立子 shell），所以：
#   1. 不再自己画 run_with_progress 的单行进度条——三个子 shell 同时刷
#      \r\033[K 会互相打架，进度条会乱成一团。合并进度条由外层的
#      progress_bar_concurrent 统一画，这里退化成安安静静 wait。
#   2. 不再用 section() 打整块横幅——多个子 shell 同时打多行横幅一样会串行，
#      改成一行 info()，被交叉打印的风险小得多。
stress_cpu() {
  local secs="$1"
  local log="$STRESS_LOG_DIR/cpu-stress-ng.log"

  local ncpu; ncpu="$(nproc)"
  info "[CPU] stress-ng on all $ncpu logical CPUs, method=all, $(fmt_dur "$secs")"

  monitor_start "cpu"
  stress-ng --cpu 0 --cpu-method all \
            --timeout "${secs}s" \
            --metrics-brief --times \
            --log-file "$log" > "$STRESS_LOG_DIR/cpu-stdout.log" 2>&1 &
  local pid=$!
  local rc=0
  wait "$pid" || rc=$?
  monitor_stop

  local tmax fmin favg
  tmax="$(phase_max_temp cpu)"; fmin="$(phase_min_freq cpu)"; favg="$(phase_avg_freq cpu)"
  metric_add "cpu" "峰值温度" "${tmax:-未知}"
  metric_add "cpu" "平均频率MHz" "${favg:-未知}"
  metric_add "cpu" "最低频率MHz" "${fmin:-未知}"
  metric_add "cpu" "逻辑核心数" "$ncpu"

  local detail="全核满载 $(fmt_dur "$secs")，${ncpu} 逻辑核心"
  [[ -n "$favg" ]] && detail="$detail，平均频率 ${favg}MHz"
  [[ -n "$tmax" ]] && detail="$detail，峰值温度 ${tmax}°C"

  local nfailed; nfailed="$(ng_parse_failed "$log")"
  metric_add "cpu" "失败压测项" "$nfailed"

  if (( nfailed > 0 )); then
    result_add "stress_cpu" "CPU 压力测试" "$ST_FAIL" \
      "CPU 压测报告 ${nfailed} 个子项失败；$detail" "raw/stress/cpu-stress-ng.log"
  elif (( rc != 0 )); then
    result_add "stress_cpu" "CPU 压力测试" "$ST_FAIL" \
      "CPU 压测程序异常退出（退出码 $rc）；$detail" "raw/stress/cpu-stress-ng.log"
  elif [[ -n "$tmax" ]] && (( tmax >= CPU_TEMP_FAIL )); then
    result_add "stress_cpu" "CPU 压力测试" "$ST_FAIL" \
      "CPU 温度达到 ${tmax}°C，超过上限 ${CPU_TEMP_FAIL}°C（散热异常）；$detail" "raw/stress/cpu-stress-ng.log"
  elif [[ -n "$tmax" ]] && (( tmax >= CPU_TEMP_WARN )); then
    result_add "stress_cpu" "CPU 压力测试" "$ST_WARN" \
      "运行正常但温度偏高 ${tmax}°C（告警线 ${CPU_TEMP_WARN}°C）；$detail" "raw/stress/cpu-stress-ng.log"
  else
    result_add "stress_cpu" "CPU 压力测试" "$ST_PASS" "$detail" "raw/stress/cpu-stress-ng.log"
  fi
}

# ---------------------------------------------------------------- 内存
# 和 stress_cpu() 一样：现在是并发子 shell 之一，不再自己画进度条 /
# 打整块横幅，见 stress_cpu() 顶部注释。
stress_mem() {
  local secs="$1"
  local log="$STRESS_LOG_DIR/mem-stressapptest.log"

  local total_mb avail_mb target_mb threads
  total_mb="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)"
  avail_mb="$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)"

  # 目标容量 = （可用内存 - 给 live 系统留的余量） x 覆盖率
  #
  # ⚠️ 绝对不能直接按 MemAvailable 的百分比取。0.7.0 现场实测翻过车：
  #   32GB 的机器，MemAvailable 29194MB，按 95% 取到 27734MB，
  #   跑到第 9 分钟被 OOM killer 打死
  #       Out of memory: Killed process 4168 (stressapptest) anon-rss:28397568kB
  #   然后 rc=137 被判成 FAIL —— 一台好机器就这么被拦在出货前。
  #
  # 根子在于 MemAvailable 是"此刻"的估计，而测试跑起来之后：
  #   - live 系统的 tmpfs 还在涨（报告、日志、raw 数据都写在内存里，
  #     尤其是没找到 U 盘数据分区、报告落 /tmp 的时候）
  #   - squashfs 的 page cache 也在争内存
  # 所以必须先扣一个**绝对**余量，再谈百分比。
  #
  # 余量 = 总内存的 10%，下限 2GB，上限 8GB。
  # 这个公式在小内存机器上保守（32GB -> 扣 3.1GB，实际测到约 82%），
  # 在大内存机器上反而更激进（512GB -> 只扣 8GB，覆盖率约 98%），
  # 正好符合"内存越大越该测透、而 live 系统本身占用并不随内存增长"的事实。
  local reserve_mb
  reserve_mb=$(( total_mb * 10 / 100 ))
  (( reserve_mb < 2048 )) && reserve_mb=2048
  (( reserve_mb > 8192 )) && reserve_mb=8192

  local usable_mb=$(( avail_mb - reserve_mb ))
  (( usable_mb < 256 )) && usable_mb=256

  # 还想再收紧的话在 klburn.conf 里调这个（默认 100 = 把上面算出来的可用量测满）
  : "${MEM_TEST_PERCENT:=100}"
  target_mb=$(( usable_mb * MEM_TEST_PERCENT / 100 ))
  (( target_mb < 256 )) && target_mb=256
  threads="$(nproc)"; (( threads > 16 )) && threads=16

  local pct=$(( target_mb * 100 / total_mb ))
  info "[MEM] total ${total_mb}MB, available ${avail_mb}MB, reserved ${reserve_mb}MB for the live OS"
  info "[MEM] -> testing ${target_mb}MB (${pct}% of total), $(fmt_dur "$secs")"

  # ⚠️ 这里**故意不起采样器**。CPU 和内存现在是并发跑的两个子 shell，各起一个
  # monitor_start 就是两个后台采样进程同时往同一个 sys_metrics.csv 里写 ——
  # 实测 600 秒的测试写出 239 行（cpu 120 行 + mem 119 行），同一时刻的温度/频率/
  # 负载被原样记两遍，报告里的 CPU 曲线每个点都画两次。而且两个采样器还会抢
  # "文件不存在就写表头"那一步，撞上就是两行表头。
  #
  # 关键是：**mem 那份采样根本没人读**。stress_mem 从头到尾没调过
  # phase_max_temp / phase_min_freq / phase_avg_freq，纯粹是白写。
  # CPU 那个采样器和内存跑的是同一段时间窗，温度/频率本来就是全局的，
  # 留它一个就够了。
  stressapptest -M "$target_mb" -s "$secs" -m "$threads" -W \
    > "$log" 2>&1 &
  local pid=$!
  local rc=0
  wait "$pid" || rc=$?

  # stressapptest 在超大内存机器上偶尔分配失败秒退，退到 stress-ng --vm
  if (( rc != 0 )) && grep -qiE 'failed to allocate|Could not allocate' "$log" 2>/dev/null; then
    warn "[MEM] stressapptest allocation failed, falling back to stress-ng --vm"
    log="$STRESS_LOG_DIR/mem-stress-ng.log"
    stress-ng --vm "$threads" --vm-bytes "${target_mb}M" --vm-method all \
              --timeout "${secs}s" --metrics-brief --log-file "$log" \
              > "$STRESS_LOG_DIR/mem-fallback-stdout.log" 2>&1 &
    pid=$!; rc=0
    wait "$pid" || rc=$?
    MEM_TOOL="stress-ng --vm"
  else
    MEM_TOOL="stressapptest"
  fi
  # 这里同样没有 monitor_stop —— 上面就没起采样器。
  # （留着也只是空转，但会让下一个读代码的人以为这里有个采样器该被停掉。）

  metric_add "mem" "测试容量MB" "$target_mb"
  metric_add "mem" "占识别容量" "${pct}%"
  metric_add "mem" "测试工具" "$MEM_TOOL"

  # 说"系统识别内存"而不是"总内存"：装机容量和系统识别容量可能对不上
  # （少条 / 开了内存镜像），那种情况由 check_memory_capacity 单独判 WARN，
  # 这里只能诚实地说压测覆盖的是系统认到的那部分。
  # ⚠️ 这句进客户报告，**不许出现工具名**（§2-1：盘里带了什么工具是内部实现）。
  # MEM_TOOL 照常记进 metrics.jsonl，内部报告里一个字都没少。
  local detail="覆盖 ${target_mb}MB（占系统识别内存 ${total_mb}MB 的 ${pct}%），持续 $(fmt_dur "$secs")"
  local ref="raw/stress/$(basename "$log")"

  # ⚠️ 这里绝对不能用 grep -q 'hardware incident' 之类的关键字匹配。
  # stressapptest 正常跑完也会打这两行：
  #     Stats: Found 0 hardware incidents
  #     Stats: Completed: ... with 0 hardware incidents, 0 errors
  # 按字面子串匹配的话，每一台好机器都会被判 FAIL。必须把数字抠出来比。
  local incidents errors sat_status
  if [[ "$MEM_TOOL" == "stressapptest" ]]; then
    read -r incidents errors sat_status < <(mem_parse_stressapptest "$log")
  else
    # stress-ng --vm 的兜底路径：看它自己汇总的 failed 计数
    incidents=0
    errors="$(ng_parse_failed "$log")"
    sat_status="UNKNOWN"
  fi

  metric_add "mem" "校验错误数" "$errors"
  metric_add "mem" "硬件异常数" "$incidents"

  # 判定顺序有讲究：真错误 > 自检结论 > OOM（环境问题）> 其它异常退出。
  # OOM 必须排在"异常退出"前面，否则又会被当成故障。
  if (( incidents > 0 || errors > 0 )); then
    result_add "stress_mem" "内存压力测试" "$ST_FAIL" \
      "检测到 ${incidents} 处硬件异常、${errors} 处数据校验错误（内存条或内存控制器故障）；$detail" "$ref"
  elif [[ "$sat_status" == "FAIL" ]]; then
    result_add "stress_mem" "内存压力测试" "$ST_FAIL" \
      "内存测试程序的自检结论为未通过；$detail" "$ref"
  elif oom_killed "$rc"; then
    # 被 OOM killer 打死 = 测试程序申请的容量超过了测试系统当时能给的，
    # 和内存条本身好不好没有任何关系。判 WARN 并说清楚，绝不能判 FAIL。
    metric_add "mem" "本次是否跑满" "否（测试环境内存不足）"
    result_add "stress_mem" "内存压力测试" "$ST_WARN" \
      "本次内存压测未能跑完整个时长：测试系统在运行过程中可用内存不足，\
测试程序被系统回收。这是测试环境的容量限制，**不是内存故障** —— \
在此之前已完成的校验未发现任何数据错误。${detail}" "$ref"
  elif (( rc != 0 )); then
    result_add "stress_mem" "内存压力测试" "$ST_FAIL" \
      "测试进程异常退出（退出码 $rc）；$detail" "$ref"
  else
    result_add "stress_mem" "内存压力测试" "$ST_PASS" "无数据校验错误；$detail" "$ref"
  fi
}

# ---------------------------------------------------------------- 硬盘
stress_disk() {
  local secs="$1"
  section "PHASE 4/5  DISK STRESS (separate, not concurrent)  ($(fmt_dur "$secs"))"

  if (( ${#DISK_CAND[@]} == 0 )); then
    result_add "stress_disk" "硬盘压力测试" "$ST_SKIP" "未发现可测试的本机硬盘" ""
    return
  fi

  # 时间三七开：先跑顺序大块看持续带宽，再跑 4K 随机看 IOPS 和稳定性
  local seq_secs=$(( secs * 30 / 100 ))
  local rnd_secs=$(( secs - seq_secs ))
  (( seq_secs < 20 )) && { seq_secs=20; rnd_secs=$(( secs > 40 ? secs - 20 : 20 )); }

  info "Targets: ${DISK_CAND[*]}"
  info "Sequential write $(fmt_dur "$seq_secs") + random 4K read/write $(fmt_dur "$rnd_secs")"

  monitor_start "disk"
  local rc_total=0

  # ---- 顺序写 ----
  local jf="$STRESS_LOG_DIR/fio-seq.job"
  {
    printf '[global]\nioengine=libaio\ndirect=1\nbs=1M\niodepth=16\nrw=write\n'
    printf 'time_based=1\nruntime=%s\nramp_time=5\ngroup_reporting=0\nthread=1\n\n' "$seq_secs"
    local d
    for d in "${DISK_CAND[@]}"; do
      printf '[seq-%s]\nfilename=%s\n\n' "$(basename "$d")" "$d"
    done
  } > "$jf"
  fio --output-format=json --output="$RAW_DIR/fio-seq.json" "$jf" \
      > "$STRESS_LOG_DIR/fio-seq.log" 2>&1 &
  run_disk_with_dashboard $! "$seq_secs" "SEQ WRITE" || rc_total=$?

  # ---- 随机读写 ----
  jf="$STRESS_LOG_DIR/fio-rand.job"
  {
    printf '[global]\nioengine=libaio\ndirect=1\nbs=4k\niodepth=32\nrw=randrw\nrwmixread=70\n'
    printf 'norandommap=1\nrandrepeat=0\ntime_based=1\nruntime=%s\nramp_time=5\ngroup_reporting=0\nthread=1\n\n' "$rnd_secs"
    local d
    for d in "${DISK_CAND[@]}"; do
      printf '[rand-%s]\nfilename=%s\n\n' "$(basename "$d")" "$d"
    done
  } > "$jf"
  fio --output-format=json --output="$RAW_DIR/fio-rand.json" "$jf" \
      > "$STRESS_LOG_DIR/fio-rand.log" 2>&1 &
  local rc2=0
  run_disk_with_dashboard $! "$rnd_secs" "RANDOM 4K" || rc2=$?
  (( rc2 != 0 )) && rc_total=$rc2

  monitor_stop

  # fio 的 json 里每个 job 都有 error 字段，非 0 就是真出错了
  local ioerr=0 f
  for f in "$RAW_DIR/fio-seq.json" "$RAW_DIR/fio-rand.json"; do
    [[ -f "$f" ]] || continue
    local e; e="$(jq '[.jobs[]?.error] | add // 0' "$f" 2>/dev/null || echo 0)"
    [[ "$e" =~ ^[0-9]+$ ]] && (( e != 0 )) && ioerr=$(( ioerr + e ))
  done

  local ndisk="${#DISK_CAND[@]}"
  local detail="${ndisk} 块盘并发裸盘读写：顺序 $(fmt_dur "$seq_secs") + 4K随机 $(fmt_dur "$rnd_secs")"

  # ⚠️ 这两句进客户报告，**不许出现工具名**（§6-2：盘里带的是哪个工具是内部实现）。
  # 1.8.4 把工具名成组加进禁词表时漏了 fio —— 因为当时只按"咬过人的词"加，
  # 而这两句从来没红过。现在 FORBIDDEN 里有 fio 了，改坏会当场跑红。
  if (( ioerr != 0 )); then
    result_add "stress_disk" "硬盘压力测试" "$ST_FAIL" \
      "硬盘读写测试报告 I/O 错误（错误计数 ${ioerr}）；$detail" "raw/fio-rand.json"
  elif (( rc_total != 0 )); then
    result_add "stress_disk" "硬盘压力测试" "$ST_FAIL" \
      "硬盘读写测试程序异常退出（退出码 $rc_total）；$detail" "raw/stress/fio-rand.log"
  else
    result_add "stress_disk" "硬盘压力测试" "$ST_PASS" "无 I/O 错误；$detail" "raw/fio-rand.json"
  fi
}

# 现场没确认 / 没有盘时调用
stress_disk_skipped() {
  local reason="$1"
  section "PHASE 4/5  DISK STRESS  (SKIPPED)"
  warn "Disk stress test skipped."
  result_add "stress_disk" "硬盘压力测试" "$ST_SKIP" "$reason" ""
}
