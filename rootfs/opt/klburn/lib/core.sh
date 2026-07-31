#!/usr/bin/env bash
# KLBurn 运行时核心：全局路径、日志、结果记录
#
# 约定：屏幕输出一律英文（Linux 文本控制台默认显示不了中文，会变方块），
#       中文只出现在最终的 report.html 里。

# ---------------------------------------------------------------- 常量
KLB_ROOT="/opt/klburn"
KLB_LIB="$KLB_ROOT/lib"
KLB_TOOLS="$KLB_ROOT/tools"

# 结果状态
ST_PASS="PASS"
ST_FAIL="FAIL"
ST_SKIP="SKIP"     # 没这个硬件 / 现场选择跳过，不算不合格
ST_WARN="WARN"     # 有异常读数但不足以判 FAIL

# ---------------------------------------------------------------- 颜色
if [[ -t 1 ]]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
  C_CYN=$'\033[1;36m'; C_GRY=$'\033[0;37m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_GRY=""; C_BLD=""; C_RST=""
fi

# ---------------------------------------------------------------- 日志
# RUN_DIR 确定之前先写 /tmp，确定之后 log_attach 会把内容接过去
MAIN_LOG="/tmp/klburn-early.log"

# ⚠️ 外面这层 `{ ...; } 2>/dev/null` 不是多余的。
# 重定向失败（日志文件不可写）时，报错是 **shell 在执行命令之前**打出来的，
# 打在 shell 自己的 stderr 上：
#     core.sh: line NN: /tmp/klburn-early.log: Permission denied
# 命令级的 `2>/dev/null` 和 `|| true` 都管不着它 —— 前者只管 printf 自己的
# stderr，后者只吞退出码。和 capture() 里吃掉 bash 那行 "Killed" 是同一类问题。
# 日志写不进去绝不能在现场屏幕上刷红字，更不能因此中断测试。
_log_raw() { { printf '%s\n' "$*" >> "$MAIN_LOG"; } 2>/dev/null || true; }

ts()   { date '+%Y-%m-%d %H:%M:%S'; }
tss()  { date '+%H:%M:%S'; }

info() { printf '%s[%s]%s %s\n' "$C_CYN" "$(tss)" "$C_RST" "$*"; _log_raw "[$(ts)] INFO  $*"; }
ok()   { printf '%s[%s] OK%s   %s\n' "$C_GRN" "$(tss)" "$C_RST" "$*"; _log_raw "[$(ts)] OK    $*"; }
warn() { printf '%s[%s] WARN%s %s\n' "$C_YEL" "$(tss)" "$C_RST" "$*"; _log_raw "[$(ts)] WARN  $*"; }
fail() { printf '%s[%s] FAIL%s %s\n' "$C_RED" "$(tss)" "$C_RST" "$*"; _log_raw "[$(ts)] FAIL  $*"; }
dbg()  { _log_raw "[$(ts)] DEBUG $*"; }

# RUN_DIR 就绪后调用，把早期日志并进去
log_attach() {
  local newlog="$1"
  mkdir -p "$(dirname "$newlog")"
  if [[ -f "$MAIN_LOG" && "$MAIN_LOG" != "$newlog" ]]; then
    cat "$MAIN_LOG" >> "$newlog" 2>/dev/null || true
    rm -f "$MAIN_LOG"
  fi
  MAIN_LOG="$newlog"
}

# ---------------------------------------------------------------- 采集执行
# capture [-t 秒] <输出文件名(相对 raw/)> <命令...>
# 命令的 stdout+stderr 一起落盘；返回命令自己的退出码。
# 统一加超时：现场遇到过 lshw / ipmitool 在异常 BMC 上卡死不返回，
# 出厂测试不能因为一条采集命令就整个挂住。
#
# 注意别写成 `CAPTURE_TIMEOUT=90 capture ...` —— bash 里这种前缀赋值对函数调用
# 结束后仍然残留，会悄悄改掉后面所有采集的超时。所以用显式 -t 参数。
capture() {
  local t=120
  if [[ "${1:-}" == "-t" ]]; then t="$2"; shift 2; fi
  local out="$RAW_DIR/$1"; shift
  mkdir -p "$(dirname "$out")"
  dbg "capture($t s) $* -> $out"
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '(command not found: %s)\n' "$1" > "$out"
    return 127
  fi
  # 外面这层 `{ ...; } 2>/dev/null` 是专门用来吃掉 bash 自己打的那行
  #     /opt/klburn/lib/core.sh: line NN: 1234 Killed  timeout --kill-after=10s ...
  # 采集命令超时被 --kill-after 用 SIGKILL 收掉时，bash 会把这条子进程死亡报告
  # 写到**它自己的** stderr 上（不是子进程的 stderr），现场屏幕上就冒出一行
  # 看着像崩了的红字。子进程自己的 stdout/stderr 由里面的 `> "$out" 2>&1`
  # 收进采集文件，不受这层影响。
  { timeout --kill-after=10s "$t" "$@" > "$out" 2>&1 ; } 2>/dev/null
  local rc=$?
  if (( rc == 124 || rc == 137 )); then
    printf '\n(TIMEOUT after %ss: %s)\n' "$t" "$*" >> "$out"
    # 以前只写进日志文件（dbg），屏幕上只剩 bash 那行 Killed，现场根本不知道
    # 是哪条采集超时了。改成明确告诉人：超时了、超时的是谁、不影响继续跑。
    warn "capture timed out after ${t}s: $1 (non-fatal, continuing)"
  fi
  return $rc
}

# have <cmd> —— 命令是否存在
have() { command -v "$1" >/dev/null 2>&1; }

# count_lines <文件> —— 非空行数，保证输出是一个干干净净能直接做算术的整数。
#
# ⚠️ 别再写 `n="$(grep -c . "$f" || echo 0)"` 了。grep -c 在计数为 0 时会
#    **既打印 "0" 又返回 1**，于是 || 分支再补一个 0，变量就成了两行的 "0\n0"。
#    拿它做 `(( n > 0 ))` 会在现场屏幕上直接抛
#        ((: 0
#        0: arithmetic syntax error in expression
#    而且条件恒为假。最阴的是它只在"计数为 0"时发作 —— 也就是
#    **每一台健康的机器**都会中招（干净机器的 dmesg-errors.txt 必然是空的），
#    反倒是有问题的机器不会。所有计数一律走这个函数。
count_lines() {
  local f="${1:-}" n
  [[ -f "$f" ]] || { printf '0'; return; }
  n="$(grep -c . "$f" 2>/dev/null)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

# ---------------------------------------------------------------- 结果记录
# result_add <id> <显示名(中文)> <状态> <一句话结论(中文)> [详情文件相对路径]
result_add() {
  local id="$1" name="$2" status="$3" detail="$4" ref="${5:-}"
  mkdir -p "$RUN_DIR"
  jq -cn \
    --arg id "$id" --arg name "$name" --arg status "$status" \
    --arg detail "$detail" --arg ref "$ref" --arg t "$(ts)" \
    '{id:$id,name:$name,status:$status,detail:$detail,ref:$ref,time:$t}' \
    >> "$RUN_DIR/results.jsonl"

  # 屏幕上只打 id 和状态，绝不打 detail —— detail 是给报告用的中文，
  # Linux 文本控制台显示不了中文，直接输出会变成一屏 ◆◆◆。
  # 中文原文完整保存在 results.jsonl 里，最终进 report.html。
  case "$status" in
    "$ST_PASS") ok   "$id" ;;
    "$ST_FAIL") fail "$id" ;;
    "$ST_SKIP") info "$id: SKIPPED" ;;
    *)          warn "$id" ;;
  esac
}

# metric_add <组> <键> <值> —— 给报告用的零散数值
metric_add() {
  mkdir -p "$RUN_DIR"
  jq -cn --arg g "$1" --arg k "$2" --arg v "$3" \
    '{group:$g,key:$k,value:$v}' >> "$RUN_DIR/metrics.jsonl"
}

# ---------------------------------------------------------------- 温度阈值
# 可在 /opt/klburn/klburn.conf 里覆盖
# 服务器 CPU 满载跑到 80 多度是常态，88 告警太灵敏，现场每台机器都刷黄。
# 0.6.0 起放宽到 95 告警 / 100 判故障：Intel 服务器 CPU 的 Tjmax 一般在 100~105°C，
# 到 100 度已经在降频保护了，那才是真的散热不行。
: "${CPU_TEMP_WARN:=95}"
: "${CPU_TEMP_FAIL:=100}"
: "${GPU_TEMP_WARN:=83}"
: "${GPU_TEMP_FAIL:=90}"
# 硬盘温度。以前叫 NVME_TEMP_*，但定义了之后一直没人用（任何盘的温度都不参与判定）。
# 改名成 DISK_TEMP_* 并在 verify.sh 里真正接上：SMART 上报温度的盘都按这个判，
# 不限于 NVMe —— 机械盘跑到 70°C 一样是散热出了问题。
: "${DISK_TEMP_WARN:=70}"
: "${DISK_TEMP_FAIL:=80}"

# 读 CPU 最高温度（摄氏整数）。读不到输出空。
# 直接读 hwmon，比每次 fork 一个 sensors 快得多——压测期间每 5 秒采一次。
cpu_temp_max_c() {
  local max="" f v name
  for d in /sys/class/hwmon/hwmon*; do
    [[ -r "$d/name" ]] || continue
    name="$(<"$d/name")"
    case "$name" in
      coretemp|k10temp|zenpower|cpu_thermal) ;;
      *) continue ;;
    esac
    for f in "$d"/temp*_input; do
      [[ -r "$f" ]] || continue
      v="$(<"$f")"
      [[ "$v" =~ ^[0-9]+$ ]] || continue
      v=$(( v / 1000 ))
      (( v > 0 && v < 150 )) || continue
      [[ -z "$max" || v -gt max ]] && max="$v"
    done
  done
  # 退路：内核 thermal zone
  if [[ -z "$max" ]]; then
    for f in /sys/class/thermal/thermal_zone*/temp; do
      [[ -r "$f" ]] || continue
      v="$(<"$f")"
      [[ "$v" =~ ^[0-9]+$ ]] || continue
      v=$(( v / 1000 ))
      (( v > 0 && v < 150 )) || continue
      [[ -z "$max" || v -gt max ]] && max="$v"
    done
  fi
  printf '%s' "$max"
}

# ---------------------------------------------------------------- CPU 功耗
# 读 RAPL 能量计数器算封装功耗（瓦）。
#
# RAPL 给的是**累计能量**（微焦耳），不是瞬时功率，所以必须两次采样求差再除以时间。
# 第一次调用只能记下基准、没法给出数字，返回空——调用方要能接受空值
# （读不到数据绝不能当成 0 瓦或者故障）。
#
# 只取 package 域（intel-rapl:0、intel-rapl:1 ...），不取里面的 core/uncore 子域
# （intel-rapl:0:0 之类），否则会重复计算。多路机器把每颗 CPU 加起来。
# AMD 的 zen 系列在新内核上也走 intel-rapl 这套接口，名字如此而已。
#
# 计数器会回绕，超出 max_energy_range_uj 就从 0 重来；差值为负时按一次回绕补回来。
_RAPL_PREV_UJ=""
_RAPL_PREV_TS=""
cpu_power_w() {
  local total=0 found=0 d f v now
  for d in /sys/class/powercap/intel-rapl:[0-9]* /sys/class/powercap/intel-rapl/intel-rapl:[0-9]*; do
    # 只要 package 层：名字里带两个冒号的是子域，跳过
    [[ "$(basename "$d")" == *:*:* ]] && continue
    f="$d/energy_uj"
    [[ -r "$f" ]] || continue
    v="$(<"$f")" 2>/dev/null || continue
    [[ "$v" =~ ^[0-9]+$ ]] || continue
    total=$(( total + v ))
    found=1
  done
  (( found )) || { printf ''; return; }

  now="$(date +%s%N)"
  if [[ -z "$_RAPL_PREV_UJ" || -z "$_RAPL_PREV_TS" ]]; then
    _RAPL_PREV_UJ="$total"; _RAPL_PREV_TS="$now"
    printf ''   # 第一次没有可比的基准
    return
  fi

  local duj=$(( total - _RAPL_PREV_UJ ))
  local dns=$(( now - _RAPL_PREV_TS ))
  _RAPL_PREV_UJ="$total"; _RAPL_PREV_TS="$now"

  (( dns > 0 )) || { printf ''; return; }
  # 回绕：差值为负说明计数器翻过一轮，用第一个域的量程补一次，补不出来就放弃这个点
  if (( duj < 0 )); then
    local maxf max=""
    for maxf in /sys/class/powercap/intel-rapl:0/max_energy_range_uj \
                /sys/class/powercap/intel-rapl/intel-rapl:0/max_energy_range_uj; do
      [[ -r "$maxf" ]] && { max="$(<"$maxf")"; break; }
    done
    [[ "$max" =~ ^[0-9]+$ ]] || { printf ''; return; }
    duj=$(( duj + max ))
    (( duj < 0 )) && { printf ''; return; }
  fi

  # 瓦 = 微焦 / 微秒 = duj / (dns/1000)
  awk -v uj="$duj" -v ns="$dns" 'BEGIN{ w = uj * 1000 / ns; if (w >= 0 && w < 3000) printf "%d", w }'
}

# 逐颗物理 CPU 的封装温度 -> 每行 "CPU<N> <摄氏度>"，读不到就不输出那一行。
#
# 一个 coretemp/k10temp 的 hwmon 目录对应一颗物理 CPU。优先取带
# "Package id N"（Intel）或 "Tctl"/"Tdie"（AMD）标签的那一路 —— 那是整颗
# 封装的温度；取不到才退回该颗 CPU 所有核心里的最高值。
#
# 为什么要逐颗而不是只报一个最大值：双路机器上一颗 52°C、另一颗 78°C
# 是典型的散热器没装好/风道偏，只报最大值看不出来是哪一颗。
cpu_temp_per_pkg() {
  local d name f label v best idx=0
  for d in /sys/class/hwmon/hwmon*; do
    [[ -r "$d/name" ]] || continue
    name="$(<"$d/name")"
    case "$name" in
      coretemp|k10temp|zenpower|cpu_thermal) ;;
      *) continue ;;
    esac
    best=""
    for f in "$d"/temp*_input; do
      [[ -r "$f" ]] || continue
      label=""
      [[ -r "${f%_input}_label" ]] && label="$(<"${f%_input}_label")"
      v="$(<"$f")"
      [[ "$v" =~ ^[0-9]+$ ]] || continue
      v=$(( v / 1000 ))
      (( v > 0 && v < 150 )) || continue
      case "$label" in
        Package*|Tctl*|Tdie*) best="$v"; break ;;   # 整颗封装的读数，优先
      esac
      [[ -z "$best" || v -gt best ]] && best="$v"
    done
    if [[ -n "$best" ]]; then
      printf 'CPU%d %s\n' "$idx" "$best"
      idx=$(( idx + 1 ))
    fi
  done
}

# 全核平均频率 MHz
cpu_freq_avg_mhz() {
  local sum=0 n=0 f v
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
    [[ -r "$f" ]] || continue
    v="$(<"$f")"
    [[ "$v" =~ ^[0-9]+$ ]] || continue
    sum=$(( sum + v / 1000 )); n=$(( n + 1 ))
  done
  if (( n > 0 )); then
    printf '%s' $(( sum / n ))
  else
    # 退路：/proc/cpuinfo
    awk -F': ' '/cpu MHz/{s+=$2; n++} END{if(n>0) printf "%d", s/n}' /proc/cpuinfo 2>/dev/null
  fi
}

# ---------------------------------------------------------------- 杂项
# 秒 -> 人类可读
fmt_dur() {
  local s="$1"
  printf '%dh%02dm%02ds' $((s/3600)) $((s%3600/60)) $((s%60))
}

# ---------------------------------------------------------------- 机器标识
# 报告文件名要一眼看得出是哪台机器，用 CPU 型号 + 内存容量。

# CPU 简称，例如 "Intel-Xeon-Gold-6430"、"AMD-EPYC-7763"
# 多路机器前面加路数："2x-Intel-Xeon-Gold-6430"
get_cpu_tag() {
  local model="" sockets=1
  if have dmidecode; then
    model="$(dmidecode -s processor-version 2>/dev/null | grep -v '^#' | head -1)"
    sockets="$(dmidecode -t 4 2>/dev/null | grep -c '^Processor Information')"
  fi
  [[ -n "$model" ]] || model="$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  [[ -n "$model" ]] || model="CPU"

  # 去掉商标符号和一堆没信息量的词
  model="${model//(R)/}"; model="${model//(TM)/}"; model="${model//(tm)/}"
  model="$(printf '%s' "$model" \
           | sed -E 's/@.*$//; s/\b(CPU|Processor|Genuine|Intel|AMD)?[[:space:]]*[0-9]+-Core\b//gI' \
           | sed -E 's/\bCPU\b//gI; s/\bProcessor\b//gI' \
           | sed -E 's/[[:space:]]+/ /g; s/^ +| +$//g')"
  # 文件名安全化
  model="$(printf '%s' "$model" | tr ' ' '-' | tr -cd 'A-Za-z0-9._-' | sed -E 's/-+/-/g; s/^-|-$//g')"
  [[ -n "$model" ]] || model="CPU"

  [[ "$sockets" =~ ^[0-9]+$ ]] || sockets=1
  if (( sockets > 1 )); then
    printf '%dx-%s' "$sockets" "${model:0:40}"
  else
    printf '%s' "${model:0:40}"
  fi
}

# 物理内存总量，单位 GB。
# 优先用 dmidecode 累加内存条容量（是整数，比如 512），
# /proc/meminfo 的 MemTotal 会被固件占掉一部分，算出来是 503 之类的难看数字。
get_mem_gb() {
  local gb=0
  if have dmidecode; then
    gb="$(dmidecode -t 17 2>/dev/null | awk '
      /^\tSize:/ {
        if ($2 ~ /^[0-9]+$/) {
          if ($3 == "GB") s += $2;
          else if ($3 == "MB") s += $2/1024;
          else if ($3 == "TB") s += $2*1024;
        }
      }
      END { printf "%d", s }')"
  fi
  if [[ ! "$gb" =~ ^[0-9]+$ ]] || (( gb == 0 )); then
    gb="$(awk '/MemTotal/{printf "%d", ($2/1048576)+0.5}' /proc/meminfo 2>/dev/null)"
  fi
  [[ "$gb" =~ ^[0-9]+$ ]] || gb=0
  printf '%dGB' "$gb"
}

# 报告文件/目录名：日期_时间_CPU_内存
#   20260730_110512_2x-Intel-Xeon-Gold-6430_512GB
get_machine_tag() {
  local stamp="${1:-$(date '+%Y%m%d_%H%M%S')}"
  printf '%s_%s_%s' "$stamp" "$(get_cpu_tag)" "$(get_mem_gb)"
}

# 取整机序列号：优先系统序列号，其次主板，再不行用 MAC
get_serial() {
  local s=""
  if have dmidecode; then
    s="$(dmidecode -s system-serial-number 2>/dev/null | grep -v '^#' | head -1)"
    if [[ -z "$s" || "$s" =~ ^(To[[:space:]]be[[:space:]]filled|Not[[:space:]]Specified|Default[[:space:]]string|System[[:space:]]Serial[[:space:]]Number|O\.E\.M\.|None|\ *)$ ]]; then
      s="$(dmidecode -s baseboard-serial-number 2>/dev/null | grep -v '^#' | head -1)"
    fi
  fi
  if [[ -z "$s" || "$s" =~ ^(To[[:space:]]be[[:space:]]filled|Not[[:space:]]Specified|Default[[:space:]]string|None|\ *)$ ]]; then
    local mac
    mac="$(cat /sys/class/net/*/address 2>/dev/null | grep -v '00:00:00:00:00:00' | head -1 | tr -d ':')"
    s="UNKNOWN-${mac: -6}"
  fi
  # 文件名安全化
  printf '%s' "$s" | tr -cd 'A-Za-z0-9._-' | cut -c1-40
}
