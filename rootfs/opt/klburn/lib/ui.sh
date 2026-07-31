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
  printf '   %s[1]%s  QUICK      10 minutes   (smoke test)\n'      "$C_BLD" "$C_RST"
  printf '   %s[2]%s  STANDARD   30 minutes   (default)\n'         "$C_BLD" "$C_RST"
  printf '   %s[3]%s  LONG        2 hours     (full burn-in)\n'    "$C_BLD" "$C_RST"
  printf '\n'

  start=$(date +%s)
  while :; do
    now=$(date +%s)
    remaining=$(( timeout - (now - start) ))
    if (( remaining <= 0 )); then chosen="$default_key"; printf '\n'; break; fi
    printf '\r\033[K  %sPress 1/2/3 to choose, ENTER to start now.  Auto-start STANDARD in %2ds%s' \
      "$C_YEL" "$remaining" "$C_RST"
    if IFS= read -r -s -t 1 -n 1 key; then
      case "$key" in
        1|2|3) chosen="$key"; printf '\n'; break ;;
        '')    chosen="$default_key"; printf '\n'; break ;;
      esac
    fi
  done

  case "$chosen" in
    1) DURATION_PROFILE="QUICK";    DURATION_SECONDS=600 ;;
    3) DURATION_PROFILE="LONG";     DURATION_SECONDS=7200 ;;
    *) DURATION_PROFILE="STANDARD"; DURATION_SECONDS=1800 ;;
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
  while :; do
    local alive=0 p
    for p in "${pids[@]}"; do
      kill -0 "$p" 2>/dev/null && alive=$((alive+1))
    done
    local now elapsed; now=$(date +%s); elapsed=$(( now - start ))
    progress_bar "$elapsed" "$total" "$label"
    (( alive == 0 )) && break
    sleep 2
  done
  printf '\n'
}
