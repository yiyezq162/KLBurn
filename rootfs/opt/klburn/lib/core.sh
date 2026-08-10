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
# result_add <id> <显示名(中文)> <状态> <一句话结论(中文)> [详情文件相对路径] [origin]
#
# 第六个参数 `origin` 只有一个合法值：**self**，意思是
# 「这条 SKIP 的原因在我们这边，不在被测机器上」——
# 盘里没带某个基准/诊断程序、程序跑了没给出有效结果，都属于这一类。
#
# ⚠️ 它**只对 SKIP 有意义**，而且**只影响交付报告印不印这一行**：
#    `results.jsonl`、内部工程报告、屏幕输出全都一个字不少。
#
# 为什么要有它（1.9.4，客户当面骂过一次）：交付报告里印一行
#    「SKIP  显卡专项诊断  当前测试环境未包含显卡厂商诊断程序」
# 客户读到的不是"这台机器没问题"，是"这家供应商的工具箱是破的"。
# 我们没带程序，跟他这台机器好不好毫无关系，那一行对他做"收还是不收"
# 的决定没有任何帮助 —— 属于 report-policy 二-5 那把尺子
# （判的是我们、不是机器）。
#
# **判据写在产生这条结论的地方，不写在报告生成器里。**
# 报告那边只认 origin，不去猜文案 —— 猜文案的做法（"看看句子里有没有
# '未包含'"）在改一次措辞之后就会静悄悄失效，而失效的方向是漏出去。
#
# 反过来一样要守住：**「这台机器上没有可测的东西」不是 self**。
# 「本机只安装了 1 张显卡，没有卡间互联可测」「未发现可测试的本机硬盘」
# 讲的是被测机器的事实，客户有权知道，照常进报告。
result_add() {
  local id="$1" name="$2" status="$3" detail="$4" ref="${5:-}" origin="${6:-}"
  mkdir -p "$RUN_DIR"
  jq -cn \
    --arg id "$id" --arg name "$name" --arg status "$status" \
    --arg detail "$detail" --arg ref "$ref" --arg t "$(ts)" \
    --arg origin "$origin" \
    '{id:$id,name:$name,status:$status,detail:$detail,ref:$ref,time:$t}
     + (if $origin == "" then {} else {origin:$origin} end)' \
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
# 显卡这两个只是**兜底**：真正用的是每张卡自己上报的降频/关机温度
# （见 lib/gpu.sh 的 gpu_resolve_temp_thresholds，它会就地改写这两个变量）。
# 1.9.3 之前钉死 83/90，而 RTX 4090 自报的最高工作温度就是 84°C —— 好卡每轮都刷黄。
# 兜底只在"驱动一个温度限值都不给"时生效，所以取一个各代卡都不至于误伤的值。
: "${GPU_TEMP_WARN:=90}"
: "${GPU_TEMP_FAIL:=95}"
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

# ---------------------------------------------------------------- 采样状态
# "要两次采样求差"的那几个函数（RAPL 功耗、CPU 占用率、磁盘 I/O 速率）
# 把"上一次的读数"存在这里。
#
# ⚠️ **绝不能存在 shell 全局变量里。**调用点全长这样：
#       p="$(cpu_power_w)"                      # 命令替换
#       while read ... < <(cpu_pkg_busy_pct)    # 进程替换
#       while read ... < <(disk_io_rates)
#    两种都在**子 shell**里跑，函数里对全局的赋值出了子 shell 就没了（§11-28）。
#    调用方通常会先在父 shell 里调一次"打基准"，于是"上一次"就**永远停在那次
#    基准上** —— 每个采样点算出来的都是"从压测开始到现在的平均值"，
#    不是此刻的瞬时值。
#
#    这不是理论问题。1.7.8 现场那台 2x Xeon Gold 6530 的功耗曲线：前 14 分钟
#    稳稳一条直线（平均值当然平），RAPL 计数器第一次回绕之后整条线塌到
#    429 W 再每个采样点爬 4 瓦，爬到测试结束都没爬回去，中间还塌了四次。
#    屏幕上的 CPU 占用率和硬盘速率是同一个病，只是满载时平均值和瞬时值差不多，
#    看不出来。
#
#    落到文件里，跨子 shell 才留得住。/run 是 tmpfs，盘里跑的时候一定有；
#    脱机跑测试时用 KLBURN_STATE_DIR 指到临时目录。
sample_state_file() {
  local d
  for d in "${KLBURN_STATE_DIR:-/run/klburn}" "${TMPDIR:-/tmp}/klburn-state"; do
    [[ -d "$d" ]] || mkdir -p "$d" 2>/dev/null || continue
    [[ -w "$d" ]] || continue
    printf '%s/%s' "$d" "$1"
    return 0
  done
  return 1
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
# ⚠️ **同一个 package 域在 /sys/class/powercap 下能被两条路径同时匹配到**，
#    照单全加就是整份报告的功耗曲线**翻一倍**：
#      /sys/class/powercap/intel-rapl:0                 ← zone 自己的 class 软链
#      /sys/class/powercap/intel-rapl/intel-rapl:0      ← 从 control type 目录进去
#    powercap 框架把 control type（intel-rapl）和每个 zone（intel-rapl:N）
#    都注册进 class 目录，而 zone 的 device 父节点又正是 control type，
#    于是同一块硬件在两条路径下各出现一次。原意是"第一条取不到再退第二条"，
#    写成一个 for 就成了相加。
#
#    这不是理论问题：1.7.8~1.8.2 现场那台 2x Xeon Gold 6530 报出 **1034 W**
#    封装功耗，而它的 MSR_PKG_POWER_LIMIT(0x610) PL1 = 270 W/颗、两颗顶天
#    540 W，BMC 的 Sys_Total_Power 整机才 570~627 W。1034 / 2 = 517 W
#    才是真值。2x Jintide C5218R（PL1 125 W/颗）报 567 W 同理。
#
#    去重按 zone 名（intel-rapl:N 在一个 control type 里唯一），不用 realpath，
#    省掉每次采样几个子进程。
#
# 计数器会回绕，超出 max_energy_range_uj 就从 0 重来；差值为负时按一次回绕补回来。

# 该求和的 package 域目录，一个 zone 只出现一次。
# 抽成单独一个函数是为了能脱机测（tests/test-hw-checks.sh 用 KLBURN_POWERCAP
# 指到一棵假的 sysfs 上，把"两条路径指同一个 zone"这件事复现出来）。
rapl_pkg_zones() {
  local root="${KLBURN_POWERCAP:-/sys/class/powercap}"
  local d zone seen=" "
  for d in "$root"/intel-rapl:[0-9]* "$root"/intel-rapl/intel-rapl:[0-9]*; do
    zone="${d##*/}"
    # 只要 package 层：名字里带两个冒号的是子域，跳过
    [[ "$zone" == *:*:* ]] && continue
    # 同一个 zone 从两条路径各来一次，只认第一次
    [[ "$seen" == *" $zone "* ]] && continue
    [[ -r "$d/energy_uj" ]] || continue
    seen+="$zone "
    printf '%s\n' "$d"
  done
}

cpu_power_w() {
  local total=0 found=0 d f v now sf prev_uj="" prev_ts=""
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    f="$d/energy_uj"
    v="$(<"$f")" 2>/dev/null || continue
    [[ "$v" =~ ^[0-9]+$ ]] || continue
    total=$(( total + v ))
    found=1
  done < <(rapl_pkg_zones)
  (( found )) || { printf ''; return; }

  now="$(date +%s%N)"
  sf="$(sample_state_file rapl.prev)" || { printf ''; return; }
  [[ -r "$sf" ]] && read -r prev_uj prev_ts < "$sf"
  printf '%s %s\n' "$total" "$now" > "$sf"
  # 第一次没有可比的基准
  [[ "$prev_uj" =~ ^[0-9]+$ && "$prev_ts" =~ ^[0-9]+$ ]] || { printf ''; return; }

  local duj=$(( total - prev_uj ))
  local dns=$(( now - prev_ts ))

  (( dns > 0 )) || { printf ''; return; }
  # 回绕：差值为负说明计数器翻过一轮，用第一个域的量程补一次，补不出来就放弃这个点
  # （同一台机器上各 package 的量程是一样的，取第一个就够）
  if (( duj < 0 )); then
    local max="" z
    z="$(rapl_pkg_zones | head -1)"
    [[ -n "$z" && -r "$z/max_energy_range_uj" ]] && max="$(<"$z/max_energy_range_uj")"
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

# 逐颗物理 CPU 的平均频率 -> 每行 "<封装号> <MHz>"
#
# 和 cpu_temp_per_pkg 配对用：温度按 hwmon 目录分颗，频率按 topology 分颗。
# 两边的"第几颗"都是从 0 数起，仪表盘上就能并成一行。
cpu_freq_per_pkg() {
  cpu_pkg_map_init
  local -A sum=() cnt=()
  local d n p f v
  for d in /sys/devices/system/cpu/cpu[0-9]*; do
    n="${d##*/cpu}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    f="$d/cpufreq/scaling_cur_freq"
    [[ -r "$f" ]] || continue
    v="$(<"$f")"
    [[ "$v" =~ ^[0-9]+$ ]] || continue
    p="${_PKG_OF_CPU[$n]:-0}"
    sum[$p]=$(( ${sum[$p]:-0} + v / 1000 ))
    cnt[$p]=$(( ${cnt[$p]:-0} + 1 ))
  done
  for p in $(printf '%s\n' "${!cnt[@]}" | sort -n); do
    printf '%s %s\n' "$p" $(( sum[$p] / cnt[$p] ))
  done
}

# 逻辑 CPU -> 物理封装号 的映射，只建一次。
# 取不到 topology（虚拟机里常见）时一律算第 0 颗 —— 宁可把两颗并成一颗显示，
# 也不要因为读不到就整块不画。
declare -A _PKG_OF_CPU=()
_PKG_MAP_DONE=0
cpu_pkg_map_init() {
  (( _PKG_MAP_DONE )) && return 0
  local d n p
  for d in /sys/devices/system/cpu/cpu[0-9]*; do
    n="${d##*/cpu}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    p=0
    if [[ -r "$d/topology/physical_package_id" ]]; then
      p="$(<"$d/topology/physical_package_id")"
      [[ "$p" =~ ^[0-9]+$ ]] || p=0
    fi
    _PKG_OF_CPU[$n]="$p"
  done
  _PKG_MAP_DONE=1
}

# 逐颗物理 CPU 的占用率 -> 每行 "<封装号> <百分比>"
#
# 只读一次 /proc/stat（一个文件，很便宜），按封装把各逻辑核的时间片加起来。
# 占用率是两次采样之间的**差值**，所以第一次调用给不出数字、什么都不输出 ——
# 调用方要能接受空（读不到 ≠ 0%，更不是故障）。
# 上一次的读数存在文件里，理由见 sample_state_file。
cpu_pkg_busy_pct() {
  cpu_pkg_map_init
  local -A tot=() idl=()
  local cpu us ni sy id io ir sq st rest n p have=0
  while read -r cpu us ni sy id io ir sq st rest; do
    [[ "$cpu" == cpu[0-9]* ]] || continue
    n="${cpu#cpu}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    [[ "$us$ni$sy$id" =~ ^[0-9]+$ ]] || continue
    p="${_PKG_OF_CPU[$n]:-0}"
    tot[$p]=$(( ${tot[$p]:-0} + us + ni + sy + id + io + ir + sq + st ))
    idl[$p]=$(( ${idl[$p]:-0} + id + io ))
    have=1
  done < /proc/stat
  (( have )) || return 0

  local sf; sf="$(sample_state_file cpubusy.prev)" || return 0
  local -A ptot=() pidl=()
  local pt pi
  if [[ -r "$sf" ]]; then
    while read -r p pt pi; do
      [[ "$p" =~ ^[0-9]+$ && "$pt" =~ ^[0-9]+$ && "$pi" =~ ^[0-9]+$ ]] || continue
      ptot[$p]="$pt"; pidl[$p]="$pi"
    done < "$sf"
  fi

  local dt di
  for p in $(printf '%s\n' "${!tot[@]}" | sort -n); do
    if [[ -n "${ptot[$p]:-}" ]]; then
      dt=$(( tot[$p] - ptot[$p] ))
      di=$(( idl[$p] - pidl[$p] ))
      (( dt > 0 )) && printf '%s %s\n' "$p" $(( (dt - di) * 100 / dt ))
    fi
  done

  # 存新基准放在最后：上面那圈还要用旧值，写文件不能插在中间
  : > "$sf"
  for p in "${!tot[@]}"; do
    printf '%s %s %s\n' "$p" "${tot[$p]}" "${idl[$p]}" >> "$sf"
  done
}

# CPU 型号，给屏幕用（不是文件名，所以保留空格）
cpu_model_display() {
  local m
  m="$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  [[ -n "$m" ]] || m="Unknown CPU"
  m="${m//(R)/}"; m="${m//(TM)/}"; m="${m//(tm)/}"
  printf '%s' "$m" \
    | sed -E 's/@.*$//; s/\bCPU\b//g; s/\bProcessor\b//g; s/[[:space:]]+/ /g; s/^ +| +$//g'
}

# 内存占用 -> "<已用MB> <总量MB>"
mem_used_total_mb() {
  awk '/MemTotal/{tot=$2} /MemAvailable/{av=$2}
       END{ if (tot > 0) printf "%d %d", (tot-av)/1024, tot/1024 }' /proc/meminfo 2>/dev/null
}

# 内存 ECC 计数 -> "<可纠正> <不可纠正>"，读不到给 "-- --"
#
# 走内核自带的 EDAC sysfs，不需要任何额外工具 —— 现场那一屏必须便宜。
# 结构化的逐 DIMM 计数（rasdaemon）在采集阶段单独取，那份进报告。
#
# ⚠️ 读不到就是读不到（这台机器的内存控制器没有 EDAC 驱动，很常见），
# 绝不能当成 0，更不能当成故障。
mem_ecc_counts() {
  local ce=0 ue=0 f v got=0
  for f in /sys/devices/system/edac/mc/mc[0-9]*/ce_count \
           /sys/devices/system/edac/mc/mc[0-9]*/ce_noinfo_count; do
    [[ -r "$f" ]] || continue
    v="$(<"$f")"; [[ "$v" =~ ^[0-9]+$ ]] || continue
    ce=$(( ce + v )); got=1
  done
  for f in /sys/devices/system/edac/mc/mc[0-9]*/ue_count \
           /sys/devices/system/edac/mc/mc[0-9]*/ue_noinfo_count; do
    [[ -r "$f" ]] || continue
    v="$(<"$f")"; [[ "$v" =~ ^[0-9]+$ ]] || continue
    ue=$(( ue + v )); got=1
  done
  if (( got )); then printf '%s %s' "$ce" "$ue"; else printf -- '-- --'; fi
}

# 单块盘的温度（摄氏整数），读不到输出空。
#
# /sys/block/<盘>/device/hwmon*/temp1_input 一条路同时覆盖 SATA（drivetemp，
# 内核 5.5+）和 NVMe（nvme 驱动自带 hwmon）。压测期间不能去跑 smartctl ——
# 那会和 fio 抢同一块盘的队列，把带宽数字搞脏。
disk_temp_c() {
  local base="${1:-}" f v
  [[ -n "$base" ]] || return 0
  for f in /sys/block/"$base"/device/hwmon*/temp1_input \
           /sys/block/"$base"/device/device/hwmon*/temp1_input; do
    [[ -r "$f" ]] || continue
    v="$(<"$f")"
    [[ "$v" =~ ^-?[0-9]+$ ]] || continue
    v=$(( v / 1000 ))
    (( v > 0 && v < 150 )) || continue
    printf '%s' "$v"
    return 0
  done
}

# 逐盘的读写速率 -> 每行 "<盘名> <读MB/s> <写MB/s> <IOPS>"
#
# 读 /proc/diskstats 两次求差。和 RAPL 一样是累计计数器，第一次调用只记基准、
# 不输出任何行。字段（内核文档 iostats.rst）：
#   $1 major $2 minor $3 name $4 读完成数 $6 读扇区 $8 写完成数 $10 写扇区
# 扇区一律按 512 字节算（这是块层的固定单位，和盘的物理扇区大小无关）。
# 上一次的读数存在文件里，理由见 sample_state_file。
disk_io_rates() {
  local now dt name rs ws rio wio prev sf prev_ts=""
  now="$(date +%s)"
  local -A cur=()
  while read -r _ _ name rio _ rs _ wio _ ws _; do
    [[ "$name" =~ ^(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+|hd[a-z]+)$ ]] || continue
    [[ "$rs$ws$rio$wio" =~ ^[0-9]+$ ]] || continue
    cur[$name]="$rs $ws $rio $wio"
  done < /proc/diskstats

  sf="$(sample_state_file diskstat.prev)" || return 0
  # 状态文件第一行是时间戳，之后每行 "<盘名> <读扇区> <写扇区> <读次数> <写次数>"
  local -A pv=()
  if [[ -r "$sf" ]]; then
    local first=1 k rest
    while read -r k rest; do
      if (( first )); then prev_ts="$k"; first=0; continue; fi
      [[ -n "$k" ]] && pv[$k]="$rest"
    done < "$sf"
  fi

  if [[ "$prev_ts" =~ ^[0-9]+$ ]]; then
    dt=$(( now - prev_ts ))
    (( dt < 1 )) && dt=1
    for name in "${!cur[@]}"; do
      prev="${pv[$name]:-}"
      [[ -n "$prev" ]] || continue
      # shellcheck disable=SC2086
      set -- $prev
      local prs="$1" pws="$2" prio="$3" pwio="$4"
      # shellcheck disable=SC2086
      set -- ${cur[$name]}
      local crs="$1" cws="$2" crio="$3" cwio="$4"
      (( crs < prs || cws < pws )) && continue     # 计数器重置，这一轮跳过
      printf '%s %s %s %s\n' "$name" \
        $(( (crs - prs) * 512 / 1048576 / dt )) \
        $(( (cws - pws) * 512 / 1048576 / dt )) \
        $(( (crio - prio + cwio - pwio) / dt ))
    done | sort
  fi

  { printf '%s\n' "$now"
    for name in "${!cur[@]}"; do printf '%s %s\n' "$name" "${cur[$name]}"; done
  } > "$sf"
}

# ---------------------------------------------------------------- 杂项
# 秒 -> 人类可读
fmt_dur() {
  local s="$1"
  printf '%dh%02dm%02ds' $((s/3600)) $((s%3600/60)) $((s%60))
}

# 秒 -> HH:MM:SS（仪表盘上等宽好对齐，fmt_dur 那种变长的对不齐）
fmt_hms() {
  local s="${1:-0}"
  [[ "$s" =~ ^[0-9]+$ ]] || s=0
  printf '%02d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60))
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
# BIOS 没填序列号时的各种写法。整机序列号命中就退到主板序列号，
# 主板也命中就退到网卡 MAC。
#
# ⚠️ **这份名单要和 report/generate_report.py 的 BOGUS 一致。**两边不一致的
# 后果是现成的：海光 H210-G30 那台 DMI 里写的是 `Serial Number: N/A`，
# 这边不认、Python 那边认，于是报告抬头「整机序列号 NA」、报告目录也叫 NA，
# 而它主板序列号 24003702CHK04234 是真的、就在同一份 DMI 里。
_serial_is_bogus() {
  local s; s="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
  case "$s" in
    ""|"to be filled by o.e.m."|"not specified"|"default string"|"none" \
      |"unknown"|"n/a"|"na"|"o.e.m."|"empty"|"not present"|"0123456789" \
      |"no dimm"|"system manufacturer"|"system product name" \
      |"system serial number"|"<bad index>"|"<out of spec>"|"-"|"--") return 0 ;;
  esac
  # "To be filled by O.E.M." 各家大小写和尾巴都不一样，前缀再兜一道
  [[ "$s" == "to be filled"* ]]
}

get_serial() {
  local s=""
  if have dmidecode; then
    s="$(dmidecode -s system-serial-number 2>/dev/null | grep -v '^#' | head -1)"
    if _serial_is_bogus "$s"; then
      s="$(dmidecode -s baseboard-serial-number 2>/dev/null | grep -v '^#' | head -1)"
    fi
  fi
  if _serial_is_bogus "$s"; then
    local mac
    mac="$(cat /sys/class/net/*/address 2>/dev/null | grep -v '00:00:00:00:00:00' | head -1 | tr -d ':')"
    s="UNKNOWN-${mac: -6}"
  fi
  # 文件名安全化
  printf '%s' "$s" | tr -cd 'A-Za-z0-9._-' | cut -c1-40
}
