#!/usr/bin/env bash
#
# 现场界面（配置核对面板 + 压测仪表盘）的渲染回归测试。
#
#     ./tests/test-screen-render.sh
#
# 不需要任何硬件：所有渲染函数都是纯函数，喂 fixture 就能断言。
#
# 这套测试守的是三样东西，每一样都对应"现场那块屏幕会不会变成废物"：
#
#   1. **屏幕上不许出现非 ASCII 字节。** 现场是通过 BMC 的 KVM 或串口看的，
#      字体和字符集都不受我们控制。一个 UTF-8 中文字或者一个 Unicode 制表符
#      就能把整屏顶成乱码，而那块屏幕是操作员判断机器状态的唯一依据。
#      单元测试是唯一能便宜地守住这条的地方（e2e 截图能看出来，但要 20 分钟）。
#
#   2. **80 列必须能完整显示、不折行。** 行只要超过终端宽度就会自动换行，
#      整屏重绘的行数就对不上，画出来是滚动的碎片。
#
#   3. **读不到数据要画 "--"，不能画 0，更不能整屏 N/A。** 0°C 看着像读数，
#      "--" 才是实话；而"这台机器没有显卡"应该是整块不画，不是铺一屏 N/A。
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/rootfs/opt/klburn/lib"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

RAW_DIR="$TMP/raw"; RUN_DIR="$TMP"
mkdir -p "$RAW_DIR/nic" "$RAW_DIR/deep"
DISK_CAND=(); DISK_INFO=(); DISK_EXCLUDED=(); DISK_SMART=()
IPMI_OK=0
KLBURN_VERSION="9.9.9"

# ⚠️ 被测的 lib 必须**先 source**，断言助手才能定义在它们后面。
# core.sh 里也有一个 ok()（打运行日志用的）。顺序反过来的话它会把测试自己的
# ok() 顶掉 —— 屏幕上照样一行行打勾，PASS 却一个都不加，最后汇总
# "通过 0 项"。这正是 §11-13 那条不变量，本套件第一次跑就踩到了。
# 末尾还有一条自检守着这件事。
# shellcheck source=/dev/null
source "$LIB/core.sh"
# shellcheck source=/dev/null
source "$LIB/ui.sh"
# shellcheck source=/dev/null
source "$LIB/collect.sh"      # 配置面板要用 dmi_* / psu_ac_state 这几个解析函数
# shellcheck source=/dev/null
source "$LIB/stress.sh"       # 末尾那组"压测输出不许上屏"的守卫要用

PASS=0; FAIL=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n     期望 [%s] 实际 [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }
check(){ [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$2" "$3"; }

# 断言函数名打错不能静悄悄地过去（§11-13"断言悄悄停止计数"的同款病）
command_not_found_handle() {
  printf "  \033[31mFAIL\033[0m 调用了不存在的命令 %s —— 多半是断言函数名打错了，\n" "$1"
  printf "       这条断言根本没跑。中止本套件。\n"
  kill -TERM $$
  return 127
}

# ================================================================
# 通用断言：一段渲染输出必须「全是可打印 ASCII」且「每行正好 w 列」
# ================================================================
#
# ⚠️ 别用 [^[:print:]] 之类的字符类挑非 ASCII：本套件跑在 LC_ALL=C 下，
# 而现场那台机器的 locale 也是 C（factory-test.sh 顶部 export LC_ALL=C）。
# 用 ASCII 端点的区间 [\x20-\x7e] 在任何 locale 下都成立。
non_ascii_lines() {
  LC_ALL=C grep -nvE '^[ -~]*$' <<< "$1" || true
}
wrong_width_lines() {
  local text="$1" w="$2"
  awk -v w="$w" 'length($0) != w { printf "%d:%d列 %s\n", NR, length($0), $0 }' <<< "$text"
}

assert_ascii() {   # assert_ascii <标签> <文本>
  local hits; hits="$(non_ascii_lines "$2" | grep -c . || true)"
  [[ "$hits" =~ ^[0-9]+$ ]] || hits=0
  check "$1：输出里没有非 ASCII 字节" "0" "$hits"
  (( hits )) && non_ascii_lines "$2" | head -3 | sed 's/^/       /'
}
assert_width() {   # assert_width <标签> <文本> <宽>
  local hits; hits="$(wrong_width_lines "$2" "$3" | grep -c . || true)"
  [[ "$hits" =~ ^[0-9]+$ ]] || hits=0
  check "$1：每行正好 $3 列（多一列就折行，折行整屏就废了）" "0" "$hits"
  (( hits )) && wrong_width_lines "$2" "$3" | head -3 | sed 's/^/       /'
}
nlines() { printf '%s' "$(printf '%s\n' "$1" | grep -c . || true)"; }

# ================================================================
echo "=== 框线基元 ==="

check "box_rule 是 ASCII 等号框线" "+==========+" "$(box_rule 12)"
check "box_sep  是 ASCII 减号框线" "+----------+" "$(box_sep 12)"
check "box_row  左对齐并补满"      "|  hi      |" "$(box_row 12 '  hi')"
LONGROW="$(box_row 12 'aaaaaaaaaaaaaaaaaaaa')"
check "box_row  超长内容要截断而不是撑长" "12" "${#LONGROW}"

check "str_put 盖在中间且不改变总长度" "abc CD hi" "$(str_put 'abcdefghi' 3 ' CD ')"
check "str_put 越界要裁掉，不许把行撑长" "9" \
      "$(printf '%s' "$(str_put 'abcdefghi' 7 'XXXXXX')" | wc -c)"
check "str_put 起点在行外时原样返回" "abcdefghi" "$(str_put 'abcdefghi' 99 'X')"

HDR="$(box_row3 80 'LEFT' 'MIDDLE' 'RIGHT')"
check "box_row3 三段都在" "yes" \
      "$(if [[ "$HDR" == *LEFT* && "$HDR" == *MIDDLE* && "$HDR" == *RIGHT* ]]; then echo yes; else echo no; fi)"
assert_width "box_row3" "$HDR" 80
check "box_row3 的右段确实贴右边" "yes" \
      "$(if [[ "$HDR" == *"RIGHT  |" ]]; then echo yes; else echo no; fi)"

# ascii_clean 是整条"屏幕不许有非 ASCII"不变量的唯一收口处
check "ascii_clean 吃掉中文" "abc" "$(ascii_clean 'a中b文c')"
check "ascii_clean 吃掉 ESC 和控制字符" "[31mX" "$(ascii_clean "$(printf '\033[31mX\r')")"
check "含中文的型号串进 box_row 之后仍是纯 ASCII" "0" \
      "$(non_ascii_lines "$(box_row 40 '  Model 华为 TaiShan')" | grep -c . || true)"

# ================================================================
echo
echo "=== 仪表盘：CPU 分区 ==="

CPU2="0|Intel Xeon Gold 6430|3100|67|100
1|Intel Xeon Gold 6430|3090|65|99"

for w in 80 100 120; do
  out="$(dash_cpu_rows "$w" "$CPU2")"
  assert_ascii "CPU 分区（${w}列）" "$out"
  assert_width "CPU 分区（${w}列）" "$out" "$w"
done

out="$(dash_cpu_rows 80 "$CPU2")"
check "两颗 CPU -> 表头 1 行 + 数据 2 行" "3" "$(nlines "$out")"
check "第 0 颗的频率出现在该出现的地方" "1" \
      "$(printf '%s\n' "$out" | grep -c '#0 .*3100 MHz .*  67 C .* 100%' || true)"
check "第 1 颗单独一行（双路机一颗凉一颗烫要看得出来）" "1" \
      "$(printf '%s\n' "$out" | grep -c '#1 .*3090 MHz .*  65 C' || true)"

# 读不到温度/占用率是正常情况（温度驱动不是 coretemp 的机器很多），
# 必须画 "--"，绝不能画 0 —— 0°C 看着像读数，会让人以为传感器坏了
out="$(dash_cpu_rows 80 '0|Some CPU|||')"
check "温度读不到时画 --（不是 0）" "1" "$(printf '%s\n' "$out" | grep -c -- '--' || true)"
check "温度读不到时绝不画 0 C"     "0" "$(printf '%s\n' "$out" | grep -c '  0 C' || true)"
assert_width "CPU 分区（全空读数）" "$out" 80

check "没有 CPU 数据时整块不画（不是打一堆 N/A）" "0" "$(nlines "$(dash_cpu_rows 80 '')")"

# ================================================================
echo
echo "=== 仪表盘：GPU 分区 ==="

gpu_fixture() {   # gpu_fixture <张数>
  local n="$1" i
  for (( i = 0; i < n; i++ )); do
    printf '%d|NVIDIA H200 PCIe|%d|144384|71|598|100\n' "$i" $(( 141000 + i ))
  done
}

out="$(dash_gpu_rows 80 "$(gpu_fixture 2)")"
assert_ascii "GPU 分区" "$out"
assert_width "GPU 分区" "$out" 80
check "两张卡 -> 表头 1 行 + 数据 2 行" "3" "$(nlines "$out")"
check "显存按 已用/总量 GB 显示（逐卡各一行）" "2" \
      "$(printf '%s\n' "$out" | grep -c '137.7/141.0 GB' || true)"
check "温度/功耗/利用率都在该在的列上" "1" \
      "$(printf '%s\n' "$out" | grep -c '^|   0 .*137.7/141.0 GB .*  71 C .*  598 W .* 100%' || true)"

check "8 张卡全显示（表头 + 8）" "9" "$(nlines "$(dash_gpu_rows 80 "$(gpu_fixture 8)")")"
out9="$(dash_gpu_rows 80 "$(gpu_fixture 9)")"
check "9 张卡：显示前 8 张 + 一行收口" "10" "$(nlines "$out9")"
check "第 9 张不上屏（超出的那张不能凭空显示）" "0" \
      "$(printf '%s\n' "$out9" | grep -cE '^\|   8 ' || true)"
check "收口那行要说清楚还有几张、以及报告里都有" "1" \
      "$(printf '%s\n' "$out9" | grep -c 'and 1 more (all included in the report)' || true)"
assert_width "GPU 分区（9 张卡）" "$out9" 80

check "12 张卡时收口写 and 4 more" "1" \
      "$(dash_gpu_rows 80 "$(gpu_fixture 12)" | grep -c 'and 4 more' || true)"

# nvidia-smi 不在 / 没有显卡：整块不渲染
check "没有 GPU 数据时整块不画（无卡机器不该出现 GPU 那一块）" "0" \
      "$(nlines "$(dash_gpu_rows 80 '')")"
out="$(dash_gpu_rows 80 '0|Some GPU||||| ')"
check "显存/温度/功耗都读不到时画 --，不判故障也不画 0" "1" \
      "$(printf '%s\n' "$out" | grep -c -- '--' || true)"
assert_width "GPU 分区（全空读数）" "$out" 80

# ================================================================
echo
echo "=== 仪表盘：硬盘分区与进度条 ==="

DISKS="nvme0n1|1820|1650|412000|43
sda|180|175|1400|38"
out="$(dash_disk_rows 80 "$DISKS")"
assert_ascii "硬盘分区" "$out"
assert_width "硬盘分区" "$out" 80
check "两块盘 -> 表头 1 行 + 数据 2 行" "3" "$(nlines "$out")"
check "带宽和 IOPS 都在" "1" \
      "$(printf '%s\n' "$out" | grep -c 'nvme0n1 .*1820 MB/s .*1650 MB/s .*412000 .*  43 C' || true)"
check "没有硬盘数据时整块不画" "0" "$(nlines "$(dash_disk_rows 80 '')")"

PROG="$(dash_progress 80 252 600)"
assert_ascii "进度条" "$PROG"
assert_width "进度条" "$PROG" 80
check "进度条两行（耗时 + 条）" "2" "$(nlines "$PROG")"
check "已用/剩余是 HH:MM:SS" "1" \
      "$(printf '%s\n' "$PROG" | grep -c 'ELAPSED 00:04:12   REMAINING 00:05:48' || true)"
check "百分比算对" "1" "$(printf '%s\n' "$PROG" | grep -c ' 42%' || true)"
check "跑过头也不许超过 100%" "1" \
      "$(dash_progress 80 900 600 | grep -c '100%' || true)"
assert_width "进度条（跑过头）" "$(dash_progress 80 900 600)" 80
check "总时长为 0 时不崩、也不除零" "2" "$(nlines "$(dash_progress 80 0 0)")"

# ================================================================
echo
echo "=== 配置核对面板 ==="

cat > "$RAW_DIR/dmidecode-system.txt" <<'EOF'
Handle 0x0100, DMI type 1, 27 bytes
System Information
	Manufacturer: Dell Inc.
	Product Name: PowerEdge R750
	Serial Number: ABC1234
	UUID: 4c4c4544-0042-4310

Handle 0x0000, DMI type 0, 26 bytes
BIOS Information
	Vendor: Dell Inc.
	Version: 2.10.2
	Release Date: 03/11/2025

Handle 0x0200, DMI type 2, 15 bytes
Base Board Information
	Manufacturer: Dell Inc.
	Asset Tag: KL-2026-0042
EOF

cat > "$RAW_DIR/lscpu.txt" <<'EOF'
Architecture:            x86_64
CPU(s):                  128
Thread(s) per core:      2
Core(s) per socket:      32
Socket(s):               2
Model name:              Intel(R) Xeon(R) Gold 6430
NUMA node(s):            2
EOF
printf 'processor\t: 0\nmodel name\t: Intel(R) Xeon(R) Gold 6430\nmicrocode\t: 0x2b000603\n' \
  > "$RAW_DIR/cpuinfo.txt"

{
  for i in 1 2; do
    printf 'Handle 0x001%d, DMI type 17, 92 bytes\nMemory Device\n' "$i"
    printf '\tSize: 32 GB\n\tLocator: CPU0_DIMM%d\n\tType: DDR5\n' "$i"
    printf '\tConfigured Memory Speed: 4800 MT/s\n\n'
  done
  printf 'Handle 0x0020, DMI type 17, 92 bytes\nMemory Device\n\tSize: No Module Installed\n\tLocator: CPU1_DIMMA\n\n'
} > "$RAW_DIR/dmidecode-memory.txt"
printf 'MemTotal:       66584576 kB\n' > "$RAW_DIR/meminfo.txt"

cat > "$RAW_DIR/deep/nvidia-inventory.csv" <<'EOF'
index, name, uuid, serial, vbios_version, driver_version, memory.total [MiB]
0, NVIDIA H200 PCIe, GPU-aaa, 1234, 96.00.1, 595.84, 143771 MiB
1, NVIDIA H200 PCIe, GPU-bbb, 1235, 96.00.1, 595.84, 143771 MiB
EOF

printf '18:00.0 RAID bus controller: Broadcom MegaRAID 9560-16i [1000:10e2] (rev 01)\n' \
  > "$RAW_DIR/lspci.txt"
printf 'FW Package Build = 5.29.00.00\n' > "$RAW_DIR/storcli-show.txt"

cat > "$RAW_DIR/dmidecode-psu.txt" <<'EOF'
Handle 0x0B00, DMI type 39, 22 bytes
System Power Supply
	Location: PSU1
	Status: Present, OK

Handle 0x0B01, DMI type 39, 22 bytes
System Power Supply
	Location: PSU2
	Status: Present, OK
EOF
printf 'PSU1_Vin         | 230.000    | Volts      | ok\nPSU2_Vin         | 0.000      | Volts      | ok\n' \
  > "$RAW_DIR/ipmi-sensors.txt"
IPMI_OK=1

DISK_INFO=("/dev/nvme0n1|1.6TB|SAMSUNG MZQL21T9HCJR|S6CVNE0T|0|nvme|gpt")
DISK_EXCLUDED=("/dev/sda|446.6GB|DELLBOSS VD|has a mounted partition")

check "SYSTEM 段认出厂商/型号/序列号" "1" \
      "$(cfg_system_body "$RAW_DIR" | grep -c 'Dell Inc\..*PowerEdge R750' || true)"
check "SYSTEM 段认出 BIOS 版本和日期" "1" \
      "$(cfg_system_body "$RAW_DIR" | grep -c 'ABC1234.*2.10.2 (03/11/2025)' || true)"
check "SYSTEM 段带上资产标签" "1" \
      "$(cfg_system_body "$RAW_DIR" | grep -c 'KL-2026-0042' || true)"
check "CPU 段：路数 x 型号 + 每颗核数/线程数" "1" \
      "$(cfg_cpu_body "$RAW_DIR" | grep -c '2 x Intel(R) Xeon(R) Gold 6430.*32C/64T' || true)"
check "CPU 段：微码和 NUMA 也要有（现场核对配置时要看）" "1" \
      "$(cfg_cpu_body "$RAW_DIR" | grep -c 'NUMA nodes 2.*Microcode 0x2b000603' || true)"
check "MEMORY 段：装机容量和条数" "1" \
      "$(cfg_memory_body "$RAW_DIR" | grep -c 'Installed 64 GB (2 x 32 GB DDR5' || true)"
check "MEMORY 段：插槽利用率 + 系统识别容量" "1" \
      "$(cfg_memory_body "$RAW_DIR" | grep -c 'Populated 2/3 slots.*OS sees 63' || true)"
check "STORAGE 段：可测的盘标 TESTABLE" "1" \
      "$(cfg_storage_body | grep -c '/dev/nvme0n1.*S6CVNE0T.*\[TESTABLE\]' || true)"
check "STORAGE 段：系统盘标 MOUNTED（不是消失）" "1" \
      "$(cfg_storage_body | grep -c '/dev/sda.*\[MOUNTED\]' || true)"
check "GPU 段：逐卡型号/显存/驱动版本" "2" \
      "$(cfg_gpu_body "$RAW_DIR" | grep -c 'NVIDIA H200 PCIe.*140 GB.*Driver 595.84' || true)"
check "PLATFORM 段：阵列卡型号 + 固件版本" "1" \
      "$(cfg_platform_body "$RAW_DIR" | grep -c 'MegaRAID 9560-16i.*FW 5.29.00.00' || true)"
check "PLATFORM 段：只有一路进电时如实写 1（不写 2）" "1" \
      "$(cfg_platform_body "$RAW_DIR" | grep -c 'PSU  2/2 present, 1 with AC input' || true)"

# ---- 缺硬件时整块不画 ----
rm -f "$RAW_DIR/deep/nvidia-inventory.csv"
check "没有显卡时 GPU 段一行都不产出" "0" "$(cfg_gpu_body "$RAW_DIR" | grep -c . || true)"
cfg_reset
cfg_add "GPU" "$(cfg_gpu_body "$RAW_DIR")"
check "cfg_add 收到空内容时整段不加（不会出现空的 GPU 标题）" "0" "${#_CFG_TITLES[@]}"

# ---- 整屏 ----
cat > "$RAW_DIR/deep/nvidia-inventory.csv" <<'EOF'
index, name, uuid, serial, vbios_version, driver_version, memory.total [MiB]
0, NVIDIA H200 PCIe, GPU-aaa, 1234, 96.00.1, 595.84, 143771 MiB
EOF
cfg_reset
cfg_add "SYSTEM"   "$(cfg_system_body   "$RAW_DIR")"
cfg_add "CPU"      "$(cfg_cpu_body      "$RAW_DIR")"
cfg_add "MEMORY"   "$(cfg_memory_body   "$RAW_DIR")"
cfg_add "STORAGE"  "$(cfg_storage_body)"           6
cfg_add "GPU"      "$(cfg_gpu_body      "$RAW_DIR")" 8
cfg_add "PLATFORM" "$(cfg_platform_body "$RAW_DIR")"

for w in 80 100 120; do
  panel="$(cfg_panel "$w" '2026-08-02 14:33:07')"
  assert_ascii "配置面板（${w}列）" "$panel"
  assert_width "配置面板（${w}列）" "$panel" "$w"
done

panel="$(cfg_panel 80 '2026-08-02 14:33:07')"
check "面板抬头有版本号和标题" "1" \
      "$(printf '%s\n' "$panel" | grep -c 'KLBurn v9.9.9.*CONFIGURATION REVIEW.*2026-08-02' || true)"
check "六个分区标题都在" "6" \
      "$(printf '%s\n' "$panel" | grep -cE '^\|  (SYSTEM|CPU|MEMORY|STORAGE|GPU|PLATFORM) ' || true)"

# ---- 装不下时要砍，不能滚屏 ----
DISK_INFO=()
for i in $(seq 1 20); do
  DISK_INFO+=("/dev/sd${i}|1.0TB|MODEL${i}|SN${i}|0|sas|gpt")
done
cfg_reset
cfg_add "STORAGE" "$(cfg_storage_body)" 6
check "20 块盘时先按 cap 收到 6 行" "6" "${_CFG_SHOWN[0]}"
cfg_fit 12
H="$(_cfg_height)"
check "cfg_fit 之后总高度不超过给定的行数预算" "yes" \
      "$(if (( H <= 12 )); then echo yes; else echo no; fi)"
panel="$(cfg_panel 80 'x')"
check "砍掉的行数要如实写在屏幕上（装不下 != 报告里没有）" "1" \
      "$(printf '%s\n' "$panel" | grep -c 'and [0-9]* more (all included in the report)' || true)"
assert_width "配置面板（被砍过）" "$panel" 80

# ================================================================
echo
echo "=== 源码层面的守卫 ==="

# §11-14：粘滞刷新区那条不变量。整屏重绘可以，把光标往回挪不行。
#
# 注释行要排掉 —— 上面那段说明里就写着 \033[A（讲的正是"别这么写"），
# 不排的话这条守卫会被自己的文档咬死，那种红是假的，只会逼人去把守卫关掉。
check "ui.sh 里不许再出现 \\033[A 这种把光标往回挪的写法（§11-14）" "0" \
      "$(grep -n '033\[[0-9]*A' "$LIB/ui.sh" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -c . || true)"

# Unicode 制表符：源码里就不许有。等它跑到 BMC 屏幕上再发现就晚了。
# U+2500~U+257F 的 UTF-8 编码以 e2 94 / e2 95 开头（中文是 e4~e9，不会误伤注释）。
BOXDRAW=$(( $(LC_ALL=C grep -c $'\xe2\x94' "$LIB/ui.sh" || true) \
          + $(LC_ALL=C grep -c $'\xe2\x95' "$LIB/ui.sh" || true) ))
check "ui.sh 里没有 Unicode 制表符（BMC 的 KVM 上会变乱码）" "0" "$BOXDRAW"

# 仪表盘的前提：压测期间没有别人往控制台写。
FT="$ROOT/rootfs/opt/klburn/factory-test.sh"
check "factory-test.sh 进压测前要把内核消息压下去（不算注释）" "1" \
      "$(grep -n 'console_quiet_on' "$FT" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -c . || true)"
check "压测结束和异常退出都要恢复（cleanup 里也有一处）" "2" \
      "$(grep -n 'console_quiet_off' "$FT" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -c . || true)"
check "config_review 必须真的被调用（少调 = 现场那一屏凭空消失）" "1" \
      "$(grep -c '^config_review ' "$FT" || true)"

# 配置核对面板绝不能卡住流程：必须有超时分支。
check "config_review 的倒计时到点必须自己往下走（不能等按键）" "yes" \
      "$(if declare -f config_review | grep -q 'remaining <= 0'; then echo yes; else echo no; fi)"

# 压测子进程一个字都不许上屏 —— 否则整屏重绘就是在和它们抢屏幕。
check "stress-ng 的输出全部落日志文件，不上屏" "yes" \
      "$(if declare -f stress_cpu | grep -q -- '--log-file'; then echo yes; else echo no; fi)"
check "stressapptest 的输出也全部落日志文件" "yes" \
      "$(if declare -f stress_mem | grep -q '> "\$log" 2>&1'; then echo yes; else echo no; fi)"
check "硬盘压测改用整屏重绘的仪表盘（不再是单行进度条）" "2" \
      "$(declare -f stress_disk | grep -c 'run_disk_with_dashboard' || true)"

# 自检：断言到底有没有在计数。
# core.sh 里也有一个 ok()，被测的 lib 一旦在断言助手**之后**被 source，
# 它就会把测试自己的 ok() 顶掉 —— 屏幕上一行行打勾、PASS 一个都不加，
# 最后汇总"通过 0 项，失败 0 项"，而 run-all 只看得到那一行。
# 本套件第一次跑就是这么绿的（§11-13）。
if (( PASS < 40 )); then
  printf '  \033[31mFAIL\033[0m 只统计到 %d 条断言，明显偏少 —— 多半是 ok() 被 core.sh 顶掉了\n' "$PASS"
  FAIL=$((FAIL+1))
fi

echo
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
