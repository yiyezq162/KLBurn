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
# shellcheck source=/dev/null
source "$LIB/conformance.sh"
# gpu.sh 只为了 gpu_temp_limits（显卡自报的温度限值）。它顶上是几个变量赋值，
# source 进来没有副作用。
# shellcheck source=/dev/null
source "$LIB/gpu.sh"

PASS=0; FAIL=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n     期望 [%s] 实际 [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }
check(){ [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$2" "$3"; }

# 断言函数名打错不能静悄悄地过去（§11-13"断言悄悄停止计数"的同款病）：
# 本脚本不开 set -e，`xxx: command not found` 只往 stderr 打一行就没了，
# PASS/FAIL 都不动 —— 屏幕照样"全部通过"，只是少跑了几条。实测踩到过一次。
command_not_found_handle() {
  # ⚠️ 这里**不能**写 FAIL=$((FAIL+1))。bash 是在 fork 出来的子进程里执行这个
  #    handler 的，加了也加不到父进程头上 —— 屏幕上红一条，最后那行汇总却还是
  #    "失败 0 项"，正好是本项目最恨的那种"屏幕全绿"。（实测踩过。）
  #    所以直接把整个套件干掉，让退出码非零、run-all 能看见。
  printf "  \033[31mFAIL\033[0m 调用了不存在的命令 %s —— 多半是断言函数名打错了，\n" "$1"
  printf "       这条断言根本没跑。中止本套件。\n"
  kill -TERM $$
  return 127
}

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

Handle 0x0060, DMI type 39, 22 bytes
System Power Supply
	Power Unit Group: 4
	Location: PSU4
	Name: To Be Filled By O.E.M.
	Manufacturer: To Be Filled By O.E.M.
	Serial Number: To Be Filled By O.E.M.
	Max Power Capacity: 0 W
	Status: Present, OK
	Plugged: Yes
EOF
# 第三个字段：这一位到底有没有真的插着电源。
# PSU4 取自 6530 那台的真实 DMI —— **空的电源位，BIOS 照样报 Present, OK**。
# 照单全收的话报告写「共 4 个电源模块在位」，客户一数电源就发现对不上。
check "四条 type 39 解析出四行「位置|状态|真伪」" \
      "PSU1|Present, OK|1
PSU2|Present, Critical|1
PSU3|Present, OK|1
PSU4|Present, OK|0" "$(dmi_psu_list "$TMP/dmidecode-psu.txt")"

# 成对钉死：判据必须两个条件同时成立，少一个都不许判成幽灵。
# PSU3 就是反例 —— 厂商/型号是占位符，但额定 2700W 是真的，它是真电源。
check "PSU3：身份是占位符但额定功率真实 -> 仍算真电源" "1" \
      "$(dmi_psu_list "$TMP/dmidecode-psu.txt" | awk -F'|' '$1=="PSU3"{print $3}')"
check "PSU4：0W + 身份全占位符 -> 判为空槽位" "0" \
      "$(dmi_psu_list "$TMP/dmidecode-psu.txt" | awk -F'|' '$1=="PSU4"{print $3}')"

# 只有 0W、身份是真的（有些 BIOS 对真电源不填额定功率）-> 不许当幽灵
cat > "$TMP/dmidecode-psu-0w.txt" <<'EOF'
Handle 0x0061, DMI type 39, 22 bytes
System Power Supply
	Location: PSU1
	Name: CRPS2700D2
	Manufacturer: Great Wall
	Serial Number: 33000285DHB06810
	Max Power Capacity: 0 W
	Status: Present, OK
EOF
check "额定 0W 但身份真实（BIOS 没填功率）-> 仍算真电源，不许漏掉" "1" \
      "$(dmi_psu_list "$TMP/dmidecode-psu-0w.txt" | awk -F'|' '{print $3}')"

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

# ---- 第二个来源：BMC 的离散量电源状态（ipmi-sdr.txt）----
# 不是所有 BMC 都有 PSU1_Vin 这种数值传感器。Supermicro X11DPG-QT 只有离散量，
# 1.8.2 的报告里「交流输入」那一列因此整列是破折号 —— 而 sdr 里一直写着答案。
# 样本全部取自现场：6530 那台（PSU1 掉了交流）、Supermicro（PS1 Status 这种命名）。
cat > "$TMP/ipmi-sdr.txt" <<'EOF'
CPU1 Temp        | 3Ah | ok  |  3.1 | 45 degrees C
PSU1_Status      | BFh | ok  | 10.8 | Presence detected, Failure detected, Power Supply AC lost
PSU2_Status      | C7h | ok  | 10.16 | Presence detected
PSU3_Status      | 57h | ns  | 10.24 | No Reading
PSU5_Status      | 58h | ok  | 10.40 | Presence detected, Power Supply input out-of-range, but present
PSU6_Status      | 59h | ok  | 10.48 | Presence detected, Power Supply input lost or out-of-range
PS7 Status       | C4h | ok  | 10.92 | Presence detected
EOF
check "明写 AC lost -> 没有交流输入" \
      "absent"  "$(psu_ac_state_sdr 1 "$TMP/ipmi-sdr.txt")"
check "只置了 Presence detected -> 有交流输入" \
      "present" "$(psu_ac_state_sdr 2 "$TMP/ipmi-sdr.txt")"
check "No Reading -> unknown（读不到 ≠ 没电）" \
      "unknown" "$(psu_ac_state_sdr 3 "$TMP/ipmi-sdr.txt")"
# ⚠️ offset 5 明写着 "but present"：电进来了，只是不在标称范围内。
#    拿 out-of-range 当"没进电"的判据就读反了。
check "input out-of-range **but present** -> 仍算有电（别拿 out-of-range 当判据）" \
      "present" "$(psu_ac_state_sdr 5 "$TMP/ipmi-sdr.txt")"
check "input lost or out-of-range -> 没有交流输入（带 lost 的才是）" \
      "absent"  "$(psu_ac_state_sdr 6 "$TMP/ipmi-sdr.txt")"
check "「PS7 Status」这种命名也要认得出" \
      "present" "$(psu_ac_state_sdr 7 "$TMP/ipmi-sdr.txt")"
check "没有对应编号 -> unknown" \
      "unknown" "$(psu_ac_state_sdr 9 "$TMP/ipmi-sdr.txt")"
check "整个 sdr 文件都没有 -> unknown" \
      "unknown" "$(psu_ac_state_sdr 1 "$TMP/does-not-exist.txt")"
# 编号必须整词匹配：idx=1 不许命中 PSU11_Status
cat > "$TMP/ipmi-sdr-11.txt" <<'EOF'
PSU11_Status     | C7h | ok  | 10.16 | Presence detected, Power Supply AC lost
EOF
check "idx=1 不许命中 PSU11_Status" \
      "unknown" "$(psu_ac_state_sdr 1 "$TMP/ipmi-sdr-11.txt")"

# 合并：数值传感器优先，读不到才退到离散量
check "有 Vin 时以 Vin 为准（哪怕离散量说得更乐观）" \
      "absent" "$(psu_ac_state_any 2 "$TMP/ipmi-sensors.txt" "$TMP/ipmi-sdr.txt")"
check "没有 Vin 的编号退到离散量" \
      "present" "$(psu_ac_state_any 7 "$TMP/ipmi-sensors.txt" "$TMP/ipmi-sdr.txt")"
check "两个来源都没有 -> unknown" \
      "unknown" "$(psu_ac_state_any 9 "$TMP/ipmi-sensors.txt" "$TMP/ipmi-sdr.txt")"

# ================================================================
echo
echo "=== 电源整体判定（check_psu）==="
# 判 FAIL 的门槛必须卡死："BMC 确认这一路有电、模块却还报异常"才是模块坏了。
# 读不到交流输入传感器（没 BMC / BMC 没这个编号）时判 FAIL 就是误杀 ——
# 测试台上只接一半电源线是常态，而没有 BMC 的机器上 DMI 对"没插线"和
# "模块坏了"报的都是 Present, Critical。

psu_case() {
  # psu_case <dmi内容> <数值传感器内容> [离散量sdr内容] -> 把结论放进 LAST_STATUS
  RAW_DIR="$TMP/psu-case"; RUN_DIR="$TMP/psu-case"
  rm -rf "$RAW_DIR"; mkdir -p "$RAW_DIR"
  printf '%s\n' "$1" > "$RAW_DIR/dmidecode-psu.txt"
  [[ -n "$2" ]] && printf '%s\n' "$2" > "$RAW_DIR/ipmi-sensors.txt"
  [[ -n "${3:-}" ]] && printf '%s\n' "$3" > "$RAW_DIR/ipmi-sdr.txt"
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

# ⚠️ `Not Present` 里含有 `Present` 子串。原来判在位写的是 *"Present"*，
# 于是槽位明写 "Not Present" 也被算成在位 —— 海光那台两个槽位 DMI 全是
# `Status: Not Present` / `Plugged: No`，报告却打出「共 2 个电源模块在位，
# 交流输入与模块状态均正常」PASS。判错方向是最糟的那个：真缺一路电源
# 会被说成正常。（一号红线在电源这条路上的同款。）
DMI_NOT_PRESENT='Handle 0x1, DMI type 39, 22 bytes
System Power Supply
	Location: PSU1
	Name: CRPS2700D2
	Serial Number: SN0001
	Max Power Capacity: 2700 W
	Status: Present, OK

Handle 0x2, DMI type 39, 22 bytes
System Power Supply
	Location: PSU2
	Name: CRPS2700D2
	Serial Number: SN0002
	Max Power Capacity: 2700 W
	Status: Not Present'
psu_case "$DMI_NOT_PRESENT" "$SENS_BOTH_HOT"
check "标记 Not Present 的槽位不许算进「在位」数" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '共 1 个电源模块在位')"
check "而且不许因此判故障（少插一路不是模块坏了）" "PASS" "$LAST_STATUS"

# 海光那台的真实形状：两个槽位全是占位符 + Not Present。
# 「上报了但全是空槽位」和「压根没上报」都判 SKIP，但要分开说。
DMI_ALL_GHOST='Handle 0x1, DMI type 39, 22 bytes
System Power Supply
	Location: To Be Filled By O.E.M.
	Name: To Be Filled By O.E.M.
	Manufacturer: To Be Filled By O.E.M.
	Serial Number: To Be Filled By O.E.M.
	Max Power Capacity: Unknown
	Status: Not Present

Handle 0x2, DMI type 39, 22 bytes
System Power Supply
	Location: To Be Filled By O.E.M.
	Name: To Be Filled By O.E.M.
	Manufacturer: To Be Filled By O.E.M.
	Serial Number: To Be Filled By O.E.M.
	Max Power Capacity: Unknown
	Status: Not Present'
psu_case "$DMI_ALL_GHOST" "$SENS_BOTH_HOT"
check "槽位全是占位符 + 未在位 -> SKIP，绝不许说成「N 个在位、一切正常」" \
      "SKIP" "$LAST_STATUS"
check "SKIP 文案要说明不影响整机结论" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '不影响整机结论')"
check "更不许出现「交流输入与模块状态均正常」这种凭空的结论" "0" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '均正常')"

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

# ---- 两个来源都读不到时，PASS 文案不许声称"交流输入正常" ----
# 1.8.2 的报告自相矛盾：判定文案写「交流输入与模块状态均正常」，
# 而同一份报告电源表的「交流输入」那一列整列是破折号。
# 判定照旧 PASS（读不到传感器是我们的能力缺失，不是这台机器的故障），
# 但话只能说到"BIOS 报告状态正常"为止。
psu_case "$DMI_OK_OK" "$SENS_UNRELATED"
check "两路都 Present, OK 但两个来源都读不到 -> 仍判 PASS" "PASS" "$LAST_STATUS"
check "读不到交流输入时，不许写「交流输入…正常」" "0" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '交流输入与模块状态均正常')"
check "而要明说没能逐路核对进电" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '未能逐路核对')"
check "在位数照常要给出来" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '共 2 个电源模块在位')"

# ---- 没有 Vin、但 BMC 有离散量时，要能用上（Supermicro X11DPG-QT）----
SDR_BOTH_OK='PS1 Status | C4h | ok | 10.92 | Presence detected
PS2 Status | C5h | ok | 10.91 | Presence detected'
SDR_PS2_ACLOST='PS1 Status | C4h | ok | 10.92 | Presence detected
PS2 Status | C5h | ok | 10.91 | Presence detected, Power Supply AC lost'

psu_case "$DMI_OK_OK" "$SENS_UNRELATED" "$SDR_BOTH_OK"
check "没有 Vin 但离散量说两路都在位无告警 -> PASS" "PASS" "$LAST_STATUS"
check "这时候可以（也应该）说交流输入正常" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '交流输入与模块状态均正常')"

# ★ 这条是这次新增的**检出能力**：1.8.2 在这台机器上什么都看不出来
psu_case "$DMI_OK_OK" "$SENS_UNRELATED" "$SDR_PS2_ACLOST"
check "离散量明写 PSU2 掉了交流 -> WARN（无冗余）" "WARN" "$LAST_STATUS"
check "要点出是哪一路" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c 'PSU2')"

# ⚠️ 判 FAIL 的门槛不许因为多了个来源就降下来。
#    离散量只是 BMC 的一句陈述，不是量出来的电压；拿它当 FAIL 的证据
#    等于把标准放低一档，而这条判定的方向是"宁可漏，不可误杀"（§2-2）。
psu_case "$DMI_OK_CRIT" "$SENS_UNRELATED" "$SDR_BOTH_OK"
check "DMI 报 Critical + 只有离散量说有电 -> 仍是 WARN，不许升成 FAIL" \
      "WARN" "$LAST_STATUS"
psu_case "$DMI_OK_CRIT" "$SENS_BOTH_HOT" "$SDR_BOTH_OK"
check "数值传感器确认有电 + DMI 报 Critical -> 这才判 FAIL" \
      "FAIL" "$LAST_STATUS"

# ================================================================
# ★ 1.9.4：BMC 读到这一路进了电，就一定是真电源，DMI 怎么写都不算数
# ================================================================
# 1.9.3 那台 6530 的真实形状：PSU4 额定 0 W、四个身份字段全是占位符
# （"幽灵槽位"三个条件全中），可 BMC 上白纸黑字写着
#     PSU4_Vin 220 Volts   PSU4_Pout 130 Watts
# 那是一路**正在给整机供电的真电源**，只是这块主板的 BIOS 没填它那一格。
# 误杀的后果：报告写「共 3 个电源模块在位」，而同一轮的现场配置核对屏
# 打的是「PSU 4/4 present」—— 同一轮测试的两处对不上。
DMI_3REAL_1GHOST='Handle 0x1, DMI type 39, 22 bytes
System Power Supply
	Location: PSU1
	Name: CRPS2700D2
	Serial Number: SN0001
	Max Power Capacity: 2700 W
	Status: Present, OK

Handle 0x2, DMI type 39, 22 bytes
System Power Supply
	Location: PSU2
	Name: CRPS2700D2
	Serial Number: SN0002
	Max Power Capacity: 2700 W
	Status: Present, OK

Handle 0x3, DMI type 39, 22 bytes
System Power Supply
	Location: PSU3
	Name: To Be Filled By O.E.M.
	Serial Number: 2P070175056
	Max Power Capacity: 2700 W
	Status: Present, OK

Handle 0x4, DMI type 39, 22 bytes
System Power Supply
	Location: PSU4
	Name: To Be Filled By O.E.M.
	Manufacturer: To Be Filled By O.E.M.
	Serial Number: To Be Filled By O.E.M.
	Max Power Capacity: 0 W
	Status: Present, OK'
# 三路带电（含那路 DMI 里像空槽位的 PSU4），PSU2 没接线 —— 就是 6530 那台的样子
SENS_4PSU_P2DEAD='PSU1_Vin | 220.000 | Volts | ok | 10.1
PSU2_Vin | na      | Volts | na | 10.9
PSU3_Vin | 220.000 | Volts | ok | 10.17
PSU4_Vin | 220.000 | Volts | ok | 10.25'

psu_case "$DMI_3REAL_1GHOST" "$SENS_4PSU_P2DEAD"
check "BMC 读到 PSU4 有 220V -> 它是真电源，四路都要算进在位数" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '共 4 个电源模块在位')"
# ⚠️⚠️ 1.9.9 把这一支从 WARN 改成了 PASS。
#
# 翻了仓库里全部七个版本的现场数据：这条 WARN 出现了 **11 次，一次都不是
# 机器的毛病** —— 全是"四路电源的机器，测试台上只插了两三根电源线"。
# 而它每次都会在报告抬头单列一块「以下 N 项为告警，建议出货前确认」，
# 把一台好机器的报告刷成黄的。**一条从来没有一次是真问题的告警，
# 唯一的作用是训练看报告的人忽略告警。**
check "四路里少一路、还剩 3 路带电 -> PASS（现场接线条件，不是故障）" "PASS" "$LAST_STATUS"
check "还剩 3 路带电时要说「仍具备电源冗余」" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '仍具备电源冗余')"
check "而且绝不许出现「不具备电源冗余」" "0" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '不具备电源冗余')"
check "但没进电的那一路必须点名（不是把这件事抹掉）" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c 'PSU2')"
check "文案要说明这是现场接线条件，不是模块有毛病" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '现场接线条件')"

# ⚠️ **成对断言：豁免不许扩大化。** 只剩一路的时候掉了就整机断电，
#    那才是真的没有冗余，必须照旧 WARN。只钉上面那半的话，
#    把整条判定改成"永远 PASS"也能变绿。
psu_case "$DMI_OK_OK" "$SENS_PSU2_DEAD"
check "两路里掉一路、只剩 1 路 -> 仍然判 WARN（真的没冗余了）" "WARN" "$LAST_STATUS"
check "两路里掉一路、只剩 1 路 -> 这才说不具备冗余" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '仅剩 1 路在供电，不具备电源冗余')"

# 反过来的另一头：BMC 里那一路**也没有**读数时，幽灵槽位仍然要丢掉 ——
# "捞回来"的判据只有"BMC 确认进了电"，不许放宽成"只要有个槽位就算"。
SENS_3PSU_NO4='PSU1_Vin | 220.000 | Volts | ok | 10.1
PSU2_Vin | 220.000 | Volts | ok | 10.9
PSU3_Vin | 220.000 | Volts | ok | 10.17'
psu_case "$DMI_3REAL_1GHOST" "$SENS_3PSU_NO4"
check "BMC 也读不到 PSU4 -> 仍按空槽位丢掉，只算 3 路（捞回来的判据不许放宽）" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '共 3 个电源模块在位')"

RAW_DIR="$TMP"; RUN_DIR="$TMP"

# ================================================================
echo
echo "=== dmidecode 自己打的「读不出来」标记不许当成内容（<BAD INDEX>）==="
# Supermicro X11DPG-QT 的两路电源：厂商/型号/序列号/Name 四个字段全是
# `<BAD INDEX>`（BIOS 把字符串下标填到了字符串表外面），额定功率是 65535 W
# （0xFFFF，也是"没填"）。这是**真电源**，BMC 的 PS1/PS2 Status 都是
# Presence detected —— 绝不能因为身份字段全是垃圾就把它当空槽位丢掉。
cat > "$TMP/dmidecode-psu-badindex.txt" <<'EOF'
Handle 0x0015, DMI type 39, 22 bytes
System Power Supply
	Location: PSU1
	Name: <BAD INDEX>
	Manufacturer: <BAD INDEX>
	Serial Number: <BAD INDEX>
	Model Part Number: <BAD INDEX>
	Max Power Capacity: 65535 W
	Status: Present, OK

Handle 0x0016, DMI type 39, 22 bytes
System Power Supply
	Location: PSU2
	Name: <BAD INDEX>
	Manufacturer: <BAD INDEX>
	Serial Number: <BAD INDEX>
	Model Part Number: <BAD INDEX>
	Max Power Capacity: 65535 W
	Status: Present, OK
EOF
check "<BAD INDEX> + 65535W 的两路电源仍是真电源，一路都不许丢" \
      "PSU1|Present, OK|1
PSU2|Present, OK|1" "$(dmi_psu_list "$TMP/dmidecode-psu-badindex.txt")"

# 反过来：身份全是 <BAD INDEX> **而且**额定功率显式为 0，那才是空槽位。
cat > "$TMP/dmidecode-psu-badindex0.txt" <<'EOF'
Handle 0x0015, DMI type 39, 22 bytes
System Power Supply
	Location: PSU4
	Name: <BAD INDEX>
	Manufacturer: <BAD INDEX>
	Serial Number: <BAD INDEX>
	Max Power Capacity: 0 W
	Status: Present, OK
EOF
check "<BAD INDEX> 身份 + 额定 0W -> 判为空槽位" "0" \
      "$(dmi_psu_list "$TMP/dmidecode-psu-badindex0.txt" | awk -F'|' '{print $3}')"

# ================================================================
echo
echo "=== 整机序列号的占位符名单（_serial_is_bogus）==="
# 海光 H210-G30 那台 DMI 写的是 `Serial Number: N/A`。shell 这边原来不认，
# Python 那边的 BOGUS 认，于是报告抬头「整机序列号 NA」、报告目录也叫 NA，
# 而同一份 DMI 里主板序列号 24003702CHK04234 是真的。两份名单必须一致。
for v in "N/A" "NA" "n/a" "To be filled by O.E.M." "To Be Filled By O.E.M." \
         "Not Specified" "Default string" "None" "Unknown" "<BAD INDEX>" \
         "0123456789" "System Serial Number" "-" "" "   "; do
  _serial_is_bogus "$v" \
    && ok "占位符要认出来：[$v]" \
    || bad "占位符要认出来：[$v]" "bogus" "当成了真序列号"
done
for v in "24003702CHK04234" "21204-00012" "100NA460736" "9800202107245263"; do
  _serial_is_bogus "$v" \
    && bad "真序列号不许被当成占位符：[$v]" "真序列号" "bogus" \
    || ok "真序列号不许被当成占位符：[$v]"
done

# ================================================================
echo
echo "=== 三份占位符名单必须一致（shell / awk / Python）==="
# 同一张"这一格没填"的名单在项目里有三份，各写各的：
#   lib/core.sh      _serial_is_bogus()   整机序列号退到主板/MAC
#   lib/collect.sh   junk()（awk）        电源身份字段算不算"真身份"
#   report/generate_report.py  BOGUS      客户报告里那一格显示什么
# 三处的注释都写着"要和另一边保持一致"，而 1.8.4 之前它们并不一致：
#   `N/A`                      只有 Python 认  -> 报告抬头「整机序列号 NA」
#   `To Be Filled By O.E.M`    只有 shell 认   -> 原样印进客户报告
#   `0123456789` / `--`        awk 不认        -> 空槽位被当成在位的电源
# 靠人记是记不住的（三次不一致，三次都是这么来的），所以这里拿同一张表
# 把三处**逐个值实测**一遍。加新占位符时三处一起加，这条会告诉你漏了哪个。
BOGUS_CORE=(
  "To be filled by O.E.M." "To Be Filled By O.E.M" "TO BE FILLED BY O.E.M."
  "Not Specified" "Default string" "None" "Unknown" "N/A" "NA" "No DIMM"
  "Not Present" "Empty" "O.E.M." "System Manufacturer" "System Product Name"
  "System Serial Number" "0123456789" "<BAD INDEX>" "<OUT OF SPEC>" "-" "--"
)
# 反面样本：这些是**真值**，三处都不许当成占位符。
BOGUS_REAL=( "24003702CHK04234" "21204-00012" "Supermicro" "PWS-2K21A-1R" "100NA460736" )

# ---- 1) shell ----
_n_bad=0
for v in "${BOGUS_CORE[@]}"; do _serial_is_bogus "$v" || { _n_bad=$((_n_bad+1)); printf '       shell 漏认：[%s]\n' "$v"; }; done
check "shell（_serial_is_bogus）认得出核心名单里的每一个" "0" "$_n_bad"
_n_bad=0
for v in "${BOGUS_REAL[@]}"; do _serial_is_bogus "$v" && { _n_bad=$((_n_bad+1)); printf '       shell 误杀：[%s]\n' "$v"; }; done
check "shell 不许把真值当占位符" "0" "$_n_bad"

# ---- 2) awk（junk()，经 dmi_psu_list 驱动）----
# 造一路"额定 0W + 身份字段全是待测占位符"的电源：junk() 全认出来时
# dmi_psu_list 的第三列（real）才会是 0。认漏一个 -> idreal=1 -> real=1。
_n_bad=0
for v in "${BOGUS_CORE[@]}"; do
  cat > "$TMP/psu-bogus-one.txt" <<EOF
Handle 0x0100, DMI type 39, 22 bytes
System Power Supply
	Location: PSU1
	Manufacturer: $v
	Serial Number: $v
	Model Part Number: $v
	Max Power Capacity: 0 W
	Status: Present, OK
EOF
  [[ "$(dmi_psu_list "$TMP/psu-bogus-one.txt" | awk -F'|' '{print $3}')" == "0" ]] \
    || { _n_bad=$((_n_bad+1)); printf '       awk 漏认：[%s]\n' "$v"; }
done
check "awk（junk）认得出核心名单里的每一个" "0" "$_n_bad"
# 反面：身份是真的，就算额定 0W 也不是空槽位
_n_bad=0
for v in "${BOGUS_REAL[@]}"; do
  cat > "$TMP/psu-real-one.txt" <<EOF
Handle 0x0100, DMI type 39, 22 bytes
System Power Supply
	Location: PSU1
	Manufacturer: $v
	Serial Number: $v
	Model Part Number: $v
	Max Power Capacity: 0 W
	Status: Present, OK
EOF
  [[ "$(dmi_psu_list "$TMP/psu-real-one.txt" | awk -F'|' '{print $3}')" == "1" ]] \
    || { _n_bad=$((_n_bad+1)); printf '       awk 误杀：[%s]\n' "$v"; }
done
check "awk 不许把真身份当占位符（否则真电源被当成空槽位丢掉）" "0" "$_n_bad"

# ---- 3) Python ----
# clean() 返回 None 表示"这一格读不出来"，报告里显示成 —
if command -v python3 >/dev/null 2>&1; then
  _py_out="$(
    printf '%s\n' "${BOGUS_CORE[@]}" > "$TMP/bogus-core.txt"
    printf '%s\n' "${BOGUS_REAL[@]}" > "$TMP/bogus-real.txt"
    python3 - "$LIB/../report/generate_report.py" "$TMP/bogus-core.txt" "$TMP/bogus-real.txt" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gr", sys.argv[1])
gr = importlib.util.module_from_spec(spec); spec.loader.exec_module(gr)
miss = [v for v in open(sys.argv[2], encoding="utf-8").read().splitlines()
        if v and gr.clean(v) is not None]
kill = [v for v in open(sys.argv[3], encoding="utf-8").read().splitlines()
        if v and gr.clean(v) is None]
for v in miss: print("       Python 漏认：[%s]" % v, file=sys.stderr)
for v in kill: print("       Python 误杀：[%s]" % v, file=sys.stderr)
print("%d %d" % (len(miss), len(kill)))
PYEOF
  )"
  check "Python（BOGUS/clean）认得出核心名单里的每一个，且不误杀真值" "0 0" "$_py_out"
else
  echo "  (没装 python3，跳过 Python 那一份)"
fi

# ================================================================
echo
echo "=== RAPL 功耗域去重（rapl_pkg_zones）==="
# ⚠️ 同一个 package 域在 /sys/class/powercap 下能被两条路径同时匹配到：
#      /sys/class/powercap/intel-rapl:0              ← zone 自己的 class 软链
#      /sys/class/powercap/intel-rapl/intel-rapl:0   ← 从 control type 目录进去
#   1.8.2 之前两条都加进了总和，于是报告里那条 CPU 封装功耗曲线**整整翻一倍**：
#   2x Xeon Gold 6530（PL1 270W/颗）报出 1034 W，2x Jintide C5218R
#   （PL1 125W/颗）报出 567 W。这里把那棵 sysfs 照原样搭出来，钉住去重。
PC="$TMP/powercap"
mkdir -p "$PC/devices/intel-rapl"
for z in intel-rapl:0 intel-rapl:1; do
  mkdir -p "$PC/devices/intel-rapl/$z"
  echo 1000000                > "$PC/devices/intel-rapl/$z/energy_uj"
  echo 262143328850           > "$PC/devices/intel-rapl/$z/max_energy_range_uj"
  # 子域（core/uncore/dram），不该被算进来
  mkdir -p "$PC/devices/intel-rapl/$z/$z:0"
  echo 500000 > "$PC/devices/intel-rapl/$z/$z:0/energy_uj"
  ln -s "devices/intel-rapl/$z"      "$PC/$z"
  ln -s "devices/intel-rapl/$z/$z:0" "$PC/$z:0"
done
ln -s "devices/intel-rapl" "$PC/intel-rapl"

check "两路 CPU 只该数出两个 package 域（同一个 zone 两条路径只算一次）" \
      "2" "$(KLBURN_POWERCAP="$PC" rapl_pkg_zones | wc -l)"
check "数出来的 zone 名去重后就是 0 和 1" \
      "intel-rapl:0
intel-rapl:1" "$(KLBURN_POWERCAP="$PC" rapl_pkg_zones | sed 's#.*/##' | sort)"
check "core/uncore 子域不许进来" "0" \
      "$(KLBURN_POWERCAP="$PC" rapl_pkg_zones | grep -c ':.*:')"
check "powercap 目录不存在时安静地什么都不给" "" \
      "$(KLBURN_POWERCAP="$TMP/no-such-powercap" rapl_pkg_zones)"

# 只有 control type 那条路径可用（class 软链没建出来）时也得数得出来
PC2="$TMP/powercap-only-parent"
mkdir -p "$PC2/intel-rapl/intel-rapl:0"
echo 1000000 > "$PC2/intel-rapl/intel-rapl:0/energy_uj"
check "只有 control type 目录那条路径时照样能数到" "1" \
      "$(KLBURN_POWERCAP="$PC2" rapl_pkg_zones | wc -l)"

# ================================================================
echo
echo "=== 两次采样求差的那几个函数：上一次的读数必须跨得过子 shell ==="
# ⚠️ 调用点全是命令替换 / 进程替换：
#     p="$(cpu_power_w)"  /  while read ... < <(cpu_pkg_busy_pct)
#   两种都在**子 shell**里跑，函数里对 shell 全局的赋值出了子 shell 就没了
#   （§11-28）。1.8.2 之前这三个函数就是把"上一次"存在全局里的，于是"上一次"
#   永远停在父 shell 那次基准上 —— 每个点算出来的是"从压测开始到现在的平均值"。
#   1.7.8 那台 6530 的功耗曲线因此前 14 分钟一条直线、计数器一回绕就塌到
#   429 W 再每点爬 4 瓦，爬到测完都没回去。
#
# 这里搭一棵能改能量值的假 powercap，**全程用命令替换调**（就是现场那种调法），
# 三次采样两段区间，两段的功耗差 10 倍 —— 算平均值的话第二段会被第一段拖高。
export KLBURN_POWERCAP="$TMP/powercap-rate" KLBURN_STATE_DIR="$TMP/state"
PC3="$KLBURN_POWERCAP"
mkdir -p "$PC3/devices/intel-rapl/intel-rapl:0"
ln -s "devices/intel-rapl/intel-rapl:0" "$PC3/intel-rapl:0"
ln -s "devices/intel-rapl"              "$PC3/intel-rapl"
EUJ="$PC3/devices/intel-rapl/intel-rapl:0/energy_uj"
echo 262143328850 > "$PC3/devices/intel-rapl/intel-rapl:0/max_energy_range_uj"

echo 0 > "$EUJ"
check "第一次调用只记基准，不给数字" "" "$(cpu_power_w)"
sleep 1; echo 100000000 > "$EUJ"      # 1 秒里烧了 100 J -> 100 W
w1="$(cpu_power_w)"
sleep 1; echo 110000000 > "$EUJ"      # 再 1 秒只烧了 10 J -> 10 W
w2="$(cpu_power_w)"

[[ "$w1" =~ ^[0-9]+$ ]] && (( w1 >= 80 && w1 <= 120 )) \
  && ok "第一段 100 W 左右（实际 $w1）" \
  || bad "第一段 100 W 左右" "80~120" "$w1"
# ★ 这条才是关键：算平均值的话这里会是 55 W 上下，而不是 10 W
[[ "$w2" =~ ^[0-9]+$ ]] && (( w2 >= 5 && w2 <= 30 )) \
  && ok "第二段是**这一段**的瞬时值，不是从基准算起的平均值（实际 $w2）" \
  || bad "第二段是这一段的瞬时值，不是平均值" "5~30（平均值会是 55 上下）" "$w2"

unset KLBURN_POWERCAP KLBURN_STATE_DIR

# 结构性守卫：这三个函数一律走 sample_state_file，谁都不许再把上一次的读数
# 放回 shell 全局里 —— 放回去了上面那条断言未必抓得到（父 shell 打过基准时
# 平均值和瞬时值在满载下很接近），但曲线一定是错的。
for fn in cpu_power_w cpu_pkg_busy_pct disk_io_rates; do
  body="$(declare -f "$fn")"
  case "$body" in
    *sample_state_file*) ok "$fn 的上一次读数存在文件里（跨得过子 shell）" ;;
    *) bad "$fn 的上一次读数存在文件里（跨得过子 shell）" "用 sample_state_file" "没用" ;;
  esac
done

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

# ---------------------------------------------------------------- 文案要走摘要
# 上面几条只验状态。这一条验的是 verify_dmesg **真的用上了摘要函数** ——
# 只测 dmesg_error_summary 本身是不够的：1.8.0 那次就是判定对了、
# 而现场看到的文案还是「3018 条 + 一大串内核断言」。
printf 'boot\n' > "$RAW_DIR/dmesg-pre.txt"
{
  printf 'boot\n'
  for _ in $(seq 1 50); do
    printf '[Thu Aug  6 14:08:00 2026] NVRM: GPU0 nvAssertOkFailedNoLog: Assertion failed: GPU lost from the bus [NV_ERR_GPU_IS_LOST] (0x0000000F) returned from _intrServiceStallCommonCheckBegin(pGpu, pIntr, &pOldContext) @ intr.c:1653\n'
  done
} > "$RAW_DIR/dmesg-post.txt"
LAST_STATUS=""; LAST_DETAIL=""
verify_dmesg 2>/dev/null >/dev/null
check "同一条错误刷 50 遍 -> 仍然 FAIL" "FAIL" "$LAST_STATUS"
check "文案要说这是同一个问题，不是 50 个" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '都指向同一个问题' || true)"
check "文案要翻译成人话" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '从 PCIe 总线上掉线' || true)"
check "文案里不许出现内核断言函数名（客户看不懂）" "0" \
      "$(printf '%s' "$LAST_DETAIL" | grep -cE 'nvAssertOkFailedNoLog|intr\.c:|pOldContext' || true)"

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

# klburn.conf 里的覆盖必须真的生效。
#
# 加载顺序是 core.sh -> klburn.conf -> 其余 lib（factory-test.sh 里），
# 所以后面这些 lib 里的默认值必须写成"没定义过才给"。标量靠
# `: "${VAR:=默认}"` 天然成立，**数组没有对应写法**，一不小心就写成裸赋值 ——
# 那样现场在 klburn.conf 里换内网 NTP 会被原样顶掉，而且不会有任何报错，
# 表现是"配了内网源，校时还是走外网、还是失败"，离线机房里根本查不出原因。
#
# 这条断言是变异测试逼出来的：把 network.sh 改回裸赋值，整套测试当时全绿。
cat > "$TMP/conf-override.sh" <<EOF
RUN_DIR="$TMP"; RAW_DIR="$TMP"
source "$LIB/core.sh" >/dev/null 2>&1
# 下面两行模拟现场在 /opt/klburn/klburn.conf 里写的覆盖
NET_TIME_SERVERS=(ntp.internal.lan)
NET_PING_COUNT=9
source "$LIB/network.sh" >/dev/null 2>&1
printf '%s|%s' "\${NET_TIME_SERVERS[*]}" "\$NET_PING_COUNT"
EOF
check "klburn.conf 预设的值不许被 lib 顶掉（数组和标量都要）" \
      "ntp.internal.lan|9" "$(bash "$TMP/conf-override.sh" 2>/dev/null)"

if have chronyd; then
  # 中文引号是文案的一部分，不是打错的 shell 引号
  # shellcheck disable=SC1111
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
#
# ⚠️ 断言**必须直接调用 raid_bmc_hint 再读全局**，不能写成
#       "$([[ -n "$(raid_bmc_hint)" ]] && ...)"
# 1.7.6 以前就是那么写的，于是这一组和下面「BMC 全哑 -> 状态」那一组各自都绿，
# 而**中间那根线是断的**：真实调用方也用了命令替换，子 shell 里设的
# RAID_BMC_SILENT 根本传不出来，整条判定从上线起就是死代码。
# 现在验的是这个函数真正的产出 —— 那个全局标志位本身。
flag_after_hint() {   # 直接调用（不套 $(...)），回 silent / quiet
  RAID_BMC_SILENT=0
  raid_bmc_hint
  (( RAID_BMC_SILENT == 1 )) && echo silent || echo quiet
}

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
check "板子定义了 RAID/HBA/Slot 传感器但全部 No Reading -> 标志位置上" \
      "silent" "$(flag_after_hint)"

RAW_DIR="$TMP/case-hasraid"; mkdir -p "$RAW_DIR"
cp "$TMP/ipmi-sdr-hasraid.txt" "$RAW_DIR/ipmi-sdr.txt"
check "传感器有实际读数 -> 真有东西在响应，标志位不置" \
      "quiet" "$(flag_after_hint)"

RAW_DIR="$TMP/case-none"; mkdir -p "$RAW_DIR"
cp "$TMP/ipmi-sdr-none.txt" "$RAW_DIR/ipmi-sdr.txt"
check "板子压根没定义 RAID/HBA/Slot 相关传感器 -> 不该瞎猜，标志位不置" \
      "quiet" "$(flag_after_hint)"

RAW_DIR="$TMP/case-noipmi"; mkdir -p "$RAW_DIR"
cp "$TMP/ipmi-sdr-noraid.txt" "$RAW_DIR/ipmi-sdr.txt"
IPMI_OK=0
check "没有 BMC（IPMI_OK=0）时不该假装读到了什么" \
      "quiet" "$(flag_after_hint)"
IPMI_OK=1

# ---- 这条提示的**出口**：走留档，不进客户报告 ----
# 它分不开「本来就没装卡」和「卡坏到 PCI 都枚举不到」。分不开的东西不该去染
# 客户的结论 —— 海光那台真没装卡、机器完全正常，抬成 WARN 就是白惹一次解释。
RAW_DIR="$TMP/case-noraid"
RAID_BMC_SILENT=0; raid_bmc_hint; raid_bmc_note
check "BMC 全哑时要落一份留档给内部报告" "1" \
      "$([[ -s "$RAW_DIR/raid-bmc-note.txt" ]] && echo 1 || echo 0)"
check "留档里要写清「如果确实装了卡该去做什么」" "1" \
      "$(grep -c '插到位' "$RAW_DIR/raid-bmc-note.txt" || true)"
check "留档里要说明它不进客户报告、不改变结论" "1" \
      "$(grep -c '不改变整机结论' "$RAW_DIR/raid-bmc-note.txt" || true)"

RAW_DIR="$TMP/case-hasraid"
RAID_BMC_SILENT=0; raid_bmc_hint; raid_bmc_note
check "传感器正常时不该凭空落这份留档" "0" \
      "$([[ -e "$RAW_DIR/raid-bmc-note.txt" ]] && echo 1 || echo 0)"

RAW_DIR="$TMP"

# ================================================================
echo
echo "=== 计数器快照与差值判定（ECC / 热节流 / PCIe AER）==="
# 1.7.0 新增的三条判定。它们判的都是**差值**（测后减测前），不是绝对值 ——
# 一台用过的机器带着历史计数是正常的。
#
# 三个 *_snapshot 都吃一个 sysfs 根目录参数，这里搭一棵假树喂它们，
# 不需要真硬件。**这一组最要紧的是"读不到 = SKIP，绝不是 FAIL"**：
# 很多平台和虚拟机压根没有 EDAC / thermal_throttle / AER 接口。

CNT="$TMP/counters"
SYSC="$CNT/sys"
mkdir -p "$CNT"

mk_ecc() {   # mk_ecc <mc> <dimm> <标签> <ce> <ue>
  local d="$SYSC/devices/system/edac/mc/mc$1/dimm$2"
  mkdir -p "$d"
  printf '%s\n' "$3" > "$d/dimm_label"
  printf '%s\n' "$4" > "$d/dimm_ce_count"
  printf '%s\n' "$5" > "$d/dimm_ue_count"
}
mk_throttle() {   # mk_throttle <cpu> <core计数> <package计数>
  local d="$SYSC/devices/system/cpu/cpu$1/thermal_throttle"
  mkdir -p "$d"
  printf '%s\n' "$2" > "$d/core_throttle_count"
  printf '%s\n' "$3" > "$d/package_throttle_count"
}
mk_aer() {   # mk_aer <BDF> <可纠正> <致命> <非致命>
  local d="$SYSC/bus/pci/devices/$1"
  mkdir -p "$d"
  printf 'RxErr 0\nBadTLP 0\nTOTAL_ERR_COR %s\n'   "$2" > "$d/aer_dev_correctable"
  printf 'Undefined 0\nTOTAL_ERR_FATAL %s\n'       "$3" > "$d/aer_dev_fatal"
  printf 'Undefined 0\nTOTAL_ERR_FATAL %s\n'       "$4" > "$d/aer_dev_nonfatal"
}

rm -rf "$SYSC"
mk_ecc 0 0 "CPU0_DIMM_A1" 0 0
mk_ecc 0 1 "CPU0_DIMM_B1" 3 0
mk_throttle 0 0 0
mk_throttle 1 5 2
mk_aer "0000:18:00.0" 7 0 0

check "ecc_snapshot 逐条 DIMM 按标签归位" "1" \
      "$(ecc_snapshot "$SYSC" | grep -c '^ECC CPU0_DIMM_B1 3 0$' || true)"
check "ecc_snapshot 认到两条内存" "2" "$(ecc_snapshot "$SYSC" | grep -c '^ECC ' || true)"
check "throttle_snapshot 读到逐核计数" "1" \
      "$(throttle_snapshot "$SYSC" | grep -c '^THROTTLE cpu1 5 2$' || true)"
check "aer_snapshot 读到 TOTAL_ERR_COR" "1" \
      "$(aer_snapshot "$SYSC" | grep -c '^AER 0000:18:00.0 7 0 0$' || true)"

# 没有这些 sysfs 接口时必须是**空输出**，不是 0 —— 空 = 判 SKIP，0 = 判 PASS，
# 这两件事的含义完全不同（"没这个功能" vs "查过了没问题"）。
check "没有 EDAC 时 ecc_snapshot 一行都不输出"      "0" "$(ecc_snapshot "$TMP/nosuch" | grep -c . || true)"
check "没有热节流接口时 throttle_snapshot 不输出"    "0" "$(throttle_snapshot "$TMP/nosuch" | grep -c . || true)"
check "没有 AER 接口时 aer_snapshot 不输出"          "0" "$(aer_snapshot "$TMP/nosuch" | grep -c . || true)"

# ---- 差值 ----
{ ecc_snapshot "$SYSC"; throttle_snapshot "$SYSC"; aer_snapshot "$SYSC"; } > "$CNT/pre.txt"
# 压测之后：B1 又多了 2 个可纠正、A1 出了 1 个不可纠正、cpu1 多节流 3 次、AER 多 4 个
rm -rf "$SYSC"
mk_ecc 0 0 "CPU0_DIMM_A1" 0 1
mk_ecc 0 1 "CPU0_DIMM_B1" 5 0
mk_throttle 0 0 0
mk_throttle 1 8 2
mk_aer "0000:18:00.0" 11 0 0
{ ecc_snapshot "$SYSC"; throttle_snapshot "$SYSC"; aer_snapshot "$SYSC"; } > "$CNT/post.txt"

check "counters_delta 只报增量大于 0 的（B1 可纠正 3->5）" "1" \
      "$(counters_delta ECC "$CNT/pre.txt" "$CNT/post.txt" | grep -c '^CPU0_DIMM_B1 1 3 5 2$' || true)"
check "counters_delta 认得出新增的不可纠正（A1 0->1）" "1" \
      "$(counters_delta ECC "$CNT/pre.txt" "$CNT/post.txt" | grep -c '^CPU0_DIMM_A1 2 0 1 1$' || true)"
check "没变化的条目不出现在差值里" "0" \
      "$(counters_delta ECC "$CNT/pre.txt" "$CNT/post.txt" | grep -c '^CPU0_DIMM_A1 1 ' || true)"
check "counters_delta 认得出热节流增量" "1" \
      "$(counters_delta THROTTLE "$CNT/pre.txt" "$CNT/post.txt" | grep -c '^cpu1 1 5 8 3$' || true)"

# 计数器回绕/清零绝不能算成"新增"（负增量要被丢掉）
printf 'ECC X 100 0\n' > "$CNT/hi.txt"
printf 'ECC X 0 0\n'   > "$CNT/lo.txt"
check "计数器变小（清零/换硬件）不算新增" "0" \
      "$(counters_delta ECC "$CNT/hi.txt" "$CNT/lo.txt" | grep -c . || true)"

# ---- 三条判定 ----
RAW_DIR="$CNT"; RUN_DIR="$CNT"
LAST_STATUS=""; LAST_DETAIL=""
result_add() { LAST_STATUS="$3"; LAST_DETAIL="$4"; }
metric_add() { :; }

cp "$CNT/pre.txt" "$RAW_DIR/counters-pre.txt"
cp "$CNT/pre.txt" "$RAW_DIR/counters-post.txt"
LAST_STATUS=""; verify_ecc
check "ECC 前后一模一样 -> PASS" "PASS" "$LAST_STATUS"
LAST_STATUS=""; verify_throttle
check "热节流前后一模一样 -> PASS" "PASS" "$LAST_STATUS"
LAST_STATUS=""; verify_aer
check "AER 前后一模一样 -> PASS" "PASS" "$LAST_STATUS"

# 只新增可纠正 -> WARN（还纠得回来，不拉低整机结论）
printf 'ECC A1 0 0\nECC B1 3 0\n' > "$RAW_DIR/counters-pre.txt"
printf 'ECC A1 0 0\nECC B1 9 0\n' > "$RAW_DIR/counters-post.txt"
LAST_STATUS=""; LAST_DETAIL=""; verify_ecc
check "只新增可纠正 ECC -> WARN（不是 FAIL）" "WARN" "$LAST_STATUS"
check "而且要说清楚错误已被纠正、本次结果仍然有效" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '已被 ECC 纠正' || true)"
check "文案里要点到具体是哪一条内存" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c 'B1' || true)"

# 新增不可纠正 -> FAIL
printf 'ECC A1 0 0\n' > "$RAW_DIR/counters-pre.txt"
printf 'ECC A1 0 2\n' > "$RAW_DIR/counters-post.txt"
LAST_STATUS=""; verify_ecc
check "新增不可纠正 ECC -> FAIL" "FAIL" "$LAST_STATUS"

# 可纠正 + 不可纠正同时有 -> 必须是 FAIL，不能被 WARN 盖过去
printf 'ECC A1 0 0\nECC B1 0 0\n' > "$RAW_DIR/counters-pre.txt"
printf 'ECC A1 9 0\nECC B1 0 1\n' > "$RAW_DIR/counters-post.txt"
LAST_STATUS=""; verify_ecc
check "可纠正和不可纠正同时新增 -> FAIL（不可纠正优先）" "FAIL" "$LAST_STATUS"

# 没有 EDAC -> SKIP。**这条最重要：读不到绝不能判故障**
printf '# 只有热节流，没有 ECC\nTHROTTLE cpu0 0 0\n' > "$RAW_DIR/counters-pre.txt"
printf '# 只有热节流，没有 ECC\nTHROTTLE cpu0 0 0\n' > "$RAW_DIR/counters-post.txt"
LAST_STATUS=""; LAST_DETAIL=""; verify_ecc
check "内核没有 EDAC 接口 -> SKIP（不是 PASS 也不是 FAIL）" "SKIP" "$LAST_STATUS"
check "SKIP 的文案要写明不影响整机结论" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '不影响整机结论' || true)"

# 热节流：新增 -> WARN（散热问题，但机器本身没坏）
printf 'THROTTLE cpu0 0 0\n' > "$RAW_DIR/counters-pre.txt"
printf 'THROTTLE cpu0 4 1\n' > "$RAW_DIR/counters-post.txt"
LAST_STATUS=""; LAST_DETAIL=""; verify_throttle
check "压测期间出现热节流 -> WARN（保护机制正常工作，不是故障）" "WARN" "$LAST_STATUS"
check "要提示这时温度读数可能仍然正常（否则没人会去查散热）" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '温度读数可能仍在正常范围' || true)"

printf '# 没有热节流接口\nECC A1 0 0\n' > "$RAW_DIR/counters-pre.txt"
printf '# 没有热节流接口\nECC A1 0 0\n' > "$RAW_DIR/counters-post.txt"
LAST_STATUS=""; verify_throttle
check "CPU 不提供热节流计数 -> SKIP" "SKIP" "$LAST_STATUS"

# AER：可纠正 -> WARN，不可纠正 -> FAIL
printf 'AER 0000:18:00.0 0 0 0\n'  > "$RAW_DIR/counters-pre.txt"
printf 'AER 0000:18:00.0 12 0 0\n' > "$RAW_DIR/counters-post.txt"
LAST_STATUS=""; verify_aer
check "只新增 PCIe 可纠正错误 -> WARN" "WARN" "$LAST_STATUS"

printf 'AER 0000:18:00.0 0 0 0\n' > "$RAW_DIR/counters-pre.txt"
printf 'AER 0000:18:00.0 0 0 3\n' > "$RAW_DIR/counters-post.txt"
LAST_STATUS=""; verify_aer
check "新增 PCIe 不可纠正（非致命）-> FAIL" "FAIL" "$LAST_STATUS"

printf 'AER 0000:18:00.0 0 0 0\n' > "$RAW_DIR/counters-pre.txt"
printf 'AER 0000:18:00.0 0 1 0\n' > "$RAW_DIR/counters-post.txt"
LAST_STATUS=""; verify_aer
check "新增 PCIe 不可纠正（致命）-> FAIL" "FAIL" "$LAST_STATUS"

printf '# 没有 AER\nECC A1 0 0\n' > "$RAW_DIR/counters-pre.txt"
printf '# 没有 AER\nECC A1 0 0\n' > "$RAW_DIR/counters-post.txt"
LAST_STATUS=""; verify_aer
check "固件没开 AER -> SKIP" "SKIP" "$LAST_STATUS"

# 快照文件整个不存在（采集阶段就崩了）也必须是 SKIP，不能崩也不能判故障
rm -f "$RAW_DIR/counters-pre.txt" "$RAW_DIR/counters-post.txt"
LAST_STATUS=""; verify_ecc
check "连快照文件都没有 -> SKIP（不崩、不判故障）" "SKIP" "$LAST_STATUS"

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
[Sat Aug  1 16:13:10 2026] I/O error, dev fd0, sector 0 op 0x0:(READ) flags 0x0 phys_seg 1 prio class 2
[Sat Aug  1 16:13:10 2026] blk_update_request: I/O error, dev fd0, sector 0 op 0x0:(READ) flags 0x0 phys_seg 1 prio class 2
[Mon Aug  3 10:35:25 2026] pcieport 0000:00:01.4: AER: enabled with IRQ 25
[Mon Aug  3 10:35:25 2026] pcieport 0000:00:01.6: AER: enabled with IRQ 26
[Mon Aug  3 10:35:25 2026] pcieport 0000:00:07.1: AER: enabled with IRQ 27
[Mon Aug  3 10:35:25 2026] pcieport 0000:00:08.1: AER: enabled with IRQ 29
EOF

dmesg_scan_hw_errors "$DMESG_BAD" "$TMP/hits-bad.txt"
check "阵列卡完整故障链 9 行必须全部命中" "9" "$(count_lines "$TMP/hits-bad.txt")"

dmesg_scan_hw_errors "$DMESG_NOISE" "$TMP/hits-noise.txt"
check "开机正常噪声一条都不许命中（含 NMI / AER无冒号 / AER启用 / EDAC 初始化 / Correctable Errors）" \
      "0" "$(count_lines "$TMP/hits-noise.txt")"

# 逐条钉死几个最容易被改坏的，免得以后有人把裸 NMI 或裸 CE 加回来
for bad_line in \
  'ACPI: X2APIC_NMI (uid[0xffffffff] high edge lint[0x1])' \
  'NMI watchdog: Enabled. Permanently consumes one hw-PMU counter.' \
  'acpi PNP0A08:00: _OSC: platform does not support [SHPCHotplug AER LTR DPC]' \
  'pcieport 0000:00:01.4: AER: enabled with IRQ 25' \
  'EDAC MC0: Giving out device to module i10nm_edac controller Intel_10nm Socket#0 IMC#0: DEV 0000:7e:0c.0 (INTERRUPT)' \
  'RAS: Correctable Errors collector initialized.' \
  'megaraid_sas 0000:98:00.0: FW now in Ready state'
do
  printf '[Wed Nov 26 02:16:23 2025] %s\n' "$bad_line" > "$TMP/one.txt"
  dmesg_scan_hw_errors "$TMP/one.txt" "$TMP/one-hit.txt"
  check "不许命中: ${bad_line:0:60}" "0" "$(count_lines "$TMP/one-hit.txt")"
done

# ---- 软驱：豁免它，但绝不能顺手把真盘的 I/O error 一起豁免掉 ----
#
# 这一组是 tests/e2e-qemu.sh 跑出来的。虚拟机里内核探测那个不存在的软驱，
# 打了三行 "I/O error, dev fd0"，verify_dmesg_boot 当场判 FAIL，结论写着
# 「机器在上电初始化时就有硬件异常」—— 而那台"机器"什么毛病都没有。
#
# 真服务器上同样会遇到：BMC 虚拟媒体（iDRAC/iLO）挂了虚拟软驱、
# 或者 BIOS 开了软驱模拟。软驱不在测试范围内，它探测失败说明不了任何事。
#
# 但豁免必须窄。下面成对断言：fd0 放过，sd/nvme/vd 一个都不许放过。
printf '%s\n' \
  '[Sat Aug  1 16:13:10 2026] I/O error, dev fd0, sector 0 op 0x0:(READ) flags 0x0 phys_seg 1 prio class 2' \
  > "$TMP/fd0.txt"
dmesg_scan_hw_errors "$TMP/fd0.txt" "$TMP/fd0-hit.txt"
check "软驱探测的 I/O error 不算故障（虚拟媒体挂的软驱，真机上也有）" \
      "0" "$(count_lines "$TMP/fd0-hit.txt")"

for real_dev in sda nvme0n1 vdb sdak; do
  printf '[Sat Aug  1 16:13:10 2026] I/O error, dev %s, sector 12345 op 0x0:(READ) flags 0x0 phys_seg 1 prio class 2\n' \
    "$real_dev" > "$TMP/real.txt"
  dmesg_scan_hw_errors "$TMP/real.txt" "$TMP/real-hit.txt"
  check "真盘 $real_dev 的 I/O error 必须照常命中（豁免不许扩大化）" \
        "1" "$(count_lines "$TMP/real-hit.txt")"
done

# ---- AER 启用日志：豁免它，但真正的 AER 报错一条都不许跟着漏掉 ----
#
# 1.7.4 那台海光 C86（OPN3350）判 FAIL 的全部理由，就是下面这一行 ×4：
#   pcieport 0000:00:01.4: AER: enabled with IRQ 25
# 那是内核**打开** AER 上报的初始化日志，含义和"出错了"正好相反。
# 固件把 AER 交给操作系统的平台都会打，和 CPU 厂商无关 ——
# Intel 那批板子的 BIOS 不交（打的是没冒号的 "_OSC: ... [... AER ...]"），
# 所以这个误报一直藏到海光这台才露出来。
#
# 和软驱那组一样成对钉死：启用日志放过，真报错一条都不许放过。
printf '%s\n' \
  '[Mon Aug  3 10:35:25 2026] pcieport 0000:00:01.4: AER: enabled with IRQ 25' \
  > "$TMP/aer-init.txt"
dmesg_scan_hw_errors "$TMP/aer-init.txt" "$TMP/aer-init-hit.txt"
check "AER 启用日志不算故障（固件把 AER 交给 OS 的平台每个 root port 都有一行）" \
      "0" "$(count_lines "$TMP/aer-init-hit.txt")"

while IFS= read -r aer_line; do
  printf '[Mon Aug  3 10:35:25 2026] %s\n' "$aer_line" > "$TMP/aer-real.txt"
  dmesg_scan_hw_errors "$TMP/aer-real.txt" "$TMP/aer-real-hit.txt"
  check "真的 AER 报错必须照常命中: ${aer_line:0:56}" \
        "1" "$(count_lines "$TMP/aer-real-hit.txt")"
done <<'EOF'
pcieport 0000:00:01.4: AER: Corrected error received: 0000:03:00.0
pcieport 0000:00:01.4: AER: Multiple Corrected error received: 0000:03:00.0
pcieport 0000:00:01.4: AER: Uncorrected (Non-Fatal) error received: 0000:03:00.0
megaraid_sas 0000:98:00.0: AER: can't recover (no error_detected callback)
pcieport 0000:97:01.0: AER: device recovery failed
nvme 0000:03:00.0: AER: PCIe Bus Error: severity=Corrected, type=Data Link Layer, (Receiver ID)
EOF

# 真正的 EDAC 报错格式必须还能抓住（收紧模式别把真错误也关在门外）
printf '[Wed Nov 26 02:16:23 2025] EDAC MC0: 1 CE memory read error on CPU_SrcID#0_MC#0_Chan#0_DIMM#0\n' > "$TMP/one.txt"
dmesg_scan_hw_errors "$TMP/one.txt" "$TMP/one-hit.txt"
check "真的 EDAC 可纠正错误必须命中" "1" "$(count_lines "$TMP/one-hit.txt")"
printf '[Wed Nov 26 02:16:23 2025] Uhhuh. NMI received for unknown reason 3d on CPU 0.\n' > "$TMP/one.txt"
dmesg_scan_hw_errors "$TMP/one.txt" "$TMP/one-hit.txt"
check "真的 NMI 故障必须命中" "1" "$(count_lines "$TMP/one-hit.txt")"

# ---- 设备中途掉下总线：必须命中，但不能牵连"驱动版本不支持这张卡" ----
#
# 1.7.8 现场那台 RTX 5090 开测 20 秒掉线，内核刷了 3019 行 "GPU lost from the
# bus"，而当时这个模式里一个 NVIDIA 关键字都没有 —— 1.1MB 的 NVRM 报错命中数
# 是 0，"内核日志复查"判 PASS，整机判 PASS 出厂。
#
# 又一次成对钉死。这一组的负样本尤其要紧：那几句是**我们带的驱动版本旧了**，
# 判 FAIL 就是把好卡说成坏卡，踩的是"能力缺失 ≠ 硬件故障"那条红线。
while IFS= read -r loss_line; do
  printf '[Wed Nov 26 03:18:53 2025] %s\n' "$loss_line" > "$TMP/loss.txt"
  dmesg_scan_hw_errors "$TMP/loss.txt" "$TMP/loss-hit.txt"
  check "设备掉下总线必须命中: ${loss_line:0:56}" \
        "1" "$(count_lines "$TMP/loss-hit.txt")"
done <<'EOF'
NVRM: GPU0 nvAssertOkFailedNoLog: Assertion failed: GPU lost from the bus [NV_ERR_GPU_IS_LOST] (0x0000000F) returned from _intrServiceStallCommonCheckBegin(pGpu, pIntr, &pOldContext) @ intr.c:1653
NVRM: GPU0 nvCheckOkFailedNoLog: Check failed: GPU lost from the bus [NV_ERR_GPU_IS_LOST] (0x0000000F)
pcieport 0000:97:01.0: device [10de:2b85] has fallen off the bus
EOF

while IFS= read -r mism_line; do
  printf '[Wed Nov 26 02:16:37 2025] %s\n' "$mism_line" > "$TMP/mism.txt"
  dmesg_scan_hw_errors "$TMP/mism.txt" "$TMP/mism-hit.txt"
  check "驱动版本不匹配绝不许命中（我们的驱动旧了，不是客户的卡坏了）: ${mism_line:0:46}" \
        "0" "$(count_lines "$TMP/mism-hit.txt")"
done <<'EOF'
NVRM: The NVIDIA GPU 0000:01:00.0 (PCI ID: 10de:2b85) installed in this system
NVRM: is not supported by the NVIDIA 550.54.14 driver release.
NVRM: is not supported by open nvidia.ko.
NVRM: No NVIDIA GPU found.
NVRM: The NVIDIA probe routine was not called for 1 device(s).
NVRM: minimum required driver version is 550.00
NVRM: loading NVIDIA UNIX Open Kernel Module for x86_64  595.84  Release Build
EOF

# ================================================================
echo
echo "=== 内核错误摘要：说人话，别把内核断言原文甩给客户 ==="
#
# 1.8.0 现场那台坏卡的报告上写的是：
#   「压测期间内核日志出现 3018 条硬件错误。示例：[...] NVRM: GPU0
#     nvAssertOkFailedNoLog: Assertion failed: GPU lost from the bus ...」
# 两个毛病：「3018 条」读起来像 3018 个不同的毛病（其实是同一件事刷了 3018 遍），
# 而且直接把内核断言贴给客户看。

# 同一条错误重复几千遍 -> 必须说"这是一个问题"，而不是"3018 个"
: > "$TMP/dig-same.txt"
for _ in $(seq 1 200); do
  printf '[Thu Aug  6 14:08:00 2026] NVRM: GPU0 nvAssertOkFailedNoLog: Assertion failed: GPU lost from the bus [NV_ERR_GPU_IS_LOST] (0x0000000F) returned from _intrServiceStallCommonCheckBegin(pGpu, pIntr, &pOldContext) @ intr.c:1653\n' >> "$TMP/dig-same.txt"
done
dig="$(dmesg_error_summary "$TMP/dig-same.txt" 200)"
check "同一条刷屏 -> 归成 1 类" "1" \
      "$(printf '%s' "$dig" | grep -c '都指向同一个问题' || true)"
check "而且要翻译成人话（显卡掉总线）" "1" \
      "$(printf '%s' "$dig" | grep -c '从 PCIe 总线上掉线' || true)"
check "客户报告里不许出现内核断言函数名" "0" \
      "$(printf '%s' "$dig" | grep -cE 'nvAssertOkFailedNoLog|intr\.c:|pOldContext' || true)"
check "总条数还是要说清楚（不能把 200 条说没了）" "1" \
      "$(printf '%s' "$dig" | grep -c '200 条' || true)"

# 多类错误 -> 逐类报数
cat > "$TMP/dig-multi.txt" <<'EOF'
[Wed Nov 26 02:16:27 2025] pcieport 0000:97:01.0: DPC: containment event, status:0x1f03, ERR_NONFATAL received from 0000:98:00.0
[Wed Nov 26 02:16:28 2025] megaraid_sas 0000:98:00.0: FW in FAULT state Fault code:0xfff0000 subcode:0xff00
[Wed Nov 26 02:16:29 2025] megaraid_sas 0000:98:00.0: FW in FAULT state Fault code:0xfff0001 subcode:0xff00
[Wed Nov 26 02:16:30 2025] EDAC MC0: 1 CE memory read error on CPU_SrcID#0_MC#0_Chan#0_DIMM#0
EOF
dig2="$(dmesg_error_summary "$TMP/dig-multi.txt" 4)"
check "多类错误 -> 说清楚涉及几类" "1" \
      "$(printf '%s' "$dig2" | grep -c '涉及 3 类问题' || true)"
check "存储控制器那类要认出来" "1" \
      "$(printf '%s' "$dig2" | grep -c '存储控制器/阵列卡固件进入故障状态' || true)"
check "内存 ECC 那类要认出来" "1" \
      "$(printf '%s' "$dig2" | grep -c '内存 ECC 错误' || true)"

# ⚠️ 认不出来的错误**绝不能被吞掉** —— 那等于报告上少了一条硬件错误。
printf '[Wed Nov 26 02:16:27 2025] some_driver 0000:11:22.0: totally novel catastrophe code=7\n' \
  > "$TMP/dig-unknown.txt"
dig3="$(dmesg_error_summary "$TMP/dig-unknown.txt" 1)"
check "认不出的错误要走「其他」并附上原文，不能凭空消失" "1" \
      "$(printf '%s' "$dig3" | grep -c '其他内核硬件错误' || true)"
check "而且原文要带出来，好让我们查" "1" \
      "$(printf '%s' "$dig3" | grep -c 'totally novel catastrophe' || true)"

check "空文件不崩" "1" "$(dmesg_error_summary "$TMP/nope-none.txt" 0 | grep -c '共 0 条' || true)"

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

# ---- 一张坏阵列卡不该被读成两处独立故障 ----
# 同一张卡会在「阵列卡」和「开机内核日志复查」各判一次 FAIL，两条都对，
# 但报告抬头写着"失败 2 项"。collect_raid 确认过卡有问题时，这里点一句。
cp "$DMESG_BAD" "$RAW_DIR/dmesg-pre.txt"
RAID_FAULT_FOUND=1
LAST_STATUS=""; LAST_DETAIL=""; verify_dmesg_boot
check "阵列卡已判故障时，这里要点出「是同一件事」" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '同一件事')"
check "判定本身不受影响，照旧 FAIL" "FAIL" "$LAST_STATUS"

# 反面一：collect_raid 没判故障（比如内核里压根没这张卡的驱动，§2-2 判 SKIP）
# 时不许点这一句 —— 那会把"我们缺能力"说成"卡坏了"。
RAID_FAULT_FOUND=0
LAST_STATUS=""; LAST_DETAIL=""; verify_dmesg_boot
check "阵列卡那项没判故障时，不许点「同一件事」" "0" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '同一件事')"

# 反面二：日志里的错误根本不是阵列卡那一类时也不许点 ——
# 一台既有坏卡、又另外有内存 MCE 的机器会被说成"都是阵列卡的事"。
printf '[Wed Nov 26 02:16:27 2025] mce: [Hardware Error]: Machine check events logged\n' \
  > "$RAW_DIR/dmesg-pre.txt"
RAID_FAULT_FOUND=1
LAST_STATUS=""; LAST_DETAIL=""; verify_dmesg_boot
check "日志里没有阵列卡那一类错误时，不许点「同一件事」" "0" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '同一件事')"
RAID_FAULT_FOUND=0

# ================================================================
echo
echo "=== 硬盘温度：没跑硬盘压测时不许说成「压测结束时」 ==="
# 现场 99% 会跳过硬盘压测（客户不让往盘里写破坏性数据）。这时候盘并没有被压过，
# 写"压测结束时温度"会让客户以为我们烤过盘。CPU/内存那一轮照样跑了十几分钟、
# 机箱确实热过，读数有意义，只是不能说成是硬盘压测的结果。
RAW_DIR="$TMP/dtemp"; RUN_DIR="$TMP/dtemp"
rm -rf "$RAW_DIR"; mkdir -p "$RAW_DIR/smart-pre" "$RAW_DIR/smart-post"
SMART_TARGETS=("sda")
printf '{"temperature_c":31,"smart_passed":true}\n' > "$RAW_DIR/smart-pre/sda.norm.json"
printf '{"temperature_c":33,"smart_passed":true}\n' > "$RAW_DIR/smart-post/sda.norm.json"

DISK_CONFIRMED=0
LAST_STATUS=""; LAST_DETAIL=""; verify_disk_temp
check "跳过了硬盘压测 -> 说「测试结束时」" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '测试结束时')"
check "跳过了硬盘压测 -> 不许说「压测结束时」" "0" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '压测结束时')"
check "判定不受影响" "PASS" "$LAST_STATUS"

DISK_CONFIRMED=1
LAST_STATUS=""; LAST_DETAIL=""; verify_disk_temp
check "真跑了硬盘压测 -> 照旧说「压测结束时」" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '压测结束时')"
DISK_CONFIRMED=0
SMART_TARGETS=()

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

# 1.7.5 起 check_pcie_link 要先分得清板载和插槽，没有 DMI 插槽表就判 SKIP。
# 这里先给它一张插槽表：27:00.0 和 c8:00.0 都是"Bus Address 填卡自己"那种写法。
cat > "$RAW_DIR/dmidecode.txt" <<'EOF'
Handle 0x0900, DMI type 9, 17 bytes
System Slot Information
	Designation: OCP/Slot2_CPU0
	Type: x8 PCI Express 2
	Current Usage: In Use
	Bus Address: 0000:27:00.0

Handle 0x0901, DMI type 9, 17 bytes
System Slot Information
	Designation: Slot9_CPU1
	Type: x16 PCI Express 4
	Current Usage: In Use
	Bus Address: 0000:c8:00.0
EOF

LAST_STATUS=""; check_pcie_link
check "两个端点都满速 -> PASS（桥的降速不算数）" "PASS" "$LAST_STATUS"

# 把 4090 改成插在 x8 槽、且只训练到 Gen1
sed -i 's/^\t\tLnkSta:\tSpeed 16GT\/s, Width x16/\t\tLnkSta:\tSpeed 2.5GT\/s, Width x8/' "$RAW_DIR/lspci-vv.txt"

# ---- 1.9.8：**只有空闲快照的时候不许判 WARN** ----
#
# 这一条钉的是 1.9.7 现场那次误报。同一台 6530、同一张 4090、同一个槽，
# 连测六轮读出来是 16 / 2.5 / 2.5 / 2.5 / 16 / 2.5 GT/s —— 硬件一个螺丝
# 都没动，判定结果却是掷骰子。一次空闲快照本来就不能当判据。
rm -f "$RAW_DIR/pcie-link-samples.txt"
LAST_STATUS=""; LAST_DETAIL=""; check_pcie_link
check "只有空闲快照、一条加载态读数都没有 -> 不判 WARN" "PASS" "$LAST_STATUS"
check "但数值仍要如实报出来（不判 ≠ 不说）" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c 'c8:00.0')"
check "而且要说明为什么不作结论" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '不对它们作出结论')"

# ---- 加载态一直没回满 -> 这才是真的降速，照报 ----
cat > "$RAW_DIR/pcie-link-samples.txt" <<'EOF'
27:00.0 5 8
c8:00.0 2.5 8
c8:00.0 2.5 8
c8:00.0 2.5 8
EOF
LAST_STATUS=""; LAST_DETAIL=""; check_pcie_link
check "全程复读也没回满 -> WARN" "WARN" "$LAST_STATUS"
check "WARN 文案里要点名是哪个设备" "1" "$(printf '%s' "$LAST_DETAIL" | grep -c 'c8:00.0')"
check "WARN 文案要讲清判据是全程最好的一次读数" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '最好')"
check "既然已经按加载态判了，就不许再把核实推给看报告的人" "0" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '请对照')"

# ---- 空闲时掉档、加载后回满 -> 正常的省电行为，一个字都不该报 ----
cat > "$RAW_DIR/pcie-link-samples.txt" <<'EOF'
c8:00.0 2.5 8
c8:00.0 16 16
c8:00.0 2.5 8
EOF
LAST_STATUS=""; LAST_DETAIL=""; check_pcie_link
check "加载后回满额定 -> PASS（这就是 4090 那个误报）" "PASS" "$LAST_STATUS"
check "回满了就不许再提这张卡" "0" "$(printf '%s' "$LAST_DETAIL" | grep -c 'c8:00.0')"

# ---- 纯函数：全程最好的一次 ----
check "pcie_link_best 取全程最大值和采样条数" "16 16 3" \
      "$(pcie_link_best "$RAW_DIR/pcie-link-samples.txt" c8:00.0)"
check "pcie_link_best 对没采到的设备给 0 0 0" "0 0 0" \
      "$(pcie_link_best "$RAW_DIR/pcie-link-samples.txt" 99:00.0)"
check "pcie_link_best 采样文件不存在时也不崩" "0 0 0" \
      "$(pcie_link_best "$RAW_DIR/nope.txt" c8:00.0)"
check "pcie_sysfs_path 给 domain 0 的 BDF 补上前缀" \
      "/sys/bus/pci/devices/0000:c8:00.0" "$(pcie_sysfs_path c8:00.0)"
check "pcie_sysfs_path 对已经带 domain 的原样放行" \
      "/sys/bus/pci/devices/10000:01:00.0" "$(pcie_sysfs_path 10000:01:00.0)"

rm -f "$RAW_DIR/lspci-vv.txt"
LAST_STATUS=""; check_pcie_link
check "没有 lspci-vv 数据 -> SKIP" "SKIP" "$LAST_STATUS"

# ================================================================
echo
echo "=== PCIe 链路：板载集成设备不参与判定，插槽上的卡照常判 ==="
# 1.7.4 那台海光：**板载**千兆口协商到 x2（额定 x4），报告里报了个 WARN。
# 板载走线宽度是主板厂商的设计，现场既拔不下来也插不进去 —— 那条 WARN 只会
# 让客户以为机器有毛病。而插槽上的卡降速是能修的（没插到底/插错槽/riser 差），
# 必须照报。这一组钉的就是这条分界线。
#
# DMI 的三种填法全都要认，样本取自两台真机：
#   端点式：Bus Address 就是卡自己       27:00.0（6530 的 OCP 网卡）
#   桥式  ：Bus Address 是插槽那个桥     26:05.0 -> 后面挂着 28:00.0 阵列卡
#   空槽  ：Bus Address 在 lspci 里没有  00:01.1（海光那台的 J8）
RAW_DIR="$TMP/pcieslot"; RUN_DIR="$TMP/pcieslot"
rm -rf "$RAW_DIR"; mkdir -p "$RAW_DIR"

cat > "$RAW_DIR/dmidecode.txt" <<'EOF'
Handle 0x0900, DMI type 9, 17 bytes
System Slot Information
	Designation: OCP/Slot2_CPU0
	Type: x8 PCI Express 2
	Current Usage: In Use
	Bus Address: 0000:27:00.0

Handle 0x0901, DMI type 9, 17 bytes
System Slot Information
	Designation: RAID_Slot1
	Type: x8 PCI Express 3
	Current Usage: In Use
	Bus Address: 0000:26:05.0

Handle 0x0902, DMI type 9, 17 bytes
System Slot Information
	Designation: J8
	Type: x4 PCI Express
	Current Usage: Available
	Bus Address: 0000:00:01.1
EOF

cat > "$RAW_DIR/lspci-vv.txt" <<'EOF'
00:01.6 PCI bridge [0604]: Chengdu Haiguang IC Design Co., Ltd. PCIE GPP Bridge [1d94:1453] (prog-if 00 [Normal decode])
	Bus: primary=00, secondary=03, subordinate=03, sec-latency=0
	Capabilities: [58] Express (v2) Root Port (Slot-), MSI 00
		LnkCap:	Port #6, Speed 8GT/s, Width x4, ASPM L1, Exit Latency L1 <64us
		LnkSta:	Speed 5GT/s, Width x2
26:05.0 PCI bridge [0604]: Intel Corporation Device [8086:352a] (rev 30) (prog-if 00 [Normal decode])
	Bus: primary=26, secondary=28, subordinate=28, sec-latency=0
	Capabilities: [40] Express (v2) Root Port (Slot+), MSI 00
		LnkCap:	Port #9, Speed 32GT/s, Width x8, ASPM not supported
		LnkSta:	Speed 8GT/s, Width x8
03:00.0 Ethernet controller [0200]: Beijing Wangxun Technology Co., Ltd. WX1860A2 Gigabit Ethernet Controller [8088:0101] (rev 01)
	Capabilities: [80] Express (v2) Endpoint, MSI 00
		LnkCap:	Port #0, Speed 5GT/s, Width x4, ASPM L0s L1, Exit Latency L0s <1us, L1 <2us
		LnkSta:	Speed 5GT/s, Width x2 (downgraded)
03:00.1 Ethernet controller [0200]: Beijing Wangxun Technology Co., Ltd. WX1860A2 Gigabit Ethernet Controller [8088:0101] (rev 01)
	Capabilities: [80] Express (v2) Endpoint, MSI 00
		LnkCap:	Port #0, Speed 5GT/s, Width x4, ASPM L0s L1, Exit Latency L0s <1us, L1 <2us
		LnkSta:	Speed 5GT/s, Width x2 (downgraded)
27:00.0 Ethernet controller [0200]: Intel Corporation 82599ES 10-Gigabit SFI/SFP+ Network Connection [8086:10fb] (rev 01)
	Capabilities: [a0] Express (v2) Endpoint, MSI 00
		LnkCap:	Port #4, Speed 5GT/s, Width x8, ASPM L0s, Exit Latency L0s <1us
		LnkSta:	Speed 5GT/s, Width x8
27:00.1 Ethernet controller [0200]: Intel Corporation 82599ES 10-Gigabit SFI/SFP+ Network Connection [8086:10fb] (rev 01)
	Capabilities: [a0] Express (v2) Endpoint, MSI 00
		LnkCap:	Port #4, Speed 5GT/s, Width x8, ASPM L0s, Exit Latency L0s <1us
		LnkSta:	Speed 5GT/s, Width x8
28:00.0 Serial Attached SCSI controller [0107]: Broadcom / LSI MegaRAID SAS-3 3108 [Invader] [1000:005d] (rev 02)
	Capabilities: [b0] Express (v2) Endpoint, MSI 00
		LnkCap:	Port #0, Speed 8GT/s, Width x8, ASPM not supported
		LnkSta:	Speed 8GT/s, Width x8
EOF

SMAP="$(pcie_slot_map "$RAW_DIR/dmidecode.txt" "$RAW_DIR/lspci-vv.txt")"
slot_of() { printf '%s\n' "$SMAP" | awk -F'|' -v b="$1" '$1==b{print $2; exit}'; }

check "端点式：DMI 直接写了 27:00.0 -> 插槽"       "slot"    "$(slot_of 27:00.0)"
check "端点式：同一张卡的第二个功能也算插槽（DMI 只列 function 0）" \
      "slot" "$(slot_of 27:00.1)"
check "桥式：26:05.0 后面的 28:00.0 阵列卡 -> 插槽" "slot"    "$(slot_of 28:00.0)"
check "板载：海光那两个千兆口 -> 板载"             "onboard" "$(slot_of 03:00.0)"
check "板载：第二个口也是板载"                     "onboard" "$(slot_of 03:00.1)"
check "空槽 J8（00:01.1 在 lspci 里根本没有）不许盖住任何设备" "0" \
      "$(printf '%s\n' "$SMAP" | grep -c 'J8')"
check "桥自己不出现在分类表里" "0" \
      "$(printf '%s\n' "$SMAP" | grep -cE '^(00:01\.6|26:05\.0)\|')"
check "插槽名要带出来（内部报告靠它显示卡在第几槽）" "1" \
      "$(printf '%s\n' "$SMAP" | grep -c '^28:00\.0|slot|RAID_Slot1$')"

# ---- 判定：板载降速不进客户报告 ----
LAST_STATUS=""; LAST_DETAIL=""; check_pcie_link
check "只有板载口降速 -> 不报 WARN" "PASS" "$LAST_STATUS"
for b in 03:00.0 03:00.1; do
  check "板载口 $b 不许出现在客户可见文案里" "0" \
        "$(printf '%s' "$LAST_DETAIL" | grep -c "$b")"
done
# ⚠️ 这里必须先 cat 再 grep：文件不存在时 `grep -c` 一个字都不输出（退出码 2），
# 于是断言比的是 "0" vs ""，永远红。cat 空输入时 grep -c 老老实实给 0。
check "板载降速也不许进「其他实测指标」（那张表同样在客户报告里）" "0" \
      "$(cat "$RUN_DIR/metrics.jsonl" 2>/dev/null | grep -c '03:00' || true)"
check "但工程留档里必须有它，而且标着 onboard" "2" \
      "$(grep -cE '^03:00\.[01] +onboard' "$RAW_DIR/pcie-link.txt" || true)"
check "插槽上那三张卡照常留档" "3" \
      "$(grep -cE '^(27:00\.[01]|28:00\.0) +slot' "$RAW_DIR/pcie-link.txt" || true)"

# ---- 反过来：插槽上的卡降速，必须照报 ----
# 豁免扩大化是这条最危险的失败方式：放过板载的同时顺手把插槽也放过，
# 于是"卡没插到底"这种真能修的问题从此再没人看得到。
sed -i 's/^\t\tLnkSta:\tSpeed 8GT\/s, Width x8$/\t\tLnkSta:\tSpeed 8GT\/s, Width x4/' "$RAW_DIR/lspci-vv.txt"
# 加载态复读也一直是 x4（阵列卡不会因为省电砍宽度，这就是真的没插到底）
cat > "$RAW_DIR/pcie-link-samples.txt" <<'EOF'
28:00.0 8 4
28:00.0 8 4
EOF
LAST_STATUS=""; LAST_DETAIL=""; check_pcie_link
check "插槽上的阵列卡降到 x4 -> 照常 WARN" "WARN" "$LAST_STATUS"
check "WARN 文案里要点名 28:00.0" "1" "$(printf '%s' "$LAST_DETAIL" | grep -c '28:00\.0')"
check "同一份文案里仍然不许出现板载口" "0" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '03:00\.')"

# ---- 固件没给插槽表：分不清就不判，绝不拿板载走线去吓客户 ----
printf 'Handle 0x0001, DMI type 1, 27 bytes\nSystem Information\n\tManufacturer: X\n' \
  > "$RAW_DIR/dmidecode.txt"
LAST_STATUS=""; LAST_DETAIL=""; check_pcie_link
check "固件没提供插槽信息 -> SKIP（不是 WARN）" "SKIP" "$LAST_STATUS"
check "SKIP 文案要说明不影响整机结论" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '不影响整机结论')"

# ---- 插槽都是空的（海光那台就是这样）----
cat > "$RAW_DIR/dmidecode.txt" <<'EOF'
Handle 0x0900, DMI type 9, 17 bytes
System Slot Information
	Designation: J8
	Type: x4 PCI Express
	Current Usage: Available
	Bus Address: 0000:00:01.1
EOF
LAST_STATUS=""; check_pcie_link
check "插槽全空、只有板载设备 -> SKIP（没有需要判定的链路）" "SKIP" "$LAST_STATUS"

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
# 现场实证：同一台机器连测两次，第一次卡在 lspci 里还看得见，
# 第二次卡坏到 PCI 枚举都过不去、lspci 里整个消失，判「未安装阵列卡」。
#
# 1.7.0 的对策是"BMC 传感器全哑就抬成 WARN"。1.7.7 改了两点：
#   接线修好了（原来靠 $(raid_bmc_hint) 传标志位，命令替换是子 shell，传不出来）
#   接通之后发现这个判据**分不开「没装卡」和「卡坏到不枚举」**，
#   于是每台没装卡的好机器都会吃一条告警 —— 所以状态一律 SKIP，
#   提示改走屏幕 / klburn.log / raw 留档。断言钉的就是"不许再抬 WARN"。
RAW_DIR="$TMP/raid-absent"; RUN_DIR="$TMP/raid-absent"
rm -rf "$RAW_DIR"; mkdir -p "$RAW_DIR"
: > "$RAW_DIR/lspci.txt"                      # lspci 里一张卡都没有
cp "$TMP/ipmi-sdr-noraid.txt" "$RAW_DIR/ipmi-sdr.txt"   # BMC 传感器全哑
IPMI_OK=1
LAST_STATUS=""; LAST_DETAIL=""; collect_raid
check "BMC 预留了 RAID 传感器却全无读数 -> 仍然 SKIP，不许抬成 WARN" \
      "SKIP" "$LAST_STATUS"
check "客户可见文案里只写「未安装阵列卡」" "未安装阵列卡" "$LAST_DETAIL"
check "而那条提示要落进 raw 留档（给内部报告和现场看）" "1" \
      "$([[ -s "$RAW_DIR/raid-bmc-note.txt" ]] && echo 1 || echo 0)"

# 反过来：BMC 传感器有读数时，连留档都不该有
RAW_DIR="$TMP/raid-absent2"; RUN_DIR="$TMP/raid-absent2"
rm -rf "$RAW_DIR"; mkdir -p "$RAW_DIR"
: > "$RAW_DIR/lspci.txt"
cp "$TMP/ipmi-sdr-hasraid.txt" "$RAW_DIR/ipmi-sdr.txt"
LAST_STATUS=""; LAST_DETAIL=""; collect_raid
check "BMC 上传感器有读数 -> SKIP，且不落那份留档" "SKIP" "$LAST_STATUS"
check "不该凭空落留档" "0" \
      "$([[ -e "$RAW_DIR/raid-bmc-note.txt" ]] && echo 1 || echo 0)"

RAW_DIR="$TMP"; RUN_DIR="$TMP"

# ================================================================
echo
echo "=== 阵列卡：驱动没能接管 vs 我们没有管理工具 ==="
#
# 1.8.1 现场那台 Supermicro X11DPG-QT（Montage Jintide C5218R）逼出来的。
# 新装的一张 MegaRAID SAS-3 3108 固件挂在 FAULT state，驱动连试两次都没接管，
# 整张卡不可用 —— 而「阵列卡」那一项报的是
#   SKIP ...（当前测试环境的管理工具不支持该型号）...此项不影响整机结论
# 把**一张坏卡**说成了**我们的工具不行**。
#
# 这是 §2-2 的反面：「能力缺失 ≠ 硬件故障」防的是误伤好机器，
# 而**把硬件故障粉饰成能力缺失，是把坏机器放出厂**，更糟。
#
# 判据：内核里有这张卡的驱动（Kernel modules）却没接管（无 Kernel driver in use）。
# 两条都要，成对断言钉在下面。

# ---- 纯函数：正反样本 ----
cat > "$TMP/lspci-unbound.txt" <<'EOF'
86:00.0 Serial Attached SCSI controller [0107]: Broadcom / LSI MegaRAID SAS-3 3108 [Invader] [1000:005d] (rev 02)
	Subsystem: Super Micro Computer Inc MegaRAID SAS-3 3108 [Invader] [15d9:0a09]
	Region 0: I/O ports at d000 [size=256]
	Kernel modules: megaraid_sas
EOF
check "有驱动却没接管 -> 命中（这就是那张坏卡）" "1" \
      "$(raid_unbound_devices "$TMP/lspci-unbound.txt" | grep -c . || true)"
check "命中行里要带得出型号（报告文案要用）" "1" \
      "$(raid_unbound_devices "$TMP/lspci-unbound.txt" | grep -c 'MegaRAID SAS-3 3108' || true)"

cat > "$TMP/lspci-bound.txt" <<'EOF'
63:00.0 RAID bus controller [0104]: Broadcom / LSI MegaRAID SAS-3 3316 [Intruder] [1000:00ce] (rev 01)
	Kernel driver in use: megaraid_sas
	Kernel modules: megaraid_sas
EOF
check "驱动接管了的好卡 -> 不许命中" "0" \
      "$(raid_unbound_devices "$TMP/lspci-bound.txt" | grep -c . || true)"

# §2-2 红线：内核里压根没这张卡的驱动 = **我们**的能力缺失，绝不能判成卡坏了
cat > "$TMP/lspci-nodriver.txt" <<'EOF'
17:00.0 RAID bus controller [0104]: Exotic Vendor MegaThing 9000 [abcd:1234] (rev 01)
	Region 0: Memory at e0e00000 (64-bit, non-prefetchable) [size=64K]
EOF
check "内核里没有这张卡的驱动 -> 不许命中（那是我们缺能力，不是卡坏了）" "0" \
      "$(raid_unbound_devices "$TMP/lspci-nodriver.txt" | grep -c . || true)"

# 射程不许外溢到别的设备类
cat > "$TMP/lspci-other.txt" <<'EOF'
81:00.0 Ethernet controller [0200]: Realtek RTL8111 [10ec:8168] (rev 15)
	Kernel modules: r8169
98:00.0 VGA compatible controller [0300]: NVIDIA Corporation GB202 [10de:2b85] (rev a1)
	Kernel modules: nvidiafb, nouveau
EOF
check "网卡/显卡没绑驱动也不许命中（只管阵列卡和 HBA）" "0" \
      "$(raid_unbound_devices "$TMP/lspci-other.txt" | grep -c . || true)"

# ---- 走完整的 collect_raid，验最终判定和文案 ----
RAW_DIR="$TMP/raid-dead"; RUN_DIR="$TMP/raid-dead"
rm -rf "$RAW_DIR"; mkdir -p "$RAW_DIR"
grep -m1 '^86:00.0' "$TMP/lspci-unbound.txt" > "$RAW_DIR/lspci.txt"
cp "$TMP/lspci-unbound.txt" "$RAW_DIR/lspci-vv.txt"
: > "$RAW_DIR/ipmi-sdr.txt"
KLB_TOOLS="$TMP/tools-none"; mkdir -p "$KLB_TOOLS"
LAST_STATUS=""; LAST_DETAIL=""; collect_raid
check "驱动没接管这张卡 -> FAIL（不能再说成「工具不支持」）" "FAIL" "$LAST_STATUS"
check "文案里要点明驱动没能接管" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '驱动未能接管' || true)"
check "而且绝不能再出现「管理工具不支持该型号」这种甩锅说法" "0" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '管理工具不支持' || true)"
check "也绝不能再写「此项不影响整机结论」" "0" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '不影响整机结论' || true)"
check "要告诉客户后面的盘也看不到（这才是他真正关心的后果）" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '硬盘在操作系统里也看不到' || true)"

# 反面：驱动接管了、只是没有对得上的管理工具 -> 还是 SKIP，文案照旧
RAW_DIR="$TMP/raid-toolgap"; RUN_DIR="$TMP/raid-toolgap"
rm -rf "$RAW_DIR"; mkdir -p "$RAW_DIR"
grep -m1 '^63:00.0' "$TMP/lspci-bound.txt" > "$RAW_DIR/lspci.txt"
cp "$TMP/lspci-bound.txt" "$RAW_DIR/lspci-vv.txt"
: > "$RAW_DIR/ipmi-sdr.txt"
LAST_STATUS=""; LAST_DETAIL=""; collect_raid
check "驱动接管了、只是缺管理工具 -> 仍然 SKIP（能力缺失不判故障）" "SKIP" "$LAST_STATUS"
check "这种情况才该说「管理工具不支持该型号」" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '管理工具不支持' || true)"
check "而且要写明不影响整机结论" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '不影响整机结论' || true)"

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
echo "=== 启动 U 盘的排除：三层里只有一层挡得住 Ventoy ==="
# scan_disks 把盘分成"可以交给 fio 写"和"绝对不碰"。判错方向只有一个后果：
# **fio 把启动 U 盘写穿** —— 测试盘当场报废、历史报告全丢，而且不可逆。
#
# 排除有三层，看着重复，其实各管一段：
#   rm=1（可移动）        普通 U 盘
#   有分区被挂载          正在用的系统盘
#   live_media_disks      ← Ventoy 专属。它拿 dm-mapper 把 ISO 和 exFAT 包了一层，
#                           而那个 dm 设备 udev 不处理、lsblk 完全看不见，
#                           于是**前两层同时落空**：U 盘的 rm 报 0、
#                           分区也不显示为已挂载。这时候只剩走 sysfs slaves 链的
#                           live_media_disks 还认得出来。
#
# 下面的 fixture 就照 Ventoy 那个形状造：rm=0、hotplug=0、没有挂载点、有分区表。
# 这块盘在 lsblk 眼里和一块普通的空盘一模一样。
KLB_LIB="$LIB"    # core.sh 里写死 /opt/klburn/lib，测试环境里没有那个路径

cat > "$TMP/lsblk-ventoy.json" <<'EOF'
{"blockdevices":[
 {"name":"sda","path":"/dev/sda","type":"disk","size":32000000000,"model":"Ventoy USB",
  "serial":"VT001","rota":false,"tran":"usb","rm":false,"hotplug":false,"pttype":"gpt",
  "children":[{"name":"sda1","type":"part","mountpoints":[null]}]},
 {"name":"vda","path":"/dev/vda","type":"disk","size":2000000000000,"model":"REAL DISK",
  "serial":"RD001","rota":true,"tran":"sata","rm":false,"hotplug":false,"pttype":null,
  "children":[]}
]}
EOF
lsblk() { cat "$TMP/lsblk-ventoy.json"; }

excluded_why() {   # <盘名> -> 排除理由；没被排除就是空
  local want="$1" e
  for e in "${DISK_EXCLUDED[@]:-}"; do
    [[ "$e" == "/dev/$want|"* ]] && { printf '%s' "${e##*|}"; return; }
  done
}

live_media_disks() { printf 'sda\n'; }
scan_disks >/dev/null 2>&1
check "Ventoy 形状的启动盘（rm=0、没挂载）必须被排除" \
      "the KLBurn USB stick itself" "$(excluded_why sda)"
check "排除掉启动盘之后，真实盘还得留在可测列表里" "/dev/vda" "${DISK_CAND[*]:-}"
check "被排除的盘绝不能同时出现在 fio 的目标里" "0" \
      "$(printf '%s' "${DISK_CAND[*]:-}" | grep -c 'sda' || true)"
# 已挂载的真实盘不压测，但 SMART 还是要采 —— 启动 U 盘则连 SMART 都不进
check "启动 U 盘不进 SMART 采集列表（它不是被测机器的硬件）" "0" \
      "$(printf '%s' "${DISK_SMART[*]:-}" | grep -c 'sda' || true)"

unset -f lsblk live_media_disks

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

# ---------------------------------------------------------------- 多厂商管理工具
# 一张阵列卡只有对得上的那个厂商工具认得：Dell PERC 要 perccli、
# HPE Smart Array 要 ssacli、Adaptec 要 arcconf、IT 模式的 LSI HBA 要 sas3ircu。
# 盘里带哪几个由 vendor/ 决定，一个都不带也是常态。
#
# ⚠️ **这几个二进制我们手上没有，下面全是桩。** 桩能验的是"代码路径对不对"
#    ——挨个试、命中即用、都不命中就 SKIP——**验不了真工具的输出格式**。
#    所以这里一条断言都不要写成"我们验证过 arcconf 能读某某卡"。
FAKE_TOOLS="$TMP/faketools"
rm -rf "$FAKE_TOOLS"; mkdir -p "$FAKE_TOOLS"
KLB_TOOLS="$FAKE_TOOLS"

# capture 在上面 dmesg 那一节被打成 `:` 了，raid_tool_run 拿它落原始输出，
# 所以这里换一个"真的会写文件"的桩，内容由 FAKE_TOOL_OUT 控制。
FAKE_TOOL_OUT=""
capture() {
  while [[ "${1:-}" == "-t" ]]; do shift 2; done
  local out="$RAW_DIR/$1"
  mkdir -p "$(dirname "$out")"
  printf '%s\n' "$FAKE_TOOL_OUT" > "$out"
}

run_raid() {          # 结果落在 LAST_STATUS / LAST_DETAIL 上，不能进 $( )
  LAST_STATUS=""; LAST_DETAIL=""
  collect_raid >/dev/null 2>&1
}

# 一个工具都没带（vendor/ 空着）—— 最常见的情况
FAKE_TOOL_OUT="(command not found)"
run_raid
check "一个厂商工具都没带 -> SKIP（不是 FAIL：少带工具不是机器的毛病）" \
      "SKIP" "$LAST_STATUS"

# 带了 ssacli，而且它认到了卡
printf '#!/bin/sh\nexit 0\n' > "$FAKE_TOOLS/ssacli"; chmod +x "$FAKE_TOOLS/ssacli"
FAKE_TOOL_OUT="Smart Array P408i-a SR Gen10 in Slot 12"
run_raid
check "带了对得上的工具、它认到卡 -> PASS" "PASS" "$LAST_STATUS"
check "PASS 的文案里要说读到了固件版本和逻辑盘状态" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '固件版本与逻辑盘状态')"
for forbidden in "ssacli" "arcconf" "perccli" "sas3ircu" "storcli" "vendor/"; do
  check "命中之后的文案里也不许出现工具名「${forbidden}」" "0" \
        "$(printf '%s' "$LAST_DETAIL" | grep -c "$forbidden" || true)"
done

# 带了工具，但它认不了这张卡（换个牌子的卡就是这样）——**照样 SKIP，不许 FAIL**
FAKE_TOOL_OUT="Error: No controllers detected."
run_raid
check "带了工具但认不了这张卡 -> 仍然 SKIP（不是 FAIL）" "SKIP" "$LAST_STATUS"
check "认不了的时候文案还是要报出 PCI 反查到的型号" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c 'MegaRAID SAS-3 3108')"

# 顺序：storcli 先试，它命中了就不该再去试别家（raw/ 文件名是报告生成器认的）
chain="$(declare -f collect_raid)"
check "storcli 必须排在 RAID_TOOL_ORDER 之前（它的 raw/ 文件名报告生成器认死了）" \
      "yes" \
      "$(if [[ "$(grep -n 'storcli-show.txt' <<<"$chain" | head -1 | cut -d: -f1)" \
               -lt "$(grep -n 'RAID_TOOL_ORDER' <<<"$chain" | head -1 | cut -d: -f1)" ]]; \
         then echo yes; else echo no; fi)"
check "每个列进 RAID_TOOL_ORDER 的工具都要在 raid_tool_run 里有对应分支" "0" \
      "$(missing=0
         body="$(declare -f raid_tool_run)"
         for t in "${RAID_TOOL_ORDER[@]}"; do
           grep -qF "$t)" <<<"$body" || missing=$(( missing + 1 ))
         done
         printf '%s' "$missing")"

unset -f capture run_raid
capture() { :; }                    # 还原成上面 dmesg 那一节用的那个桩
KLB_TOOLS="$TMP/no-such-tools"

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
# 后半段那几个是**采集/压测工具的名字**。1.8.4 之前这张表只有 storcli 一个
# 工具名（因为只有它咬过人），于是「stressapptest 测试 246632MB」「或 ethtool
# 读不到速率」这类文案一路印到客户手上 —— 判据和 storcli 那条一模一样，
# 只是没人把词加进来。工具名一律按 §2-1「盘里带了什么工具」处理。
# ⚠️ 工具名这一组**要成组维护，不要只加"咬过人的那个"**。
#
# 1.8.4 把工具名加进来时是一个一个凭印象加的，于是 `fio` 漏了 ——
# 而 stress_disk 里两句「fio 报告 I/O 错误」「fio 异常退出」就这么一直
# 大摇大摆地进客户报告，直到 1.9.0 才被发现。判据对每个工具名都一样：
# **盘里带的是哪个工具，客户不需要知道**（docs/report-policy.md §6-2）。
# 加新工具（尤其是 vendor/ 里的闭源件）时，同一批就把名字加到这里。
FORBIDDEN='测试盘|盘内|精简版|构建目录|重新出盘|vendor/|storcli|README|源码|commit|ISO 里|打包进|未正确安装|stressapptest|stress-ng|gpu_burn|nvidia-smi|dmidecode|ethtool|smartctl|ipmitool|fio|lspci|lsblk|numactl|turbostat|weasyprint|mstflint|lldpctl|rasdaemon|edac-util|bandwidthTest|p2pBandwidth|xlinpack|mlc_avx512'

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
# ⚠️ 已知的一个粗糙之处，踩之前先知道：Python 里的三引号 docstring 会被
#    `"[^"]*"` 当成**一个巨大的字符串**整块取出来，里面只要同时有中文和工具名
#    就会误报（1.7.7 写 raid_vd_of 的说明时踩过）。docstring 进不了报告，
#    但这条守卫看不出来。**解法是把那种说明写成 # 注释，不是放宽这里** ——
#    放宽它就等于给"长文案藏在续行里"那类漏网重新开门。
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
# 这里调的是 collect.sh 里真的那个 megaraid_pd_ids（本文件后面才把它换成桩，
# 那是给 smart_targets_build 那组用例用的）。shellcheck 只看文件、看不到 source
# 进来的定义，于是把"先调用、后定义"当成了错误。
# ⚠️ 后面那个桩一旦被挪到这行之前，这三组有界试探的用例就全在测桩，会静悄悄地绿。
# shellcheck disable=SC2218
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

# 默认档位不能变：现场 30 秒不按键就按它跑，改错了没人会立刻发现。
#
# 1.9.5 起改成**真调一次**那张键→档位的表（_select_duration_apply），
# 不再 grep `default_key="2"` —— 那个变量在把倒计时循环抽成 menu_pick 之后
# 就不在 select_duration 里了，而 grep 找不到时这条断言只会说"默认档变了"，
# 指向一个完全不存在的问题。调用真函数则不管怎么重构都成立。
(
  # shellcheck source=/dev/null
  source "$LIB/ui.sh" 2>/dev/null || true
  DURATION_PROFILE=""; DURATION_SECONDS=0
  _select_duration_apply "" >/dev/null 2>&1
  printf '%s %s\n' "$DURATION_PROFILE" "$DURATION_SECONDS"
) > "$TMP/dur-default.txt" 2>/dev/null
check "倒计时结束的默认档位必须是 STANDARD（30 分钟）" "STANDARD 1800" \
      "$(cat "$TMP/dur-default.txt" 2>/dev/null)"
# 菜单把 2 当默认键交给 menu_pick，而 2 又落在上面那张表的 STANDARD 上 ——
# 两头都钉住，改任何一头都跑红。
check "范围菜单和时长菜单都必须有倒计时兜底（无人值守不能停在等按键的屏上）" "2" \
      "$(grep -cE '^[[:space:]]*chosen="\$\(menu_pick ' "$UI_SH" || true)"
check "时长菜单的默认键是 2" "1" \
      "$(grep -cE 'menu_pick 2 "\$\{DURATION_MENU_TIMEOUT' "$UI_SH" || true)"
check "范围菜单的默认键是 1（全量）" "1" \
      "$(grep -cE 'menu_pick 1 "\$\{SCOPE_MENU_TIMEOUT' "$UI_SH" || true)"

# ================================================================
echo
echo "=== 测试范围：范围 -> 判定项的映射（1.9.5）==="
#
# 这张表就是这个功能的全部语义。下面把它**再写一遍**（独立于 core.sh 里的
# 实现），两边必须逐格对得上 —— 改一格就是改一次产品行为，
# 而"某个部件在某个范围下悄悄不跑了"是没有任何人会发现的那类改动。
#
# 每行：<判定组> <这个组会在哪些范围下跑>
scope_spec() {
  cat <<'EOF'
inventory     full cpu mem gpu disk info
platform      full cpu mem gpu disk info
conform       full cpu mem gpu disk info
nic           full cpu mem gpu disk info
gpu_health    full gpu info
bench_cpu     full cpu info
bench_mem     full mem info
bench_gpu     full gpu info
bench_disk    full disk info
validate_cpu  full cpu
validate_gpu  full gpu
stress_cpu    full cpu
stress_mem    full mem
stress_gpu    full gpu
stress_disk   full disk
verify_ecc    full cpu mem
verify_throttle full cpu
verify_disk   full disk
verify_common full cpu mem gpu disk
EOF
}

n_cells=0
bad_cells=""
while read -r group allow; do
  [[ -n "$group" ]] || continue
  for s in full cpu mem gpu disk info; do
    n_cells=$(( n_cells + 1 ))
    want=no; [[ " $allow " == *" $s "* ]] && want=yes
    got=no;  scope_runs "$group" "$s" && got=yes
    [[ "$want" == "$got" ]] || bad_cells="$bad_cells ${group}/${s}(期望$want)"
  done
done < <(scope_spec)
check "范围映射表逐格对得上（共 $n_cells 格）" "" "$bad_cells"
check "映射表真的被逐格验过了（不是零格空转）" "114" "$n_cells"

# 认不出来的组名一律**跑**。新加判定忘了登记的后果应该是"多跑一项"，
# 而不是"那条结论从报告里静悄悄消失"—— 后者没有任何人会发现。
for s in full cpu mem gpu disk info; do
  check "没登记的判定组在 $s 下默认要跑" "yes" \
        "$(scope_runs some_brand_new_check "$s" && echo yes || echo no)"
done

# 一个都不压的范围只有 info。scope_has_stress 是主流程用来决定
# "要不要选时长、要不要进 PHASE 3、要不要做测后复查"的总开关。
for s in full cpu mem gpu disk; do
  check "$s 要跑压测" "yes" "$(scope_has_stress "$s" && echo yes || echo no)"
done
check "info 一个压测都不跑" "no" "$(scope_has_stress info && echo yes || echo no)"

# ---- 目录名后缀 ----
# ⚠️ **只能是 ASCII**：这个串要当 exFAT 目录名，也会打在 Linux 文本控制台上
#    （1.7.2 那一屏 ◆◆◆ 就是中文进了控制台）。
for s in full cpu mem gpu disk info; do
  t="$(scope_tag "$s")"
  check "scope_tag $s 非空" "yes" "$([[ -n "$t" ]] && echo yes || echo no)"
  check "scope_tag $s 只含 ASCII 字母" "$t" \
        "$(printf '%s' "$t" | LC_ALL=C tr -cd 'A-Za-z')"
  l="$(scope_label "$s")"
  check "scope_label $s 只含可打印 ASCII" "$l" \
        "$(printf '%s' "$l" | LC_ALL=C tr -cd '\40-\176')"
done
check "六个范围的后缀两两不同（撞了就等于没加后缀）" "6" \
      "$(for s in full cpu mem gpu disk info; do scope_tag "$s"; echo; done | sort -u | grep -c .)"

# 目录名末尾必须带范围后缀 —— 这是"半年后还分得清这份报告测过什么"的
# 唯一线索（报告文件名跟着目录名走）。
tag_cpu="$(KLB_SCOPE=cpu get_machine_tag 20260810_101500 cpu)"
check "get_machine_tag 末尾带范围后缀" "yes" \
      "$([[ "$tag_cpu" == *_CPU ]] && echo yes || echo no)"
check "目录名仍然以 日期_时间 开头（e2e 和批次工具都按这个形状认）" "yes" \
      "$([[ "$tag_cpu" =~ ^[0-9]{8}_[0-9]{6}_.+ ]] && echo yes || echo no)"
check "目录名里不许有非 ASCII" "$tag_cpu" \
      "$(printf '%s' "$tag_cpu" | LC_ALL=C tr -cd '\40-\176')"

# ---- 三处范围名单必须一致 ----
# shell 认的键、交付报告的中文表、批次工具的中文表 —— 三处对不上的后果和
# BOGUS 名单那次一模一样：一边认、一边不认，而且不会有任何报错。
#
# ⚠️ 判据只能是**解析出那张 SCOPE_CN 表**再比键，不能拿 `grep '"cpu":'` 去数 ——
#    同一个文件里 SCOPE_COVER / PROFILE_TEXT 也有一模一样形状的行，
#    数出来是 2、3，而那条断言只会说"少了/多了一个中文名"，指向一个不存在的问题。
SUMMARY_PY="$(cd "$LIB/../../../.." && pwd)/tools/klburn-summary.py"
scope_cn_keys() {
  python3 - "$1" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^SCOPE_CN\s*=\s*\{(.*?)^\}", src, re.S | re.M)
d = dict(re.findall(r'"(\w+)":\s*"([^"]+)"', m.group(1))) if m else {}
print("|".join("%s=%s" % kv for kv in sorted(d.items())))
PYEOF
}
GEN_SCOPES="$(scope_cn_keys "$GEN_PY")"
SUM_SCOPES="$(scope_cn_keys "$SUMMARY_PY")"
check "交付报告里的 SCOPE_CN 正好是那六个范围" \
      "cpu=CPU 专项测试|disk=硬盘专项测试|full=全量老化测试|gpu=显卡专项测试|info=仅导出硬件信息|mem=内存专项测试" \
      "$GEN_SCOPES"
check "批次工具的 SCOPE_CN 和交付报告逐个一致（对不上的后果和 BOGUS 名单那次一样）" \
      "$GEN_SCOPES" "$SUM_SCOPES"
# shell 那边认的键也必须是同一套 —— 三处对不上时不会有任何报错
for s in full cpu mem gpu disk info; do
  check "shell 认识范围 $s" "yes" "$(scope_valid "$s" && echo yes || echo no)"
  check "交付报告里有 $s 的中文名" "yes" \
        "$([[ "$GEN_SCOPES" == *"${s}="* ]] && echo yes || echo no)"
done
check "shell 不认识瞎编的范围" "no" "$(scope_valid nonsense && echo yes || echo no)"

# ---- 硬盘专测那道闸门 ----
#
# ⚠️⚠️ **KLB_SCOPE=disk 只是让破坏性写确认必然被问到，绝不是让它跳过。**
#    往裸设备写数据会毁掉盘上原有内容，confirm_disk_write 是唯一的闸门。
#    这条断言钉的是"没有任何一条路径能在不问的情况下把 DISK_CONFIRMED 置 1"。
FT_SH="$LIB/../factory-test.sh"
check "DISK_CONFIRMED=1 在主流程里只有一处" "1" \
      "$(grep -c '^\s*DISK_CONFIRMED=1\s*$' "$FT_SH" || true)"
# ⚠️ 别写成 `... | grep -q ...`：grep -q 命中就关管道，上游吃 SIGPIPE 退 141，
#    而本脚本开着 pipefail，整条管道于是返回失败 —— 输出短的时候时好时坏。
#    先接进变量再比（同一个坑 1.9.5 在 test-screen-render 里真踩到过）。
_dc_ctx="$(grep -B1 '^\s*DISK_CONFIRMED=1\s*$' "$FT_SH" || true)"
check "那一处必须紧跟在 confirm_disk_write 的成功分支里" "yes" \
      "$(case "$_dc_ctx" in *'if confirm_disk_write'*) echo yes ;; *) echo no ;; esac)"
# 两处：一处是"要不要问破坏性写确认"，一处是"要不要真跑 fio"。
# 两处都得在，缺前一处 = 硬盘专测不问就跑，缺后一处 = 问了却不跑。
check "破坏性写确认和硬盘压测两段都由 scope_runs stress_disk 管" "2" \
      "$(grep -c 'scope_runs stress_disk' "$FT_SH" || true)"

# ---- 两道确认必须是**同一种交互**（1.9.9）----
#
# 1.9.8 之前第一关是"打 yes 再回车"，第二关却是**单键**（`[y]` / `[n]`，
# 按下去立刻擦盘）。现场反馈是"第一遍 yes 没毛病，第二遍不知道该打 y 还是 yes"
# —— 同一件事在相邻两屏上换了两种交互，本身就是个坑；而且单键那种按下去的
# 一瞬间就开始擦盘，**连反悔的余地都没有**，比第一关还危险。
# 现在两关都是整行读（read_line_countdown），都必须回车才生效。
_ST_SH="$LIB/storage.sh"
_confirm="$(declare -f confirm_disk_write)"
check "两道确认都必须走整行读（不许有单键读）" "2" \
      "$(printf '%s\n' "$_confirm" | grep -c 'read_line_countdown' || true)"
check "确认面板里不许再出现单键读（按下去就擦盘，没有反悔余地）" "0" \
      "$(printf '%s\n' "$_confirm" | grep -c 'read -r -s -t 1 -n 1' || true)"
# 第二关接受 y 和 yes 两种写法（现场记不住到底该打哪个，两个都认）
check "第二关要认单个 y" "1" \
      "$(grep -cF '"${norm2,,}" == "y"' "$_ST_SH" || true)"
check "第二关也要认完整的 yes（现场记不住该打哪个，两个都得认）" "1" \
      "$(grep -cF '"${norm2,,}" == "yes"' "$_ST_SH" || true)"
# ⚠️ 但**第一关仍然只认 yes**：那是整套流程里最外面的一道闸，
#    放宽成单个字母就等于把"手滑按到 y"变成一次真擦盘。
check "第一关仍然只认完整的 yes（不许放宽成 y）" "1" \
      "$(grep -c '"${norm,,}" != "yes"' "$_ST_SH" || true)"
check "面板上不许再印那个多余的 \[n\]（不擦是默认动作，不需要按键）" "0" \
      "$(printf '%s\n' "$_confirm" | grep -c '\[n\]' || true)"
unset _ST_SH _confirm

# ---- 范围里的部件不在这台机器上：直接跳出，判 FAIL ----
#
# 选了显卡专项、插的却是没有独立显卡的机器。1.9.6 之前这种情况一路跑到底、
# 打绿色 PASS，下面还写着"本轮只对显卡做了压力测试与专项诊断"——一项都没做。
check "gpu 范围 + 没有可用显卡 -> 置 SCOPE_ABORT" "1" \
      "$(grep -cE 'if \[\[ "\$KLB_SCOPE" == "gpu" \]\] && \(\( GPU_USABLE == 0 \)\); then' "$FT_SH" || true)"
check "disk 范围 + 没有可测硬盘 -> 置 SCOPE_ABORT" "1" \
      "$(grep -cE 'elif \[\[ "\$KLB_SCOPE" == "disk" \]\] && \(\( \$\{#DISK_CAND\[@\]\} == 0 \)\); then' "$FT_SH" || true)"
check "两档各落一条 scope_target_missing 的 FAIL" "2" \
      "$(grep -c 'result_add "scope_target_missing"' "$FT_SH" || true)"
check "两条判定的状态都必须是 FAIL" "2" \
      "$(grep -A1 'result_add "scope_target_missing"' "$FT_SH" | grep -c 'ST_FAIL' || true)"
# ⚠️ **只管显卡和硬盘。**CPU / 内存不做这件事：没有这两样机器根本开不了机，
#    "选了 CPU 专测却没有 CPU"这件事不存在。多写一档就是凭空多一条误判路径。
check "不许给 cpu / mem 也加这条（没有它们机器开不了机）" "0" \
      "$(grep -cE 'KLB_SCOPE" == "(cpu|mem)" \]\] && \(\(' "$FT_SH" || true)"
# 跳出必须是**真的跳出**。六处：配置核对屏、破坏性写确认（别问一个不会执行的
# 擦盘）、性能基准+专项验证、压测、PCIe 链路判定、测后复查。
# 少守一处的后果是"说跳出了其实还在跑"，比不跳出更难查。
check "SCOPE_ABORT 要挡住六段（核对屏 / 写确认 / 基准 / 压测 / PCIe / 复查）" "6" \
      "$(grep -cE 'SCOPE_ABORT == 0' "$FT_SH" || true)"
# ⚠️ 这条 FAIL 说的是「这一轮作废」，**不是「这台机器坏了」**。
#    没装显卡 / 没有可测盘的机器本身没有任何毛病 —— 两条文案里都必须写明，
#    否则就撞上一号红线（能力缺失 ≠ 硬件故障）。
check "两条文案都要写明这不是硬件故障" "2" \
      "$(grep -c '这不是硬件故障' "$FT_SH" || true)"
# 硬盘那条要把两种情况都说到：真没装盘 / 盘都在使用中
check "硬盘那条要说清楚「盘都在使用中」也算" "1" \
      "$(grep -c '盘都在使用中、不参与破坏性测试' "$FT_SH" || true)"

# ---- 校验清单必须排除还在写的日志 ----
#
# `klburn.log` 在清单生成之后还会被写（"Checksums:"那一行自己就会追加，
# 后面还有整机结论、逐项结果）。不排除的话 `sha256sum -c` 永远报它 FAILED ——
# 五个范围真跑下来每一轮都红在这一条（1.9.6 修）。
# 一份永远校验不过的清单，和没有这份清单是一回事。
check "SHA256SUMS 必须把 klburn.log 排除在外" "1" \
      "$(grep -c "! -name 'klburn.log'" "$FT_SH" || true)"
check "清单里要写明为什么排除它（拿到清单的人得看得懂）" "1" \
      "$(grep -c 'klburn.log 不在清单里' "$FT_SH" || true)"

# ================================================================
echo
echo "=== 汇总入口的调用链不能少人（少一个 = 那项结论从报告里消失）==="
# 这组是变异测试逼出来的：把 verify_disk_temp 从 verify_all 里删掉，
# 上面所有用例照样全绿 —— 因为它们都是直接调函数，没人管它到底有没有被跑。
# 这正是 GPU 那条 bug 的同款病：判定函数还在，只是再也没被调用过，
# 报告里那一项就凭空消失，既不是 PASS 也不是 SKIP，谁也不会注意到。
# declare -f 打出来的函数体不含注释，所以数的是真调用。

for fn in collect_smart verify_smart verify_disk_temp verify_dmesg verify_sel \
          collect_counters verify_ecc verify_throttle verify_aer verify_bmc_sensors; do
  check "verify_all 必须调用 $fn" \
        "yes" "$(declare -f verify_all | grep -q "\b${fn}\b" && echo yes || echo no)"
done

for fn in collect_system check_memory_capacity collect_sensors collect_smart \
          check_nic_selftest net_link_up_all lldp_start collect_nic check_nic_speed net_test \
          collect_ipmi collect_raid check_psu gpu_detect collect_deep collect_counters \
          verify_dmesg_boot; do
  check "collect_all 必须调用 $fn" \
        "yes" "$(declare -f collect_all | grep -q "\b${fn}\b" && echo yes || echo no)"
done

# ---- PCIe 链路判定必须排在压测之后 ----
#
# 1.9.8 起它从 collect_all（PHASE 1）挪到了主流程压测之后 —— 判据是
# "全程最好的一次读数"，在 PHASE 1 判等于又变回拿一次空闲快照定生死。
# 挪回去不会有任何报错，只会静悄悄地把误报放回来，所以这里钉死。
check "check_pcie_link 不许再回到 collect_all 里（那是空闲快照）" "no" \
      "$(declare -f collect_all | grep -q '\bcheck_pcie_link\b' && echo yes || echo no)"
check "主流程里要起 PCIe 链路采样器" "1" \
      "$(grep -c '^  pcie_link_monitor_start$' "$FT_SH" || true)"
check "而且要在判定之前停掉它" "1" \
      "$(grep -c '^  pcie_link_monitor_stop$' "$FT_SH" || true)"
check "主流程里要调用 check_pcie_link" "1" \
      "$(grep -c '^  check_pcie_link$' "$FT_SH" || true)"
check "采样器起在压测之前、判定排在压测之后" "yes" \
      "$( [[ "$(grep -n 'pcie_link_monitor_start' "$FT_SH" | head -1 | cut -d: -f1)" \
             -lt "$(grep -n '^  check_pcie_link$' "$FT_SH" | head -1 | cut -d: -f1)" ]] \
          && echo yes || echo no)"
check "异常退出时也要收掉采样器（否则它会一直往 raw/ 里追加）" "1" \
      "$(grep -c 'pcie_link_monitor_stop 2>/dev/null' "$FT_SH" || true)"

# 上面那两组必须**有能力变红**：这个项目栽过"从没红过的测试等于没写"。
# 拿一个真不存在的函数名喂给同一条判据，它必须给出 no。
check "调用链守卫本身抓得住漏掉的函数（否则上面几十条都是摆设）" "no" \
      "$(declare -f collect_all | grep -q '\bcheck_this_never_exists\b' && echo yes || echo no)"

# 1.9.0 新增的两个汇总入口，同一条道理。
# ⚠️ 这两组比上面那两组还容易漏：它们各是一整个新文件，加一条判定时很自然
#    只顾着写函数，忘了它得先被调用一次才会产生结论。
# bench.sh / gpu.sh 在这里才 source：本套件前面几百条断言不需要它们，
# 提前引入反而可能顶掉某些用例自己搭的桩。
# shellcheck source=/dev/null
source "$LIB/bench.sh"
# shellcheck source=/dev/null
source "$LIB/gpu.sh"
for fn in check_dimm_uniform check_nic_uniform check_disk_uniform check_gpu_uniform \
          check_gpu_ecc check_gpu_remap check_bios_profile check_virtual_dev \
          check_sn_consistency; do
  check "conformance_all 必须调用 $fn" \
        "yes" "$(declare -f conformance_all | grep -q "\b${fn}\b" && echo yes || echo no)"
done
for fn in bench_init bench_gpu_bandwidth bench_gpu_p2p bench_cpu_flops \
          bench_mem_bandwidth bench_disk_bandwidth; do
  check "bench_all 必须调用 $fn" \
        "yes" "$(declare -f bench_all | grep -q "\b${fn}\b" && echo yes || echo no)"
done
# 满载运行状态那条挂在 gpu_stress 收尾处，不在任何汇总入口里 —— 单独钉一下，
# 否则它掉出去了没有任何测试会红（stress_gpu 自己的断言只看 stress_gpu）。
check "gpu_stress 必须在收尾时调用 check_gpu_load_profile" \
      "yes" "$(declare -f gpu_stress | grep -q '\bcheck_gpu_load_profile\b' && echo yes || echo no)"

# factory-test.sh 是脚本不是函数，declare -f 看不到它 —— 直接扫源码，
# 确认这两个汇总入口真的被调用过（少一个 = 整块判定从报告里消失）。
FT="$(cd "$LIB/.." && pwd)/factory-test.sh"
for fn in conformance_all bench_all; do
  check "factory-test.sh 必须调用 $fn" "yes" \
        "$(grep -qE "^[[:space:]]*${fn}( |\$)" "$FT" && echo yes || echo no)"
done
# 校验清单必须**在两份报告和 PDF 都出完之后**才生成 —— 报告自己也在清单里，
# 排在前面的话清单里就没有报告，那它就证明不了"你手上这份和我归档的是同一份"。
check "factory-test.sh 必须生成校验清单" "yes" \
      "$(grep -qE '^[[:space:]]*write_checksums' "$FT" && echo yes || echo no)"
ft_pdf="$(grep -n 'render_pdf "\$INTERNAL_HTML"' "$FT" | head -1 | cut -d: -f1)"
ft_sum="$(grep -n '^write_checksums' "$FT" | head -1 | cut -d: -f1)"
check "校验清单要排在两份 PDF 之后（报告自己也在清单里）" "yes" \
      "$( [[ -n "$ft_pdf" && -n "$ft_sum" && "$ft_pdf" -lt "$ft_sum" ]] && echo yes || echo no )"
# 基准要在压测之前跑：和满载压测同时跑出来的带宽/算力数字没有任何参考价值
check "bench_all 必须排在并发压测之前（空闲时测才有意义）" "yes" \
      "$(if [[ "$(grep -n '^[[:space:]]*bench_all' "$FT" | head -1 | cut -d: -f1)" \
               -lt "$(grep -n 'stress_cpu "\$CPU_SECS"' "$FT" | head -1 | cut -d: -f1)" ]]; \
         then echo yes; else echo no; fi)"

# ---------------------------------------------------------------- 指路要对得上
#
# `bench_disk_bandwidth` 的文案里有一句「逐盘数值见下方「X」」，X 是报告里
# 那张逐盘表的小节标题 —— 而那个标题是**跟着数据动的**：现场没确认破坏性
# 写入时只测得到读，写那一列整个不画，标题也就只写「顺序读」。
#
# 两个字面量分别落在两个文件里（判定文案在 shell、小节标题在 Python），
# 改一边忘了另一边，客户读到的就是一句指向报告里根本不存在的小节的话。
# 这条按**字面量**对账，所以两边都不许把它拼出来（Python 那边有注释说明）。
GEN_PY="$(cd "$LIB/.." && pwd)/report/generate_report.py"
for secname in "硬盘顺序读写带宽" "硬盘顺序读带宽"; do
  check "小节名「${secname}」必须在 bench.sh 和报告生成器里同时存在" "yes yes" \
        "$( { grep -qF "$secname" "$LIB/bench.sh" && printf 'yes' || printf 'no'; } ; printf ' ' ; \
            { grep -qF "$secname" "$GEN_PY" && printf 'yes' || printf 'no'; } )"
done
# 同一条判据必须抓得住不存在的名字，否则上面两条是摆设。
check "小节名对账守卫本身抓得住漏掉的一边" "no no" \
      "$( { grep -qF "硬盘这个小节根本不存在" "$LIB/bench.sh" && printf 'yes' || printf 'no'; } ; printf ' ' ; \
          { grep -qF "硬盘这个小节根本不存在" "$GEN_PY" && printf 'yes' || printf 'no'; } )"

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
# 测后传感器快照必须排在判定之前，否则它读的是**测前**那份 ——
# "压测把风扇跑停了"这一整类事就永远查不出来，而那正是这条判定的理由。
vchain="$(declare -f verify_all)"
# ⚠️ 两个行号都必须**取得到**才算数。上面那一批"谁排在谁前面"的断言都用
#    `[[ "$a" -lt "$b" ]]`，而 bash 在 `[[ ]]` 里把空串当 0 —— 采集那一行整个
#    没了的时候 a 是空、0 < b 成立，断言反而变绿。这一条把空值单独拦掉。
_vpos() { grep -n -- "$1" <<<"$vchain" | head -1 | cut -d: -f1; }
vp_cap="$(_vpos 'ipmi-sensors-post.txt')"; vp_jdg="$(_vpos 'verify_bmc_sensors')"
check "ipmi-sensors-post.txt 的采集必须排在 verify_bmc_sensors 之前" "yes" \
      "$( [[ -n "$vp_cap" && -n "$vp_jdg" && "$vp_cap" -lt "$vp_jdg" ]] && echo yes || echo no )"
# （check_nic_selftest 必须排在 net_link_up_all 之前那一条，在下面
#   「发起和读结果必须都挂在链上」那一组里已经钉着了，不重复。）
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
echo
echo "=== 硬盘信息采集（collect_disk）==="
# 21 个判定 id 里，这是唯一一个单元测试碰不到的 —— 一直只有 QEMU 端到端
# 那台虚拟机在跑它，而虚拟机永远只走"普通盘"那一条分支。
#
# 三条分支都在 collect_smart 的 pre 阶段末尾。最该锁住的是**第一条**：
# 一块盘都没有时判 WARN，不判 FAIL。那是"本机未安装硬盘"，不是"硬盘坏了"
# —— 二号原则（能力缺失 ≠ 硬件故障）。判成 FAIL 就是把一台无盘机器
# （现场真有，出厂只测 CPU/内存/网卡的那种）拦在出货前。
#
# collect_smart 前半段真的会去跑 smartctl / nvme / lsblk，靠两处打桩绕开：
#   capture           上面 dmesg 那一节已经打成 `:` 了，这里顺带用上
#   megaraid_pd_ids   1161 行 unset 之后又是真的那个了，这里按用例重新打桩
# **smart_targets_build 用真的那个** —— 这样连"按 DISK_SMART 展开成采集目标"
# 那一段也一起测了，而且不必在本文件里给它加一个更靠后的定义
# （加了会让 shellcheck 对着 1125 行那个调用报 SC2218）。
megaraid_pd_ids() { :; }       # 默认：没有阵列卡后端物理盘
mkdir -p "$TMP/smart-pre"      # collect_smart 里那句 jq 要往这儿写归一化结果

# 结果落在 LAST_STATUS / LAST_DETAIL 上，所以**不能**放进 $( ) 里调 ——
# 子 shell 里的赋值传不回来，断言会永远拿到空值然后一路绿。
run_collect_disk() {
  DISK_SMART=("$@")
  LAST_STATUS=""; LAST_DETAIL=""
  collect_smart pre >/dev/null 2>&1
}

run_collect_disk
check "一块盘都没有 -> WARN（不是 FAIL：没装盘不等于盘坏了）" "$ST_WARN" "$LAST_STATUS"
check "无盘时文案要说「本机未安装硬盘」" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '本机未安装硬盘')"

run_collect_disk /dev/sda /dev/nvme0n1
check "两块普通盘 -> PASS" "$ST_PASS" "$LAST_STATUS"
check "普通盘的文案要报出盘数" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '共 2 块盘')"
check "普通盘的文案里不该提阵列卡后端物理盘" "0" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '物理盘' || true)"

# 阵列卡后端的物理盘没有 /dev 节点，只能靠 -d megaraid,N 透传去读 ——
# 这条分支就是 v1.2.0 的主功能，而它一次真机都没验过（§12 里写着）。
megaraid_pd_ids() { printf '8\n9\n'; }
run_collect_disk /dev/sda
check "阵列卡后端物理盘 -> PASS" "$ST_PASS" "$LAST_STATUS"
check "采集目标 = 1 块逻辑盘 + 2 块物理盘" "3" "${#SMART_TARGETS[@]}"
check "有阵列卡后端盘时，文案要单独报出物理盘块数" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '共 3 块盘，其中 2 块为阵列卡后端的物理盘')"

# 全局 FORBIDDEN 扫描已经覆盖了 collect.sh 里所有 result_add 的文案，
# 这里对着**真跑出来的那一份** detail 再钉一条：扫描是按源码文本走的，
# 而这条走的是运行时拼出来的字符串（上面那句就是拼的）。
for forbidden in "storcli" "vendor/" "重新出盘" "构建目录" "盘内"; do
  check "collect_disk 的客户可见文案里不许出现「${forbidden}」" "0" \
        "$(printf '%s' "$LAST_DETAIL" | grep -c "$forbidden" || true)"
done

# ================================================================
echo
echo "=== 整机结论：全程最不该出错的那一次判定 ==="
# 屏幕上那个 PASS/FAIL 大字，1.3.0 之前是
#     grep -q '"status":"FAIL"' results.jsonl
# 判出来的。它能用，纯粹因为 jq -cn 的紧凑输出恰好没有空格。格式一变就永远
# 匹配不上，不会有任何报错，表现是**每台机器都显示绿色 PASS** —— 判错方向
# 是把坏机器放出厂，比误伤好机器还糟。这正是 §11 一号不变量
# （不要拿关键字匹配当判定）自己没守住的地方。
#
# 下面**从 factory-test.sh 里把那句 jq 抠出来**再喂样本，而不是在测试里另抄
# 一份 —— 抄一份的话，改坏了生产代码这里照样绿。
FT="$(dirname "${BASH_SOURCE[0]}")/../rootfs/opt/klburn/factory-test.sh"

check "整机结论不许再用 grep 匹配 results.jsonl（不算注释）" "0" \
      "$(grep -n "grep -q .*status.*FAIL" "$FT" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -c .)"

mapfile -t VERDICT_FILTERS < <(grep -oE "jq -e -s '[^']+'" "$FT" | sed -E "s/^jq -e -s '//; s/'$//")
check "抠得到 factory-test.sh 里那两句 jq（一句找 FAIL，一句看有没有结果）" "2" \
      "${#VERDICT_FILTERS[@]}"

# 照抄 factory-test.sh 的两步：有 FAIL -> FAIL；一条判定都没有 -> 也 FAIL
verdict_of() {
  local f="$1"
  jq -e -s "${VERDICT_FILTERS[0]}" "$f" >/dev/null 2>&1 && { echo FAIL; return; }
  jq -e -s "${VERDICT_FILTERS[1]}" "$f" >/dev/null 2>&1 || { echo FAIL; return; }
  echo PASS
}

printf '%s\n' '{"id":"a","status":"PASS"}' '{"id":"b","status":"SKIP"}' \
              '{"id":"c","status":"WARN"}' > "$TMP/v-clean.jsonl"
check "全是 PASS/SKIP/WARN -> 整机 PASS（SKIP 和 WARN 都不拉低结论）" \
      "PASS" "$(verdict_of "$TMP/v-clean.jsonl")"

printf '%s\n' '{"id":"a","status":"PASS"}' '{"id":"b","status":"FAIL"}' > "$TMP/v-fail.jsonl"
check "有一条 FAIL -> 整机 FAIL" "FAIL" "$(verdict_of "$TMP/v-fail.jsonl")"

# 这条就是老写法会栽的地方：同样的语义，只是 JSON 里多了空格
printf '%s\n' '{"id": "a", "status": "FAIL"}' > "$TMP/v-spaced.jsonl"
check "JSON 里带空格照样要判出 FAIL（老的文本匹配在这里会漏判成 PASS）" \
      "FAIL" "$(verdict_of "$TMP/v-spaced.jsonl")"

# 反过来也不能误伤：中文 detail 里出现这串字样时不许当成真有 FAIL
jq -cn '{id:"a",name:"n",status:"WARN",detail:"日志里带 \"status\":\"FAIL\" 字样"}' \
   > "$TMP/v-tricky.jsonl"
check "detail 文案里出现 status/FAIL 字样不算数（只看真正的 status 字段）" \
      "PASS" "$(verdict_of "$TMP/v-tricky.jsonl")"

# 一条判定都没有 != 全都通过。采集阶段就崩了、U 盘写满了、进程被收掉都会走到这里，
# 1.3.0 之前这三种情况全都打出绿色大字 PASS —— 一台什么都没测过的机器看着是合格的。
: > "$TMP/v-empty.jsonl"
check "results.jsonl 是空的 -> 不许判 PASS（这一轮根本没测过）" \
      "FAIL" "$(verdict_of "$TMP/v-empty.jsonl")"
check "results.jsonl 压根不存在 -> 不许判 PASS" \
      "FAIL" "$(verdict_of "$TMP/v-nonexistent.jsonl")"
printf '%s\n' '{"id":"a","status":"PASS"' > "$TMP/v-broken.jsonl"   # 少个右括号
check "results.jsonl 解析不了 -> 不许判 PASS（写到一半断电就是这样）" \
      "FAIL" "$(verdict_of "$TMP/v-broken.jsonl")"

# ================================================================
echo
echo "=== 配置一致性：内存条字段与占位符 ==="
cat > "$TMP/conf-mem.txt" <<'EOF'
Handle 0x0001, DMI type 17, 92 bytes
Memory Device
	Size: 32 GB
	Locator: CPU0_DIMMA0
	Manufacturer: Hynix
	Part Number: HMCG88AGBRA123N
	Configured Memory Speed: 4800 MT/s
	Volatile Size: 32 GB

Handle 0x0002, DMI type 17, 92 bytes
Memory Device
	Size: 32 GB
	Locator: CPU0_DIMMB0
	Manufacturer: Hynix
	Part Number: HMCG88AGBRA123N
	Configured Memory Speed: 4800 MT/s
	Volatile Size: 32 GB

Handle 0x0003, DMI type 17, 92 bytes
Memory Device
	Size: No Module Installed
	Locator: CPU0_DIMMC0
	Manufacturer: NO DIMM
	Part Number: NO DIMM
EOF
check "只数装了条的槽位（空槽的 Part Number 不算一种型号）" "1" \
      "$(dmi_dimm_field "$TMP/conf-mem.txt" "Part Number" | count_uniq)"
check "字段名带空格也要取得对（Configured Memory Speed）" "1" \
      "$(dmi_dimm_field "$TMP/conf-mem.txt" "Configured Memory Speed" | count_uniq)"
check "Volatile Size 那行不能被当成 Size" "2" \
      "$(dmi_dimm_field "$TMP/conf-mem.txt" "Locator" | grep -c .)"

# 占位符必须先过滤再去重：不过滤的话，BIOS 没填 PN 的机器会被判成"混插"
cat > "$TMP/conf-mem-bogus.txt" <<'EOF'
Handle 0x0001, DMI type 17, 92 bytes
Memory Device
	Size: 32 GB
	Locator: A1
	Part Number: HMCG88AGBRA123N

Handle 0x0002, DMI type 17, 92 bytes
Memory Device
	Size: 32 GB
	Locator: A2
	Part Number: Not Specified
EOF
check "占位符要先过滤掉，否则一台内存一致的机器会被判成混插" "1" \
      "$(dmi_dimm_field "$TMP/conf-mem-bogus.txt" "Part Number" | count_uniq)"

echo
echo "=== 设备自己的自检：硬盘 / 网卡（1.9.2）==="
#
# 这两条的共同点：**结论是设备自己给的，我们一个判据都不定。**
# 我们只负责发起、把它说的话转述过来，以及在它没说话的时候老老实实 SKIP。

# ---- 硬盘：smartctl -l selftest（ATA 和 NVMe 两种日志都要认）----
cat > "$TMP/st-ok.txt" <<'EOF'
SMART Self-test log structure revision number 1
Num  Test_Description    Status                  Remaining  LifeTime(hours)  LBA_of_first_error
# 1  Short offline       Completed without error       00%      2143         -
EOF
check "跑完没错 -> ok" "ok" "$(selftest_verdict "$TMP/st-ok.txt")"

cat > "$TMP/st-fail.txt" <<'EOF'
Num  Test_Description    Status                  Remaining  LifeTime(hours)  LBA_of_first_error
# 1  Short offline       Completed: read failure       90%      2143         1953458
EOF
check "盘自己说读失败 -> fail" "fail" "$(selftest_verdict "$TMP/st-fail.txt")"
# ⚠️ "Completed: read failure" 里也有 Completed —— 顺序反了会读成通过。
check "「Completed: read failure」不许被当成通过" "0" \
      "$(selftest_verdict "$TMP/st-fail.txt" | grep -c '^ok$' || true)"

cat > "$TMP/st-run.txt" <<'EOF'
Num  Test_Description    Status                  Remaining  LifeTime(hours)  LBA_of_first_error
# 1  Short offline       Self-test routine in progress 70%      2143         -
EOF
check "还在跑 -> running（我们等不及，不是盘的毛病）" "running" "$(selftest_verdict "$TMP/st-run.txt")"

cat > "$TMP/st-abort.txt" <<'EOF'
Num  Test_Description    Status                  Remaining  LifeTime(hours)  LBA_of_first_error
# 1  Short offline       Interrupted (host reset)      80%      2143         -
EOF
check "被主机打断 -> running（硬盘压测踩的，不是盘坏了）" "running" \
      "$(selftest_verdict "$TMP/st-abort.txt")"

cat > "$TMP/st-nvme.txt" <<'EOF'
Self-test Log (NVMe Log 0x06)
Num  Test_Description  Status                       Power_on_Hours  Failing_LBA  NSID Seg SCT Code
 0   Short             Completed without error                7461            -     -   -   -    -
EOF
check "NVMe 的日志格式也要认（按文字认，不按列号取）" "ok" "$(selftest_verdict "$TMP/st-nvme.txt")"
printf 'Self-test Log (NVMe Log 0x06)\nNo Self-tests Logged\n' > "$TMP/st-none.txt"
check "没有自检记录 -> none（SKIP，不是 FAIL）" "none" "$(selftest_verdict "$TMP/st-none.txt")"
check "文件不存在 -> none" "none" "$(selftest_verdict "$TMP/nope-st.txt")"

# ---- 网卡：ethtool -t ----
printf 'The test result is PASS\nThe test extra info:\nRegister test  (offline)  0\n' \
  > "$TMP/nst-pass.txt"
check "网卡自检通过" "pass" "$(nic_selftest_verdict "$TMP/nst-pass.txt")"
printf 'The test result is FAIL\nThe test extra info:\nEeprom test (offline)  1\n' \
  > "$TMP/nst-fail.txt"
check "网卡自检失败" "fail" "$(nic_selftest_verdict "$TMP/nst-fail.txt")"
# ⚠️ "The test result is FAIL" 里也有 "test result is" —— 顺序反了会读成通过
check "FAIL 不许被当成 PASS" "0" \
      "$(nic_selftest_verdict "$TMP/nst-fail.txt" | grep -c '^pass$' || true)"
printf 'netlink error: Operation not supported\n' > "$TMP/nst-unsup.txt"
check "驱动不实现自检 -> unsupported（SKIP，不是这块卡坏了）" "unsupported" \
      "$(nic_selftest_verdict "$TMP/nst-unsup.txt")"
check "空输出 -> unsupported" "unsupported" "$(nic_selftest_verdict "$TMP/nope-nst.txt")"

# ---- 网卡自检：只有「链路」子项不通过 = 那个口没插网线，不是硬件故障（1.9.3）----
#
# ⚠️ 这一组钉的是 1.9.2 现场那台 6530：整机判 FAIL，理由写的是
#    "该网口存在硬件故障，需更换或返修后复测"，而那个口的报告表格里
#    同时写着"未连接链路（未接网线）"。原始输出一字不改抄在下面 ——
#    五个子项里只有 Link test 是 1，另外四个查卡上硬件的全是 0。
#    `ethtool -t` 的总结论是所有子项的与，所以没插线的口总结论必然 FAIL。
#    **只读总结论 = 把每一个没插网线的口都判成坏网卡。**（二号红线）
cat > "$TMP/nst-nolink.txt" <<'EOF'
The test result is FAIL
The test extra info:
Register test  (offline)	 0
Eeprom test    (offline)	 0
Interrupt test (offline)	 0
Loopback test  (offline)	 0
Link test   (on/offline)	 1
EOF
check "只有链路子项没过 -> link_only（不是 fail）" "link_only" \
      "$(nic_selftest_verdict "$TMP/nst-nolink.txt")"
check "  这条绝不能判成 fail（好机器会被拦在出货前）" "0" \
      "$(nic_selftest_verdict "$TMP/nst-nolink.txt" | grep -c '^fail$' || true)"
check "  子项计数：0 个硬件项失败、1 个网线相关项失败、0 个驱动跑不了" "0 1 0" \
      "$(nic_selftest_subtests "$TMP/nst-nolink.txt")"
# 不带括号的写法（mlx5 / bnxt 这一类）也要认，否则换张卡就又漏了
cat > "$TMP/nst-nolink2.txt" <<'EOF'
The test result is FAIL
The test extra info:
Link Test        1
Speed Test       0
Health Test      0
Interrupt Test   0
Loopback Test    0
EOF
check "不带括号的子项写法也要认" "link_only" \
      "$(nic_selftest_verdict "$TMP/nst-nolink2.txt")"

# ---- 1.9.8：mlx5 的原样输出，这是 1.9.7 现场卡住出货的那一份 ----
#
# ⚠️ 那台 7542 上的 ConnectX-5 两个口都**没插网线**，报告写着
#    「2 个网口自带的自检未通过…说明该网口存在硬件故障，需更换或返修」。
#    1.9.2 认得 Link Test，但 mlx5 还有一条 Speed Test —— 内核里
#    mlx5e_test_link_speed() 头一句就是 `if (!netif_carrier_ok()) return 1`，
#    它和 Link Test 一样是没插网线必然不通过的，名字里却没有 "link"。
#    再加上口是 down 的时候回环自检直接返回 -EOPNOTSUPP（-95），
#    于是"硬件项失败"数一下子变成 2，整机判 FAIL。
cat > "$TMP/nst-mlx5.txt" <<'EOF'
The test result is FAIL
The test extra info:
Link Test          1
Speed Test         1
Health Test        0
Loopback Test    -95
EOF
check "mlx5 没插网线 -> link_only（1.9.7 就是这条判成了硬件故障）" "link_only" \
      "$(nic_selftest_verdict "$TMP/nst-mlx5.txt")"
check "  这条绝不能判成 fail（卡住出货的就是它）" "0" \
      "$(nic_selftest_verdict "$TMP/nst-mlx5.txt" | grep -c '^fail$' || true)"
check "  子项计数：Speed 归网线相关、-95 归驱动跑不了" "0 2 1" \
      "$(nic_selftest_subtests "$TMP/nst-mlx5.txt")"
# 负数单独成立：只有一条负数时不许判成失败（能力缺失 ≠ 硬件故障，一号红线）
printf 'The test result is FAIL\nThe test extra info:\nLoopback Test  -95\n' \
  > "$TMP/nst-nosup.txt"
check "只有驱动跑不了的子项 -> nosupport_only（不是 fail）" "nosupport_only" \
      "$(nic_selftest_verdict "$TMP/nst-nosup.txt")"
# 但真硬件项失败仍然要抓住 —— 豁免扩大化是这条最危险的失败方式
printf 'The test result is FAIL\nThe test extra info:\nSpeed Test 1\nEeprom test 1\n' \
  > "$TMP/nst-mixed.txt"
check "网线相关项 + 真硬件项同时失败 -> 仍然 fail" "fail" \
      "$(nic_selftest_verdict "$TMP/nst-mixed.txt")"

# ---- 兜底那一层：没插网线的口，任何情况下都不判 FAIL ----
#
# 上面几条钉的是**纯函数**怎么拆子项。但那份名单是按我们见过的驱动列的，
# 下一个厂家换一个名字（"Cable Test"？"PHY Test"？）我们又会把一台好机器
# 判成"需更换或返修"。这一组钉的是 check_nic_selftest 里那道兜底：
# **口上没有载波时，卡自己说的 FAIL 只降级成"接上网线复测"，绝不判 FAIL。**
RAW_DIR="$TMP/nicselftest"; RUN_DIR="$TMP/nicselftest"
rm -rf "$RAW_DIR"; mkdir -p "$RAW_DIR/nic" "$TMP/nicbin"

# ⚠️ ethtool 必须做成 **PATH 上的一个假程序**，不能定义成 shell 函数：
#    被测代码里写的是 `timeout 90 ethtool -t ...` —— `timeout` 只认得
#    磁盘上的可执行文件，shell 函数它看不见，桩会被整个绕过去
#    （第一版就是这么写的，结果自检读到空文件、判成 SKIP，用例全红）。
cat > "$TMP/nicbin/ethtool" <<'EOF'
#!/usr/bin/env bash
# 卡自己说 FAIL，但一条子项明细都拆不出来 —— 最坏的那种情况：
# 我们没有任何依据说那是网线的事，全靠"这个口有没有载波"来定。
[[ "${1:-}" == "-t" ]] && { printf 'The test result is FAIL\n'; exit 0; }
exit 1
EOF
chmod +x "$TMP/nicbin/ethtool"
_PATH_SAVE="$PATH"; PATH="$TMP/nicbin:$PATH"

net_phys_ifaces() { printf 'ens9f0\n'; }

net_iface_has_carrier() { return 1; }          # 没插网线
LAST_STATUS=""; LAST_DETAIL=""; check_nic_selftest
check "⚠️ 没插网线 + 卡自己说 FAIL -> 判 WARN，绝不判 FAIL" "WARN" "$LAST_STATUS"
check "  一个 FAIL 都不许出（卡住整批出货的就是它）" "0" \
      "$(printf '%s' "$LAST_STATUS" | grep -c '^FAIL$' || true)"
check "  文案要说明这几个口现场没接网线" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '没有接网线')"
check "  文案要给出下一步（接上线重测）" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '接上网线后重测')"

# 成对断言：**插着网线**的口说 FAIL，那就是真的 FAIL，一条都不许放过。
# 只钉上面那半的话，把整条判定改成"永远 WARN"也能变绿。
net_iface_has_carrier() { return 0; }          # 插着网线
LAST_STATUS=""; LAST_DETAIL=""; check_nic_selftest
check "插着网线 + 卡自己说 FAIL -> 照常判 FAIL（豁免不许扩大化）" "FAIL" "$LAST_STATUS"
check "  文案要写明这个口已接网线（否则和上面那条读起来一样）" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '该口已接网线')"

PATH="$_PATH_SAVE"
unset -f net_phys_ifaces net_iface_has_carrier
# 把被桩顶掉的真函数装回来，别影响后面的用例。
# ⚠️ **只重新 source network.sh，绝不能连 core.sh 一起** —— 本套件自己
#    重定义了 result_add 来抓 LAST_STATUS，把 core.sh 再 source 一遍
#    会把它顶回原版，后面几十条断言全部读到空串（第一版踩过）。
# shellcheck source=/dev/null
source "$LIB/network.sh"
# 反过来：真故障一个都不许放过
cat > "$TMP/nst-hwbad.txt" <<'EOF'
The test result is FAIL
The test extra info:
Register test  (offline)	 1
Link test   (on/offline)	 0
EOF
check "寄存器子项没过 -> fail（这才是真故障，必须拦住）" "fail" \
      "$(nic_selftest_verdict "$TMP/nst-hwbad.txt")"
cat > "$TMP/nst-bothbad.txt" <<'EOF'
The test result is FAIL
The test extra info:
Eeprom test    (offline)	 1
Link test   (on/offline)	 1
EOF
check "硬件项和链路项都没过 -> fail（不许被链路那条捞走）" "fail" \
      "$(nic_selftest_verdict "$TMP/nst-bothbad.txt")"
# 拆不出明细时**不知道**是网线还是硬件 —— 纯函数只如实报"说不清"，
# 由 check_nic_selftest 按这个口有没有载波去定：有网线还说不清就照卡自己的
# 结论判 FAIL，没网线则降级成"接上线复测"。
printf 'The test result is FAIL\n' > "$TMP/nst-nodetail.txt"
check "总结论 FAIL 但没有子项明细 -> unknown_fail（说不清，交给调用方定）" "unknown_fail" \
      "$(nic_selftest_verdict "$TMP/nst-nodetail.txt")"
check "  说不清的时候也不许直接判 pass" "0" \
      "$(nic_selftest_verdict "$TMP/nst-nodetail.txt" | grep -c '^pass$' || true)"
# "Loopback" 里没有 "link"，别把回环项误归到链路那一档
check "Loopback 不许被当成链路项" "fail" \
      "$(printf 'The test result is FAIL\nThe test extra info:\nLoopback test (offline)\t 1\n' \
         > "$TMP/nst-lb.txt"; nic_selftest_verdict "$TMP/nst-lb.txt")"

# ================================================================
echo
echo "=== BMC 的 USB 虚拟网口不参与判定（1.9.8）==="
#
# ⚠️ 1.9.7 现场那台 7542：
#      enxbe3af2b6059f  driver rndis_host  bus-info usb-0000:48:00.3-1.1
#      Link detected: yes   IPv4 169.254.3.1/24   Gateway: -   -> NO_GATEWAY
#    那是主板上 BMC 通过 USB 暴露给系统的带内管理通道，那头没有 DHCP 服务器，
#    **永远拿不到网关** —— 于是每一台带 BMC 的机器都会被我们自己刷一条
#    「网卡连通性 WARN」，还把"共 N 个物理网口"多数一个。
check "USB 总线上的网口 -> 虚拟口" "yes" \
      "$(net_iface_is_virtual usb rndis_host && echo yes || echo no)"
# ⚠️ 这一条**只能靠总线判**：驱动名不在下面那张表里，两条判据里只有
#    "挂在 USB 上"能成立。少了它，换一颗 USB 网卡芯片就又漏进判定了。
check "USB 上但驱动不认识 -> 仍然是虚拟口（只靠总线也要判得出来）" "yes" \
      "$(net_iface_is_virtual usb ax88179_178a && echo yes || echo no)"
check "光看驱动也要认得出来（读不到 subsystem 的内核兜底）" "yes" \
      "$(net_iface_is_virtual '' rndis_host && echo yes || echo no)"
for d in cdc_ether cdc_ncm cdc_eem usbnet; do
  check "  $d 同样是虚拟口" "yes" \
        "$(net_iface_is_virtual '' "$d" && echo yes || echo no)"
done
# 反过来：真网卡一个都不许被误伤 —— 豁免扩大化的后果是网卡整项没人测了
check "PCI 上的 Intel 万兆口 -> 真网口" "no" \
      "$(net_iface_is_virtual pci ixgbe && echo yes || echo no)"
check "PCI 上的 ConnectX-5 -> 真网口" "no" \
      "$(net_iface_is_virtual pci mlx5_core && echo yes || echo no)"
check "两样都读不到时按真网口算（宁可多测一个，不可漏测一个）" "no" \
      "$(net_iface_is_virtual '' '' && echo yes || echo no)"

# 169.254 是没拿到 DHCP 时自己编的地址，不是租约
check "169.254 是链路本地地址" "yes" \
      "$(net_addr_is_linklocal 169.254.3.1 && echo yes || echo no)"
check "正常的内网地址不是" "no" \
      "$(net_addr_is_linklocal 192.168.110.147 && echo yes || echo no)"
check "空串不是（不能把'读不到'当成链路本地）" "no" \
      "$(net_addr_is_linklocal '' && echo yes || echo no)"

# ================================================================
echo
echo "=== 校时：内网也要能对上时间（1.9.8）==="
#
# ⚠️ 1.9.7 现场那台 7542 网是通的（ping 网关 4/4 通、0.525ms），但那个网
#    出不了公网，三个公网 NTP 全部拨不通，报告日期停在一个八个月前的假日期上。
#    DHCP 下发的 NTP 服务器（option 42）是内网机器最靠谱的一条路。
cat > "$TMP/dhclient.leases" <<'EOF'
lease {
  interface "eno1";
  fixed-address 192.168.110.147;
  option subnet-mask 255.255.255.0;
  option routers 192.168.110.1;
  option ntp-servers 192.168.110.1, 192.168.110.9;
  option domain-name-servers 192.168.110.1;
}
EOF
check "从 DHCP 租约里抠出 NTP 服务器" "192.168.110.1
192.168.110.9" "$(net_dhcp_ntp_servers "$TMP/dhclient.leases")"
printf 'lease {\n  interface "eno1";\n  option routers 10.0.0.1;\n}\n' \
  > "$TMP/dhclient-nontp.leases"
check "租约里没有 NTP 那一项时给空（不能把 routers 当成 NTP）" "" \
      "$(net_dhcp_ntp_servers "$TMP/dhclient-nontp.leases")"
check "租约文件不存在时也不崩" "" "$(net_dhcp_ntp_servers "$TMP/nope.leases")"

# ---- 发起和读结果必须都挂在链上，而且顺序不能反 ----
check "collect_all 必须发起硬盘自检" "yes" \
      "$(declare -f collect_all | grep -q '\bdisk_selftest_start\b' && echo yes || echo no)"
check "verify_all 必须去读硬盘自检的结果（否则盘白跑一遍）" "yes" \
      "$(declare -f verify_all | grep -q '\bverify_disk_selftest\b' && echo yes || echo no)"
check "collect_all 必须跑网卡自检" "yes" \
      "$(declare -f collect_all | grep -q '\bcheck_nic_selftest\b' && echo yes || echo no)"
# 网卡 offline 自检会把链路踢下去 —— 排在拉链路之后的话，
# 后面 DHCP 拿到的是一个刚被自己踢掉的链路，好机器会被判成"网口不通"。
cchain="$(declare -f collect_all)"
_cpos() { grep -n -- "$1" <<<"$cchain" | head -1 | cut -d: -f1; }
cp_st="$(_cpos 'check_nic_selftest')"; cp_up="$(_cpos 'net_link_up_all')"
check "check_nic_selftest 必须排在 net_link_up_all 之前（自检会踢链路）" "yes" \
      "$( [[ -n "$cp_st" && -n "$cp_up" && "$cp_st" -lt "$cp_up" ]] && echo yes || echo no )"
# 自检发起要用 collect_smart 读通那次的 -d，所以必须排在它后面
cp_ss="$(_cpos 'disk_selftest_start')"; cp_cs="$(_cpos 'collect_smart "pre"')"
check "disk_selftest_start 必须排在 collect_smart pre 之后（要用它落的 .dtype）" "yes" \
      "$( [[ -n "$cp_ss" && -n "$cp_cs" && "$cp_cs" -lt "$cp_ss" ]] && echo yes || echo no )"

echo
echo "=== BMC 部件传感器 vs 主板自己写的阈值（1.9.2）==="
#
# ⚠️ 这是全项目唯一一处"拿阈值去判"的地方，而阈值不是我们定的 ——
#    后六列是主板厂商烧进 BMC 的。拿读数去比它，和"我们替客户定标准"
#    是相反的两件事。
#
# 下面这几行是**真机原样**（澜起 C5218R / 海光 7380 的 ipmitool sensor list）。
cat > "$TMP/sensors-ok.txt" <<'EOF'
CPU1 Temp        | 34.000     | degrees C  | ok    | 5.000     | 5.000     | 10.000    | 92.000    | 97.000    | 97.000
VRMCpu1 Temp     | 30.000     | degrees C  | ok    | 5.000     | 5.000     | 10.000    | 95.000    | 100.000   | 105.000
InFAN1_Speed     | 3200.000   | RPM        | ok    | 400.000   | 600.000   | 800.000   | 23000.000 | 25000.000 | 28000.000
PSU1_FanSpeed    | 6000.000   | RPM        | ok    | 200.000   | 400.000   | 600.000   | 36000.000 | 38000.000 | 40000.000
PWR_Button       | 0x0        | discrete   | 0x0080| na        | na        | na        | na        | na        | na
CPU0_Status      | 0x80       | discrete   | 0x8080| na        | na        | na        | na        | na        | na
FAN_Total_Power  | 6.000      | Watts      | ok    | 0.000     | 0.000     | 0.000     | 380.000   | 400.000   | 450.000
Chassis_Intr     | na         | discrete   | na    | na        | na        | na        | na        | na        | na
EOF
check "只判数值型传感器，离散量（读数是 0x80 那种）整条跳过" "5" \
      "$(ipmi_sensor_scan "$TMP/sensors-ok.txt" | grep -c . || true)"
check "好机器上一条都不许亮（十份真机数据实测就是 0 条）" "0" \
      "$(ipmi_sensor_scan "$TMP/sensors-ok.txt" | grep -vc '^ok|' || true)"

# 一颗停转的风扇 —— 工厂最常见的缺陷之一，而它在这张表里是明写着的
cat > "$TMP/sensors-fan.txt" <<'EOF'
InFAN1_Speed     | 3200.000   | RPM        | ok    | 400.000   | 600.000   | 800.000   | 23000.000 | 25000.000 | 28000.000
InFAN2_Speed     | 200.000    | RPM        | lcr   | 400.000   | 600.000   | 800.000   | 23000.000 | 25000.000 | 28000.000
EOF
check "转速掉到主板设定的临界下限以下 -> crit" "1" \
      "$(ipmi_sensor_scan "$TMP/sensors-fan.txt" | grep -c '^crit|' || true)"
check "越线那条要说清楚是低于哪个限、限是多少" "1" \
      "$(ipmi_sensor_scan "$TMP/sensors-fan.txt" | grep -c '低于主板设定的临界下限 600' || true)"
check "没越线的那条照常记成 ok（用来数「共核对了几项」）" "1" \
      "$(ipmi_sensor_scan "$TMP/sensors-fan.txt" | grep -c '^ok|' || true)"

# ⚠️ **读数恰好为 0 一律降一级。**0 既可能是"这个位置没装部件"，也可能是
#    "装了但停转"，从读数上分不开 —— 分不开的东西不该去染客户的结论。
#    这条不降级的话，一台空着两个风扇位的好机器会被判 FAIL。
cat > "$TMP/sensors-zero.txt" <<'EOF'
InFAN3_Speed     | 0.000      | RPM        | lcr   | 400.000   | 600.000   | 800.000   | 23000.000 | 25000.000 | 28000.000
EOF
check "读数为 0 -> zero（降级），不是 crit" "1" \
      "$(ipmi_sensor_scan "$TMP/sensors-zero.txt" | grep -c '^zero|' || true)"
check "读数为 0 时不许出现 crit" "0" \
      "$(ipmi_sensor_scan "$TMP/sensors-zero.txt" | grep -c '^crit|' || true)"

# 上告警线（unc）和上临界线（ucr）要分开：一个是 WARN 一个是 FAIL
cat > "$TMP/sensors-temp.txt" <<'EOF'
VRMCpu1 Temp     | 96.000     | degrees C  | unc   | 5.000     | 5.000     | 10.000    | 95.000    | 100.000   | 105.000
VRMCpu2 Temp     | 101.000    | degrees C  | ucr   | 5.000     | 5.000     | 10.000    | 95.000    | 100.000   | 105.000
EOF
check "越 non-critical -> warn" "1" \
      "$(ipmi_sensor_scan "$TMP/sensors-temp.txt" | grep -c '^warn|' || true)"
check "越 critical -> crit"     "1" \
      "$(ipmi_sensor_scan "$TMP/sensors-temp.txt" | grep -c '^crit|' || true)"

# 一条阈值都没有的传感器：**跳过**。"没有可比的东西"不等于"没问题"
cat > "$TMP/sensors-nothr.txt" <<'EOF'
Some_Reading     | 42.000     | unspecified| ok    | na        | na        | na        | na        | na        | na
EOF
check "没有任何数值型阈值 -> 整条跳过（不是判 ok）" "0" \
      "$(ipmi_sensor_scan "$TMP/sensors-nothr.txt" | grep -c . || true)"
check "文件不存在 -> 一行都不输出（调用方据此 SKIP）" "0" \
      "$(ipmi_sensor_scan "$TMP/nope-sensors.txt" | grep -c . || true)"

# 文案：单位要换成中文报告里读得下去的写法，传感器名（主板丝印）原样留着
# ⚠️ **上下限那个数也必须带单位。**scan 吐出来的是光秃秃的数字（结构化数据里
#    不塞单位），拼成一句话时要补回去 —— 否则客户读到的是
#    「96 °C，高于主板设定的告警上限 95」：95 什么？
#    和 1.9.1「拆进表格之后单位就没了」是同一个毛病，只是这次是拼漏的。
check "单位换算 + 说清楚量的是什么 + 限值也带单位" \
      "风扇 InFAN2_Speed：200 RPM，低于主板设定的临界下限 600 RPM" \
      "$(ipmi_sensor_phrase "InFAN2_Speed" "200" "RPM" "低于主板设定的临界下限 600")"
check "摄氏度不许原样写 degrees C，限值也要跟着换" \
      "温度 VRMCpu2 Temp：101 °C，高于主板设定的临界上限 100 °C" \
      "$(ipmi_sensor_phrase "VRMCpu2 Temp" "101" "degrees C" "高于主板设定的临界上限 100")"
check "认不出来的单位原样留着，绝不吞信息" "1" \
      "$(ipmi_sensor_phrase "X" "1" "Bogons" "y" | grep -c 'Bogons')"

# ⚠️ **拿十份真机数据全部跑一遍：好机器上一条都不许亮。**
# 一条新判定最危险的失败方式不是漏判，是每台好机器都刷红 —— 那会让整份报告
# 失去可信度，而且没人会先怀疑判据。所以这条守卫直接吃 test_out 下的真文件，
# 有几份吃几份（仓库里没有这些数据时自动跳过，不影响 CI）。
REPO_ROOT="$(cd "$LIB/../../../.." && pwd)"
real_n=0
while IFS= read -r real; do
  [[ -s "$real" ]] || continue
  real_n=$(( real_n + 1 ))
  tag="$(basename "$(dirname "$(dirname "$real")")" | cut -c1-26)"
  check "真机 ${tag}…：可判传感器数 > 0" "yes" \
        "$( [[ "$(ipmi_sensor_scan "$real" | grep -c . || true)" -gt 0 ]] && echo yes || echo no )"
  check "真机 ${tag}…：一条都不许亮" "0" \
        "$(ipmi_sensor_scan "$real" | grep -vc '^ok|' || true)"
done < <(find "$REPO_ROOT/test_out" -name 'ipmi-sensors.txt' 2>/dev/null | sort)
# 自检：上面那个循环真的吃到东西了没有。吃到 0 份也会"全绿"，
# 而那正是"只在玩具输入上为绿"的另一种长相。
check "真机传感器样本至少吃到一份（否则上面整组是空转）" "yes" \
      "$( (( real_n > 0 )) && echo yes || echo no )"

# ---- 判定出口：四态各走一遍 ----
sensor_case() {
  RAW_DIR="$TMP/bmc-case"; RUN_DIR="$RAW_DIR"
  rm -rf "$RAW_DIR"; mkdir -p "$RAW_DIR"
  [[ -n "${1:-}" ]] && printf '%s\n' "$1" > "$RAW_DIR/ipmi-sensors-post.txt"
  LAST_STATUS=""; LAST_DETAIL=""
  IPMI_OK="${2:-1}" verify_bmc_sensors >/dev/null 2>&1
  RAW_DIR="$TMP"; RUN_DIR="$TMP"
}

sensor_case "$(cat "$TMP/sensors-ok.txt")"
check "全部在范围内 -> PASS" "PASS" "$LAST_STATUS"
check "PASS 文案要报出共核对了几项" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '核对 5 项部件传感器')"
check "PASS 文案要点明限是主板设定的（不是我们定的）" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '主板设定的上下限')"

sensor_case "$(cat "$TMP/sensors-fan.txt")"
check "有风扇掉到临界线以下 -> FAIL" "FAIL" "$LAST_STATUS"
check "FAIL 文案要说清是哪一颗、掉到多少、限是多少" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '风扇 InFAN2_Speed：200 RPM，低于主板设定的临界下限 600 RPM')"
check "FAIL 文案里要写明这是部件异常、需检修" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '需检修后复测')"
check "越线的逐条要落一份证据文件" "1" \
      "$(grep -c '^crit|InFAN2_Speed' "$TMP/bmc-case/ipmi-sensor-breach.txt" 2>/dev/null || true)"

# sensors-temp.txt 里一条越告警线、一条越临界线 —— 有 crit 就必须 FAIL，
# 不许被同一批里的 warn 冲淡（"真坏就是坏"）
sensor_case "$(cat "$TMP/sensors-temp.txt")"
check "同一批里既有告警又有临界 -> 整条判 FAIL（不许被冲淡）" "FAIL" "$LAST_STATUS"

cat > "$TMP/sensors-warnonly.txt" <<'EOF'
VRMCpu1 Temp     | 96.000     | degrees C  | unc   | 5.000     | 5.000     | 10.000    | 95.000    | 100.000   | 105.000
CPU1 Temp        | 34.000     | degrees C  | ok    | 5.000     | 5.000     | 10.000    | 92.000    | 97.000    | 97.000
EOF
sensor_case "$(cat "$TMP/sensors-warnonly.txt")"
check "只越告警线 -> WARN（不是 FAIL）" "WARN" "$LAST_STATUS"
check "WARN 文案要写明机器仍可正常工作（配置/关注，不是故障）" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '机器仍可正常工作')"

sensor_case "$(cat "$TMP/sensors-zero.txt")"
check "读数为 0 -> WARN 而不是 FAIL（装没装从读数上分不开）" "WARN" "$LAST_STATUS"
check "0 的文案必须把两种可能都写出来" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '既可能是该位置未安装部件，也可能是部件已停转')"

sensor_case "" 0
check "没有 BMC -> SKIP（不是 FAIL：读不到不是机器的毛病）" "SKIP" "$LAST_STATUS"
check "SKIP 文案要写「此项不影响整机结论」" "1" \
      "$(printf '%s' "$LAST_DETAIL" | grep -c '此项不影响整机结论')"

sensor_case "$(cat "$TMP/sensors-nothr.txt")" 1
check "有 BMC 但一条带阈值的传感器都没有 -> SKIP（不是 PASS）" "SKIP" "$LAST_STATUS"

# 测后那份不在时要退到测前那份，而不是直接 SKIP
RAW_DIR="$TMP/bmc-fallback"; RUN_DIR="$RAW_DIR"
rm -rf "$RAW_DIR"; mkdir -p "$RAW_DIR"
cp "$TMP/sensors-ok.txt" "$RAW_DIR/ipmi-sensors.txt"
LAST_STATUS=""; IPMI_OK=1 verify_bmc_sensors >/dev/null 2>&1
check "只有测前那份时退回去用它（有数据就别 SKIP）" "PASS" "$LAST_STATUS"
RAW_DIR="$TMP"; RUN_DIR="$TMP"

echo
echo "=== 平台设置：x2APIC / VT-d / 子 NUMA 划分 ==="
printf 'x2apic: enabled by BIOS, switching to x2apic ops\nSetting APIC routing to cluster x2apic.\n' \
  > "$TMP/dmesg-x2-on.txt"
printf 'x2apic disabled by BIOS\nAPIC: Switch to symmetric I/O mode setup\n' \
  > "$TMP/dmesg-x2-off.txt"
printf 'Linux version 6.8.0\nnothing about apic here\n' > "$TMP/dmesg-x2-none.txt"
check "内核说开了 -> enabled"        "enabled"  "$(bios_x2apic_state "$TMP/dmesg-x2-on.txt")"
check "内核说被 BIOS 关了 -> disabled" "disabled" "$(bios_x2apic_state "$TMP/dmesg-x2-off.txt")"
check "内核什么都没说 -> unknown，不许猜" "unknown" "$(bios_x2apic_state "$TMP/dmesg-x2-none.txt")"
check "日志文件不存在 -> unknown"     "unknown"  "$(bios_x2apic_state "$TMP/nope-dmesg.txt")"

# VT-d：sysfs 是第一判据（有设备就是真在工作），dmesg 只在 sysfs 读不到时兜底
mkdir -p "$TMP/iommu-on/dmar0" "$TMP/iommu-empty"
printf 'DMAR: IOMMU enabled\n' > "$TMP/dmesg-vtd-on.txt"
printf 'DMAR: No DMAR devices found\n' > "$TMP/dmesg-vtd-off.txt"
check "sysfs 里有 IOMMU 设备 -> enabled" "enabled" \
      "$(bios_vtd_state "$TMP/dmesg-vtd-off.txt" "$TMP/iommu-on")"
check "sysfs 目录在但是空的 -> disabled" "disabled" \
      "$(bios_vtd_state "$TMP/dmesg-vtd-off.txt" "$TMP/iommu-empty")"
check "没有 sysfs 时退回读内核日志" "enabled" \
      "$(bios_vtd_state "$TMP/dmesg-vtd-on.txt" "$TMP/no-such-dir")"
check "两边都读不到 -> unknown" "unknown" \
      "$(bios_vtd_state "$TMP/dmesg-x2-none.txt" "$TMP/no-such-dir")"
# sysfs 目录空着**就是答案**，不许再掉进 dmesg 那两条 grep 里把它变成 unknown。
# 原来写的是"没有 dmesg 才认 disabled"，于是有 dmesg、又没命中任何一条时
# 报的是"读不到"—— 一个已经确定的结论被换成了不确定。
check "sysfs 空目录 + 一份什么都没说的 dmesg -> 仍然是 disabled" "disabled" \
      "$(bios_vtd_state "$TMP/dmesg-x2-none.txt" "$TMP/iommu-empty")"

# ⚠️ **下面这几条用的是真机日志原文。**
# 原来那两条判据（`DMAR: IOMMU enabled` / `AMD-Vi: Found IOMMU`）在
# test_out 的十份真机 run-dir 上**一台都没命中过** —— 6.8 内核不打那两句。
# 也就是说 dmesg 那条兜底路一直是死的，只有测试自己造的字符串喂得进去。
printf '[Mon Aug  3 17:50:32 2026] DMAR: Host address width 52\n[Mon Aug  3 17:50:33 2026] DMAR: Intel(R) Virtualization Technology for Directed I/O\n' \
  > "$TMP/dmesg-vtd-intel-real.txt"
check "真机 Intel/澜起的原话要认得出（DMAR: Intel(R) Virtualization…）" "enabled" \
      "$(bios_vtd_state "$TMP/dmesg-vtd-intel-real.txt" "$TMP/no-such-dir")"
printf '[Tue Aug  4 14:04:29 2026] iommu: Default domain type: Translated\n[Tue Aug  4 14:04:29 2026] iommu: DMA domain TLB invalidation policy: lazy mode\n' \
  > "$TMP/dmesg-vtd-hygon-real.txt"
check "真机海光的原话要认得出（iommu: Default domain type:）" "enabled" \
      "$(bios_vtd_state "$TMP/dmesg-vtd-hygon-real.txt" "$TMP/no-such-dir")"
# 只有 ACPI 表、没有初始化成功那句 = 不能算开着（宁可 unknown，绝不猜）
printf '[Mon Aug  3 22:30:40 2026] ACPI: DMAR 0x000000005D13CB70 000218 (v01 SUPERM)\n[Mon Aug  3 22:30:42 2026] DMAR: DRHD base: 0x000000d37fc000 flags: 0x0\n' \
  > "$TMP/dmesg-vtd-acpionly.txt"
check "只有 ACPI DMAR 表、没有初始化成功那句 -> unknown（不许猜成 enabled）" "unknown" \
      "$(bios_vtd_state "$TMP/dmesg-vtd-acpionly.txt" "$TMP/no-such-dir")"

check "2 路 2 节点 = 每路 1 个"  "1" "$(numa_per_socket 2 2)"
check "2 路 8 节点 = 每路 4 个"  "4" "$(numa_per_socket 8 2)"
check "除不尽时给 0（不许四舍五入出一个假答案）" "0" "$(numa_per_socket 3 2)"
check "读不到插槽数时给 0"       "0" "$(numa_per_socket 4 0)"
check "每路 1 个 = 未启用子 NUMA 划分" "disabled" "$(snc_state 1)"
check "每路 2 个 = SNC2"               "SNC2"     "$(snc_state 2)"
check "每路 4 个 = SNC4"               "SNC4"     "$(snc_state 4)"
check "算不出来时 unknown"             "unknown"  "$(snc_state 0)"

echo
echo "=== 板载网口是不是在 BIOS 里被禁用了 ==="
cat > "$TMP/type41.txt" <<'EOF'
Handle 0x0030, DMI type 41, 11 bytes
Onboard Device
	Reference Designation: Onboard LAN 1
	Type: Ethernet
	Status: Enabled
	Type Instance: 1
	Bus Address: 0000:19:00.0

Handle 0x0031, DMI type 41, 11 bytes
Onboard Device
	Reference Designation: Onboard LAN 2
	Type: Ethernet
	Status: Enabled
	Type Instance: 2
	Bus Address: 0000:19:00.1

Handle 0x0032, DMI type 41, 11 bytes
Onboard Device
	Reference Designation: Onboard VGA
	Type: Video
	Status: Enabled
	Bus Address: 0000:03:00.0
EOF
printf '0000:19:00.0\n0000:65:00.0\n' > "$TMP/netaddrs.txt"
check "板载网口只认 Type: Ethernet（显卡那条不算）" "2" \
      "$(onboard_nic_scan "$TMP/type41.txt" "$TMP/netaddrs.txt" | grep -c .)"
check "系统里能找到的那个口是 active" "1" \
      "$(onboard_nic_scan "$TMP/type41.txt" "$TMP/netaddrs.txt" | grep -c ' active$')"
check "找不到的那个口是 inactive（= BIOS 里禁用了）" "1" \
      "$(onboard_nic_scan "$TMP/type41.txt" "$TMP/netaddrs.txt" | grep -c ' inactive$')"
: > "$TMP/netaddrs-empty.txt"
check "一个网口都没有时，板载口全部算 inactive" "2" \
      "$(onboard_nic_scan "$TMP/type41.txt" "$TMP/netaddrs-empty.txt" | grep -c ' inactive$')"
check "主板不提供 type 41 时输出空（不是判成禁用）" "0" \
      "$(onboard_nic_scan "$TMP/nope-41.txt" "$TMP/netaddrs.txt" | grep -c .)"

# ---- 主板压根没填地址：unknown，不是 inactive（1.9.3）----
#
# ⚠️ 海光那台的 type 41 两条 LAN 全填 `Bus Address: 0000:00:00.0` —— 那是主桥的
#    地址，任何网卡都不可能在那儿。1.9.2 拿它去匹配真网口（0000:03:00.0），
#    一个都对不上，于是报告里写着「板载网口共 2 个，其中 0 个在系统中可用」，
#    而同一份报告里那两个口的型号/固件/链路状态全都采到了。
#    **读不出来的标记不是内容**，不能读成"BIOS 里禁用了"。
cat > "$TMP/type41-placeholder.txt" <<'EOF'
Handle 0x0019, DMI type 41, 11 bytes
Onboard Device
	Reference Designation: LAN1
	Type: Ethernet
	Status: Enabled
	Type Instance: 1
	Bus Address: 0000:00:00.0

Handle 0x001A, DMI type 41, 11 bytes
Onboard Device
	Reference Designation: LAN2
	Type: Ethernet
	Status: Enabled
	Type Instance: 2
	Bus Address: 0000:00:00.0
EOF
printf '0000:03:00.0\n0000:03:00.1\n' > "$TMP/netaddrs-hygon.txt"
check "占位地址 0000:00:00.0 -> unknown" "2" \
      "$(onboard_nic_scan "$TMP/type41-placeholder.txt" "$TMP/netaddrs-hygon.txt" \
         | grep -c ' unknown$')"
check "  绝不能标成 inactive（那等于说 BIOS 里禁用了）" "0" \
      "$(onboard_nic_scan "$TMP/type41-placeholder.txt" "$TMP/netaddrs-hygon.txt" \
         | grep -c ' inactive$')"
check "  真地址不受影响，照旧 active/inactive" "0" \
      "$(onboard_nic_scan "$TMP/type41.txt" "$TMP/netaddrs.txt" | grep -c ' unknown$')"

echo
echo "=== 显卡温度限值：问卡自己要，不是我们定（1.9.3）==="
#
# ⚠️ GPU_TEMP_WARN 原来钉死 83°C。1.9.2 现场那张 RTX 4090 满载峰值 84°C，
#    于是报「温度偏高」—— 而它自己报的最高工作温度就是 84°C，
#    降频在 86、关机在 91。**83 这个数是我们凭空写的。**
#    每代卡、每种散热形态的限值都不一样，只能问卡自己（和 BMC 传感器那条同理）。
#
# Ada 起 nvidia-smi 给的是"余量"（T.Limit）：基准点 = 当前温度 + T.Limit，
# 某个限值的绝对温度 = 基准点 - 它自己那个 T.Limit 值。下面这份是真机原样。
cat > "$TMP/gpu-q-tlimit.txt" <<'EOF'
GPU 00000000:01:00.0
    Temperature
        GPU Current Temp                               : 43 C
        GPU T.Limit Temp                               : 41 C
        GPU Shutdown T.Limit Temp                      : -7 C
        GPU Slowdown T.Limit Temp                      : -2 C
        GPU Max Operating T.Limit Temp                 : 0 C
        GPU Target Temperature                         : 84 C
        Memory Current Temp                            : N/A
EOF
check "余量写法（Ada）：降频 86 / 关机 91" "86 91" \
      "$(gpu_temp_limits "$TMP/gpu-q-tlimit.txt" 0)"
check "  这张卡跑到 84°C 不该算高（84 < 86）" "yes" \
      "$( [[ "$(gpu_temp_limits "$TMP/gpu-q-tlimit.txt" 0 | cut -d' ' -f1)" -gt 84 ]] \
         && echo yes || echo no )"
cat > "$TMP/gpu-q-abs.txt" <<'EOF'
GPU 00000000:17:00.0
    Temperature
        GPU Current Temp                  : 33 C
        GPU Shutdown Temp                 : 92 C
        GPU Slowdown Temp                 : 89 C
        GPU Max Operating Temp            : 85 C
EOF
check "绝对值写法（数据中心卡/老驱动）：89 / 92" "89 92" \
      "$(gpu_temp_limits "$TMP/gpu-q-abs.txt" 0)"
# 多卡：按卡号取各自那一段，别串段
cat "$TMP/gpu-q-abs.txt" "$TMP/gpu-q-tlimit.txt" > "$TMP/gpu-q-2cards.txt"
check "多卡时卡0取第一段" "89 92" "$(gpu_temp_limits "$TMP/gpu-q-2cards.txt" 0)"
check "多卡时卡1取第二段" "86 91" "$(gpu_temp_limits "$TMP/gpu-q-2cards.txt" 1)"
check "问一张不存在的卡 -> 空（退回静态兜底）" "" \
      "$(gpu_temp_limits "$TMP/gpu-q-2cards.txt" 9)"
# ⚠️ 算出来的数必须过常识关。拿一个 15°C 的"降频阈值"去判每张卡的话，
#    每一台带显卡的机器都会被判成散热异常。
cat > "$TMP/gpu-q-junk.txt" <<'EOF'
GPU 00000000:17:00.0
    Temperature
        GPU Current Temp                  : 33 C
        GPU Shutdown Temp                 : 20 C
        GPU Slowdown Temp                 : 15 C
EOF
check "限值离谱（15/20）-> 空，绝不拿它去判" "" \
      "$(gpu_temp_limits "$TMP/gpu-q-junk.txt" 0)"
cat > "$TMP/gpu-q-na.txt" <<'EOF'
GPU 00000000:17:00.0
    Temperature
        GPU Current Temp                  : 33 C
        GPU Shutdown Temp                 : N/A
        GPU Slowdown Temp                 : N/A
EOF
check "驱动给 N/A -> 空" "" "$(gpu_temp_limits "$TMP/gpu-q-na.txt" 0)"
check "文件不存在 -> 空" "" "$(gpu_temp_limits "$TMP/nope-gpuq.txt" 0)"
# 关机温度必须高于降频温度，反了说明我们把两个字段读串了
cat > "$TMP/gpu-q-swapped.txt" <<'EOF'
GPU 00000000:17:00.0
    Temperature
        GPU Shutdown Temp                 : 85 C
        GPU Slowdown Temp                 : 92 C
EOF
check "关机温度低于降频温度 -> 空（读串了就别用）" "" \
      "$(gpu_temp_limits "$TMP/gpu-q-swapped.txt" 0)"

echo
echo "=== 虚拟设备核对 ==="
printf 'flags\t\t: fpu vme de pse tsc msr pae mce cx8 apic hypervisor\n' > "$TMP/cpuinfo-vm.txt"
printf 'flags\t\t: fpu vme de pse tsc msr pae mce cx8 apic sep mtrr\n'   > "$TMP/cpuinfo-bare.txt"
cat > "$TMP/dmisys-vm.txt" <<'EOF'
System Information
	Manufacturer: QEMU
	Product Name: Standard PC (Q35 + ICH9, 2009)
EOF
cat > "$TMP/dmisys-bare.txt" <<'EOF'
System Information
	Manufacturer: Supermicro
	Product Name: SYS-4029GP-TRT
EOF
printf '{"blockdevices":[{"name":"vda","type":"disk"}]}\n' > "$TMP/lsblk-vm.json"
printf '{"blockdevices":[{"name":"sda","type":"disk"}]}\n' > "$TMP/lsblk-bare.json"
printf 'ens3|virtio_net\n' > "$TMP/nicdrv-vm.txt"
printf 'eno1|i40e\neno2|i40e\n' > "$TMP/nicdrv-bare.txt"

check "物理机：一条都不该报" "0" \
      "$(virtual_device_scan "$TMP/cpuinfo-bare.txt" "$TMP/dmisys-bare.txt" \
                             "$TMP/lsblk-bare.json"  "$TMP/nicdrv-bare.txt" | grep -c .)"
check "虚拟机：整机 / 主板 / 硬盘 / 网卡四条都要报出来" "4" \
      "$(virtual_device_scan "$TMP/cpuinfo-vm.txt" "$TMP/dmisys-vm.txt" \
                             "$TMP/lsblk-vm.json"  "$TMP/nicdrv-vm.txt" | grep -c .)"
check "文件全都不存在时也不能崩、也不报虚拟设备" "0" \
      "$(virtual_device_scan "$TMP/nope1" "$TMP/nope2" "$TMP/nope3" "$TMP/nope4" | grep -c .)"

echo
echo "=== 序列号一致性：BMC 那一头 ==="
cat > "$TMP/fru.txt" <<'EOF'
FRU Device Description : Builtin FRU Device (ID 0)
 Chassis Type          : Other
 Chassis Serial        : CHASSIS-0001
 Board Mfg             : Supermicro
 Board Serial          : BOARD-0002
 Product Manufacturer  : Supermicro
 Product Name          : SYS-4029GP-TRT
 Product Serial        : SYS-XYZ-0003
EOF
check "优先取 Product Serial（那才是贴在机器上那个 SN）" "SYS-XYZ-0003" \
      "$(fru_serial "$TMP/fru.txt")"
# 只有主板序列号时要退到主板，不能因为没有 Product Serial 就说读不到
printf ' Board Serial          : BOARD-0002\n' > "$TMP/fru-board.txt"
check "只有主板序列号时退到它" "BOARD-0002" "$(fru_serial "$TMP/fru-board.txt")"
printf ' Product Serial        : To be filled by O.E.M.\n Board Serial : 0123456789\n' \
  > "$TMP/fru-bogus.txt"
check "全是占位符时输出空（不能把 'To be filled by O.E.M.' 当序列号）" "" \
      "$(fru_serial "$TMP/fru-bogus.txt")"
check "没有 BMC 时输出空" "" "$(fru_serial "$TMP/nope-fru.txt")"

echo
echo "=== 显卡一致性 / ECC / 行重映射 ==="
printf 'NVIDIA H100 80GB HBM3,96.00.89.00.01\nNVIDIA H100 80GB HBM3,96.00.89.00.01\n' \
  > "$TMP/gpu-uni-ok.txt"
check "型号和 VBIOS 都一致 -> 各 1 种" "1 1" "$(gpu_uniform_scan "$TMP/gpu-uni-ok.txt")"
printf 'NVIDIA H100 80GB HBM3,96.00.89.00.01\nNVIDIA H100 80GB HBM3,96.00.74.00.01\n' \
  > "$TMP/gpu-uni-bad.txt"
check "VBIOS 两种要认出来" "1 2" "$(gpu_uniform_scan "$TMP/gpu-uni-bad.txt")"
check "文件不存在时给 0 0（-> SKIP，不是「不一致」）" "0 0" \
      "$(gpu_uniform_scan "$TMP/nope-gpu.txt")"

# ECC：不支持 ECC 的卡给的是 [N/A]，**那不是 0**。
# 当成 0 加起来的话，报告会写"ECC 全部正常"——一张压根没有 ECC 的卡被说成没问题。
printf '0, 0, 0, 12, 0\n1, 0, 0, 8, 0\n' > "$TMP/ecc-ok.csv"
check "两张卡都读到数字 -> 有效卡数 2，本次上电计数全 0" "2 0 0" \
      "$(gpu_ecc_scan "$TMP/ecc-ok.csv")"
printf '0, [N/A], [N/A], [N/A], [N/A]\n1, [N/A], [N/A], [N/A], [N/A]\n' > "$TMP/ecc-na.csv"
check "全是 [N/A] -> 有效卡数 0（判 SKIP，不能报成「ECC 正常」）" "0 0 0" \
      "$(gpu_ecc_scan "$TMP/ecc-na.csv")"
printf '0, 3, 0, 3, 0\n1, 0, 2, 0, 2\n' > "$TMP/ecc-bad.csv"
check "可纠正和不可纠正要分开求和" "2 3 2" "$(gpu_ecc_scan "$TMP/ecc-bad.csv")"

# 行重映射的 CSV **没有卡号列**（1.9.4 起）：`--query-remapped-rows` 不认
# `index` 这个字段名，带上它整条查询会被驱动否掉。四列依次是
# correctable / uncorrectable / pending / failure。
printf '0, 0, No, No\n0, 0, No, No\n' > "$TMP/remap-ok.csv"
check "两张卡都干净" "2 0 0 0" "$(gpu_remap_scan "$TMP/remap-ok.csv")"
printf '4, 2, No, No\n0, 0, Yes, No\n' > "$TMP/remap-warn.csv"
check "不可纠正行数求和、待生效按卡数算" "2 2 1 0" "$(gpu_remap_scan "$TMP/remap-warn.csv")"
printf '0, 0, No, Yes\n' > "$TMP/remap-fail.csv"
check "重映射失败要单独数出来（那一条判 FAIL）" "1 0 0 1" "$(gpu_remap_scan "$TMP/remap-fail.csv")"
printf '[N/A], [N/A], [N/A], [N/A]\n' > "$TMP/remap-na.csv"
check "不支持行重映射的卡 -> 有效卡数 0（判 SKIP）" "0 0 0 0" \
      "$(gpu_remap_scan "$TMP/remap-na.csv")"
# ⚠️ 这一条钉的是 1.9.3 那个静默失效：查询字段名和驱动对不上时，
#    nvidia-smi 把报错打到 **stdout**，于是 CSV 里躺着一行英文。
#    它必须被当成"没读到"（有效卡数 0 -> SKIP），绝不能被解析成一张卡。
printf 'Field "index" is not a valid field to query.\n' > "$TMP/remap-err.csv"
check "驱动把「字段名不认识」打进 CSV 时不许当成一张卡" "0 0 0 0" \
      "$(gpu_remap_scan "$TMP/remap-err.csv")"
# 查询里**只能**有那四个字段 —— 多一个 index，A100/H100 上这一项就会
# 静悄悄判 SKIP，并对客户断言"该型号无此机制"（一句假话）。
check "check_gpu_remap 的查询里不许再出现 index 字段" "0" \
      "$(grep -c -- '--query-remapped-rows=index' "$LIB/conformance.sh" || true)"
check "上面那条判据本身有能力变红" "1" \
      "$(printf -- '--query-remapped-rows=index,remapped_rows.pending\n' \
         | grep -c -- '--query-remapped-rows=index' || true)"

echo
echo "=== 硬盘型号一致性的分组键 ==="
cat > "$TMP/lsblk-disks.json" <<'EOF'
{"blockdevices":[
 {"name":"sda","type":"disk","tran":"sata","size":960197124096,"model":"INTEL SSDSC2KB960G8","rm":false},
 {"name":"sdb","type":"disk","tran":"sata","size":960197124096,"model":"SAMSUNG MZ7L3960HCJR","rm":false},
 {"name":"nvme0n1","type":"disk","tran":"nvme","size":1920383410176,"model":"SAMSUNG MZQL21T9HCJR","rm":false},
 {"name":"sdc","type":"disk","tran":"usb","size":31000000000,"model":"SanDisk Ultra","rm":true}
]}
EOF
check "按接口+容量分组，U 盘排掉" "3" "$(disk_spec_model "$TMP/lsblk-disks.json" | grep -c .)"
check "同接口同容量的两块盘落在同一组（分组数 1，不是盘数 2）" "1" \
      "$(disk_spec_model "$TMP/lsblk-disks.json" | cut -d'|' -f1 | grep 'sata_960197124096' | sort -u | grep -c .)"
check "那一组里有两种型号（要判 WARN）" "2" \
      "$(disk_spec_model "$TMP/lsblk-disks.json" | awk -F'|' '$1=="sata_960197124096"{print $2}' | count_uniq)"

# 老版本 lsblk 的 rm 是字符串 "1"/"0"，不是布尔。
# 只判 != true 的话 U 盘会混进来，被当成"同规格硬盘型号不一致"
cat > "$TMP/lsblk-oldrm.json" <<'EOF'
{"blockdevices":[
 {"name":"sda","type":"disk","tran":"sata","size":960197124096,"model":"INTEL SSDSC2KB960G8","rm":"0"},
 {"name":"sdc","type":"disk","tran":"usb","size":31000000000,"model":"SanDisk Ultra","rm":"1"}
]}
EOF
check "老 lsblk 把 rm 写成字符串 \"1\" 时也要排掉 U 盘" "1" \
      "$(disk_spec_model "$TMP/lsblk-oldrm.json" | grep -c .)"

# ⚠️⚠️ **`.rm` 判不出"这是不是我们自己那根启动盘"。**
#
# 上面两份 fixture 都把 U 盘写成 rm=true —— 那是**造出来的**输入。
# 真机上实测：我们的启动盘是 `tran=usb` 但 **`rm=false`**（rm 说的是
# "介质可不可换"，不是"挂在 USB 上"）。test_out 那台「没插硬盘」的机器里，
# lsblk 唯一一块 disk 就是它（SA400S37120G, rm=false）。
#
# 只按 rm 过滤的后果，是一台**一块硬盘都没有**的机器拿到一条
# 「硬盘型号一致性 PASS：按接口与容量分为 1 组」，而同一份报告里
# 「硬盘信息采集」写着「本机未安装硬盘」—— 两句话自相矛盾，
# 而且那一组说的是我们自己的盘。
#
# 范围一律取 scan_disks 已经算好的 DISK_SMART[]（§8.2 那套启动盘反查）。
cat > "$TMP/lsblk-usb-notrm.json" <<'EOF'
{"blockdevices":[
 {"name":"sda","type":"disk","tran":"usb","size":120034123776,"model":"SA400S37120G","rm":false},
 {"name":"sdb","type":"disk","tran":"sata","size":960197124096,"model":"INTEL SSDSC2KB960G8","rm":false}
]}
EOF
check "真机形态：rm=false 的启动 U 盘，光靠 .rm 拦不住（这就是那条 bug）" "2" \
      "$(disk_spec_model "$TMP/lsblk-usb-notrm.json" | grep -c .)"
printf 'sdb\n' > "$TMP/scope-one.txt"
check "给了范围就只比范围里的盘" "1" \
      "$(disk_spec_model "$TMP/lsblk-usb-notrm.json" "$TMP/scope-one.txt" | grep -c .)"
check "范围里的那块盘才是被比的那块" "sata_960197124096|INTEL SSDSC2KB960G8" \
      "$(disk_spec_model "$TMP/lsblk-usb-notrm.json" "$TMP/scope-one.txt")"
printf '/dev/sdb\n' > "$TMP/scope-devpath.txt"
check "范围文件写成 /dev/sdb 也认" "1" \
      "$(disk_spec_model "$TMP/lsblk-usb-notrm.json" "$TMP/scope-devpath.txt" | grep -c .)"
# 一块盘都没有的机器：范围是空的，输出必须也是空的 ——
# **绝不能因为"范围空了"就退回全量**，那正是这条 bug 本来的样子。
: > "$TMP/scope-empty.txt"
check "没插硬盘（范围为空）-> 一条都不输出，判 SKIP 而不是拿 U 盘凑一组" "0" \
      "$(disk_spec_model "$TMP/lsblk-usb-notrm.json" "$TMP/scope-empty.txt" | grep -c . || true)"
# 上面那条要是靠 `NR==FNR` 那个惯用法实现的，空范围也会得到 0 ——
# **对的结果、错的理由**。所以再钉一条"范围非空时确实按范围放行"，
# 两条一起才能区分"真的读了范围"和"整条数据流被当成范围吃掉了"。
printf 'sda\n' > "$TMP/scope-usbonly.txt"
check "范围只写 U 盘时就只输出 U 盘那一行（证明范围真的被读进去了）" \
      "usb_120034123776|SA400S37120G" \
      "$(disk_spec_model "$TMP/lsblk-usb-notrm.json" "$TMP/scope-usbonly.txt")"
check "给了范围路径却没有那个文件 -> 宁可不比（不许悄悄退回全量）" "0" \
      "$(disk_spec_model "$TMP/lsblk-usb-notrm.json" "$TMP/no-such-scope.txt" | grep -c . || true)"
# 范围是 scan_disks 算的，不是这里重新发明的
check "check_disk_uniform 必须拿 DISK_SMART 当范围（别再自己判 U 盘）" "yes" \
      "$(declare -f disk_uniform_scope | grep -q 'DISK_SMART' && echo yes || echo no)"
check "check_disk_uniform 必须把范围传给 disk_spec_model" "yes" \
      "$(declare -f check_disk_uniform | grep -q 'disk_spec_model "\$f" "\$scope"' && echo yes || echo no)"

# ================================================================
# 收尾自检：这个脚本会 source 被测的 lib，而 lib 里也有 ok()。
# 万一哪次改动把本脚本的 ok() 顶掉了，后面的断言会照常打勾却不再计数 ——
# 屏幕全绿、总数悄悄少一截，比直接报错难发现得多（已经发生过一次）。
check "ok() 必须还是本脚本自己的那个（否则断言会停止计数）" "yes" \
      "$(declare -f ok | grep -q 'PASS=' && echo yes || echo no)"

echo
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
