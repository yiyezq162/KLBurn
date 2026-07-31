#!/usr/bin/env bash
# KLBurn 控制台 UI。屏幕上全英文，避免 Linux 文本控制台显示中文变方块。

COLS="$(tput cols 2>/dev/null || echo 80)"
[[ "$COLS" =~ ^[0-9]+$ ]] || COLS=80
(( COLS < 60 )) && COLS=80

hr()  { printf '%s%s%s\n' "$C_GRY" "$(printf '=%.0s' $(seq 1 "$COLS"))" "$C_RST"; }
hr2() { printf '%s%s%s\n' "$C_GRY" "$(printf -- '-%.0s' $(seq 1 "$COLS"))" "$C_RST"; }

section() {
  printf '\n'
  hr
  printf '%s  %s%s\n' "$C_BLD$C_CYN" "$*" "$C_RST"
  hr
}

banner() {
  clear 2>/dev/null || true
  printf '%s' "$C_BLD$C_CYN"
  cat <<'EOF'
  _  ___     ____
 | |/ / |   |  _ \ _   _ _ __ _ __
 | ' /| |   | |_) | | | | '__| '_ \
 | . \| |___|  _ <| |_| | |  | | | |
 |_|\_\_____|_| \_\\__,_|_|  |_| |_|
EOF
  printf '%s' "$C_RST"
  printf '  %sServer Factory Burn-in Test%s   v%s\n' "$C_BLD" "$C_RST" "${KLBURN_VERSION:-?}"
  # 公司名通常是中文，文本控制台打不出来（会变一串 ◆）。
  # 只在纯 ASCII 时才显示；中文名照常进 report.html，不受影响。
  local cn ascii
  cn="${COMPANY_NAME:-}"
  ascii="$(printf '%s' "$cn" | LC_ALL=C tr -cd '\40-\176')"
  [[ -n "$ascii" && "$ascii" == "$cn" ]] && printf '  %s\n' "$cn"
  hr
}

# ---------------------------------------------------------------- 带倒计时的整行输入
# read_line_countdown <变量名> <超时秒> <提示语>
# 返回 0 = 用户按了回车（值在变量里）；返回 1 = 超时
read_line_countdown() {
  local __var="$1" timeout="$2" prompt="$3"
  local buf="" ch start now remaining
  start=$(date +%s)
  while :; do
    now=$(date +%s)
    remaining=$(( timeout - (now - start) ))
    if (( remaining <= 0 )); then
      printf '\n'
      printf -v "$__var" '%s' ''
      return 1
    fi
    printf '\r\033[K%s%s [%3ds]%s %s' "$C_YEL" "$prompt" "$remaining" "$C_RST" "$buf"
    if IFS= read -r -s -t 1 -n 1 ch; then
      case "$ch" in
        '')            printf '\n'; printf -v "$__var" '%s' "$buf"; return 0 ;;
        $'\177'|$'\b') buf="${buf%?}" ;;
        *)             buf+="$ch" ;;
      esac
    fi
  done
}

# ---------------------------------------------------------------- 时长选择菜单
# 结果写到全局 DURATION_PROFILE / DURATION_SECONDS
select_duration() {
  local default_key="2" timeout=30 key start now remaining chosen=""

  section "SELECT TEST DURATION"
  printf '   %s[1]%s  QUICK       10 minutes   (smoke test)\n'       "$C_BLD" "$C_RST"
  printf '   %s[2]%s  STANDARD    30 minutes   (default)\n'          "$C_BLD" "$C_RST"
  printf '   %s[3]%s  EXTENDED     1 hour\n'                         "$C_BLD" "$C_RST"
  printf '   %s[4]%s  LONG         2 hours     (full burn-in)\n'     "$C_BLD" "$C_RST"
  printf '   %s[5]%s  SOAK         4 hours\n'                        "$C_BLD" "$C_RST"
  printf '   %s[6]%s  ENDURANCE    8 hours     (overnight)\n'        "$C_BLD" "$C_RST"
  printf '\n'
  printf '   %sCPU / memory / GPU run concurrently for the full time above.%s\n' "$C_GRY" "$C_RST"
  printf '   %sIf disk stress is confirmed, it adds another 30%% on top.%s\n\n'  "$C_GRY" "$C_RST"

  start=$(date +%s)
  while :; do
    now=$(date +%s)
    remaining=$(( timeout - (now - start) ))
    if (( remaining <= 0 )); then chosen="$default_key"; printf '\n'; break; fi
    printf '\r\033[K  %sPress 1-6 to choose, ENTER to start now.  Auto-start STANDARD in %2ds%s' \
      "$C_YEL" "$remaining" "$C_RST"
    if IFS= read -r -s -t 1 -n 1 key; then
      case "$key" in
        [1-6]) chosen="$key"; printf '\n'; break ;;
        '')    chosen="$default_key"; printf '\n'; break ;;
      esac
    fi
  done

  case "$chosen" in
    1) DURATION_PROFILE="QUICK";     DURATION_SECONDS=600 ;;
    3) DURATION_PROFILE="EXTENDED";  DURATION_SECONDS=3600 ;;
    4) DURATION_PROFILE="LONG";      DURATION_SECONDS=7200 ;;
    5) DURATION_PROFILE="SOAK";      DURATION_SECONDS=14400 ;;
    6) DURATION_PROFILE="ENDURANCE"; DURATION_SECONDS=28800 ;;
    *) DURATION_PROFILE="STANDARD";  DURATION_SECONDS=1800 ;;
  esac
  printf '  %s==> %s (%s total stress time)%s\n\n' \
    "$C_GRN$C_BLD" "$DURATION_PROFILE" "$(fmt_dur "$DURATION_SECONDS")" "$C_RST"
}

# ---------------------------------------------------------------- 最终结论大字
verdict_banner() {
  local verdict="$1"
  printf '\n'
  case "$verdict" in
    PASS)
      printf '%s' "$C_GRN$C_BLD"
      cat <<'EOF'
  ########    ###     ######   ######
  ##     ##  ## ##   ##    ## ##    ##
  ##     ## ##   ##  ##       ##
  ########  ##   ##   ######   ######
  ##        #########       ##       ##
  ##        ##     ## ##    ## ##    ##
  ##        ##     ##  ######   ######
EOF
      ;;
    *)
      printf '%s' "$C_RED$C_BLD"
      cat <<'EOF'
  ########    ###    #### ##
  ##         ## ##    ##  ##
  ##        ##   ##   ##  ##
  ######   ##     ##  ##  ##
  ##       #########  ##  ##
  ##       ##     ##  ##  ##
  ##       ##     ## #### ########
EOF
      ;;
  esac
  printf '%s\n' "$C_RST"
}

# ---------------------------------------------------------------- 进度条（压测期间）
# progress_bar <已用秒> <总秒> <标签>
progress_bar() {
  local elapsed="$1" total="$2" label="$3"
  (( total <= 0 )) && total=1
  # 格式串里除进度条本身外的固定开销正好 39 个字符：
  #   2空格 + 10标签 + 1空格 + '[' + ']' + 1空格 + 3百分比 + '%' + 2空格 + 8耗时 + '/' + 8总时长
  # 整行只要达到或超过终端宽度就会自动换行，\r 随后回到的是换行后的新行，
  # 结果就是每刷新一次多一行、把整屏刷满。留 3 格余量确保永不触发换行。
  local width=$(( COLS - 39 - 3 ))
  (( width < 10 )) && width=10
  local filled=$(( elapsed * width / total ))
  (( filled > width )) && filled=$width
  local pct=$(( elapsed * 100 / total ))
  (( pct > 100 )) && pct=100
  printf '\r\033[K  %-10s [%s%s] %3d%%  %s/%s' \
    "$label" \
    "$(printf '#%.0s' $(seq 1 $((filled>0?filled:0)) ) )" \
    "$(printf ' %.0s' $(seq 1 $((width-filled>0?width-filled:0)) ) )" \
    "$pct" "$(fmt_dur "$elapsed")" "$(fmt_dur "$total")"
}

# ---------------------------------------------------------------- 压测期间的实时读数
#
# 设计上踩过的坑，别再退回去：
#
# 0.6.0/0.7.0 用的是"进度条一行 + 读数一行，画完用 \033[A 把光标挪回去"的
# 粘滞两行区。现场直接翻车：只要有**别的东西**往控制台上写（内核的 OOM 消息、
# bash 的 "... Killed"、并发子 shell 的 info 行），光标就不在预期的位置上了，
# 之后每一次 \r 都回到错的行，进度条碎片被甩到屏幕右边，看着就像整个程序卡死。
# 现场那次从 17:13 一直"卡"到 17:22 —— 其实程序一直在跑，只是屏幕不动了。
#
# 现在的做法是不跟光标较劲：
#   - 进度条仍然是单行 \r 刷新（这条从 0.1.0 起就是对的，没出过问题）
#   - 读数改成**正常打印**的一整块，随屏幕自然滚动，每张卡各占一行
# 就算中间被别的输出插一脚，最多是块和块之间多几行日志，永远不会错位。
# 附带好处：滚上去能看到整个压测过程的温度变化历史。

# gpu_status_rows -> 每行 "序号|型号|温度|功耗|频率|利用率"
#
# 读 gpu_monitor 已经在写的 gpu_metrics.csv 的最后一轮采样，
# **不再单独 fork nvidia-smi**：多卡机器上每次起一个 nvidia-smi 要几百毫秒，
# 还会和压测抢 GPU。
#
# ⚠️ 不能用 `for (i in rows)` 遍历 —— awk 的关联数组无序，多卡机器上
# 卡号顺序每次都不一样，看着像在乱跳。按 1..n 顺序走。
gpu_status_rows() {
  local csv="${1:-${RUN_DIR:-}/gpu_metrics.csv}"
  [[ -s "$csv" ]] || return 0
  awk -F, 'NR>1 && NF>=7 { last=$1; rows[++n]=$0 }
           END {
             for (i = 1; i <= n; i++) {
               split(rows[i], c, ",")
               if (c[1] == last)
                 printf "%s|%s|%s|%s|%s|%s\n", c[2], c[3], c[4], c[5], c[6], c[7]
             }
           }' "$csv" 2>/dev/null
}

# 一整块实时读数。全英文：Linux 文本控制台显示不了中文。
status_block() {
  local elapsed="$1" total="$2"
  local f p line idx name temp power clk util

  hr2
  printf '  %s%s%s  BURN-IN  %s / %s\n' \
    "$C_BLD" "$(tss)" "$C_RST" "$(fmt_dur "$elapsed")" "$(fmt_dur "$total")"

  # ---- CPU：逐颗封装温度各占一行，和下面的 GPU 行左对齐 ----
  # 列宽写死成和 GPU 行一致，这样 CPU0/CPU1/GPU0/GPU1 的编号、温度、功耗
  # 都落在同一列上，扫一眼就能看出哪颗/哪张偏高。
  f="$(cpu_freq_avg_mhz)"
  p="$(cpu_power_w)"
  local got=0 first=1
  while read -r idx temp; do
    [[ -n "$idx" ]] || continue
    got=1
    if (( first )); then
      # 频率和封装功耗是整机级的读数，只挂在第一行后面，不逐颗重复
      printf '   %-5s %3s C  %6s W  %6s MHz\n' \
        "$idx" "$temp" "${p:---}" "${f:---}"
      first=0
    else
      printf '   %-5s %3s C\n' "$idx" "$temp"
    fi
  done < <(cpu_temp_per_pkg)
  if (( got == 0 )); then
    # 读不到温度是正常情况（服务器 CPU 的温度驱动不一定是 coretemp），
    # 照样把频率和功耗打出来，不要整行消失
    printf '   %-5s %5s  %6s W  %6s MHz\n' "CPU" "n/a" "${p:---}" "${f:---}"
  fi

  # ---- GPU：一张卡一行 ----
  while IFS='|' read -r idx name temp power clk util; do
    [[ -n "$idx" ]] || continue
    printf '   %-5s %3s C  %6s W  %6s MHz  util %3s%%  %s\n' \
      "GPU$idx" "${temp:---}" "${power:---}" "${clk:---}" "${util:---}" "$name"
  done < <(gpu_status_rows)

  hr2
}

# ---------------------------------------------------------------- 并发压测的合并进度条
# CPU / 内存 / GPU 现在是并发跑的三个子 shell，各自不能再画自己的进度条——
# 三条 \r\033[K 互相抢同一行，画出来的是乱码。改成这里画一条共享进度条，
# 按外面传的总秒数走，但退出条件是"所有给定 PID 都结束了"而不是单纯到点：
# 到点了但压测子进程还没退出（真跑慢了）就继续在 100% 停着刷新，
# 如实反映"还没测完"而不是假装已经收工。
#
# progress_bar_concurrent <总秒数> <标签> <pid...>
progress_bar_concurrent() {
  local total="$1" label="$2"; shift 2
  local pids=("$@")
  local start; start=$(date +%s)

  # RAPL 是累计计数器，先打一次基准，不然第一块读数的功耗是空的
  cpu_power_w >/dev/null 2>&1 || true

  # 读数块的间隔：按总时长自适应，全程大约打 20 块。
  # 10min -> 30s，30min -> 90s，2h -> 6min，8h -> 24min。
  # 固定 30 秒的话，八小时的耐久测试会刷出近千块，把屏幕淹掉。
  local interval="${STATUS_BLOCK_INTERVAL:-0}"
  if (( interval <= 0 )); then
    interval=$(( total / 20 ))
    (( interval < 30 )) && interval=30
  fi

  # 一上来先打一块，让现场立刻看到机器确实在动、温度在爬
  status_block 0 "$total"

  local last_block=0
  while :; do
    local alive=0 p
    for p in "${pids[@]}"; do
      kill -0 "$p" 2>/dev/null && alive=$((alive+1))
    done
    local now elapsed; now=$(date +%s); elapsed=$(( now - start ))

    progress_bar "$elapsed" "$total" "$label"

    if (( elapsed - last_block >= interval )); then
      # 换行把进度条那一行留在屏幕上，读数块正常往下滚。
      # 不用 \033[A 之类的光标移动 —— 别的东西往控制台写一行就会全乱套。
      printf '\n'
      status_block "$elapsed" "$total"
      last_block=$elapsed
    fi

    (( alive == 0 )) && break
    sleep 2
  done

  progress_bar "$total" "$total" "$label"
  printf '\n'
  status_block "$total" "$total"
}
