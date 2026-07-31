#!/usr/bin/env bash
#
# 内存容量核对 / 电源检查 / 网卡连通性 这三块判读逻辑的回归测试。
# 不需要任何硬件，随时可跑：
#
#     ./tests/test-hw-checks.sh
#
# 样本全部取自真机（2x Intel Xeon Gold 6530 那台）的实际输出，
# 包括那台机器上真实存在的两种异常：
#   - DMI 报装机 64GB，系统只认到 31GB
#   - 4 个电源里 PSU2/PSU4 没接交流输入（Vin 读不到值 / 读到 0V）
# 这两种情况早期版本都是静默 PASS 的，是这套测试要锁住的行为。
#
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../rootfs/opt/klburn/lib" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

RAW_DIR="$TMP"; RUN_DIR="$TMP"
# core.sh 提供 have()/dbg()/info() 等，collect.sh 和 network.sh 里都要用到
# shellcheck source=/dev/null
source "$LIB/core.sh"
# shellcheck source=/dev/null
source "$LIB/collect.sh"
# shellcheck source=/dev/null
source "$LIB/network.sh"
# shellcheck source=/dev/null
source "$LIB/verify.sh"

PASS=0; FAIL=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n     期望 [%s] 实际 [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }
check(){ [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$2" "$3"; }

# ================================================================
echo "=== 内存装机容量解析 ==="

# DDR5 的每条内存会多打一行 "Volatile Size"，累加时必须排掉
cat > "$TMP/mem-ddr5.txt" <<'EOF'
Handle 0x006B, DMI type 17, 92 bytes
Memory Device
	Array Handle: 0x006A
	Size: 16 GB
	Locator: CPU0_DIMMA0
	Type: DDR5
	Manufacturer: Hynix
	Volatile Size: 16 GB
	Cache Size: None

Handle 0x006C, DMI type 17, 92 bytes
Memory Device
	Size: No Module Installed
	Locator: CPU0_DIMMA1

Handle 0x006D, DMI type 17, 92 bytes
Memory Device
	Size: 16 GB
	Locator: CPU0_DIMME0
	Volatile Size: 16 GB
EOF
check "两条 16GB DDR5（各带一行 Volatile Size）应算出 32768MB" \
      "32768" "$(dmi_installed_mem_mb "$TMP/mem-ddr5.txt")"

cat > "$TMP/mem-mixed.txt" <<'EOF'
Handle 0x0001, DMI type 17, 92 bytes
Memory Device
	Size: 2048 MB
	Locator: DIMM0

Handle 0x0002, DMI type 17, 92 bytes
Memory Device
	Size: 1 TB
	Locator: DIMM1
EOF
check "MB / TB 单位混用也要换算正确" \
      "1050624" "$(dmi_installed_mem_mb "$TMP/mem-mixed.txt")"

cat > "$TMP/mem-none.txt" <<'EOF'
Handle 0x0001, DMI type 17, 92 bytes
Memory Device
	Size: No Module Installed
	Locator: DIMM0
EOF
check "一条都没装应算出 0（而不是空字符串）" \
      "0" "$(dmi_installed_mem_mb "$TMP/mem-none.txt")"

check "dmidecode 输出缺失时算出 0，不报错" \
      "0" "$(dmi_installed_mem_mb "$TMP/does-not-exist.txt")"

# ---------------------------------------------------------------- 系统识别容量
cat > "$TMP/meminfo.txt" <<'EOF'
MemTotal:       32526256 kB
MemFree:        30014588 kB
MemAvailable:   30137364 kB
EOF
check "MemTotal 32526256kB 应算出 31763MB" \
      "31763" "$(os_visible_mem_mb "$TMP/meminfo.txt")"

check "meminfo 读不到时算出 0" \
      "0" "$(os_visible_mem_mb "$TMP/does-not-exist.txt")"

# ---------------------------------------------------------------- 允差
check "64GB 机器允差取 6%（3932MB）" \
      "3932" "$(mem_gap_tolerance_mb 65536)"
check "8GB 小机器允差不低于 2048MB" \
      "2048" "$(mem_gap_tolerance_mb 8192)"

# 真机场景：装机 64GB、系统只认 31763MB —— 差值必须超过允差（才会判 WARN）
gap=$(( 65536 - 31763 ))
tol="$(mem_gap_tolerance_mb 65536)"
check "真机场景（装 64GB 只认 31GB）差值应大于允差" \
      "over" "$( ((gap > tol)) && echo over || echo within )"

# 正常机器：装机 32GB、系统认 31763MB（固件占掉约 1GB）—— 不能误报
gap=$(( 32768 - 31763 ))
tol="$(mem_gap_tolerance_mb 32768)"
check "正常机器（装 32GB 认 31.7GB，固件占用）不应超允差" \
      "within" "$( ((gap > tol)) && echo over || echo within )"

# ================================================================
echo
echo "=== 电源（DMI type 39 + BMC 传感器）==="

cat > "$TMP/dmidecode-psu.txt" <<'EOF'
Handle 0x005D, DMI type 39, 22 bytes
System Power Supply
	Power Unit Group: 1
	Location: PSU1
	Name: CRPS2700D2
	Manufacturer: Great Wall
	Max Power Capacity: 2700 W
	Status: Present, OK
	Plugged: Yes

Handle 0x005E, DMI type 39, 22 bytes
System Power Supply
	Power Unit Group: 2
	Location: PSU2
	Name: CRPS2700D2
	Manufacturer: Great Wall
	Max Power Capacity: 2700 W
	Status: Present, Critical
	Plugged: Yes

Handle 0x005F, DMI type 39, 22 bytes
System Power Supply
	Power Unit Group: 3
	Location: PSU3
	Name: To Be Filled By O.E.M.
	Max Power Capacity: 2700 W
	Status: Present, OK
	Plugged: Yes
EOF
check "三个电源应解析出三行「位置|状态」" \
      "PSU1|Present, OK
PSU2|Present, Critical
PSU3|Present, OK" "$(dmi_psu_list "$TMP/dmidecode-psu.txt")"

check "没有 type 39 输出时不产出任何行、不报错" \
      "" "$(dmi_psu_list "$TMP/does-not-exist.txt")"

# ---------------------------------------------------------------- 交流输入判定
cat > "$TMP/ipmi-sensors.txt" <<'EOF'
PSU1_Vin         | 218.000    | Volts      | ok    | 76.000    | 80.000    | 86.000    | 280.000   | 290.000   | 304.000
PSU1_Pin         | 345.000    | Watts      | ok    | 0.000     | 0.000     | 0.000     | 3300.000  | 3435.000  | 3600.000
PSU2_Vin         | na         | Volts      | na    | 76.000    | 80.000    | 86.000    | 280.000   | 290.000   | 304.000
PSU2_Hs_Temp     | 33.000     | degrees C  | ok    | -15.000   | -10.000   | -5.000    | 108.000   | 112.000   | 115.000
PSU3_Vin         | 220.000    | Volts      | ok    | 76.000    | 80.000    | 86.000    | 280.000   | 290.000   | 304.000
PSU4_Vin         | 0.000      | Volts      | nr    | 76.000    | 80.000    | 86.000    | 280.000   | 290.000   | 304.000
EOF
check "PSU1 读到 218V -> 有交流输入" \
      "present" "$(psu_ac_state 1 "$TMP/ipmi-sensors.txt")"
check "PSU2 的 Vin 是 na -> 没有交流输入（这一路没插电源线）" \
      "absent"  "$(psu_ac_state 2 "$TMP/ipmi-sensors.txt")"
check "PSU3 读到 220V -> 有交流输入" \
      "present" "$(psu_ac_state 3 "$TMP/ipmi-sensors.txt")"
check "PSU4 的 Vin 读到 0V -> 没有交流输入" \
      "absent"  "$(psu_ac_state 4 "$TMP/ipmi-sensors.txt")"
check "没有对应传感器的编号 -> unknown（不能瞎猜成故障）" \
      "unknown" "$(psu_ac_state 9 "$TMP/ipmi-sensors.txt")"
check "整个传感器文件都没有 -> unknown" \
      "unknown" "$(psu_ac_state 1 "$TMP/does-not-exist.txt")"

# 别的机型的命名风格也要认
cat > "$TMP/ipmi-alt.txt" <<'EOF'
PS1 Input Voltage | 231.000    | Volts      | ok    | na        | na        | na
PS2 Input Voltage | na         | Volts      | na    | na        | na        | na
EOF
check "「PS1 Input Voltage」这种命名也要认得出有电" \
      "present" "$(psu_ac_state 1 "$TMP/ipmi-alt.txt")"
check "「PS2 Input Voltage」读不到值 -> 没电" \
      "absent"  "$(psu_ac_state 2 "$TMP/ipmi-alt.txt")"

# ================================================================
echo
echo "=== 电源整体判定（check_psu）==="
# 判 FAIL 的门槛必须卡死："BMC 确认这一路有电、模块却还报异常"才是模块坏了。
# 读不到交流输入传感器（没 BMC / BMC 没这个编号）时判 FAIL 就是误杀 ——
# 测试台上只接一半电源线是常态，而没有 BMC 的机器上 DMI 对"没插线"和
# "模块坏了"报的都是 Present, Critical。

psu_case() {
  # psu_case <dmi内容> <传感器内容>  -> 把结论放进 LAST_STATUS
  RAW_DIR="$TMP/psu-case"; RUN_DIR="$TMP/psu-case"
  rm -rf "$RAW_DIR"; mkdir -p "$RAW_DIR"
  printf '%s\n' "$1" > "$RAW_DIR/dmidecode-psu.txt"
  [[ -n "$2" ]] && printf '%s\n' "$2" > "$RAW_DIR/ipmi-sensors.txt"
  LAST_STATUS=""
  check_psu
}

LAST_STATUS=""
LAST_DETAIL=""
result_add() { LAST_STATUS="$3"; LAST_DETAIL="$4"; }
metric_add() { :; }

DMI_OK_OK='Handle 0x1, DMI type 39, 22 bytes
System Power Supply
	Location: PSU1
	Status: Present, OK

Handle 0x2, DMI type 39, 22 bytes
System Power Supply
	Location: PSU2
	Status: Present, OK'

DMI_OK_CRIT='Handle 0x1, DMI type 39, 22 bytes
System Power Supply
	Location: PSU1
	Status: Present, OK

Handle 0x2, DMI type 39, 22 bytes
System Power Supply
	Location: PSU2
	Status: Present, Critical'

SENS_BOTH_HOT='PSU1_Vin | 218.000 | Volts | ok | 76.000
PSU2_Vin | 220.000 | Volts | ok | 76.000'
SENS_PSU2_DEAD='PSU1_Vin | 218.000 | Volts | ok | 76.000
PSU2_Vin | na      | Volts | na | 76.000'
SENS_UNRELATED='CPU0_Temp | 45.000 | degrees C | ok | 3.100'

psu_case "$DMI_OK_OK" "$SENS_BOTH_HOT"
check "两路都有电、状态都正常 -> PASS" "PASS" "$LAST_STATUS"

psu_case "$DMI_OK_OK" "$SENS_PSU2_DEAD"
check "PSU2 没接交流输入但模块没报异常 -> WARN（无冗余，不是故障）" "WARN" "$LAST_STATUS"

psu_case "$DMI_OK_CRIT" "$SENS_BOTH_HOT"
check "PSU2 有电却报 Critical -> FAIL（这才是模块真坏了）" "FAIL" "$LAST_STATUS"

psu_case "$DMI_OK_CRIT" "$SENS_PSU2_DEAD"
check "PSU2 报 Critical 且确认没电 -> WARN（就是没插线，不是故障）" "WARN" "$LAST_STATUS"

# ↓ 这条是这次审查加的：没有 BMC 的机器绝不能因为 DMI 报 Critical 就判 FAIL
psu_case "$DMI_OK_CRIT" "$SENS_UNRELATED"
check "报 Critical 但读不到任何 Vin 传感器 -> WARN 而不是 FAIL（分不清没插线还是坏了）" \
      "WARN" "$LAST_STATUS"

RAW_DIR="$TMP/psu-nofile"; RUN_DIR="$TMP/psu-nofile"; mkdir -p "$RAW_DIR"
LAST_STATUS=""; check_psu
check "BIOS 完全不上报 DMI type 39 -> SKIP" "SKIP" "$LAST_STATUS"

RAW_DIR="$TMP"; RUN_DIR="$TMP"

# ================================================================
echo
echo "=== 计数不能算出 \"0\\n0\"（count_lines）==="
# 真实事故：`n="\$(grep -c . f || echo 0)"` 在计数为 0 时会得到两行的 "0\n0"，
# 因为 grep -c 既打印 "0" 又返回 1，|| 分支再补一个。拿去做 (( n > 0 ))
# 会在现场屏幕上抛 arithmetic syntax error。而它**只在健康机器上发作**：
# 干净机器的 dmesg-errors.txt 必然是空的。

: > "$TMP/cnt-empty.txt"
printf 'a\nb\nc\n'        > "$TMP/cnt-3.txt"
printf 'a\n\n\nb\n'       > "$TMP/cnt-blank.txt"

check "空文件应算出 0"           "0" "$(count_lines "$TMP/cnt-empty.txt")"
check "三行应算出 3"             "3" "$(count_lines "$TMP/cnt-3.txt")"
check "空行不计入"               "2" "$(count_lines "$TMP/cnt-blank.txt")"
check "文件不存在应算出 0"       "0" "$(count_lines "$TMP/cnt-nope.txt")"
check "参数为空应算出 0"         "0" "$(count_lines "")"

# 核心断言：结果必须是"一行"，且能直接进算术不报错
check "计数为 0 时结果只能有一行（不能是 0\\n0）" \
      "0" "$(count_lines "$TMP/cnt-empty.txt" | wc -l)"

n="$(count_lines "$TMP/cnt-empty.txt")"
arith_err="$( ( (( n > 0 )) ) 2>&1 >/dev/null )"
check "计数为 0 的结果拿去做算术不能报错" "" "$arith_err"

# 守住调用点：所有 grep -c 的计数一律不许再跟 `|| echo 0`。
# 要排掉注释行 —— count_lines 的说明里就写着这句反面示范，
# 不排的话这条守卫会被自己的文档绊倒（第一次跑就是这么红的）。
check "运行时脚本里不许再出现 'grep -c ... || echo 0' 这种写法" \
      "0" "$(grep -rn 'grep -[a-zA-Z]*c[a-zA-Z]* .*|| echo 0' "$LIB" \
             | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -c .)"

# ---------------------------------------------------------------- 真实调用点
# 上面测的是 count_lines 本身，这条测的是它实际被用的那个地方。
# 复现现场那次的条件：一台干净机器，dmesg 里没有任何硬件错误，
# 于是 dmesg-errors.txt 是 0 字节 —— 旧代码正是在这里把 "0\n0" 塞进 (( n > 0 ))，
# 屏幕上冒出一行 arithmetic syntax error（每台好机器都会中招）。
RAW_DIR="$TMP/dmesg-case"; RUN_DIR="$TMP/dmesg-case"; mkdir -p "$RAW_DIR"
capture() { :; }        # 别去真的跑 dmesg，直接用下面这份 fixture
printf 'boot line one\nboot line two\n' > "$RAW_DIR/dmesg-pre.txt"
printf 'boot line one\nboot line two\n' > "$RAW_DIR/dmesg-post.txt"

LAST_STATUS=""
verify_dmesg 2>"$TMP/dmesg.err" >/dev/null

check "干净机器（dmesg 无硬件错误）-> PASS" "PASS" "$LAST_STATUS"
check "而且 stderr 必须是干净的（旧代码在这里抛 arithmetic syntax error）" \
      "0" "$(grep -c . "$TMP/dmesg.err")"

# 反向：真有硬件错误时还得抓得住，别为了消错误把判定也消掉了
printf 'boot line one\n' > "$RAW_DIR/dmesg-pre.txt"
printf 'boot line one\nmce: [Hardware Error]: Machine Check Exception\n' > "$RAW_DIR/dmesg-post.txt"
LAST_STATUS=""
verify_dmesg 2>/dev/null >/dev/null
check "压测期间真出现 Machine Check -> FAIL" "FAIL" "$LAST_STATUS"

RAW_DIR="$TMP"; RUN_DIR="$TMP"

# ================================================================
echo
echo "=== 网卡 ping / 地址判读 ==="

cat > "$TMP/ping-ok.txt" <<'EOF'
PING 192.168.1.1 (192.168.1.1) from 192.168.1.87 ens9f0: 56(84) bytes of data.
64 bytes from 192.168.1.1: icmp_seq=1 ttl=64 time=0.152 ms
64 bytes from 192.168.1.1: icmp_seq=2 ttl=64 time=0.281 ms
64 bytes from 192.168.1.1: icmp_seq=3 ttl=64 time=0.196 ms
64 bytes from 192.168.1.1: icmp_seq=4 ttl=64 time=0.183 ms

--- 192.168.1.1 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 3005ms
rtt min/avg/max/mdev = 0.152/0.203/0.281/0.049 ms
EOF
check "全通应解析出 4 发 4 收、平均 0.203ms" \
      "4 4 0.203" "$(net_parse_ping "$TMP/ping-ok.txt")"

cat > "$TMP/ping-lost.txt" <<'EOF'
PING 10.0.0.1 (10.0.0.1) from 10.0.0.5 ens9f1: 56(84) bytes of data.

--- 10.0.0.1 ping statistics ---
4 packets transmitted, 0 received, 100% packet loss, time 3072ms
EOF
check "全丢包应解析出 4 发 0 收、无平均值" \
      "4 0 -" "$(net_parse_ping "$TMP/ping-lost.txt")"

: > "$TMP/ping-empty.txt"
check "空的 ping 输出不崩、三项都给 -" \
      "- - -" "$(net_parse_ping "$TMP/ping-empty.txt")"

check "从 ip addr 输出里取出 IPv4" \
      "192.168.1.87/24" \
      "$(net_parse_addr '2: ens9f0    inet 192.168.1.87/24 brd 192.168.1.255 scope global dynamic ens9f0\       valid_lft 43199sec')"
check "没有 IPv4 时给空" \
      "" "$(net_parse_addr '3: ens9f1    inet6 fe80::6eb3:11ff:fe09:24f6/64 scope link')"

check "从 ip route 输出里取出默认网关" \
      "192.168.1.1" "$(net_parse_gateway 'default via 192.168.1.1 dev ens9f0 proto dhcp src 192.168.1.87 metric 100')"
check "路由里没有 via 时给空（DHCP 只给地址不给网关）" \
      "" "$(net_parse_gateway '192.168.1.0/24 dev ens9f0 proto kernel scope link src 192.168.1.87')"

check "未接网线的结论文案" \
      "未连接链路（未接网线）" "$(net_result_text NO_LINK)"

# ================================================================
echo
echo "=== 联网校时（sync_clock_now）==="
# 注意：这里不测 try_sync_clock_via_network / net_dhcp 本体——它们会真的去
# ip link set up / dhclient 一个物理网口，在开发机 / CI 容器里跑会动到宿主机
# 真实网络状态，不安全也不合适。只测不碰硬件的那部分。

check "候选校时服务器列表不能是空的" \
      "over" "$( ((${#NET_TIME_SERVERS[@]} > 0)) && echo over || echo within )"

if have chronyd; then
  echo "  (本机装了 chronyd，跳过“客户端缺失应返回失败”这条——环境不对，不是用例本身的问题)"
else
  check "本机没装 chronyd 时 sync_clock_now 应直接返回失败，不报错、不挂起" \
        "1" "$(sync_clock_now; echo $?)"
fi

# ================================================================
echo
echo "=== dhclient 调用参数回归守卫 ==="
# 真机上炸过：net_dhcp() 给 dhclient 传了个根本不存在的 "-timeout <秒数>"
# 命令行参数（timeout 只是 dhclient.conf 里的配置指令，不是 CLI 选项），
# dhclient 直接打印 usage 报错退出，导致"网线明明插好了、DHCP 也通，
# 却一个口都测不到"。这条守的是"以后不会有人手滑把它加回去"。
# 精确匹配这一行本身（不是整份文件模糊搜 "-timeout"——文件里的解释性注释
# 本来就会提到 "-timeout" 这个词，广撒网搜整个文件只会误伤注释）。
# 只要日后有人手滑在 -1 和 "$ifn" 之间塞回 -timeout 之类的参数，
# 这个精确子串就再也找不到了，测试会失败。
check "net_dhcp() 应该原样保留 dhclient -4 -1 \"\$ifn\" 这个正确调用（没有夹带 -timeout）" \
      "1" "$(grep -cF 'dhclient -4 -1 "$ifn"' "$LIB/network.sh")"

# ================================================================
echo
echo "=== 网卡型号反查（nic_pci_model）==="

cat > "$TMP/lspci-nic.txt" <<'EOF'
00:17.0 SATA controller [0106]: Intel Corporation Device [8086:1ba2] (rev 11)
27:00.0 Ethernet controller [0200]: Intel Corporation 82599ES 10-Gigabit SFI/SFP+ Network Connection [8086:10fb] (rev 01)
27:00.1 Ethernet controller [0200]: Intel Corporation 82599ES 10-Gigabit SFI/SFP+ Network Connection [8086:10fb] (rev 01)
da:00.3 Ethernet controller [0200]: Intel Corporation I350 Gigabit Network Connection [8086:1521] (rev 01)
EOF

check "带 PCI domain 前缀的总线地址（ethtool 风格）应该反查出型号" \
      "Intel Corporation 82599ES 10-Gigabit SFI/SFP+ Network Connection" \
      "$(nic_pci_model "0000:27:00.0" "$TMP/lspci-nic.txt")"
check "不带前缀也应该反查出型号（lspci.txt 本来就不带）" \
      "Intel Corporation I350 Gigabit Network Connection" \
      "$(nic_pci_model "da:00.3" "$TMP/lspci-nic.txt")"
check "总线地址里的 . 不能被当成正则通配符误伤到别的地址" \
      "" "$(nic_pci_model "0000:27x00.0" "$TMP/lspci-nic.txt")"
check "查无此地址应给空，不报错" \
      "" "$(nic_pci_model "0000:99:00.0" "$TMP/lspci-nic.txt")"
check "总线地址是空字符串应给空，不报错" \
      "" "$(nic_pci_model "" "$TMP/lspci-nic.txt")"
check "lspci.txt 不存在应给空，不报错" \
      "" "$(nic_pci_model "27:00.0" "$TMP/does-not-exist.txt")"

# ================================================================
echo
echo "=== 阵列卡 / BMC 交叉核对（raid_bmc_hint）==="

IPMI_OK=1

cat > "$TMP/ipmi-sdr-noraid.txt" <<'EOF'
RAID/HBA_1_Temp  | 1Dh | ns  | 11.65 | No Reading
RAID/HBA_2_Temp  | 1Eh | ns  | 11.66 | No Reading
Slot1_Power      | 23h | ns  |  7.63 | No Reading
RiserA_Power     | B3h | ns  |  7.67 | No Reading
EOF

cat > "$TMP/ipmi-sdr-hasraid.txt" <<'EOF'
RAID/HBA_1_Temp  | 1Dh | ok  | 11.65 | 42
Slot1_Power      | 23h | ok  |  7.63 | 25 Watts
EOF

cat > "$TMP/ipmi-sdr-none.txt" <<'EOF'
CPU0_Temp        | 01h | ok  |  3.1  | 45 degrees C
Fan1             | 02h | ok  |  4.1  | 6000 RPM
EOF

RAW_DIR="$TMP/case-noraid"; mkdir -p "$RAW_DIR"
cp "$TMP/ipmi-sdr-noraid.txt" "$RAW_DIR/ipmi-sdr.txt"
check "板子定义了 RAID/HBA/Slot 传感器但全部 No Reading -> 应给出提示" \
      "hint" "$([[ -n "$(raid_bmc_hint)" ]] && echo hint || echo empty)"

RAW_DIR="$TMP/case-hasraid"; mkdir -p "$RAW_DIR"
cp "$TMP/ipmi-sdr-hasraid.txt" "$RAW_DIR/ipmi-sdr.txt"
check "传感器有实际读数 -> 说明真有东西在响应，不该给这条模棱两可的提示" \
      "empty" "$([[ -n "$(raid_bmc_hint)" ]] && echo hint || echo empty)"

RAW_DIR="$TMP/case-none"; mkdir -p "$RAW_DIR"
cp "$TMP/ipmi-sdr-none.txt" "$RAW_DIR/ipmi-sdr.txt"
check "板子压根没定义 RAID/HBA/Slot 相关传感器 -> 不该瞎猜，给空" \
      "empty" "$([[ -n "$(raid_bmc_hint)" ]] && echo hint || echo empty)"

RAW_DIR="$TMP/case-noipmi"; mkdir -p "$RAW_DIR"
cp "$TMP/ipmi-sdr-noraid.txt" "$RAW_DIR/ipmi-sdr.txt"
IPMI_OK=0
check "没有 BMC（IPMI_OK=0）时不该假装读到了什么" \
      "empty" "$([[ -n "$(raid_bmc_hint)" ]] && echo hint || echo empty)"
IPMI_OK=1

RAW_DIR="$TMP"

# ================================================================
echo
echo "=== 硬盘温度判定（verify_disk_temp）==="
# 这是 0.4.0 新接上的判定（DISK_TEMP_WARN/FAIL 以前定义了却没人用），
# 新判定最怕的就是误判 —— 尤其"读不到温度"绝不能被当成故障。

if ! have jq; then
  echo "  (本机没装 jq，smart_field 读不了归一化 JSON，跳过这一组——环境问题，不是用例问题)"
else
  RAW_DIR="$TMP/disktemp"; RUN_DIR="$TMP/disktemp"
  mkdir -p "$RAW_DIR/smart-pre" "$RAW_DIR/smart-post"

  # 截获 result_add / metric_add：不依赖真的写 results.jsonl，直接看结论。
  # 注意 detail($4) 也要接住 —— 后面几组用例会断言文案内容，
  # 这里要是只接 $3，就会把上面那个完整的替身覆盖掉，
  # 于是 LAST_DETAIL 从这行往下永远是空的（本来就这么坑过一次）。
  LAST_STATUS=""; LAST_DETAIL=""
  result_add() { LAST_STATUS="$3"; LAST_DETAIL="$4"; }
  metric_add() { :; }

  mk_post() { printf '{"temperature_c":%s}\n' "$2" > "$RAW_DIR/smart-post/$1.norm.json"; }

  DISK_SMART=(/dev/sda /dev/nvme0n1)

  mk_post sda 38; mk_post nvme0n1 55
  verify_disk_temp
  check "38°C + 55°C 都不烫 -> PASS" "PASS" "$LAST_STATUS"

  mk_post nvme0n1 70
  verify_disk_temp
  check "正好踩到告警线 70°C -> WARN" "WARN" "$LAST_STATUS"

  mk_post nvme0n1 79
  verify_disk_temp
  check "79°C 还没到上限 -> 仍然只是 WARN" "WARN" "$LAST_STATUS"

  mk_post nvme0n1 80
  verify_disk_temp
  check "正好踩到上限 80°C -> FAIL" "FAIL" "$LAST_STATUS"

  # 一块盘烫不能被另一块正常的盘稀释掉
  mk_post sda 30; mk_post nvme0n1 91
  verify_disk_temp
  check "一块盘 91°C、另一块 30°C -> 整体仍是 FAIL" "FAIL" "$LAST_STATUS"

  # 读不到温度的盘绝不能被判成故障
  mk_post sda null; mk_post nvme0n1 null
  verify_disk_temp
  check "所有盘都不上报温度 -> SKIP（不能瞎猜成故障）" "SKIP" "$LAST_STATUS"

  mk_post sda null; mk_post nvme0n1 42
  verify_disk_temp
  check "一块盘没温度、另一块 42°C -> 只按读到的那块判，PASS" "PASS" "$LAST_STATUS"

  # 明显不可信的读数要丢掉，不能当成"超标"
  mk_post sda 0; mk_post nvme0n1 200
  verify_disk_temp
  check "0°C 和 200°C 都不可信 -> 当作没读到，SKIP" "SKIP" "$LAST_STATUS"

  DISK_SMART=()
  verify_disk_temp
  check "没有本机硬盘 -> SKIP" "SKIP" "$LAST_STATUS"

  RAW_DIR="$TMP"; RUN_DIR="$TMP"
fi

# ================================================================
echo
echo "=== 内核日志关键字：真故障要抓住，正常噪声一条都不许命中 ==="
# 正样本取自现场那台 MegaRAID 濒死的机器（2x Xeon Gold 6530），完整故障链。
# 这 9 行里，旧模式只有 "AER:" 那两条能命中，而且它们全在 dmesg-pre 里、
# 被 verify_dmesg 的 delta 减光了，所以那台机器"内核日志复查"判的是 PASS。
DMESG_BAD="$TMP/dmesg-bad.txt"
cat > "$DMESG_BAD" <<'EOF'
[Wed Nov 26 02:16:27 2025] pcieport 0000:97:01.0: EDR: EDR event received
[Wed Nov 26 02:16:27 2025] pcieport 0000:97:01.0: DPC: containment event, status:0x1f03, ERR_NONFATAL received from 0000:98:00.0
[Wed Nov 26 02:16:27 2025] megaraid_sas 0000:98:00.0: AER: can't recover (no error_detected callback)
[Wed Nov 26 02:16:28 2025] megaraid_sas 0000:98:00.0: FW in FAULT state Fault code:0xfff0000 subcode:0xff00 func:megasas_wait_for_outstanding_fusion
[Wed Nov 26 02:16:28 2025] megaraid_sas 0000:98:00.0: resetting fusion adapter scsi0.
[Wed Nov 26 02:16:28 2025] pcieport 0000:97:01.0: AER: device recovery failed
[Wed Nov 26 02:18:15 2025] megaraid_sas 0000:98:00.0: Diag reset adapter never cleared megasas_adp_reset_fusion 4100
[Wed Nov 26 02:21:49 2025] megaraid_sas 0000:98:00.0: Reset failed, killing adapter scsi0.
[Wed Nov 26 02:21:50 2025] megaraid_sas 0000:98:00.0: Failed from megasas_fault_detect_work 1963, do not re-arm timer
EOF

# 负样本全部取自同一台机器**健康那次**的真实 dmesg，长得都很像错误但完全正常。
# 前三行是 0.4.0 的裸 NMI 模式会命中的——那是每台机器开机都有的，
# 一旦漏进来就是"每台机器都报 3 条硬件错误"，比漏判更糟。
DMESG_NOISE="$TMP/dmesg-noise.txt"
cat > "$DMESG_NOISE" <<'EOF'
[Wed Nov 26 02:16:23 2025] ACPI: X2APIC_NMI (uid[0xffffffff] high edge lint[0x1])
[Wed Nov 26 02:16:23 2025] ACPI: LAPIC_NMI (acpi_id[0xff] high edge lint[0x1])
[Wed Nov 26 02:16:23 2025] NMI watchdog: Enabled. Permanently consumes one hw-PMU counter.
[Wed Nov 26 02:16:23 2025] acpi PNP0A08:00: _OSC: platform does not support [SHPCHotplug AER LTR DPC]
[Wed Nov 26 02:16:24 2025] pci 0000:d7:03.0: bridge window [io  size 0x1000]: failed to assign
[Wed Nov 26 02:16:24 2025] ERST: Error Record Serialization Table (ERST) support is initialized.
[Wed Nov 26 02:16:24 2025] RAS: Correctable Errors collector initialized.
[Wed Nov 26 02:16:22 2025] x86/split lock detection: #AC: crashing the kernel on kernel split_locks and warning on user-space split_locks
[Wed Nov 26 02:16:31 2025] systemd[1]: smartd.service: Cannot add dependency job, ignoring: Unit smartd.service failed to load properly, please adjust/correct and reload service manager: File exists
[Wed Nov 26 02:16:25 2025] megaraid_sas 0000:98:00.0: FW now in Ready state
[Wed Nov 26 02:16:26 2025] megaraid_sas 0000:98:00.0: firmware crash dump	: no
[Wed Nov 26 02:16:26 2025] megaraid_sas 0000:98:00.0: FW provided TM TaskAbort/Reset timeout	: 0 secs/0 secs
[Wed Nov 26 02:16:26 2025] megaraid_sas 0000:98:00.0: Online Controller Reset(OCR)	: Enabled
[Wed Nov 26 02:21:49 2025] ixgbe 0000:27:00.0: invalid VPD tag 0xff (size 65378) at offset 25091
[Wed Nov 26 02:16:24 2025] pcieport 0000:d7:01.0: PME: Signaling with IRQ 71
[Wed Nov 26 02:16:24 2025] EDAC MC0: Giving out device to module i10nm_edac controller Intel_10nm Socket#0 IMC#0: DEV 0000:7e:0c.0 (INTERRUPT)
[Wed Nov 26 02:16:24 2025] EDAC MC: Ver: 3.0.0
[Wed Nov 26 02:16:24 2025] EDAC i10nm: No hbm memory
EOF

dmesg_scan_hw_errors "$DMESG_BAD" "$TMP/hits-bad.txt"
check "阵列卡完整故障链 9 行必须全部命中" "9" "$(count_lines "$TMP/hits-bad.txt")"

dmesg_scan_hw_errors "$DMESG_NOISE" "$TMP/hits-noise.txt"
check "开机正常噪声一条都不许命中（含 NMI / AER无冒号 / EDAC 初始化 / Correctable Errors）" \
      "0" "$(count_lines "$TMP/hits-noise.txt")"

# 逐条钉死几个最容易被改坏的，免得以后有人把裸 NMI 或裸 CE 加回来
for bad_line in \
  'ACPI: X2APIC_NMI (uid[0xffffffff] high edge lint[0x1])' \
  'NMI watchdog: Enabled. Permanently consumes one hw-PMU counter.' \
  'acpi PNP0A08:00: _OSC: platform does not support [SHPCHotplug AER LTR DPC]' \
  'EDAC MC0: Giving out device to module i10nm_edac controller Intel_10nm Socket#0 IMC#0: DEV 0000:7e:0c.0 (INTERRUPT)' \
  'RAS: Correctable Errors collector initialized.' \
  'megaraid_sas 0000:98:00.0: FW now in Ready state'
do
  printf '[Wed Nov 26 02:16:23 2025] %s\n' "$bad_line" > "$TMP/one.txt"
  dmesg_scan_hw_errors "$TMP/one.txt" "$TMP/one-hit.txt"
  check "不许命中: ${bad_line:0:60}" "0" "$(count_lines "$TMP/one-hit.txt")"
done

# 真正的 EDAC 报错格式必须还能抓住（收紧模式别把真错误也关在门外）
printf '[Wed Nov 26 02:16:23 2025] EDAC MC0: 1 CE memory read error on CPU_SrcID#0_MC#0_Chan#0_DIMM#0\n' > "$TMP/one.txt"
dmesg_scan_hw_errors "$TMP/one.txt" "$TMP/one-hit.txt"
check "真的 EDAC 可纠正错误必须命中" "1" "$(count_lines "$TMP/one-hit.txt")"
printf '[Wed Nov 26 02:16:23 2025] Uhhuh. NMI received for unknown reason 3d on CPU 0.\n' > "$TMP/one.txt"
dmesg_scan_hw_errors "$TMP/one.txt" "$TMP/one-hit.txt"
check "真的 NMI 故障必须命中" "1" "$(count_lines "$TMP/one-hit.txt")"

# ================================================================
echo
echo "=== 开机内核日志复查（这一项就是为了堵住 delta 减掉开机错误那个洞）==="
RAW_DIR="$TMP/boot"; RUN_DIR="$TMP/boot"
rm -rf "$RAW_DIR"; mkdir -p "$RAW_DIR"

cp "$DMESG_BAD" "$RAW_DIR/dmesg-pre.txt"
LAST_STATUS=""; verify_dmesg_boot
check "开机日志里有阵列卡故障 -> FAIL" "FAIL" "$LAST_STATUS"

cp "$DMESG_NOISE" "$RAW_DIR/dmesg-pre.txt"
LAST_STATUS=""; verify_dmesg_boot
check "开机日志只有正常噪声 -> PASS" "PASS" "$LAST_STATUS"

rm -f "$RAW_DIR/dmesg-pre.txt"
LAST_STATUS=""; verify_dmesg_boot
check "没采到开机日志 -> SKIP（读不到数据不能当故障）" "SKIP" "$LAST_STATUS"

# ================================================================
echo
echo "=== PCIe 链路：只查端点，桥的正常降速一条都不许报 ==="
# 全部取自现场真机 lspci -vv -nn 的原始格式。
# 两个桥是关键负样本：它们的 LnkSta 确实低于 LnkCap，但那是设计如此
# （LnkCap 是槽位能力，LnkSta 是和对端协商的结果）。把桥一起判 = 每台机器都告警。
RAW_DIR="$TMP/pcie"; RUN_DIR="$TMP/pcie"
rm -rf "$RAW_DIR"; mkdir -p "$RAW_DIR"
cat > "$RAW_DIR/lspci-vv.txt" <<'EOF'
00:0f.0 PCI bridge [0604]: Intel Corporation Device [8086:1bbf] (rev 11) (prog-if 00 [Normal decode])
	Capabilities: [40] Express (v2) Root Port (Slot+), MSI 00
		LnkCap:	Port #15, Speed 8GT/s, Width x1, ASPM not supported
		LnkSta:	Speed 5GT/s, Width x1
		LnkCap2: Supported Link Speeds: 2.5-8GT/s, Crosslink- Retimer- 2Retimers- DRS-
26:01.0 PCI bridge [0604]: Intel Corporation Device [8086:352a] (rev 30) (prog-if 00 [Normal decode])
	Capabilities: [40] Express (v2) Root Port (Slot+), MSI 00
		LnkCap:	Port #9, Speed 32GT/s, Width x8, ASPM not supported
		LnkSta:	Speed 5GT/s, Width x8
27:00.0 Ethernet controller [0200]: Intel Corporation 82599ES 10-Gigabit SFI/SFP+ Network Connection [8086:10fb] (rev 01)
	Capabilities: [a0] Express (v2) Endpoint, MSI 00
		LnkCap:	Port #4, Speed 5GT/s, Width x8, ASPM L0s, Exit Latency L0s <1us
		LnkSta:	Speed 5GT/s, Width x8
c8:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD102 [GeForce RTX 4090] [10de:2684] (rev a1) (prog-if 00 [VGA controller])
	Capabilities: [60] Express (v2) Legacy Endpoint, MSI 00
		LnkCap:	Port #0, Speed 16GT/s, Width x16, ASPM L1, Exit Latency L1 <4us
		LnkSta:	Speed 16GT/s, Width x16
EOF

rows="$(pcie_link_scan "$RAW_DIR/lspci-vv.txt")"
check "只解析出 2 个端点（两个 PCI bridge 必须被跳过）" "2" "$(printf '%s\n' "$rows" | grep -c .)"
check "桥 26:01.0 不许出现在结果里" "0" "$(printf '%s\n' "$rows" | grep -c '^26:01\.0')"
check "4090 端点被识别" "1" "$(printf '%s\n' "$rows" | grep -c '^c8:00\.0')"
check "4090 的额定/实际解析正确" "c8:00.0|NVIDIA Corporation AD102 [GeForce RTX 4090]|16|16|16|16" \
      "$(printf '%s\n' "$rows" | grep '^c8:00\.0')"

LAST_STATUS=""; check_pcie_link
check "两个端点都满速 -> PASS（桥的降速不算数）" "PASS" "$LAST_STATUS"

# 把 4090 改成插在 x8 槽、且只训练到 Gen1
sed -i 's/^\t\tLnkSta:\tSpeed 16GT\/s, Width x16/\t\tLnkSta:\tSpeed 2.5GT\/s, Width x8/' "$RAW_DIR/lspci-vv.txt"
LAST_STATUS=""; check_pcie_link
check "端点宽度和速率都没跑到额定 -> WARN" "WARN" "$LAST_STATUS"
check "WARN 文案里要点名是哪个设备" "1" "$(printf '%s' "$LAST_DETAIL" | grep -c 'c8:00.0')"

rm -f "$RAW_DIR/lspci-vv.txt"
LAST_STATUS=""; check_pcie_link
check "没有 lspci-vv 数据 -> SKIP" "SKIP" "$LAST_STATUS"

# ================================================================
echo
echo "=== 网卡协商速率达标 ==="
RAW_DIR="$TMP/nicspeed"; RUN_DIR="$TMP/nicspeed"
rm -rf "$RAW_DIR"; mkdir -p "$RAW_DIR/nic"

# 现场真机 ens9f0 的原样输出：万兆口，协商到 10000Mb/s
ETH_10G_OK='Settings for ens9f0:
	Supported ports: [ FIBRE ]
	Supported link modes:   10000baseT/Full
	Supported pause frame use: Symmetric
	Supports auto-negotiation: No
	Supported FEC modes: Not reported
	Advertised link modes:  10000baseT/Full
	Speed: 10000Mb/s
	Duplex: Full
	Port: FIBRE
	Link detected: yes'

# 同一块卡，只协商到千兆（线不对 / 模块不对 / 对端口不对）
ETH_10G_SLOW="${ETH_10G_OK//Speed: 10000Mb\/s/Speed: 1000Mb/s}"

# 支持多档速率、且跨行列出的口——解析要吃到下一个字段名为止，取最大值
ETH_MULTI='Settings for eno1:
	Supported ports: [ TP ]
	Supported link modes:   100baseT/Full
	                        1000baseT/Full
	                        10000baseT/Full
	Supported pause frame use: Symmetric
	Speed: 10000Mb/s
	Duplex: Full
	Link detected: yes'

# 没插网线：ethtool 报的速率是假的，必须整条让开
ETH_NOLINK='Settings for ens66f0:
	Supported link modes:   10000baseT/Full
	Speed: Unknown!
	Duplex: Unknown! (255)
	Link detected: no'

# 也是没插网线，但驱动没报 Unknown!，而是留了个陈旧/缺省的速率。
# 这种才是 "Link detected: yes" 那道守卫真正要挡的：光靠"速率读不到就让开"
# 兜不住它，会把一个压根没插线的口判成"万兆口只跑了 10Mb/s"。
ETH_NOLINK_STALE='Settings for ens66f1:
	Supported link modes:   10000baseT/Full
	Speed: 10Mb/s
	Duplex: Half
	Link detected: no'

printf '%s\n' "$ETH_MULTI" > "$TMP/eth-multi.txt"
check "跨行的 Supported link modes 取最大值 10000" "10000" "$(nic_supported_max_mbps "$TMP/eth-multi.txt")"
check "当前速率解析 10000" "10000" "$(nic_current_mbps "$TMP/eth-multi.txt")"
printf '%s\n' "$ETH_NOLINK" > "$TMP/eth-nolink.txt"
check "Speed: Unknown! 要当成读不到（0），不能当成 0 速率故障" "0" "$(nic_current_mbps "$TMP/eth-nolink.txt")"

nic_speed_case() {
  rm -rf "$RAW_DIR/nic"; mkdir -p "$RAW_DIR/nic"
  local n=1 body
  for body in "$@"; do
    printf '%s\n' "$body" > "$RAW_DIR/nic/eth${n}-ethtool.txt"
    n=$((n+1))
  done
  # check_nic_speed 靠 net_phys_ifaces 取网口列表，这里替身掉
  net_phys_ifaces() { local i; for i in $(seq 1 $(( n - 1 ))); do printf 'eth%d\n' "$i"; done; }
  LAST_STATUS=""; LAST_DETAIL=""
  check_nic_speed
}

nic_speed_case "$ETH_10G_OK" "$ETH_MULTI"
check "两个口都协商到额定速率 -> PASS" "PASS" "$LAST_STATUS"

nic_speed_case "$ETH_10G_SLOW"
check "万兆口只协商到千兆 -> WARN" "WARN" "$LAST_STATUS"
check "WARN 文案要写清实际和额定" "1" "$(printf '%s' "$LAST_DETAIL" | grep -c '实际 1000Mb/s，额定 10000Mb/s')"

nic_speed_case "$ETH_NOLINK"
check "全都没接网线 -> SKIP（不接网线是测试台常态，不是故障）" "SKIP" "$LAST_STATUS"

nic_speed_case "$ETH_NOLINK_STALE"
check "没插线但驱动留了陈旧速率 -> 仍然 SKIP，不许判成「万兆口只跑了 10Mb/s」" \
      "SKIP" "$LAST_STATUS"

nic_speed_case "$ETH_NOLINK" "$ETH_NOLINK_STALE" "$ETH_10G_OK"
check "混合时只判已接网线那个 -> PASS" "PASS" "$LAST_STATUS"

nic_speed_case "$ETH_NOLINK" "$ETH_10G_SLOW"
check "混合时只判已接网线那个 -> WARN" "WARN" "$LAST_STATUS"

unset -f net_phys_ifaces
# shellcheck source=/dev/null
source "$LIB/network.sh"      # 把被替身掉的 net_phys_ifaces 还原回来

# ================================================================
echo
echo "=== 阵列卡：坏到不枚举 vs 本来就没装 ==="
# 现场实证：同一台机器连测两次，第一次卡在 lspci 里还看得见（判 WARN），
# 第二次卡坏到 PCI 枚举都过不去、lspci 里整个消失，判 SKIP「未安装阵列卡」，
# 两次整机结论都是 PASS。单看一次运行这两种情况分不开，所以不能判 FAIL
# （无卡机型会被误杀），但 BMC 明明预留了 RAID/HBA 传感器却一条读数都没有时，
# 抬成 WARN 提示人工确认。
RAID_BMC_SILENT=1
check "BMC 预留了 RAID 传感器却全无读数 -> WARN" "WARN" "$(raid_absent_status)"
RAID_BMC_SILENT=0
check "BMC 上压根没有 RAID 相关传感器 -> SKIP（就是没装卡）" "SKIP" "$(raid_absent_status)"

RAW_DIR="$TMP"; RUN_DIR="$TMP"

# ================================================================
echo
echo "=== dm 设备枚举（Ventoy 下报告能不能落盘就靠它）==="
# shellcheck source=/dev/null
source "$LIB/storage.sh"
# 现场实证：Ventoy 用 dm-mapper 把 exFAT 分区包了一层，**能挂上的是 dm 映射**
# （历史数据里 data_partition 一直是 /dev/dm-1 / /dev/dm-2），底下的真实分区
# 被 device-mapper 独占持有，挂只会得到 "Can't open blockdev"。
# 而 Ventoy 禁掉了 udev 规则，/dev/dm-N 有时压根不会被创建，
# 于是靠 blkid 枚举的候选列表里，唯一能挂的那个凭空消失 —— 报告落 /tmp，关机就没。
# 这组用假的 sysfs 树锁住"不管 /dev 下有没有节点，都要能枚举出来"。
FAKESYS="$TMP/fakesys"; FAKEDEV="$TMP/fakedev"
mkdir -p "$FAKESYS/block/dm-0" "$FAKESYS/block/dm-3" "$FAKESYS/block/sda" "$FAKEDEV"
echo "252:0" > "$FAKESYS/block/dm-0/dev"
echo "252:3" > "$FAKESYS/block/dm-3/dev"
echo "8:0"   > "$FAKESYS/block/sda/dev"

# 纯枚举那一层不需要 root，也不碰 /dev —— 这是逻辑本身，必须任何环境都能测
got="$(dm_device_list "$FAKESYS" | sort | tr '\n' '|')"
check "/dev 下一个 dm 节点都没有时，仍要从 sysfs 枚举出全部 dm 设备及其设备号" \
      "dm-0 252:0|dm-3 252:3|" "$got"
check "不能把普通块设备（sda）当成 dm 设备" \
      "0" "$(printf '%s' "$got" | grep -c 'sda' || true)"

# 没有任何 dm 设备时必须安静地输出空，不能报错、不能吐垃圾
mkdir -p "$TMP/nodm/block"
check "机器上没有 dm 设备时输出为空（Rufus 场景）" \
      "" "$(dm_device_list "$TMP/nodm")"

# 残缺条目要跳过，不能吐半截垃圾出去。两种残缺法都要挡住，
# 而且要分别用样本盖到——只造其中一种的话，另一道守卫删掉了也没人发现
# （变异测试就是这么逼出这条的）。
mkdir -p "$FAKESYS/block/dm-9"        # 情况一：只有目录，没有 dev 文件
mkdir -p "$FAKESYS/block/dm-8"
printf 'garbage\n' > "$FAKESYS/block/dm-8/dev"   # 情况二：有 dev 文件但内容不是设备号
check "sysfs 条目残缺（没有 dev 文件）时跳过它，不影响其余设备" \
      "dm-0 252:0|dm-3 252:3|" "$(dm_device_list "$FAKESYS" | sort | tr '\n' '|')"
check "dev 文件内容不是合法设备号时也要跳过（不能把 garbage 当设备号用）" \
      "0" "$(dm_device_list "$FAKESYS" | grep -c 'garbage' || true)"

# 补建节点那一层要 root（mknod），没 root 就跳过——环境问题，不是逻辑问题
if [[ "$(id -u)" == "0" ]]; then
  nodes="$(dm_device_nodes "$FAKESYS" "$FAKEDEV" | sort | tr '\n' ' ')"
  check "缺失的设备节点要被自动补建并列出来" \
        "$FAKEDEV/dm-0 $FAKEDEV/dm-3 " "$nodes"
  check "补建出来的确实是块设备节点" "b" \
        "$(if [[ -b "$FAKEDEV/dm-0" ]]; then echo b; else echo no; fi)"
else
  echo "  (非 root，mknod 那一层跳过——环境问题，不是用例问题)"
fi

# 候选顺序：dm 必须排在 blkid 那几路前面，否则先去试那个永远挂不上的真实分区
chain="$(declare -f mount_data_partition)"
check "dm 候选必须排在 blkid 枚举之前（先试挂不上的真实分区纯属白等）" \
      "yes" \
      "$(if [[ "$(grep -n 'dm_device_nodes' <<<"$chain" | head -1 | cut -d: -f1)" \
               -lt "$(grep -n 'blkid -t' <<<"$chain" | head -1 | cut -d: -f1)" ]]; \
         then echo yes; else echo no; fi)"
check "dm 候选必须用 blkid -p 低层探测（刚 mknod 的设备不在 blkid 缓存里）" \
      "yes" "$(grep -q 'blkid -p' <<<"$chain" && echo yes || echo no)"

# ================================================================
echo
echo "=== 阵列卡文案：报告是给客户看的，不能出现开发者指令 ==="
RAW_DIR="$TMP/raidtxt"; RUN_DIR="$TMP/raidtxt"
rm -rf "$RAW_DIR"; mkdir -p "$RAW_DIR"
cat > "$RAW_DIR/lspci.txt" <<'EOF'
01:00.0 Ethernet controller [0200]: Broadcom Inc. and subsidiaries BCM57416 NetXtreme-E Dual-Media 10G RDMA Ethernet Controller [14e4:16d8] (rev 01)
a1:00.0 RAID bus controller [0104]: Broadcom / LSI MegaRAID SAS-3 3108 [Invader] [1000:005d] (rev 02)
EOF
KLB_TOOLS="$TMP/no-such-tools"      # 盘内没有 storcli64
IPMI_OK=0
LAST_STATUS=""; LAST_DETAIL=""
collect_raid
check "有卡但盘内没有管理工具 -> SKIP（只采集不压测，不该算告警）" "SKIP" "$LAST_STATUS"
check "文案里要报出卡的型号" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c 'MegaRAID SAS-3 3108')"
for forbidden in "storcli" "vendor/" "重新出盘" "构建目录" "README"; do
  check "客户可见文案里不许出现「${forbidden}」" "0" \
        "$(printf '%s' "$LAST_DETAIL" | grep -c "$forbidden" || true)"
done

RAW_DIR="$TMP"; RUN_DIR="$TMP"

# ================================================================
echo
echo "=== 客户可见文案里不许出现内部/开发用语（全局扫描）==="
# report.html 是**交付给客户**的东西，ISO 和工程目录只留在我们内部。
# 所以凡是会进报告的中文文本 —— result_add 的 detail、报告生成器里的
# 界面字符串 —— 一律不许提测试盘怎么做的、缺哪个工具、去哪儿补、源码在哪。
# 客户看到"本测试盘为精简版""把 storcli64 放进 vendor/"只会觉得机器有毛病。
#
# 这条守卫是全局正则扫描，不针对具体某一句 —— 以后新写的文案自动受它约束。
# 屏幕输出（英文）和代码注释不在此列，所以要排掉注释行和纯 ASCII 的行。
#
# ⚠️ 必须先把反斜杠续行拼成一整行再扫。
# 第一版写的是 `grep -oE 'result_add [^\n]*'` —— grep 本来就是逐行工作的，
# 那个 [^\n]* 只能吃到**调用的第一行**，而所有长文案都是写在续行里的：
#     result_add "collect_raid" "阵列卡" "$ST_SKIP" \
#       "...（需要厂商专用管理工具，本测试盘未包含）" \      <- 违规就藏在这里
# 于是这条守卫从上线起就是个摆设，collect.sh 里那句「本测试盘未包含」
# 一直大摇大摆地进客户报告。
#
# ⚠️ 拼行**不能用正则**匹配行尾的反斜杠。实测（GNU sed 4.9 / gawk，WSL 和
# Git Bash 上都能复现）：一行以中文标点收尾、后面紧跟反斜杠时，`/\\$/` 匹配不上——
#     printf '\xe3\x80\x82\\\nX\n' | sed -n '/\\$/p'     # 什么也没有
# 而我们的文案恰恰全是"……。\"这种收尾。所以改成按**字符**取最后一位来判断，
# 完全绕开正则引擎。
#
# 内部工程报告（generate_internal.py）**不在此列** —— 那份不交付，
# 里面本来就该直说盘里少带了哪个工具。
RT="$(cd "$LIB/.." && pwd)"
FORBIDDEN='测试盘|盘内|精简版|构建目录|重新出盘|vendor/|storcli|README|源码|commit|ISO 里|打包进|未正确安装'

join_continuations() {
  awk '{
    cur = $0; n = length(cur)
    if (n > 0 && substr(cur, n, 1) == "\\") { buf = buf substr(cur, 1, n - 1); next }
    print buf cur; buf = ""
  } END { if (buf != "") print buf }' "$@"
}

JOINED="$(join_continuations "$RT"/lib/*.sh "$RT"/factory-test.sh 2>/dev/null)"

# 先自检：拼行到底有没有生效。"此项不影响整机结论"这句只写在续行里，
# 扫不到它就说明拼行白做了，这条守卫又变回摆设。
#
# ⚠️ 这里不能用 `... | grep -q 关键字 && echo yes || echo no`：
# grep -q 匹配到第一条就退出，上游的 grep 随即吃到 SIGPIPE 退出码 141，
# 而本脚本是 `set -o pipefail` —— 整条管道的退出码就成了 141，
# 于是"匹配成功"反而走到 || 分支，永远是 no。改成先数数再比。
joined_hits="$(printf '%s\n' "$JOINED" | grep -E '^[[:space:]]*result_add ' \
               | grep -c '此项不影响整机结论' || true)"
[[ "$joined_hits" =~ ^[0-9]+$ ]] || joined_hits=0
check "续行拼接必须生效（否则整条守卫是摆设）" "yes" \
      "$( (( joined_hits > 0 )) && echo yes || echo no )"

# 只看**带中文的字符串字面量**：
#   - result_add 的显示名和 detail 都是中文串，跑不掉
#   - ref 参数是 "raw/storcli-show.txt" 这类纯 ASCII 路径，它不进 HTML，
#     一起扫会被 storcli 这个词误伤（报告生成器根本不渲染 ref）
#
# ⚠️ 别用 [一-龥] 这种字符区间挑中文：现场跑测试的 locale 是 C，grep 会直接
# 报 "Invalid collation character" 然后**什么都不输出** —— 于是 offenders 恒为空，
# 这条守卫看着全绿、实际上永远不会红。改成"先取所有引号串，再留下含非 ASCII 的"，
# 只用 ASCII 端点的区间，任何 locale 下都成立。
customer_text_offenders() {
  grep -oE '"[^"]*"' | grep -E '[^ -~]' | grep -vE '^\s*#' | grep -E "$FORBIDDEN" || true
}

offenders="$(
  {
    printf '%s\n' "$JOINED" | grep -E '^[[:space:]]*result_add '
    cat "$RT"/report/generate_report.py 2>/dev/null
  } | customer_text_offenders
)"
check "会进报告的中文文案里不许出现内部/开发用语" "0" \
      "$(printf '%s' "$offenders" | grep -c . || true)"
if [[ -n "$offenders" ]]; then
  printf '     命中的行：\n'
  printf '%s\n' "$offenders" | head -6 | cut -c1-160 | sed 's/^/       /'
fi

# 上面那条断言必须**有能力变红**。这个项目栽过一次"从没红过的测试等于没写"，
# 所以这里拿一句故意写坏的文案喂给同一条管道，它必须被抓出来。
check "守卫本身必须抓得住违规文案（否则上一条是摆设）" "1" \
      "$(printf '%s\n' \
           '  result_add "collect_raid" "阵列卡" "$ST_SKIP" "把 storcli64 放进 vendor/ 后重新出盘" ""' \
         | customer_text_offenders | grep -c . || true)"

# 注：「报告里不许出现 git hash」那条放在 tests/test-report-render.sh 里 ——
# 那边会真的生成一份 HTML 再去查，比在源码里 grep 靠谱得多
# （在源码里 grep 会被注释里提到的变量名绊倒，第一版就是这么红的）。

# ================================================================
echo
echo "=== 阵列卡后端物理盘：SMART 透传 ==="
# 阵列卡跑 RAID 模式时 /dev/sdX 是逻辑盘，物理盘不在 /dev 下 ——
# 直接 smartctl 读到的是逻辑盘，没有 SMART 属性，于是"测前测后对比"整项空跑。
# 这组用假的 sysfs 树验证：认不认得出 megaraid_sas、候选设备号取得对不对、
# **没有阵列卡的机器一分钱开销都不花**（这条最重要，别为了这个功能拖慢所有机器）。

SYSFAKE="$TMP/sysfake"
# 照着真 sysfs 的形状搭：
#   /sys/class/scsi_device/<H:C:T:L>  ->  .../<H:C:T:L>/scsi_device/<H:C:T:L>
#   那个目录里有个 device 链接指回上层的 SCSI 设备目录，块设备挂在 device/block/ 下
# 形状搭错的话测出来的是假绿 —— 所以这里不图省事，按真的来。
mk_scsi_dev() {   # mk_scsi_dev <H:C:T:L> [块设备名]
  # 分成两条 local：同一条 local 里后一个变量看不到前一个刚赋的值
  # （bash 在调用 local 之前就把参数全展开完了），写成一行的话 $hctl 是空的。
  local hctl="$1" blk="${2:-}"
  local h="${hctl%%:*}" devdir="$SYSFAKE/devices/pci0/host${hctl%%:*}/$hctl"
  mkdir -p "$devdir/scsi_device/$hctl" "$SYSFAKE/class/scsi_device"
  ln -sfn "$devdir" "$devdir/scsi_device/$hctl/device"
  ln -sfn "$devdir/scsi_device/$hctl" "$SYSFAKE/class/scsi_device/$hctl"
  if [[ -n "$blk" ]]; then
    mkdir -p "$devdir/block/$blk" "$SYSFAKE/block/$blk"
    ln -sfn "$devdir" "$SYSFAKE/block/$blk/device"
  fi
}
mk_host() {       # mk_host <host号> <驱动名>
  mkdir -p "$SYSFAKE/class/scsi_host/host$1"
  printf '%s\n' "$2" > "$SYSFAKE/class/scsi_host/host$1/proc_name"
}

# 一台典型的 MegaRAID 机器：host0 是阵列卡，
# 0:2:0:0 是逻辑盘（有块设备 sda），0:0:8:0 / 0:0:9:0 是卡后面的物理盘（没有块设备）
mk_host 0 megaraid_sas
mk_scsi_dev "0:2:0:0" sda
mk_scsi_dev "0:0:8:0"
mk_scsi_dev "0:0:9:0"
# host1 是普通 SATA 控制器，1:0:0:0 -> sdb
mk_host 1 ahci
mk_scsi_dev "1:0:0:0" sdb

check "从块设备反查 SCSI host 号" "0" "$(disk_scsi_host sda "$SYSFAKE")"
check "普通 SATA 盘的 host 号"     "1" "$(disk_scsi_host sdb "$SYSFAKE")"
check "不存在的块设备返回空"       ""  "$(disk_scsi_host nosuchdev "$SYSFAKE")"
check "认得出阵列卡驱动" "megaraid_sas" "$(scsi_host_driver 0 "$SYSFAKE")"
check "认得出普通控制器" "ahci"         "$(scsi_host_driver 1 "$SYSFAKE")"

check "候选设备号 = 没有块设备的那几个 target id" "8 9" \
      "$(megaraid_pd_candidates 0 "$SYSFAKE" | tr '\n' ' ' | sed 's/ $//')"
check "逻辑盘自己（有块设备）不能被当成物理盘" "0" \
      "$(megaraid_pd_candidates 0 "$SYSFAKE" | grep -c '^0$' || true)"
check "普通控制器下没有候选" "0" \
      "$(megaraid_pd_candidates 1 "$SYSFAKE" | grep -c . || true)"

# 下面几组要走 megaraid_pd_ids 的完整分支。它开头有一句 `have smartctl || return 0`，
# 而跑测试的 WSL 上通常没装 smartctl —— 不把 have 顶掉的话，
# 后面每一条都会因为提前返回而"通过"，又是一组永远不会红的测试。
have() { return 0; }

# 没有阵列卡的机器：megaraid_pd_ids 必须直接返回，一次 smartctl 都不许跑。
# 拿一个会计数的替身 probe 来证明这一点。
PROBE_COUNT="$TMP/probe.count"; : > "$PROBE_COUNT"
megaraid_pd_probe() { echo x >> "$PROBE_COUNT"; return 1; }
disk_scsi_host() { printf '1'; }              # 假装这块盘挂在 host1
scsi_host_driver() { printf 'ahci'; }         # 普通控制器
check "普通控制器上不做任何试探（不能拖慢没有阵列卡的机器）" "0" \
      "$(megaraid_pd_ids /dev/sdb >/dev/null 2>&1; grep -c . "$PROBE_COUNT" || true)"

# 阵列卡 + sysfs 给出候选：只试候选那几个，不做全范围扫描
: > "$PROBE_COUNT"
disk_scsi_host() { printf '0'; }
scsi_host_driver() { printf 'megaraid_sas'; }
megaraid_pd_candidates() { printf '8\n9\n'; }
megaraid_pd_probe() { echo x >> "$PROBE_COUNT"; [[ "$2" == "8" ]]; }
check "sysfs 给了候选就只试候选" "8" "$(megaraid_pd_ids /dev/sda)"
check "试探次数 = 候选个数（没有退回全范围扫描）" "2" "$(grep -c . "$PROBE_COUNT" || true)"

# sysfs 没给候选 -> 有界试探，且连续失败到上限就收工
: > "$PROBE_COUNT"
megaraid_pd_candidates() { :; }
megaraid_pd_probe() { echo x >> "$PROBE_COUNT"; return 1; }
MEGARAID_SCAN_MAX=32 MEGARAID_SCAN_MISS=12
megaraid_pd_ids /dev/sda >/dev/null
check "一个都读不到时最多试 MEGARAID_SCAN_MISS 次就停" "12" \
      "$(grep -c . "$PROBE_COUNT" || true)"

# 设备号从 8 开始（很常见）也要能扫到 —— 这就是 MISS 不能定太小的原因
: > "$PROBE_COUNT"
megaraid_pd_probe() { echo x >> "$PROBE_COUNT"; [[ "$2" == "8" || "$2" == "9" ]]; }
check "设备号从 8 开始也扫得到" "8 9" \
      "$(megaraid_pd_ids /dev/sda | tr '\n' ' ' | sed 's/ $//')"

# smart_targets_build：逻辑盘 + 它后面的物理盘，各一条
megaraid_pd_ids() { printf '8\n9\n'; }
DISK_SMART=(/dev/sda)
smart_targets_build
check "采集目标 = 1 块逻辑盘 + 2 块物理盘" "3" "${#SMART_TARGETS[@]}"
check "逻辑盘那条不带 -d 类型" "sda|/dev/sda|" "${SMART_TARGETS[0]}"
check "物理盘那条要走 megaraid 透传" "sda-pd8|/dev/sda|megaraid,8" "${SMART_TARGETS[1]}"
check "key 列表要把物理盘也带上" "sda sda-pd8 sda-pd9" \
      "$(smart_target_keys | tr '\n' ' ' | sed 's/ $//')"

# 最要紧的一条：物理盘的坏道增长必须能被 verify_smart 抓到。
# 以前按 /dev 路径遍历，这几块盘一块都对比不到 —— 整项空跑还报 PASS。
if command -v jq >/dev/null 2>&1; then
  RAW_DIR="$TMP/pd"; RUN_DIR="$TMP/pd"
  mkdir -p "$RAW_DIR/smart-pre" "$RAW_DIR/smart-post"
  LAST_STATUS=""; LAST_DETAIL=""
  result_add() { LAST_STATUS="$3"; LAST_DETAIL="$4"; }
  metric_add() { :; }

  for k in sda sda-pd8 sda-pd9; do
    printf '{"smart_passed":true,"realloc_sectors":0,"pending_sectors":0}\n' \
      > "$RAW_DIR/smart-pre/$k.norm.json"
    cp "$RAW_DIR/smart-pre/$k.norm.json" "$RAW_DIR/smart-post/$k.norm.json"
  done
  verify_smart
  check "三块盘都干净 -> PASS" "PASS" "$LAST_STATUS"
  check "结论里要数上物理盘（3 块，不是 1 块）" "1" \
        "$(printf '%s' "$LAST_DETAIL" | grep -c '3 块盘' || true)"

  # 只有阵列卡后面那块盘长了坏道
  printf '{"smart_passed":true,"realloc_sectors":0,"pending_sectors":16}\n' \
    > "$RAW_DIR/smart-post/sda-pd9.norm.json"
  verify_smart
  check "物理盘压测后新增坏道 -> FAIL（这正是以前漏掉的）" "FAIL" "$LAST_STATUS"
  check "文案里要点名是哪块物理盘" "1" \
        "$(printf '%s' "$LAST_DETAIL" | grep -c 'sda-pd9' || true)"

  RAW_DIR="$TMP"; RUN_DIR="$TMP"
fi
unset -f megaraid_pd_ids megaraid_pd_probe megaraid_pd_candidates disk_scsi_host scsi_host_driver
SMART_TARGETS=()
DISK_SMART=()
# 把顶掉的 have() 还原成 core.sh 里的定义。
# ⚠️ 不能图省事 `source "$LIB/core.sh"` —— core.sh 里也有个 ok()，
# 一 source 就会把**本测试脚本自己的 ok()** 顶掉，而那个才是给 PASS 计数的。
# 之后所有断言照常打勾、却一条都不再计入总数（实测少了 40 条），
# 屏幕上还是全绿，看不出任何异常。
have() { command -v "$1" >/dev/null 2>&1; }

# ================================================================
echo
echo "=== 时长档位：菜单里有几档，报告就得认得几档 ==="
# 屏幕上是英文 key（meta.json 里存的也是它），报告里显示中文名。
# 加档位时只改了菜单、忘了加中文名的话，客户报告上会直接出现 "ENDURANCE"
# 这种词 —— 这条守卫就是防这个。
UI_SH="$LIB/ui.sh"
GEN_PY="$(cd "$LIB/../report" && pwd)/generate_report.py"

profiles="$(grep -oE 'DURATION_PROFILE="[A-Z]+";[[:space:]]*DURATION_SECONDS=[0-9]+' "$UI_SH" || true)"
check "菜单里应有 6 个时长档位" "6" "$(printf '%s\n' "$profiles" | grep -c . || true)"

while read -r name secs; do
  [[ -n "$name" ]] || continue
  check "$name 的秒数应为 $secs" "1" \
        "$(printf '%s\n' "$profiles" \
           | grep -c "DURATION_PROFILE=\"$name\";[[:space:]]*DURATION_SECONDS=$secs" || true)"
  check "报告里必须有 $name 对应的中文名" "1" \
        "$(grep -c "\"$name\":" "$GEN_PY" || true)"
done <<'EOF'
QUICK 600
STANDARD 1800
EXTENDED 3600
LONG 7200
SOAK 14400
ENDURANCE 28800
EOF

# 默认档位不能变：现场 30 秒不按键就按它跑，改错了没人会立刻发现
check "倒计时结束的默认档位必须是 STANDARD（30 分钟）" "yes" \
      "$(if grep -q 'default_key="2"' "$UI_SH" \
            && printf '%s\n' "$profiles" | grep -q 'STANDARD";[[:space:]]*DURATION_SECONDS=1800'; \
         then echo yes; else echo no; fi)"

# ================================================================
echo
echo "=== 汇总入口的调用链不能少人（少一个 = 那项结论从报告里消失）==="
# 这组是变异测试逼出来的：把 verify_disk_temp 从 verify_all 里删掉，
# 上面所有用例照样全绿 —— 因为它们都是直接调函数，没人管它到底有没有被跑。
# 这正是 GPU 那条 bug 的同款病：判定函数还在，只是再也没被调用过，
# 报告里那一项就凭空消失，既不是 PASS 也不是 SKIP，谁也不会注意到。
# declare -f 打出来的函数体不含注释，所以数的是真调用。

for fn in collect_smart verify_smart verify_disk_temp verify_dmesg verify_sel; do
  check "verify_all 必须调用 $fn" \
        "yes" "$(declare -f verify_all | grep -q "\b${fn}\b" && echo yes || echo no)"
done

for fn in collect_system check_memory_capacity check_pcie_link collect_sensors collect_smart \
          net_link_up_all collect_nic check_nic_speed net_test collect_ipmi collect_raid \
          check_psu gpu_detect collect_deep verify_dmesg_boot; do
  check "collect_all 必须调用 $fn" \
        "yes" "$(declare -f collect_all | grep -q "\b${fn}\b" && echo yes || echo no)"
done

# 顺序也有讲究，写死几条最容易被改坏的：
chain="$(declare -f collect_all)"
check "net_link_up_all 必须排在 collect_nic 之前（口是 down 的时候 ethtool 报的链路状态是假的）" \
      "yes" \
      "$(if [[ "$(grep -n 'net_link_up_all' <<<"$chain" | head -1 | cut -d: -f1)" \
               -lt "$(grep -n 'collect_nic' <<<"$chain" | head -1 | cut -d: -f1)" ]]; \
         then echo yes; else echo no; fi)"
check "collect_ipmi 必须排在 check_psu 之前（电源判定要用 BMC 的 Vin 读数）" \
      "yes" \
      "$(if [[ "$(grep -n 'collect_ipmi' <<<"$chain" | head -1 | cut -d: -f1)" \
               -lt "$(grep -n 'check_psu' <<<"$chain" | head -1 | cut -d: -f1)" ]]; \
         then echo yes; else echo no; fi)"
check "collect_ipmi 必须排在 collect_raid 之前（阵列卡要和 BMC 传感器交叉核对）" \
      "yes" \
      "$(if [[ "$(grep -n 'collect_ipmi' <<<"$chain" | head -1 | cut -d: -f1)" \
               -lt "$(grep -n 'collect_raid' <<<"$chain" | head -1 | cut -d: -f1)" ]]; \
         then echo yes; else echo no; fi)"
check "collect_system 必须排在 check_pcie_link 之前（PCIe 判定读的是它落下的 lspci-vv.txt）" \
      "yes" \
      "$(if [[ "$(grep -n 'collect_system' <<<"$chain" | head -1 | cut -d: -f1)" \
               -lt "$(grep -n 'check_pcie_link' <<<"$chain" | head -1 | cut -d: -f1)" ]]; \
         then echo yes; else echo no; fi)"
check "collect_nic 必须排在 check_nic_speed 之前（速率判定读的是它落下的 ethtool 输出）" \
      "yes" \
      "$(if [[ "$(grep -n 'collect_nic' <<<"$chain" | head -1 | cut -d: -f1)" \
               -lt "$(grep -n 'check_nic_speed' <<<"$chain" | head -1 | cut -d: -f1)" ]]; \
         then echo yes; else echo no; fi)"
# verify_dmesg_boot 扫的就是 dmesg-pre.txt，排在它前面等于扫了个空文件 -> 每台机器都 SKIP
check "dmesg-pre.txt 的采集必须排在 verify_dmesg_boot 之前" \
      "yes" \
      "$(if [[ "$(grep -n 'dmesg-pre.txt' <<<"$chain" | head -1 | cut -d: -f1)" \
               -lt "$(grep -n 'verify_dmesg_boot' <<<"$chain" | head -1 | cut -d: -f1)" ]]; \
         then echo yes; else echo no; fi)"

# ================================================================
# 收尾自检：这个脚本会 source 被测的 lib，而 lib 里也有 ok()。
# 万一哪次改动把本脚本的 ok() 顶掉了，后面的断言会照常打勾却不再计数 ——
# 屏幕全绿、总数悄悄少一截，比直接报错难发现得多（已经发生过一次）。
check "ok() 必须还是本脚本自己的那个（否则断言会停止计数）" "yes" \
      "$(declare -f ok | grep -q 'PASS=' && echo yes || echo no)"

echo
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
