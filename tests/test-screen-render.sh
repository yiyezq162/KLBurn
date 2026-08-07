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

# 下面绝大多数断言（列宽、字符集、行数）验的是**版面**，所以统一在关掉颜色的
# 前提下跑 —— 颜色码是零宽的，混进来只会让每条断言都要先 strip 一遍。
# 颜色本身另有一组专门的断言（见末尾「上色不许动到版面」那一节），
# 钉的是"把颜色码去掉之后必须和这里一模一样"。
PANEL_COLOR=0
panel_palette 0

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
echo "=== 仪表盘：显卡掉线时不许再显示掉线前的缓存 ==="
#
# 1.8.0 现场实测：卡掉下总线之后，仪表盘**一直显示掉线那一刻的温度/功耗/
# 利用率**，屏幕上看起来卡还在满载跑，现场完全看不出出了事。
#
# 根因：gpu_status_rows 原先把 `last=$1`（最新采样时刻）写在 NF>=8 的花括号里，
# 而掉线后的行是 "14:07:55,No devices were found"（NF=2）—— 连时间戳都不看，
# last 就永远停在最后一次成功采样上。
GCSV="$TMP/gpu_metrics.csv"

mk_gpu_csv() {   # mk_gpu_csv <好的轮数> <掉线的轮数>
  local good="$1" lost="$2" i
  echo "time,index,name,temp_c,power_w,clock_sm_mhz,util_pct,mem_used_mb" > "$GCSV"
  for (( i = 0; i < good; i++ )); do
    printf '10:%02d:00,0,NVIDIA GeForce RTX 5090,71,485,2542,100,28935\n' "$i" >> "$GCSV"
  done
  for (( i = 0; i < lost; i++ )); do
    printf '11:%02d:00,No devices were found\n' "$i" >> "$GCSV"
  done
}

mk_gpu_csv 5 0
check "卡正常时读得到最新那轮" "1" "$(gpu_status_rows "$GCSV" | grep -c . || true)"
check "卡正常时掉线轮数为 0" "0" "$(gpu_lost_rounds "$GCSV")"

mk_gpu_csv 5 4
check "卡掉线后一行都不返回（绝不能再吐掉线前的缓存）" "0" \
      "$(gpu_status_rows "$GCSV" | grep -c . || true)"
check "掉线轮数数得对" "4" "$(gpu_lost_rounds "$GCSV")"
check "而且返回的不能是掉线前那条 485W 的旧读数" "0" \
      "$(gpu_status_rows "$GCSV" | grep -c '485' || true)"

# 抖动一两轮不算掉卡 —— 压测期间 nvidia-smi 偶尔读不到很正常，
# 一闪一个红字反而会让现场以为是误报。
mk_gpu_csv 5 1
check "只丢 1 轮：算抖动，还没到报警线" "1" "$(gpu_lost_rounds "$GCSV")"
mk_gpu_csv 5 2
check "丢 2 轮：仍未到报警线（GPU_LOST_ROUNDS=3）" "2" "$(gpu_lost_rounds "$GCSV")"

# 空文件 / 只有表头 / 文件不存在，一律不能算成掉卡
echo "time,index,name,temp_c,power_w,clock_sm_mhz,util_pct,mem_used_mb" > "$GCSV"
check "只有表头时不算掉卡" "0" "$(gpu_lost_rounds "$GCSV")"
check "文件不存在时不算掉卡（无显卡的机器不该报警）" "0" "$(gpu_lost_rounds "$TMP/nope.csv")"

# 掉线后又恢复：不算掉卡
mk_gpu_csv 5 4
printf '12:00:00,0,NVIDIA GeForce RTX 5090,70,480,2542,100,28935\n' >> "$GCSV"
check "掉线后又恢复读到 -> 掉线轮数归零" "0" "$(gpu_lost_rounds "$GCSV")"
check "恢复之后又能正常返回那一行" "1" "$(gpu_status_rows "$GCSV" | grep -c . || true)"

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
# 1.7.3 起版本号在标题条上、页名在框内那一行，分两行
check "标题条上有产品名和版本号" "1" \
      "$(printf '%s\n' "$panel" | grep -c 'KLBurn v9.9.9.*Server Factory Burn-in Test.*2026-08-02' || true)"
check "框内那行写着当前是哪一页" "1" \
      "$(printf '%s\n' "$panel" | grep -c '^|.*CONFIGURATION REVIEW.*|$' || true)"
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

# ================================================================
echo
echo "=== 上色不许动到版面 ==="
# 颜色只加在**边框层**，内容串一个字节都不许变。理由不是风格：
# 列宽全靠 printf '%-*.*s' 补齐，而它数的是字符个数 —— 颜色码混进内容串会被
# 算成可见字符，补出来的行短一截，整屏重绘立刻错位、越刷越花。
#
# 下面这条是整组的核心：**把颜色码去掉之后，必须和不上色时一字不差。**
# 有它在，"上色"就不可能悄悄改掉版面。
# 不能只剥 SGR（m 结尾）—— 行末还有 ESC[K（抹到行尾），
# 只剥颜色的话下面那条"去掉转义码 == 不上色"会漏掉它，等于没验。
strip_ansi() { LC_ALL=C sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g'; }

# 测试里 stdout 不是 tty，core.sh 会把 C_* 置空 —— 那样上不上色都一样，
# 这组断言就成了摆设。所以这里显式塞一组颜色进去再打开调色板。
C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
C_CYN=$'\033[1;36m'; C_GRY=$'\033[0;37m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
panel_palette 1

CPU_HOT="0|Intel Xeon Gold 6430|3100|67|100
1|Intel Xeon Gold 6430|3090|97|99
2|Intel Xeon Gold 6430|2100|102|60"

for label in "CPU 分区" "GPU 分区" "配置面板"; do :; done
colored_cpu="$(dash_cpu_rows 80 "$CPU_HOT")"
colored_gpu="$(dash_gpu_rows 80 "$(gpu_fixture 2)")"
colored_prog="$(dash_progress 80 252 600)"
panel_palette 0
plain_cpu="$(dash_cpu_rows 80 "$CPU_HOT")"
plain_gpu="$(dash_gpu_rows 80 "$(gpu_fixture 2)")"
plain_prog="$(dash_progress 80 252 600)"

check "上色后去掉颜色码 == 不上色（CPU 分区）"  "$plain_cpu"  "$(printf '%s' "$colored_cpu"  | strip_ansi)"
check "上色后去掉颜色码 == 不上色（GPU 分区）"  "$plain_gpu"  "$(printf '%s' "$colored_gpu"  | strip_ansi)"
check "上色后去掉颜色码 == 不上色（进度条）"    "$plain_prog" "$(printf '%s' "$colored_prog" | strip_ansi)"

# 而且**确实上了色**，否则上面三条用"什么都没做"也能过
check "确实加进了颜色码（否则上面几条用空实现也能过）" "yes" \
      "$(if [[ "$colored_cpu" == *$'\033['* ]]; then echo yes; else echo no; fi)"

# 温度按判定那两条线上色：67 度绿、97 度黄（>=WARN 95）、102 度红（>=FAIL 100）。
# 用的就是 klburn.conf 能覆盖的那两个阈值，现场改了阈值颜色跟着变。
panel_palette 1
CPU_TEMP_WARN=95; CPU_TEMP_FAIL=100
colored_cpu="$(dash_cpu_rows 80 "$CPU_HOT")"
check "67 度那行是绿的"   "1" "$(printf '%s\n' "$colored_cpu" | grep -c "$(printf '\033\[1;32m')   #0" || true)"
check "97 度那行是黄的"   "1" "$(printf '%s\n' "$colored_cpu" | grep -c "$(printf '\033\[1;33m')   #1" || true)"
check "102 度那行是红的"  "1" "$(printf '%s\n' "$colored_cpu" | grep -c "$(printf '\033\[1;31m')" || true)"
# 读不到温度不上色 —— 读不到既不是"正常"也不是"异常"，不该给任何暗示
check "读不到温度的行不上颜色" "0" \
      "$(dash_cpu_rows 80 '0|Some CPU|||' | grep -c "$(printf '\033\[1;3[123]m')" || true)"

# 写进 raw/ 的那份必须是纯文本：存档、grep、e2e 的日志锚点都不该带转义码
check "config_review 落盘那份要先把颜色关掉再生成" "yes" \
      "$(if declare -f config_review | grep -q 'panel_palette 0'; then echo yes; else echo no; fi)"

panel_palette 0

# ---- 标题条：每块整屏页面开头都得有 ----
# 现场那块屏经常被拍照发群里，看到的不该是"一屏滚动的日志"，
# 而是一个有名字的软件。所以是**大字**，而且每一页都在。
panel_palette 0

# ---- 高屏：大字标题 ----
ROWS=50
BRAND_COMPACT=0
BIG="$(brand_bar 80 'CONFIGURATION REVIEW')"
assert_ascii "大字标题" "$BIG"
check "大字标题是 5 行艺术字 + 1 行说明" "6" "$(nlines "$BIG")"
check "艺术字拼出来的是 KLBurn（现场认的就是这个）" "1" \
      "$(printf '%s\n' "$BIG" | grep -cF '|_|\_\_____|_|' || true)"
check "说明行有版本号" "1" \
      "$(printf '%s\n' "$BIG" | grep -c 'Server Factory Burn-in Test   v9.9.9' || true)"
check "说明行右侧写着当前是哪一页" "1" \
      "$(printf '%s\n' "$BIG" | grep -c 'CONFIGURATION REVIEW *$' || true)"
check "艺术字任何一行都不许超过面板宽度（超了就折行，折行就滚屏）" "0" \
      "$(printf '%s\n' "$BIG" | awk 'length($0) > 80' | grep -c . || true)"
assert_width "大字标题的说明行" "$(printf '%s\n' "$BIG" | tail -1)" 80
check "brand_rows 报的行数和实际画出来的一致" "$(nlines "$BIG")" "$(brand_rows)"

# ---- 矮屏（80x25 的 BMC 控制台）：退化成一行 ----
# 大字要占六行，25 行的屏上配置核对那一屏就没地方了。
ROWS=25
SMALL="$(brand_bar 80 'CONFIGURATION REVIEW')"
check "矮屏上退化成一行" "1" "$(nlines "$SMALL")"
check "矮屏上 brand_rows 也报 1" "1" "$(brand_rows)"
assert_width "矮屏标题行" "$SMALL" 80
check "退化那行照样有产品名和版本号" "1" \
      "$(printf '%s\n' "$SMALL" | grep -c 'KLBurn v9.9.9' || true)"

# ---- 装不下的时候先牺牲大字，不牺牲数据 ----
# 整屏重绘一旦超出屏幕就滚屏，滚完 ESC[H 回的原点和面板第一行对不上，越刷越歪。
ROWS=40
brand_fit 30; check "放得下就放大字" "6" "$(brand_rows)"
brand_fit 36; check "放不下就退成一行（宁可丢装饰，不丢数据）" "1" "$(brand_rows)"
brand_fit 39; check "刚好差一行也退" "1" "$(brand_rows)"
ROWS=50; BRAND_COMPACT=0

# ---- 颜色：绿色，不是反显 ----
panel_palette 1
check "大字标题是绿色的" "yes" \
      "$(if [[ "$(brand_bar 80 x)" == *$'\033[1;32m'* ]]; then echo yes; else echo no; fi)"
# 反显（背景色）在真控制台上是一整条扎眼的色块，和 ASCII 框线是两种视觉语言。
check "界面上任何地方都不许用反显/背景色" "0" \
      "$(brand_bar 80 x | grep -c '4[0-7]m' || true)"
check "去掉转义码之后和不上色时一字不差" "$BIG" \
      "$(brand_bar 80 'CONFIGURATION REVIEW' | strip_ansi)"
panel_palette 0

# 开机那张和各个页面用的必须是**同一套**大字 —— 两处各画各的，改一处就对不上了
check "开机 banner 和页面标题共用同一套艺术字" "yes" \
      "$(if declare -f banner | grep -q '_BRAND_ART'; then echo yes; else echo no; fi)"

# 每一块整屏页面都要有它 —— 少一块，那一页就"掉牌子"了
for f in cfg_panel dash_burn dash_disk select_duration; do
  check "$f 第一行是标题条" "1" "$(declare -f "$f" | grep -c 'brand_bar' || true)"
done
check "破坏性写确认那屏也要有" "1" \
      "$(grep -c 'brand_bar' "$LIB/storage.sh" || true)"
check "最终结论那屏也要有" "1" "$(grep -c '^brand_bar' "$FT" || true)"

# ---- 抬头三段不许重复（截图看出来的）----
# 第一版把 label 同时当中间段和右边段用，屏幕上就成了
#   KLBurn v1.7.2      BURN-IN  BURN-IN        BURN-IN
# 三处重复。列宽和字符集都是对的，单元测试全绿 —— 这种"字对了、意思重了"
# 的问题只有看截图才发现。现在右边放的是**档位**。
check "仪表盘抬头的右段放的是档位，不是阶段名" "yes" \
      "$(if declare -f progress_bar_concurrent | grep -q 'DURATION_PROFILE'; then echo yes; else echo no; fi)"
check "硬盘那屏同理" "yes" \
      "$(if declare -f run_disk_with_dashboard | grep -q 'DURATION_PROFILE'; then echo yes; else echo no; fi)"
HDR3="$(box_row3 80 'KLBurn v9.9.9' 'BURN-IN  CPU + MEMORY' 'QUICK')"
check "抬头里同一个词不许出现两次" "1" \
      "$(printf '%s\n' "$HDR3" | grep -o 'BURN-IN' | grep -c . || true)"

# ---- 重绘不许留空白帧 ----
# 先清屏再逐行画的话，清空和画完之间有个空窗（十几行、每行还要 fork 一次 tr），
# 人眼看到的就是每 2 秒闪一下。e2e 截图逮到过一张只画了两行的。
# 现在是回绝对原点原地覆盖 + 末尾 ESC[J。
check "重绘只回原点，不清屏（ESC[2J 会造成可见的空白帧）" "0" \
      "$(declare -f screen_home | grep -c '2J' || true)"
check "每帧末尾要抹掉上一帧残留的部分（ESC[J）" "1" \
      "$(declare -f screen_end | grep -c '\[J' || true)"
# 面板只有 80~120 列，而上一屏（开机日志）可能是 160 列的 —— 原地覆盖只盖得住
# 前 120 列，右边那截尾巴会一直挂在屏幕上（e2e 截图里看得清清楚楚）。
# 所以每行末尾还要 ESC[K 抹到行尾。
check "每行末尾要抹到行尾（ESC[K），否则右边挂着上一屏的残留" "yes" \
      "$(if [[ "$(PANEL_COLOR=1; panel_palette 1; printf '%s' "${PC[eol]}")" == *'[K'* ]]; then echo yes; else echo no; fi)"
for f in dash_burn dash_disk config_review; do
  check "$f 画完要调 screen_end" "1" "$(declare -f "$f" | grep -c 'screen_end' || true)"
done

# ---- 屏幕上一个中文都不许有：报告生成器也算屏幕输出 ----
# 那两个 python 生成器的 stdout 是 tee 到控制台的，它们原来打的是
#   内部工程报告已生成: ...
# 在 Linux 文本控制台上就是一行 ◆◆◆◆（e2e 截图里逮到的）。
# 屏幕全英文这条规矩管的是"所有会打到屏幕上的东西"，不只是 shell 那部分。
RPT="$ROOT/rootfs/opt/klburn/report"
check "generate_report.py 不许往屏幕上打中文" "0" \
      "$(grep -o 'print(\"[^\"]*\"' "$RPT/generate_report.py" | LC_ALL=C grep -c '[^ -~]' || true)"
check "generate_internal.py 不许往屏幕上打中文" "0" \
      "$(grep -o 'print(\"[^\"]*\"' "$RPT/generate_internal.py" | LC_ALL=C grep -c '[^ -~]' || true)"

# ================================================================
echo
echo "=== 掉卡那一帧：整屏画出来是什么样 ==="
#
# 上面那组测的是数据源（gpu_status_rows / gpu_lost_rounds），这一组测的是
# **真的整屏画一帧**出来对不对。分开测是有原因的：QEMU 里没有 NVIDIA 卡，
# e2e 截图永远拍不到这一帧，所以只能在这里验。
#
# 而且这一帧改动了 body 的行数计算（多了"分隔线 + 一行红字"），
# §11-11「每帧先数行数再画」——数错了就是整屏滚动、越刷越歪。
GD="$TMP/dashgpu"; mkdir -p "$GD"
RUN_DIR="$GD"
mk_dash_csv() {   # mk_dash_csv <好的轮数> <掉线的轮数>
  local good="$1" lost="$2" i
  echo "time,index,name,temp_c,power_w,clock_sm_mhz,util_pct,mem_used_mb" > "$GD/gpu_metrics.csv"
  for (( i = 0; i < good; i++ )); do
    printf '10:%02d:00,0,NVIDIA GeForce RTX 5090,71,485,2542,100,28935\n' "$i" >> "$GD/gpu_metrics.csv"
  done
  for (( i = 0; i < lost; i++ )); do
    printf '11:%02d:00,No devices were found\n' "$i" >> "$GD/gpu_metrics.csv"
  done
}

mk_dash_csv 5 0
FRAME_OK="$(dash_burn 80 QUICK 'BURN-IN  CPU + MEMORY + GPU' 60 600 | strip_ansi)"
check "卡正常时这一帧里有那张卡的读数" "1" \
      "$(printf '%s\n' "$FRAME_OK" | grep -c '485 W' || true)"
check "卡正常时不许出现掉线红字" "0" \
      "$(printf '%s\n' "$FRAME_OK" | grep -c 'NO RESPONSE' || true)"

mk_dash_csv 5 4
FRAME_LOST="$(dash_burn 80 QUICK 'BURN-IN  CPU + MEMORY + GPU' 60 600 | strip_ansi)"
check "卡掉线后这一帧必须明说卡没了" "1" \
      "$(printf '%s\n' "$FRAME_LOST" | grep -c 'NO RESPONSE' || true)"
check "而且绝不能再出现掉线前那条 485W 的旧读数" "0" \
      "$(printf '%s\n' "$FRAME_LOST" | grep -c '485 W' || true)"
check "掉线那行要告诉现场去看报告" "1" \
      "$(printf '%s\n' "$FRAME_LOST" | grep -c 'see report' || true)"
assert_ascii "掉卡帧" "$FRAME_LOST"

# 框线那部分必须还是齐的（大字标题本来就窄，不参与列宽断言）
box_only() { printf '%s\n' "$1" | grep -E '^[|+]' ; }
assert_width "掉卡帧的框线部分" "$(box_only "$FRAME_LOST")" 80
assert_width "正常帧的框线部分" "$(box_only "$FRAME_OK")" 80

# 行数：一张卡时，正常帧是「分隔 + 表头 + 1 行数据」= 3 行，
# 掉卡帧是「分隔 + 1 行红字」= 2 行，所以正好少 1 行。
# 这两个数必须和 dash_burn 里 body 的算法对得上（§11-11 每帧先数行数再画）——
# 对不上就是整屏滚动、越刷越歪。
check "掉卡帧比正常帧正好少 1 行（数据行换成红字行）" \
      "$(( $(nlines "$FRAME_OK") - 1 ))" "$(nlines "$FRAME_LOST")"
check "两帧都装得下（超出 ROWS 就会滚屏）" "yes" \
      "$( (( $(nlines "$FRAME_OK") <= ROWS && $(nlines "$FRAME_LOST") <= ROWS )) \
          && echo yes || echo no )"

# 抖动一两轮时**不许**报掉卡，也不许把面板弄没 —— 那两轮仍然显示上一次读数
mk_dash_csv 5 1
FRAME_BLIP="$(dash_burn 80 QUICK 'BURN-IN  CPU + MEMORY + GPU' 60 600 | strip_ansi)"
check "只丢 1 轮时不报掉卡（避免一闪一个红字）" "0" \
      "$(printf '%s\n' "$FRAME_BLIP" | grep -c 'NO RESPONSE' || true)"
assert_width "抖动帧的框线部分" "$(box_only "$FRAME_BLIP")" 80

# 压根没有显卡的机器：既不该有 GPU 那块，也绝不该报掉卡
rm -f "$GD/gpu_metrics.csv"
FRAME_NOGPU="$(dash_burn 80 QUICK 'BURN-IN  CPU + MEMORY' 60 600 | strip_ansi)"
check "无显卡的机器不许冒出掉卡红字" "0" \
      "$(printf '%s\n' "$FRAME_NOGPU" | grep -c 'NO RESPONSE' || true)"
assert_width "无显卡帧的框线部分" "$(box_only "$FRAME_NOGPU")" 80
RUN_DIR="$TMP"

# ---- 收尾那张逐项结果要上色（二十几行状态，黑白的话得逐行找 FAIL）----
check "逐项结果列表按状态上色" "yes" \
      "$(if grep -q 'jq -r --arg p "\$C_GRN"' "$FT"; then echo yes; else echo no; fi)"

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
