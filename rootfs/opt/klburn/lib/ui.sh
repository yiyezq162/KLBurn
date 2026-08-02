#!/usr/bin/env bash
# KLBurn 控制台 UI。屏幕上全英文，避免 Linux 文本控制台显示中文变方块。

COLS="$(tput cols 2>/dev/null || echo 80)"
[[ "$COLS" =~ ^[0-9]+$ ]] || COLS=80
(( COLS < 60 )) && COLS=80

ROWS="$(tput lines 2>/dev/null || echo 25)"
[[ "$ROWS" =~ ^[0-9]+$ ]] || ROWS=25
(( ROWS < 24 )) && ROWS=25

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
  # 大字和下面各个页面用的是**同一套**（_BRAND_ART），改一处两边都变。
  # 以前这里是内嵌的 heredoc，和页面上的那份各画各的，改一处另一处就对不上了。
  local i
  for i in "${!_BRAND_ART[@]}"; do
    printf '%s%s%s\n' "$C_GRN$C_BLD" "${_BRAND_ART[i]}" "$C_RST"
  done
  printf '  %s%s   v%s%s\n' "$C_GRN" "$BRAND_TAGLINE" "${KLBURN_VERSION:-?}" "$C_RST"
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

  brand_bar "$(panel_width)" "SELECT DURATION"
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

# ================================================================
# 屏幕面板
# ================================================================
#
# 三条硬约束，改这一段之前先读 docs/architecture.md §11-14 / §11-23：
#
#   1. **框线只用 ASCII（+ - | =）。** 现场是通过 BMC 的 KVM 或串口看这块屏幕的，
#      字体和字符集都不受我们控制，Unicode 制表符有很大概率变成一屏乱码 ——
#      而这块屏幕是操作员判断"机器现在什么状态"的唯一依据。
#
#   2. **屏幕上一律英文。** Linux 文本控制台显示不了中文。中文只进 HTML 报告。
#      所有进面板的文本都过 ascii_clean()：型号串来自 dmidecode / nvidia-smi，
#      理论上带得进非 ASCII 字节，而一个字节就能把整屏顶花。
#      这是"屏幕上不许出现非 ASCII"这条不变量**唯一的收口处**。
#
#   3. **不用 \033[A 做粘滞刷新区**（§11-14：只要有别的东西往控制台上写，
#      光标就不在预期位置，之后每次 \r 都回到错的行，看着像整个程序卡死）。
#      改成"整屏定期重绘"：每 2 秒回绝对原点、原地把每一行盖一遍。被别人写脏了，
#      下一次重绘自动修好。前提是把别的写入源掐干净 ——
#      压测子进程的输出全部重定向进日志文件，进仪表盘前 console_quiet_on
#      把内核消息压下去。
#
# 渲染函数一律是**纯函数**：只吃数据、只吐printable ASCII，不碰硬件、不带颜色。
# 这样 tests/test-screen-render.sh 可以直接喂 fixture 断言行数/列宽/字符集。

# 只留可打印 ASCII。控制字符、ESC、中文全部丢掉。
ascii_clean() { printf '%s' "$*" | LC_ALL=C tr -cd '\40-\176'; }

# 一段多行文本有几行非空行。core.sh 的 count_lines 吃的是**文件名**，这里吃的是串。
# 和它一样必须过一遍数字校验：grep -c 在没匹配时退 1，直接塞进 (( )) 会炸。
_nlines() {
  local n; n="$(printf '%s\n' "${1:-}" | grep -c . || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

# 面板宽度：跟着终端走，但夹在 80~120 之间。
#   下限 80 —— 串口和多数 BMC KVM 就是 80 列，再窄的布局没意义
#   上限 120 —— 再宽一行扫不过来，而且表格拉得太开反而难对齐
panel_width() {
  local w="${COLS:-80}"
  [[ "$w" =~ ^[0-9]+$ ]] || w=80
  (( w < 80 ))  && w=80
  (( w > 120 )) && w=120
  printf '%s' "$w"
}

# str_put <底串> <起始位置(0基)> <要盖上去的串> -> 新串
# 纯字符串操作，不 fork。越界一律裁掉，绝不让行变长（变长就折行，折行就滚屏）。
str_put() {
  local base="$1" pos="$2" s="$3"
  [[ "$pos" =~ ^-?[0-9]+$ ]] || pos=0
  (( pos < 0 )) && pos=0
  local blen=${#base}
  (( pos >= blen )) && { printf '%s' "$base"; return; }
  (( pos + ${#s} > blen )) && s="${s:0:blen-pos}"
  printf '%s%s%s' "${base:0:pos}" "$s" "${base:pos+${#s}}"
}

# ---------------------------------------------------------------- 调色板
#
# ⚠️ **颜色只加在边框层，绝不进内容串。**
#
# 这不是风格问题，是算宽度的问题：列宽全靠 `printf '%-*.*s'` 补齐/截断，
# 而它数的是**字符个数**。颜色码一旦混进内容串，那几个转义字节会被算成可见字符，
# 补出来的行就短一截 —— 整屏重绘立刻错位，越刷越花。
# 所以流程是固定的：**先按纯文本把行补齐到精确宽度，再在两头包颜色码。**
# 颜色码是零宽的，包完屏幕上的列位一点没动。
#
# 另一条：颜色是**可以整体关掉**的（PANEL_COLOR=0，或者 stdout 不是 tty）。
# 关掉之后输出和上色前一字不差 —— 写进 raw/config-review.txt 的那份就是关掉的，
# 存档和 e2e 的日志锚点都不该带转义码。
# tests/test-screen-render.sh 里有一条断言钉着这件事：
# **把颜色码去掉之后，必须和关掉颜色时的输出完全相同。**
: "${PANEL_COLOR:=1}"
declare -A PC=()
panel_palette() {
  local on="${1:-0}"
  PC=(
    [frame]="" [rst]="" [hdr]="" [ok]="" [warn]="" [bad]="" [dim]="" [none]=""
    [eol]="" [brand]="" [brandsub]=""
  )
  (( on )) || return 0
  [[ -n "${C_RST:-}" ]] || return 0      # 不是 tty（core.sh 已经把 C_* 置空）
  # 每行末尾抹到行尾。**去掉整屏清空之后这条是必须的**：
  # 面板只有 80~120 列，而上一屏（开机日志）可能是 160 列的 ——
  # 原地覆盖只盖得住前 120 列，右边那截尾巴会一直留在屏幕上。
  # e2e 截图里看得清清楚楚：面板右边挂着一串上一屏的 === 碎片。
  # 和颜色一样受 PANEL_COLOR 管：生成给文件的那份不能带任何转义码。
  PC[eol]=$'\033[K'
  # 大字标题：绿色加粗。**不用反显** —— 试过一条实心色块横杠，
  # 在真控制台上太扎眼，而且和下面的 ASCII 框线是两种视觉语言，凑一起反而乱。
  PC[brand]="$C_GRN$C_BLD"
  PC[brandsub]="$C_GRN"
  PC[frame]="$C_CYN"; PC[rst]="$C_RST"
  PC[hdr]="$C_BLD$C_CYN"
  PC[ok]="$C_GRN"; PC[warn]="$C_YEL"; PC[bad]="$C_RED$C_BLD"; PC[dim]="$C_GRY"
}
panel_palette "$PANEL_COLOR"

box_rule() {
  printf '%s+%s+%s%s\n' "${PC[frame]}" \
    "$(printf '%*s' "$(( ${1:-80} - 2 ))" '' | tr ' ' '=')" "${PC[rst]}" "${PC[eol]}"
}
box_sep() {
  printf '%s+%s+%s%s\n' "${PC[frame]}" \
    "$(printf '%*s' "$(( ${1:-80} - 2 ))" '' | tr ' ' '-')" "${PC[rst]}" "${PC[eol]}"
}

# box_row <宽> <内容> [颜色名]
# 颜色名取 PC 里的键：hdr / ok / warn / bad / dim，不给就是默认色。
box_row() {
  local inner=$(( ${1:-80} - 2 )) s pad
  s="$(ascii_clean "${2:-}")"
  # 先按纯文本补齐/截断到精确宽度，再包颜色 —— 顺序反了就会错位
  printf -v pad '%-*.*s' "$inner" "$inner" "$s"
  printf '%s|%s%s%s%s%s|%s%s\n' \
    "${PC[frame]}" "${PC[rst]}" "${PC[${3:-none}]-}" "$pad" \
    "${PC[rst]}" "${PC[frame]}" "${PC[rst]}" "${PC[eol]}"
}

# ---------------------------------------------------------------- 标题条
#
# **每一块整屏页面的第一块都是它**：配置核对、压测仪表盘、硬盘视角、
# 破坏性写确认、时长菜单、最终结论。现场看到的不该是"一屏滚动的日志"，
# 而是一个有名字的软件 —— 尤其这块屏幕经常被拍照发群里。
#
# 版本号取自 klburn.conf（构建时钉进盘里的），这里不写死。
# 公司名多半是中文，文本控制台打不出来，只进 HTML 报告 —— 见 banner()。
: "${BRAND_TAGLINE:=Server Factory Burn-in Test}"

# 大字标题。就是开机 banner 那套 ASCII 艺术字，从 0.x 一直用到现在 ——
# 现场认的就是它。**绿色**，下面跟一行 "说明 + 版本号"。
#
# 为什么不用反显的实心横杠：试过，在真控制台上一整条色块很扎眼，
# 而且和下面的框线是两种视觉语言，凑在一起反而乱。大字是这个产品本来的样子。
_BRAND_ART=(
'  _  ___     ____                '
' | |/ / |   |  _ \ _   _ _ __ _ __ '
" | ' /| |   | |_) | | | | '__| '_ \\ "
' | . \| |___|  _ <| |_| | |  | | | |'
' |_|\_\_____|_| \_\\__,_|_|  |_| |_|'
)

# 标题条实际占几行。每一屏都要按它算还剩多少行能放内容 ——
# 写死成 1 的话，高屏上大字一占六行，最下面那一段就被挤出屏幕外了。
#
# BRAND_COMPACT=1 是**装不下时的退路**：整屏重绘一旦超出屏幕高度就会滚屏，
# 滚完之后 ESC[H 回的"绝对原点"和面板第一行就不是同一行了，越刷越歪。
# 所以画之前先数行数，宁可把大字退成一行，也不能让数据被挤下去。
: "${BRAND_COMPACT:=0}"
brand_rows() {
  if (( ROWS < 28 )) || (( BRAND_COMPACT )); then printf 1
  else printf '%s' $(( ${#_BRAND_ART[@]} + 1 )); fi
}

# brand_fit <这一屏除标题条以外要占的行数>
# 大字放得下就放大字，放不下就退成一行。每帧都重新判一次 ——
# 插一张热插拔的盘、多认出一颗 CPU，行数是会变的。
brand_fit() {
  BRAND_COMPACT=0
  (( ${1:-0} + $(brand_rows) > ROWS )) && BRAND_COMPACT=1
  return 0
}

# brand_bar <宽> [右侧文字]
#
# 名字沿用 brand_bar（调用点都不用改）。窄屏上退化成一行 ——
# 80x25 的 BMC 控制台上，大字要占掉六行，配置核对那一屏就没地方了。
brand_bar() {
  local w="${1:-80}" right line tag i
  right="$(ascii_clean "${2:-}")"
  tag="$(ascii_clean "${BRAND_TAGLINE}")"
  local ver; ver="$(ascii_clean "v${KLBURN_VERSION:-?}")"

  if (( $(brand_rows) == 1 )); then
    # 矮屏 / 这一屏装不下：一行搞定，不占地方
    line="$(printf '%*s' "$w" '')"
    line="$(str_put "$line" 1 "$(ascii_clean "${PRODUCT_NAME:-KLBurn}") $ver  $tag")"
    [[ -n "$right" ]] && line="$(str_put "$line" $(( w - ${#right} - 1 )) "$right")"
    printf '%s%s%s%s\n' "${PC[brand]}" "$line" "${PC[rst]}" "${PC[eol]}"
    return 0
  fi

  for i in "${!_BRAND_ART[@]}"; do
    printf '%s%s%s%s\n' "${PC[brand]}" "$(ascii_clean "${_BRAND_ART[i]}")" \
      "${PC[rst]}" "${PC[eol]}"
  done
  # 说明行：左边"说明 + 版本"，右边当前是哪一页
  line="$(printf '%*s' "$w" '')"
  line="$(str_put "$line" 1 "$tag   $ver")"
  [[ -n "$right" ]] && line="$(str_put "$line" $(( w - ${#right} - 1 )) "$right")"
  printf '%s%s%s%s\n' "${PC[brandsub]}" "$line" "${PC[rst]}" "${PC[eol]}"
}

# box_row3 <宽> <左> <中> <右>  —— 抬头那一行：左中右三段各就各位
box_row3() {
  local inner=$(( ${1:-80} - 2 )) l c r line
  l="$(ascii_clean "${2:-}")"; c="$(ascii_clean "${3:-}")"; r="$(ascii_clean "${4:-}")"
  line="$(printf '%*s' "$inner" '')"
  line="$(str_put "$line" 2 "$l")"
  line="$(str_put "$line" $(( (inner - ${#c}) / 2 )) "$c")"
  line="$(str_put "$line" $(( inner - ${#r} - 2 )) "$r")"
  printf '%s|%s%s%s%s%s|%s%s\n' \
    "${PC[frame]}" "${PC[rst]}" "${PC[hdr]}" "$line" \
    "${PC[rst]}" "${PC[frame]}" "${PC[rst]}" "${PC[eol]}"
}

# 整屏重绘的头尾。用裸转义而不是 clear(1)：clear 要 fork、要 terminfo，
# 而这两条每 2 秒跑一次。
#
# ⚠️ **只回原点，不清屏。**
# 一开始写的是 ESC[H + ESC[2J（先清空再逐行画）。问题是清空和画完之间有个空窗：
# 十几行、每行还要 fork 一次 tr，在慢一点的机器上要几十毫秒 ——
# 人眼看到的就是**每 2 秒闪一下**，BMC 的 KVM 延迟更高会更明显。
# e2e 截图正好逮到过一张只画了两行的（截图落在空窗里）。
#
# 改成回原点**原地覆盖**：每行画完都到行尾，写满就自然盖掉旧内容；
# 最后一行之后用 ESC[J 抹掉下面可能残留的（上一帧更高时才有）。
# 屏幕上任何时刻都是一整屏内容，没有空白帧。
#
# 这**不是** §11-14 说的那种粘滞刷新区：那条禁的是 ESC[A（光标往回挪 N 行），
# 别人往控制台写一行就会错位。这里每帧都回**绝对原点**，被写脏了下一帧照样
# 从第一行盖回来，自愈性和清屏那版完全一样。
screen_home() { printf '\033[H'; }
screen_end()  { printf '\033[J'; }

# ---------------------------------------------------------------- 掐掉别的写入源
# 整屏重绘的前提是"只有我们在往控制台写"。内核消息（PCIe AER、EDAC、nvme reset）
# 会在压测期间随时插进来，把刚画好的面板顶掉一半。
# 只压 **console** 的 loglevel，不动 ring buffer —— dmesg 采集和 OOM 判定
# 读的都是 ring buffer，一个字都不会少。
_PRINTK_SAVED=""
console_quiet_on() {
  [[ -r /proc/sys/kernel/printk ]] || return 0
  _PRINTK_SAVED="$(awk '{print $1}' /proc/sys/kernel/printk 2>/dev/null)"
  [[ "$_PRINTK_SAVED" =~ ^[0-9]+$ ]] || { _PRINTK_SAVED=""; return 0; }
  dmesg -n 1 >/dev/null 2>&1 || true
}
console_quiet_off() {
  [[ -n "$_PRINTK_SAVED" ]] || return 0
  dmesg -n "$_PRINTK_SAVED" >/dev/null 2>&1 || true
  _PRINTK_SAVED=""
}

# ---------------------------------------------------------------- 数据源
# gpu_status_rows -> 每行 "序号|型号|温度|功耗|频率|利用率|显存已用MB"
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
  awk -F, 'NR>1 && NF>=8 { last=$1; rows[++n]=$0 }
           END {
             for (i = 1; i <= n; i++) {
               split(rows[i], c, ",")
               if (c[1] == last)
                 printf "%s|%s|%s|%s|%s|%s|%s\n", c[2], c[3], c[4], c[5], c[6], c[7], c[8]
             }
           }' "$csv" 2>/dev/null
}

# 显存总量（MB），逐卡一行 "序号 总量"。开仪表盘时问一次就够了 —— 它不会变。
GPU_MEM_TOTAL=""
gpu_mem_total_init() {
  [[ -z "$GPU_MEM_TOTAL" ]] || return 0
  have nvidia-smi || { GPU_MEM_TOTAL=" "; return 0; }
  GPU_MEM_TOTAL="$(nvidia-smi --query-gpu=index,memory.total \
                    --format=csv,noheader,nounits 2>/dev/null \
                   | sed 's/[[:space:]]*,[[:space:]]*/ /g')"
  [[ -n "$GPU_MEM_TOTAL" ]] || GPU_MEM_TOTAL=" "
}

# ---------------------------------------------------------------- 仪表盘：各分区
# 每个 dash_* 都是纯函数：吃已经取好的数据行，吐若干条 box_row。
# 硬件不在就**整块不画**，不要铺一屏 "N/A" 占地方。

# dash_cpu_rows <宽> <数据>   数据每行 "序号|型号|频率MHz|温度C|占用%"
dash_cpu_rows() {
  local w="$1" data="$2" idx model freq temp busy busytxt color
  [[ -n "$data" ]] || return 0
  box_row "$w" "  CPU     MODEL                              FREQ      TEMP    BUSY" hdr
  while IFS='|' read -r idx model freq temp busy; do
    [[ -n "$idx" ]] || continue
    # 读不到就画 "--"，绝不画 0 —— 0°C / 0% 看着像读数，"--" 才是实话。
    # 而且读不到温度是**正常情况**（服务器 CPU 的温度驱动不一定是 coretemp），
    # 不是故障，判定那边也是这个口径。
    busytxt='--'
    [[ "$busy" =~ ^[0-9]+$ ]] && busytxt="${busy}%"
    # 整行按温度上色，用的就是判定那两条线（klburn.conf 改了阈值，这里跟着变）。
    # 读不到温度不上色 —— 读不到不是"正常"也不是"异常"，不该给任何暗示。
    color="none"
    if [[ "$temp" =~ ^[0-9]+$ ]]; then
      if   (( temp >= ${CPU_TEMP_FAIL:-100} )); then color="bad"
      elif (( temp >= ${CPU_TEMP_WARN:-95} ));  then color="warn"
      else color="ok"; fi
    fi
    box_row "$w" "$(printf '   #%-4s  %-32.32s %6s MHz  %4s C  %4s' \
      "$idx" "$model" "${freq:-  --}" "${temp:-  --}" "$busytxt")" "$color"
  done <<< "$data"
}

# dash_gpu_rows <宽> <数据>  数据每行 "序号|型号|显存已用MB|显存总量MB|温度|功耗|利用率"
#
# 最多画 8 张，再多就一行 "and N more" 收口 —— 8 卡机器已经占满半屏了，
# 全铺开会把进度条挤出屏幕，而那是现场最需要看到的一行。
DASH_GPU_MAX=8
dash_gpu_rows() {
  local w="$1" data="$2" idx name mu mt temp power util n=0 total
  [[ -n "$data" ]] || return 0
  total="$(printf '%s\n' "$data" | grep -c . || true)"
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  box_row "$w" "  GPU   MODEL                       MEMORY            TEMP   POWER   UTIL" hdr
  while IFS='|' read -r idx name mu mt temp power util; do
    [[ -n "$idx" ]] || continue
    n=$(( n + 1 ))
    if (( n > DASH_GPU_MAX )); then
      box_row "$w" "$(printf '   ... and %d more (all included in the report)' \
        "$(( total - DASH_GPU_MAX ))")"
      break
    fi
    local memtxt='--' utiltxt='--'
    if [[ "$mu" =~ ^[0-9]+$ && "$mt" =~ ^[0-9]+$ ]] && (( mt > 0 )); then
      memtxt="$(awk -v u="$mu" -v t="$mt" 'BEGIN{printf "%.1f/%.1f GB", u/1024, t/1024}')"
    elif [[ "$mu" =~ ^[0-9]+$ ]]; then
      memtxt="$(awk -v u="$mu" 'BEGIN{printf "%.1f GB used", u/1024}')"
    fi
    [[ "$util" =~ ^[0-9]+$ ]] && utiltxt="${util}%"
    local gcolor="none"
    if [[ "$temp" =~ ^[0-9]+$ ]]; then
      if   (( temp >= ${GPU_TEMP_FAIL:-90} )); then gcolor="bad"
      elif (( temp >= ${GPU_TEMP_WARN:-83} )); then gcolor="warn"
      else gcolor="ok"; fi
    fi
    box_row "$w" "$(printf '   %-3s  %-26.26s %-16s %4s C  %5s W  %4s' \
      "$idx" "$name" "$memtxt" "${temp:-  --}" "${power:-   --}" "$utiltxt")" "$gcolor"
  done <<< "$data"
}

# dash_disk_rows <宽> <数据>  数据每行 "盘名|读MB/s|写MB/s|IOPS|温度C"
dash_disk_rows() {
  local w="$1" data="$2" name rd wr iops temp
  [[ -n "$data" ]] || return 0
  box_row "$w" "  DISK        READ        WRITE          IOPS   TEMP" hdr
  local dcolor
  while IFS='|' read -r name rd wr iops temp; do
    [[ -n "$name" ]] || continue
    dcolor="none"
    if [[ "$temp" =~ ^[0-9]+$ ]]; then
      if   (( temp >= ${DISK_TEMP_FAIL:-80} )); then dcolor="bad"
      elif (( temp >= ${DISK_TEMP_WARN:-70} )); then dcolor="warn"
      else dcolor="ok"; fi
    fi
    box_row "$w" "$(printf '   %-10s %5s MB/s  %5s MB/s  %8s   %4s C' \
      "$name" "${rd:-  --}" "${wr:-  --}" "${iops:-  --}" "${temp:-  --}")" "$dcolor"
  done <<< "$data"
}

# dash_progress <宽> <已用秒> <总秒>  -> 进度条那两行（不含边框以外的东西）
dash_progress() {
  local w="$1" elapsed="$2" total="$3"
  (( total <= 0 )) && total=1
  (( elapsed < 0 )) && elapsed=0
  local remain=$(( total - elapsed )); (( remain < 0 )) && remain=0
  local pct=$(( elapsed * 100 / total )); (( pct > 100 )) && pct=100

  box_row "$w" "$(printf '  ELAPSED %s   REMAINING %s' \
    "$(fmt_hms "$elapsed")" "$(fmt_hms "$remain")")"

  # 条宽 = 内框宽 - 前后留白 - "[]" - "  100%"
  local bw=$(( w - 2 - 2 - 2 - 6 ))
  (( bw < 10 )) && bw=10
  local filled=$(( elapsed * bw / total ))
  (( filled > bw )) && filled=$bw
  (( filled < 0 ))  && filled=0
  box_row "$w" "$(printf '  [%s%s] %3d%%' \
    "$(printf '%*s' "$filled" '' | tr ' ' '#')" \
    "$(printf '%*s' "$(( bw - filled ))" '' | tr ' ' '.')" \
    "$pct")"
}

# ---------------------------------------------------------------- 仪表盘：整屏
# dash_burn <宽> <抬头右侧> <阶段名> <已用秒> <总秒>
# 数据从硬件现取（这是唯一一个会碰硬件的函数，上面那些全是纯渲染）。
dash_burn() {
  local w="$1" right="$2" phase="$3" elapsed="$4" total="$5"

  # ---- CPU：逐颗 ----
  local -A freq=() temp=() busy=()
  local p v model; model="$(cpu_model_display)"
  while read -r p v; do [[ -n "$p" ]] && freq[$p]="$v"; done < <(cpu_freq_per_pkg)
  while read -r p v; do [[ -n "$p" ]] && busy[$p]="$v"; done < <(cpu_pkg_busy_pct)
  local i=0
  while read -r p v; do
    [[ -n "$p" ]] || continue
    temp[$i]="$v"; i=$(( i + 1 ))
  done < <(cpu_temp_per_pkg)

  local cpu_data="" idxs
  idxs="$(printf '%s\n' "${!freq[@]}" "${!temp[@]}" "${!busy[@]}" | grep -E '^[0-9]+$' | sort -un)"
  # 一颗都认不出来（虚拟机/容器里）也要有一行，否则整块 CPU 凭空消失
  [[ -n "$idxs" ]] || idxs="0"
  while read -r p; do
    [[ -n "$p" ]] || continue
    cpu_data+="${p}|${model}|${freq[$p]:-}|${temp[$p]:-}|${busy[$p]:-}"$'\n'
  done <<< "$idxs"

  # ---- 内存 / 存储 / 网口：各一行汇总 ----
  local mu mt ce ue memline
  read -r mu mt < <(mem_used_total_mb)
  read -r ce ue < <(mem_ecc_counts)
  if [[ "$mu" =~ ^[0-9]+$ && "$mt" =~ ^[0-9]+$ ]]; then
    memline="$(awk -v u="$mu" -v t="$mt" 'BEGIN{printf "Used   %.0f / %.0f GB", u/1024, t/1024}')"
  else
    memline="Used   --"
  fi

  local nic_up=0 nic_all=0 n st
  for n in /sys/class/net/*; do
    [[ -e "$n/device" ]] || continue
    nic_all=$(( nic_all + 1 ))
    st="$(cat "$n/operstate" 2>/dev/null || true)"
    [[ "$st" == "up" ]] && nic_up=$(( nic_up + 1 ))
  done

  local gpu_data="" g_idx g_name g_temp g_pow g_clk g_util g_mem
  gpu_mem_total_init
  while IFS='|' read -r g_idx g_name g_temp g_pow g_clk g_util g_mem; do
    [[ -n "$g_idx" ]] || continue
    local g_tot; g_tot="$(awk -v i="$g_idx" '$1==i{print $2; exit}' <<< "$GPU_MEM_TOTAL")"
    gpu_data+="${g_idx}|${g_name}|${g_mem}|${g_tot}|${g_temp}|${g_pow}|${g_util}"$'\n'
  done < <(gpu_status_rows)

  # ---- 画 ----
  # 先数一遍除标题条以外要占几行，装不下就让标题条退成一行（见 brand_rows）。
  # 顶框+抬头+抬头下框 3，CPU 表头 1，分隔 1，MEMORY/NETWORK 2，
  # 底下 框+进度两行+框 4。
  local body=$(( 3 + 1 + $(_nlines "$cpu_data") + 1 + 2 + 4 ))
  if [[ -n "$gpu_data" ]]; then
    local ng; ng="$(_nlines "$gpu_data")"
    body=$(( body + 2 + (ng < DASH_GPU_MAX ? ng : DASH_GPU_MAX + 1) ))
  fi
  brand_fit "$body"

  screen_home
  brand_bar "$w" "$right"
  box_rule "$w"
  box_row3 "$w" "" "$phase" ""
  box_rule "$w"
  dash_cpu_rows "$w" "${cpu_data%$'\n'}"
  box_sep "$w"
  # ECC：不可纠正红、可纠正黄、明确读到 0 才给绿；读不到（"--"）不上色。
  # 和 verify_ecc 的判定口径一致 —— 屏幕上的颜色不能和最后的结论打架。
  local ecolor="none"
  if   [[ "$ue" =~ ^[0-9]+$ ]] && (( ue > 0 )); then ecolor="bad"
  elif [[ "$ce" =~ ^[0-9]+$ ]] && (( ce > 0 )); then ecolor="warn"
  elif [[ "$ce" =~ ^[0-9]+$ && "$ue" =~ ^[0-9]+$ ]]; then ecolor="ok"
  fi
  box_row "$w" "$(printf '  MEMORY   %-26s ECC  CE %s / UE %s' "$memline" "$ce" "$ue")" "$ecolor"

  local ncolor="none"
  if   (( nic_up > 0 ));  then ncolor="ok"
  elif (( nic_all > 0 )); then ncolor="dim"     # 有口但一个都没起来
  fi
  box_row "$w" "$(printf '  NETWORK  %d ports, %d up' "$nic_all" "$nic_up")" "$ncolor"
  if [[ -n "$gpu_data" ]]; then
    box_sep "$w"
    dash_gpu_rows "$w" "${gpu_data%$'\n'}"
  fi
  box_rule "$w"
  dash_progress "$w" "$elapsed" "$total"
  box_rule "$w"
  screen_end
}

# dash_disk <宽> <抬头右侧> <阶段名> <已用秒> <总秒>
dash_disk() {
  local w="$1" right="$2" phase="$3" elapsed="$4" total="$5"
  local data="" name rd wr iops d base
  while read -r name rd wr iops; do
    [[ -n "$name" ]] || continue
    # 只画正在被压的那几块盘，别把系统盘和 U 盘也铺上来
    local wanted=0
    for d in "${DISK_CAND[@]:-}"; do
      base="$(basename "${d:-}")"
      [[ "$base" == "$name" ]] && { wanted=1; break; }
    done
    (( wanted )) || continue
    data+="${name}|${rd}|${wr}|${iops}|$(disk_temp_c "$name")"$'\n'
  done < <(disk_io_rates)

  local body=$(( 3 + 4 ))
  if [[ -n "$data" ]]; then body=$(( body + 1 + $(_nlines "$data") ))
  else body=$(( body + 1 )); fi
  brand_fit "$body"

  screen_home
  brand_bar "$w" "$right"
  box_rule "$w"
  box_row3 "$w" "" "$phase" ""
  box_rule "$w"
  if [[ -n "$data" ]]; then
    dash_disk_rows "$w" "${data%$'\n'}"
  else
    box_row "$w" "  DISK   warming up (first sample gives no rate yet) ..."
  fi
  box_rule "$w"
  dash_progress "$w" "$elapsed" "$total"
  box_rule "$w"
  screen_end
}

# ================================================================
# 开机后、压测前的「机器配置核对」面板
# ================================================================
#
# 为什么要有这一屏：以前配置只有出报告才看得到，现场没法在开跑之前核对
# "这台机器到底装了什么"。少一条内存、少一张网卡、少一块盘，等三十分钟
# 压测跑完才发现，白等。
#
# 三条规矩：
#   1. 数据**全部来自已经采集好的 raw/ 文件和全局数组**，不为了这一屏
#      再跑一遍采集命令 —— 那会让现场多等，而且两次采到的可能还不一样。
#   2. 哪一项没有就**整块不画**（没显卡就没有 GPU 那块），不铺一屏 N/A。
#   3. **绝不能卡住流程**。60 秒倒计时，按任意键立即继续，超时自动继续。
#      现场最怕的就是"插上去没反应"。
#
# 每个 cfg_*_body 都吃一个 raw 目录参数（默认 $RAW_DIR），
# 这样 tests/test-screen-render.sh 能直接喂 fixture。

_CFG_TITLES=(); _CFG_BODIES=(); _CFG_ORIG=(); _CFG_SHOWN=()

cfg_reset() { _CFG_TITLES=(); _CFG_BODIES=(); _CFG_ORIG=(); _CFG_SHOWN=(); }

# cfg_add <标题> <内容(多行)> [最多显示几行]
cfg_add() {
  local title="$1" body="$2" cap="${3:-99}" n
  body="$(printf '%s\n' "$body" | grep . || true)"
  [[ -n "$body" ]] || return 0            # 一行都没有 -> 整块不画
  n="$(printf '%s\n' "$body" | grep -c . || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  (( n > 0 )) || return 0
  _CFG_TITLES+=("$title"); _CFG_BODIES+=("$body"); _CFG_ORIG+=("$n")
  _CFG_SHOWN+=("$(( n < cap ? n : cap ))")
}

# 某一段实际会占几行（内容 + 可能的 "and N more"）
_cfg_sec_rows() {
  local i="$1"
  if (( _CFG_SHOWN[i] >= _CFG_ORIG[i] )); then printf '%s' "${_CFG_ORIG[i]}"
  else printf '%s' "$(( _CFG_SHOWN[i] + 1 ))"; fi
}

_cfg_height() {
  local h=3 i                              # 顶框 + 抬头 + 抬头下的分隔
  for i in "${!_CFG_TITLES[@]}"; do
    h=$(( h + 1 + $(_cfg_sec_rows "$i") )) # 标题行 + 内容
    (( i > 0 )) && h=$(( h + 1 ))          # 段与段之间的分隔线
  done
  printf '%s' $(( h + 1 ))                 # 底框
}

# 装不下就**砍最长的那一段**，一行一行砍，直到进得去。
# 砍掉的行数在末尾如实写出来 —— 屏幕装不下不等于报告里没有。
cfg_fit() {
  local budget="$1" guard=0 best bestn i
  while (( $(_cfg_height) > budget )) && (( guard < 400 )); do
    guard=$(( guard + 1 ))
    best=-1; bestn=1
    for i in "${!_CFG_SHOWN[@]}"; do
      (( _CFG_SHOWN[i] > bestn )) && { bestn="${_CFG_SHOWN[i]}"; best="$i"; }
    done
    (( best < 0 )) && break                # 每段都只剩一行了，砍不动
    _CFG_SHOWN[best]=$(( _CFG_SHOWN[best] - 1 ))
  done
}

# cfg_panel <宽> <抬头右侧>  -> 完整面板（纯 ASCII，含边框）
cfg_panel() {
  local w="$1" right="$2" i n line
  brand_bar "$w" "$right"
  box_rule "$w"
  box_row3 "$w" "" "CONFIGURATION REVIEW" ""
  box_rule "$w"
  local rowcolor
  for i in "${!_CFG_TITLES[@]}"; do
    (( i > 0 )) && box_sep "$w"
    box_row "$w" "  ${_CFG_TITLES[i]}" hdr
    n=0
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      n=$(( n + 1 ))
      if (( _CFG_SHOWN[i] < _CFG_ORIG[i] && n > _CFG_SHOWN[i] )); then
        box_row "$w" "$(printf '    ... and %d more (all included in the report)' \
          "$(( _CFG_ORIG[i] - _CFG_SHOWN[i] ))")" dim
        break
      fi
      # 存储那几行按"会不会被擦"上色：这一屏之后紧接着就是破坏性写确认，
      # 操作员在那一刻要一眼看出哪几块盘会被 fio 写掉。
      #   [TESTABLE]   黄色 —— 确认之后会被整盘覆盖
      #   [MOUNTED] / [TEST MEDIA]  绿色 —— 受保护，不会被碰
      # 网口按有没有链路：UP 绿、没链路灰，现场核对插线一眼就看出来。
      rowcolor="none"
      case "$line" in
        *"[TESTABLE]"*)                 rowcolor="warn" ;;
        *"[MOUNTED]"*|*"[TEST MEDIA]"*) rowcolor="ok" ;;
        *" UP "*)                       rowcolor="ok" ;;
        *"no link"*)                    rowcolor="dim" ;;
      esac
      box_row "$w" "  $line" "$rowcolor"
    done <<< "${_CFG_BODIES[i]}"
  done
  box_rule "$w"
}

# ---------------------------------------------------------------- 各段的内容
# 一律 "Label   Value" 的形状，两列时用固定列宽让第二列对齐。

cfg_system_body() {
  local f="${1:-$RAW_DIR}/dmidecode-system.txt"
  [[ -f "$f" ]] || return 0
  # 按 dmidecode 的空行分块（RS=""），逐块认字段。
  #
  # ⚠️ 取值用 val()（拿一个**副本**做 sub），不要直接改 $i —— 给字段赋值会让 awk
  # 用 OFS 重建 $0，后面那些 /XXX Information/ 的块判断就是在改过的 $0 上做的，
  # 出的错很难看出来。
  awk 'BEGIN{RS="";FS="\n"}
    function val(line,   s) { s = line; sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", s); return s }
    /^Handle .*\nSystem Information/ {
      for (i=1;i<=NF;i++) {
        if ($i ~ /^[[:space:]]+Manufacturer:/)  mfr = val($i)
        if ($i ~ /^[[:space:]]+Product Name:/)  prd = val($i)
        if ($i ~ /^[[:space:]]+Serial Number:/) sn  = val($i)
      }
    }
    /^Handle .*\nBIOS Information/ {
      for (i=1;i<=NF;i++) {
        if ($i ~ /^[[:space:]]+Version:/)      bv = val($i)
        if ($i ~ /^[[:space:]]+Release Date:/) bd = val($i)
      }
    }
    /^Handle .*\nBase Board Information/ {
      for (i=1;i<=NF;i++)
        if ($i ~ /^[[:space:]]+Asset Tag:/) at = val($i)
    }
    END {
      if (mfr != "" || prd != "")
        printf "  Manufacturer  %-26.26s Product   %s\n", mfr, prd
      if (sn != "" || bv != "")
        printf "  Serial        %-26.26s BIOS      %s%s\n", sn, bv, (bd != "" ? " (" bd ")" : "")
      if (at != "" && at !~ /Not Specified|To be filled|Default string/)
        printf "  Asset tag     %s\n", at
    }' "$f" 2>/dev/null
}

cfg_cpu_body() {
  local raw="${1:-$RAW_DIR}"
  local f="$raw/lscpu.txt" ci="$raw/cpuinfo.txt"
  [[ -f "$f" ]] || return 0
  local model sockets cps tps cpus numa mc
  model="$(awk -F': +' '/^Model name:/{print $2; exit}' "$f" 2>/dev/null)"
  sockets="$(awk -F': +' '/^Socket\(s\):/{print $2; exit}' "$f" 2>/dev/null)"
  cps="$(awk -F': +' '/^Core\(s\) per socket:/{print $2; exit}' "$f" 2>/dev/null)"
  tps="$(awk -F': +' '/^Thread\(s\) per core:/{print $2; exit}' "$f" 2>/dev/null)"
  cpus="$(awk -F': +' '/^CPU\(s\):/{print $2; exit}' "$f" 2>/dev/null)"
  numa="$(awk -F': +' '/^NUMA node\(s\):/{print $2; exit}' "$f" 2>/dev/null)"
  mc="$(awk -F': ' '/^microcode/{print $2; exit}' "$ci" 2>/dev/null)"
  [[ -n "$model" ]] || return 0

  local cores=""
  if [[ "$cps" =~ ^[0-9]+$ && "$tps" =~ ^[0-9]+$ ]]; then
    cores="$(printf '%dC/%dT' "$cps" $(( cps * tps )))"
  fi
  printf '  %s x %-30.30s %s\n' "${sockets:-1}" "$model" "$cores"
  local tail=""
  [[ -n "$cpus" ]] && tail="Total ${cpus} logical CPUs"
  [[ -n "$numa" ]] && tail="${tail}    NUMA nodes ${numa}"
  [[ -n "$mc"   ]] && tail="${tail}    Microcode ${mc}"
  [[ -n "$tail" ]] && printf '  %s\n' "$tail"
}

cfg_memory_body() {
  local raw="${1:-$RAW_DIR}"
  local memf="$raw/dmidecode-memory.txt" mi="$raw/meminfo.txt"
  [[ -f "$memf" ]] || return 0
  local installed visible slots populated kind speed one
  installed="$(dmi_installed_mem_mb "$memf")"
  if [[ -f "$mi" ]]; then visible="$(os_visible_mem_mb "$mi")"; else visible="$(os_visible_mem_mb)"; fi
  [[ "$installed" =~ ^[0-9]+$ ]] || return 0
  (( installed > 0 )) || return 0

  # ⚠️ 这几行一律走 awk，不走 `grep -E '^\tSize:'` —— GNU grep 的 ERE **不认 \t**，
  # 那样写会去匹配字面量的 t，一条都命中不了，而且不会有任何报错
  # （表现是"每台机器都显示 0 条内存"）。awk 的正则认 \t。
  slots="$(awk '/^Memory Device$/{n++} END{printf "%d", n}' "$memf" 2>/dev/null)"
  populated="$(awk '/^\tSize:[[:space:]]+[0-9]+/{n++} END{printf "%d", n}' "$memf" 2>/dev/null)"
  kind="$(awk -F': ' '/^\tType: (DDR|LPDDR)/{print $2; exit}' "$memf" 2>/dev/null)"
  speed="$(awk -F': ' '/^\tConfigured Memory Speed: [0-9]/{print $2; exit}' "$memf" 2>/dev/null)"
  one="$(awk -F': ' '/^\tSize: [0-9]+ (MB|GB)/{print $2; exit}' "$memf" 2>/dev/null)"
  printf '  Installed %d GB' "$(( installed / 1024 ))"
  [[ "$populated" =~ ^[0-9]+$ ]] && (( populated > 0 )) && \
    printf ' (%d x %s%s%s)' "$populated" "${one:-?}" \
      "${kind:+ $kind}" "${speed:+-${speed%% *}}"
  printf '\n'
  local l2="  Populated ${populated:-?}/${slots:-?} slots"
  [[ "$visible" =~ ^[0-9]+$ ]] && (( visible > 0 )) && \
    l2="$(printf '  Populated %s/%s slots        OS sees %.1f GB' \
          "${populated:-?}" "${slots:-?}" "$(awk -v v="$visible" 'BEGIN{print v/1024}')")"
  printf '%s\n' "$l2"
}

# 存储：可测的、已挂载的、被排除的，一律列出来并标明为什么
cfg_storage_body() {
  local rec path size model serial rota tran pttype
  for rec in "${DISK_INFO[@]:-}"; do
    [[ -n "$rec" ]] || continue
    IFS='|' read -r path size model serial rota tran pttype <<< "$rec"
    printf '  %-14s %9s  %-26.26s SN %-14.14s [TESTABLE]\n' \
      "$path" "$size" "$model" "${serial:--}"
  done
  local e epath esize emodel ewhy tag
  for e in "${DISK_EXCLUDED[@]:-}"; do
    [[ -n "$e" ]] || continue
    IFS='|' read -r epath esize emodel ewhy <<< "$e"
    case "$ewhy" in
      "has a mounted partition") tag="[MOUNTED]" ;;
      *"KLBurn USB"*)           tag="[TEST MEDIA]" ;;
      *)                        continue ;;   # loop/ram/软驱之类，现场不关心
    esac
    printf '  %-14s %9s  %-26.26s %-17s %s\n' \
      "$epath" "$esize" "$emodel" "" "$tag"
  done
}

cfg_network_body() {
  local raw="${1:-$RAW_DIR}" n ifn mac st spd model
  for n in /sys/class/net/*; do
    [[ -e "$n/device" ]] || continue
    ifn="$(basename "$n")"
    [[ "$ifn" == "lo" ]] && continue
    mac="$(cat "$n/address" 2>/dev/null || true)"
    st="$(cat "$n/operstate" 2>/dev/null || true)"
    spd="$(cat "$n/speed" 2>/dev/null || true)"
    model="$(awk -F': ' '/^model:/{print $2; exit}' "$raw/nic/${ifn}-driver.txt" 2>/dev/null)"
    [[ -n "$model" ]] || model="$(awk -F': ' '/^driver:/{print $2; exit}' "$raw/nic/${ifn}-driver.txt" 2>/dev/null)"
    # MAC 只留厂商前缀：这块屏幕会被拍照发群里，整串 MAC 没必要露出去
    [[ -n "$mac" ]] && mac="${mac:0:8}:xx:xx:xx"
    printf '  %-8s %-30.30s %-5s %8s   %s\n' \
      "$ifn" "${model:-unknown}" "$(printf '%s' "${st:-?}" | tr '[:lower:]' '[:upper:]')" \
      "$( [[ "$spd" =~ ^[0-9]+$ ]] && printf '%s Mb/s' "$spd" || printf 'no link' )" \
      "${mac:--}"
  done
}

cfg_gpu_body() {
  local raw="${1:-$RAW_DIR}" f="${1:-$RAW_DIR}/deep/nvidia-inventory.csv"
  [[ -f "$f" ]] || return 0
  awk -F', *' 'NR>1 && NF>=7 {
      mem = $7; sub(/ *MiB */, "", mem)
      if (mem+0 > 0) mem = sprintf("%.0f GB", mem/1024); else mem = "-"
      printf "  %-3s %-28.28s %-10s Driver %s\n", $1, $2, mem, $6
    }' "$f" 2>/dev/null
  : "$raw"
}

# 阵列卡 / BMC / 电源：各一行，凑成最后一段
cfg_platform_body() {
  local raw="${1:-$RAW_DIR}"
  local raid fw
  raid="$(grep -iE 'RAID bus controller|Serial Attached SCSI|MegaRAID' "$raw/lspci.txt" 2>/dev/null \
          | head -1 | sed -E 's/^[0-9a-f:.]+ [^:]+: //; s/ \[[0-9a-f]{4}:[0-9a-f]{4}\].*$//' || true)"
  if [[ -n "$raid" ]]; then
    fw="$(awk -F'= *' '/^(FW Package Build|Firmware Version)/{print $2; exit}' \
          "$raw/storcli-show.txt" 2>/dev/null)"
    printf '  RAID / HBA   %-40.40s%s\n' "$raid" "${fw:+   FW $fw}"
  fi

  local bmc="not detected"
  [[ "${IPMI_OK:-0}" == "1" ]] && bmc="present (IPMI)"
  local psus=() line total=0 live=0 loc st n ac
  while IFS= read -r line; do [[ -n "$line" ]] && psus+=("$line"); done < <(dmi_psu_list "$raw/dmidecode-psu.txt")
  for line in "${psus[@]:-}"; do
    [[ -n "$line" ]] || continue
    loc="${line%%|*}"; st="${line#*|}"
    [[ "$st" == *"Present"* ]] || continue
    total=$(( total + 1 ))
    n="$(printf '%s' "$loc" | grep -oE '[0-9]+' | head -1)"; [[ -n "$n" ]] || n="$total"
    ac="$(psu_ac_state "$n" "$raw/ipmi-sensors.txt")"
    [[ "$ac" == "present" ]] && live=$(( live + 1 ))
  done
  if (( total > 0 )); then
    printf '  BMC          %-20s PSU  %d/%d present, %d with AC input\n' \
      "$bmc" "$total" "$total" "$live"
  else
    printf '  BMC          %s\n' "$bmc"
  fi
}

# ---------------------------------------------------------------- 整屏 + 倒计时
# config_review <倒计时秒>
#
# **绝不能卡住流程**：超时自动继续，按任意键立即继续。
# 返回值永远是 0 —— 这一屏只是给人看的，没有"失败"这种结果。
config_review() {
  local timeout="${1:-60}" w; w="$(panel_width)"

  cfg_reset
  cfg_add "SYSTEM"  "$(cfg_system_body)"
  cfg_add "CPU"     "$(cfg_cpu_body)"
  cfg_add "MEMORY"  "$(cfg_memory_body)"
  cfg_add "STORAGE" "$(cfg_storage_body)"  6
  cfg_add "NETWORK" "$(cfg_network_body)"  6
  cfg_add "GPU"     "$(cfg_gpu_body)"      8
  cfg_add "PLATFORM" "$(cfg_platform_body)"

  if (( ${#_CFG_TITLES[@]} == 0 )); then
    warn "Nothing collected to review - skipping the configuration review screen."
    return 0
  fi

  # 留出：标题条（大字六行 / 矮屏一行，问 brand_rows）+ 倒计时 1 行 + 余量 2 行。
  # 装不下就砍最长的那一段（砍掉几行会如实写在屏幕上）。
  BRAND_COMPACT=0
  cfg_fit $(( ROWS - $(brand_rows) - 3 ))
  # 每段都砍到只剩一行了还是超（段特别多的机器）：**先牺牲大字**，不牺牲数据。
  brand_fit $(( $(_cfg_height) + 3 ))
  (( BRAND_COMPACT )) && cfg_fit $(( ROWS - 1 - 3 ))

  local stamp; stamp="$(date '+%Y-%m-%d %H:%M:%S')"

  # 落一份**纯文本**进 raw/：存档、grep、e2e 的日志锚点都不该带转义码，
  # 所以先把颜色关掉生成一遍。这一遍纯字符串操作，不值几个 CPU 周期。
  panel_palette 0
  printf '%s\n' "$(cfg_panel "$w" "$stamp")" > "$RAW_DIR/config-review.txt" 2>/dev/null || true
  panel_palette "$PANEL_COLOR"

  info "Configuration review: ${#_CFG_TITLES[@]} sections, ${timeout}s (any key continues)"
  screen_home
  cfg_panel "$w" "$stamp"
  screen_end          # 抹掉面板下面残留的采集日志

  # 倒计时用单行 \r（不是 \033[A）：这时候屏幕上没有别的写入者，
  # 面板已经画完、压测还没开始，是 \r 唯一安全的场景。
  local start now remaining key
  start=$(date +%s)
  while :; do
    now=$(date +%s); remaining=$(( timeout - (now - start) ))
    (( remaining <= 0 )) && { printf '\n'; break; }
    printf '\r\033[K      Review the configuration above.  Press any key to continue.   [%2ds]' \
      "$remaining"
    if IFS= read -r -s -t 1 -n 1 key; then printf '\n'; break; fi
  done

  ok "Configuration review done"
  return 0
}

# ---------------------------------------------------------------- 并发压测的仪表盘循环
# CPU / 内存 / GPU 是并发跑的三个子 shell，各自都不画屏（见 stress.sh）。
# 这里每 2 秒整屏重绘一次，退出条件是"所有给定 PID 都结束了"而不是单纯到点：
# 到点了但压测子进程还没退出（真跑慢了）就继续在 100% 停着刷新，
# 如实反映"还没测完"而不是假装已经收工。
#
# progress_bar_concurrent <总秒数> <标签> <pid...>
progress_bar_concurrent() {
  local total="$1" label="$2"; shift 2
  local pids=("$@")
  local start w; start=$(date +%s); w="$(panel_width)"

  # 两个累计计数器先打一次基准，不然第一屏的功耗/占用率是空的
  cpu_power_w      >/dev/null 2>&1 || true
  cpu_pkg_busy_pct >/dev/null 2>&1 || true

  local now elapsed alive p
  while :; do
    alive=0
    for p in "${pids[@]}"; do
      kill -0 "$p" 2>/dev/null && alive=$((alive+1))
    done
    now=$(date +%s); elapsed=$(( now - start ))

    # 抬头三段各有各的内容，别把同一个串塞进两处：
    #   左  KLBurn v1.7.x      中  BURN-IN  CPU + MEMORY + GPU      右  QUICK
    # 右边是**档位**（select_duration 定的），不是阶段名 —— 第一版把 label
    # 同时当中间和右边用，屏幕上就成了 "BURN-IN  BURN-IN ... BURN-IN"。
    # 单元测试查列宽和字符集，查不出这种"字对了、意思重了"的问题，是截图看出来的。
    dash_burn "$w" "${DURATION_PROFILE:-}" "BURN-IN  $label" "$elapsed" "$total"

    (( alive == 0 )) && break
    sleep 2
  done
  dash_burn "$w" "${DURATION_PROFILE:-}" "BURN-IN  $label" "$total" "$total"
}

# run_disk_with_dashboard <pid> <总秒数> <标签>
# 硬盘压测是单独跑的（不和 CPU/内存并发），屏幕换成硬盘视角。
run_disk_with_dashboard() {
  local pid="$1" total="$2" label="$3"
  local start now elapsed w; start=$(date +%s); w="$(panel_width)"
  disk_io_rates >/dev/null 2>&1 || true      # 打基准，第一屏才有速率
  while kill -0 "$pid" 2>/dev/null; do
    now=$(date +%s); elapsed=$(( now - start ))
    dash_disk "$w" "${DURATION_PROFILE:-}" "DISK STRESS  $label" "$elapsed" "$total"
    sleep 2
  done
  dash_disk "$w" "${DURATION_PROFILE:-}" "DISK STRESS  $label" "$total" "$total"
  wait "$pid"
  return $?
}
