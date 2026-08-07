#!/usr/bin/env bash
#
# 报告生成器的渲染回归测试。造一个假的 run-dir 跑一遍 generate_report.py，
# 然后对产出的 HTML 做断言。不需要硬件，只要有 python3：
#
#     ./tests/test-report-render.sh
#
# 锁住的是那些"看起来对但客户会当场问"的东西：
#   - 硬盘的寿命类字段不进这份报告（不参与判定，留在工程数据里）
#   - 没插网线的口不能把 ethtool 的 "Unknown!" 原样打进表格
#   - 硬盘/GPU 没测时二级编号不能跳号（2.1 2.2 2.5）
#   - 装机内存和系统识别内存都要写出来，对不上时才看得出来
#   - 电源要显示每一路有没有进电
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="$ROOT/rootfs/opt/klburn/report/generate_report.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
has()    { grep -qF -- "$2" "$1" && ok "报告含「$2」：$3" || bad "报告应含「$2」：$3"; }
has_no() { grep -qF -- "$2" "$1" && bad "报告不应出现「$2」：$3" || ok "报告不含「$2」：$3"; }
# 和其它套件同名同签名：check <说明> <期望> <实际>
check()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1（期望 [$2] 实际 [$3]）"; }

# 打错断言函数名（比如把 has_no 写成别的套件里才有的 check）不能静悄悄地过去。
# 本脚本不开 set -e，`check: command not found` 只往 stderr 打一行就没了，
# PASS/FAIL 都不动 —— 屏幕上照样"全部通过"，只是少数了几条。
# 这是 §11-13 那条"断言悄悄停止计数"的同款病，实测又踩了一次，所以立个网。
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

command -v python3 >/dev/null 2>&1 || { echo "需要 python3"; exit 1; }

# ================================================================
# 造 run-dir。数据照抄真机（2x Xeon Gold 6530 那台）的形状：
# 装机 4x16GB 但系统只认 31GB、4 个电源里有一路没进电、一个口接线一个口没接。
# ================================================================
RD="$TMP/run"
mkdir -p "$RD/raw/nic" "$RD/raw/smart-pre" "$RD/raw/smart-post"

cat > "$RD/meta.json" <<'EOF'
{
  "klburn_version": "0.1.0",
  "company_name":   "广州市鲲林科技有限公司",
  "base_os":        "Ubuntu Server 24.04.4",
  "build_date":     "2026-07-30 11:17:00",
  "serial":         "TESTSN0001",
  "profile":        "QUICK",
  "planned_secs":   600,
  "elapsed_secs":   609,
  "start_time":     "2025-11-26 02:17:05",
  "end_time":       "2025-11-26 02:27:14",
  "kernel":         "6.8.0-100-generic",
  "budget": { "cpu_secs": 330, "mem_secs": 270, "disk_secs": 0, "gpu_secs": 0 },
  "disk_tested":    "/dev/sda",
  "disk_confirmed": 0,
  "data_partition": "/dev/sdb1",
  "clock_suspect":  1
}
EOF

cat > "$RD/results.jsonl" <<'EOF'
{"id":"collect_system","name":"硬件信息采集","status":"PASS","detail":"采集完成","ref":"","time":"t"}
{"id":"check_mem_cap","name":"内存容量核对","status":"WARN","detail":"DMI 显示装机内存 64GB，系统实际只识别 31GB","ref":"","time":"t"}
{"id":"test_nic","name":"网卡连通性","status":"PASS","detail":"1 个口 ping 通网关","ref":"","time":"t"}
{"id":"check_psu","name":"电源","status":"WARN","detail":"PSU2 未检测到交流输入","ref":"","time":"t"}
{"id":"collect_raid","name":"阵列卡","status":"SKIP","detail":"未安装阵列卡","ref":"","time":"t"}
{"id":"collect_deep","name":"扩展信息留档","status":"PASS","detail":"已完整保存本机的固件版本、插槽、传感器、存储与网络设备的详细参数，供日后追溯。","ref":"","time":"t"}
{"id":"stress_disk","name":"硬盘压力测试","status":"SKIP","detail":"现场选择跳过（直接回车），硬盘信息已采集","ref":"","time":"t"}
{"id":"verify_smart","name":"硬盘 SMART 复查","status":"PASS","detail":"1 块盘压测前后无新增坏道/错误计数","ref":"raw/smart-post/","time":"t"}
{"id":"verify_ecc","name":"内存 ECC 复查","status":"FAIL","detail":"压测期间出现**不可纠正**内存错误：CPU0_DIMM_A1 不可纠正 0->2（新增 2）；不可纠正错误意味着数据已经出错，对应内存条应予更换。","ref":"raw/counters-post.txt","time":"t"}
{"id":"verify_throttle","name":"CPU 热节流复查","status":"WARN","detail":"压测期间 CPU 触发热节流共 12 次（涉及 4 个核心、1 个处理器封装）。热节流是 CPU 的自我保护，出现时会主动降频，因此温度读数可能仍在正常范围。此项不影响整机结论，但建议检查散热后复测。","ref":"raw/counters-post.txt","time":"t"}
{"id":"verify_aer","name":"PCIe 错误计数复查","status":"WARN","detail":"压测期间 PCIe 链路出现可纠正错误：0000:18:00.0 可纠正新增 7；可纠正错误会被链路层自动重传，不影响数据正确性。","ref":"raw/counters-post.txt","time":"t"}
EOF

cat > "$RD/metrics.jsonl" <<'EOF'
{"group":"mem","key":"装机容量MB","value":"65536"}
{"group":"mem","key":"系统识别MB","value":"31763"}
EOF

cat > "$RD/sys_metrics.csv" <<'EOF'
time,phase,cpu_temp_c,cpu_freq_mhz,load1,mem_used_mb,mem_total_mb
02:17:05,cpu,45,1156,8.28,2305,31763
02:17:10,cpu,51,2699,17.87,2764,31763
02:17:15,cpu,66,2681,64.20,2795,31763
02:17:20,cpu,73,2675,99.10,2801,31763
EOF

# ---- dmidecode：4 条 16GB + 2 个电源（一个 OK 一个 Critical）----
{
cat <<'EOF'
Handle 0x0001, DMI type 1, 27 bytes
System Information
	Manufacturer: N/A
	Product Name: 4U GPU Server
	Serial Number: TESTSN0001

Handle 0x0002, DMI type 2, 15 bytes
Base Board Information
	Manufacturer: N/A
	Product Name: 60EA32X
	Serial Number: 24003732DHB00451

Handle 0x0000, DMI type 0, 26 bytes
BIOS Information
	Vendor: American Megatrends International, LLC.
	Version: CSHH2B1080
	Release Date: 05/16/2025

Handle 0x0040, DMI type 4, 48 bytes
Processor Information
	Socket Designation: CPU0
	Manufacturer: Intel(R) Corporation
	Version: INTEL(R) XEON(R) GOLD 6530
	Core Count: 32
	Thread Count: 64
	Max Speed: 4000 MHz
	Current Speed: 2100 MHz
	Status: Populated, Enabled
EOF
for i in 0 1 2 3; do
cat <<EOF

Handle 0x006$i, DMI type 17, 92 bytes
Memory Device
	Size: 16 GB
	Locator: CPU0_DIMM${i}
	Type: DDR5
	Configured Memory Speed: 4800 MT/s
	Manufacturer: Hynix
	Part Number: HMCG78MEBRA174N
	Serial Number: 80AD0122069$i
	Rank: 1
	Volatile Size: 16 GB
EOF
done
cat <<'EOF'

Handle 0x0070, DMI type 17, 92 bytes
Memory Device
	Size: No Module Installed
	Locator: CPU0_DIMM4

Handle 0x005D, DMI type 39, 22 bytes
System Power Supply
	Location: PSU1
	Name: CRPS2700D2
	Manufacturer: Great Wall
	Serial Number: 33000285DHB06810
	Max Power Capacity: 2700 W
	Status: Present, OK

Handle 0x005E, DMI type 39, 22 bytes
System Power Supply
	Location: PSU2
	Name: CRPS2700D2
	Manufacturer: Great Wall
	Serial Number: 33000285DHB06807
	Max Power Capacity: 2700 W
	Status: Present, Critical
EOF
} > "$RD/raw/dmidecode.txt"

printf 'MemTotal:       32526256 kB\nMemAvailable:   30137364 kB\n' > "$RD/raw/meminfo.txt"

cat > "$RD/raw/ipmi-sensors.txt" <<'EOF'
PSU1_Vin         | 218.000    | Volts      | ok    | 76.000    | 80.000
PSU2_Vin         | na         | Volts      | na    | 76.000    | 80.000
EOF

cat > "$RD/raw/lsblk.json" <<'EOF'
{ "blockdevices": [
  {"name":"sda","path":"/dev/sda","size":1000204886016,"type":"disk","tran":"sata",
   "rota":true,"rm":false,"hotplug":false,"model":"ST1000NM000A-2J3","serial":"WS20SNM6"}
]}
EOF

# 归一化的 SMART 里照样有 power_on_hours —— 断言它不会被渲染出去
cat > "$RD/raw/smart-pre/sda.norm.json" <<'EOF'
{"model":"ST1000NM000A-2J3100","serial":"WS20SNM6","firmware":"TN03",
 "capacity_bytes":1000204886016,"power_on_hours":1512,"power_cycles":325,
 "temperature_c":29,"smart_passed":true}
EOF
cat > "$RD/raw/smart-post/sda.norm.json" <<'EOF'
{"temperature_c":31,"smart_passed":true}
EOF
cat > "$RD/raw/smart-pre/sda.txt" <<'EOF'
smartctl 7.4 2023-08-01 r5530
  9 Power_On_Hours          0x0032   100   100   000    Old_age   Always       -       1512
 12 Power_Cycle_Count       0x0032   100   100   020    Old_age   Always       -       325
241 Total_LBAs_Written      0x0000   100   253   000    Old_age   Offline      -       88123456
EOF

cat > "$RD/raw/lspci.txt" <<'EOF'
27:00.0 Ethernet controller [0200]: Intel Corporation 82599ES 10-Gigabit SFI/SFP+ Network Connection [8086:10fb] (rev 01)
27:00.1 Ethernet controller [0200]: Intel Corporation 82599ES 10-Gigabit SFI/SFP+ Network Connection [8086:10fb] (rev 01)
EOF

# ---- 网卡：一个口接了线并 ping 通，一个口没接线（ethtool 报 Unknown!）----
# driver.txt 里的 "model:" 行是 collect_nic() 用 nic_pci_model() 反查 lspci.txt
# 后追加进去的，这里手工模拟同样的效果，验证报告生成器读得出来。
cat > "$RD/raw/nic/ens9f0-driver.txt" <<'EOF'
driver: ixgbe
version: 6.8.0-100-generic
firmware-version: 0x00012b2c, 1.1197.0
bus-info: 0000:27:00.0
model: Intel Corporation 82599ES 10-Gigabit SFI/SFP+ Network Connection
EOF
cat > "$RD/raw/nic/ens9f0-ethtool.txt" <<'EOF'
Settings for ens9f0:
	Speed: 1000Mb/s
	Duplex: Full
	Link detected: yes
EOF
cat > "$RD/raw/nic/ens9f0-test.txt" <<'EOF'
Interface : ens9f0
Carrier   : yes
IPv4      : 192.168.1.87/24
Gateway   : 192.168.1.1
Ping      : 4/4 通，平均 0.203ms
Result    : OK
EOF
cat > "$RD/raw/nic/ens9f1-driver.txt" <<'EOF'
driver: ixgbe
firmware-version: 0x00012b2c, 1.1197.0
bus-info: 0000:27:00.1
EOF
cat > "$RD/raw/nic/ens9f1-ethtool.txt" <<'EOF'
Settings for ens9f1:
	Speed: Unknown!
	Duplex: Unknown! (255)
	Link detected: no
EOF
cat > "$RD/raw/nic/ens9f1-test.txt" <<'EOF'
Interface : ens9f1
Carrier   : no
IPv4      : -
Gateway   : -
Ping      : -
Result    : NO_LINK
EOF

# ================================================================
echo "=== 生成报告 ==="
OUT="$TMP/report.html"
if python3 "$GEN" --run-dir "$RD" --out "$OUT" >/dev/null 2>"$TMP/err"; then
  ok "generate_report.py 正常退出"
else
  bad "generate_report.py 失败：$(cat "$TMP/err")"
  printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
  exit 1
fi

echo
echo "=== 阵列卡后端的物理盘要进硬盘清单 ==="
# 阵列卡跑 RAID 模式时物理盘没有 /dev 节点，按 lsblk 那一圈根本扫不到 ——
# 但客户买的正是这些盘，清单里少了它们，报告就等于没写硬盘。
RDPD="$TMP/run-pd"
mkdir -p "$RDPD/raw/smart-pre" "$RDPD/raw/smart-post"
cp "$RD/meta.json" "$RDPD/meta.json"
cp "$RD/results.jsonl" "$RDPD/results.jsonl" 2>/dev/null || true
cat > "$RDPD/raw/lsblk.json" <<'EOF'
{"blockdevices":[
 {"name":"sda","path":"/dev/sda","size":7681501126656,"type":"disk","rota":false,
  "tran":"sas","model":"AVAGO MR9361-8i","serial":"00d1e2f3","rm":false,"hotplug":false}
]}
EOF
# 逻辑盘自己（阵列卡的 VD，通常读不到有意义的 SMART）
printf '{"model":"AVAGO MR9361-8i","serial":"00d1e2f3","smart_passed":null}\n' \
  > "$RDPD/raw/smart-pre/sda.norm.json"
cp "$RDPD/raw/smart-pre/sda.norm.json" "$RDPD/raw/smart-post/sda.norm.json"
# 卡后面两块真盘，透传读到的
for n in 8 9; do
  cat > "$RDPD/raw/smart-pre/sda-pd${n}.norm.json" <<EOF
{"model":"ST8000NM017B","serial":"WKD0A${n}9X","firmware":"SN04",
 "capacity_bytes":8001563222016,"rotation_rate":7200,"power_on_hours":260,
 "power_cycles":9,"temperature_c":33,"smart_passed":true,
 "realloc_sectors":0,"pending_sectors":0,"uncorrectable":0,"crc_errors":0}
EOF
  sed 's/"temperature_c":33/"temperature_c":41/' \
    "$RDPD/raw/smart-pre/sda-pd${n}.norm.json" > "$RDPD/raw/smart-post/sda-pd${n}.norm.json"
done
OUTPD="$TMP/report-pd.html"
if python3 "$GEN" --run-dir "$RDPD" --out "$OUTPD" >/dev/null 2>"$TMP/errpd"; then
  has "$OUTPD" "阵列卡 PD8"     "卡后面的第一块物理盘"
  has "$OUTPD" "阵列卡 PD9"     "第二块"
  has "$OUTPD" "ST8000NM017B"   "物理盘的型号（逻辑盘上读不到）"
  has "$OUTPD" "WKD0A89X"       "物理盘的序列号"
  has "$OUTPD" "41°C"           "物理盘的测后温度"
  has "$OUTPD" "机械盘"          "rotation_rate 7200 要判成机械盘"
  has "$OUTPD" "通过阵列卡逐块读取" "要有一句说明这几行是怎么来的"
  has "$OUTPD" "阵列卡逻辑盘"    "逻辑盘那行不能写成机械盘/固态盘"
  has_no "$OUTPD" "通电时间"     "物理盘同样不列寿命类字段"
  has_no "$OUTPD" "megaraid"     "透传参数是内部实现，不该出现在交付报告里"
else
  bad "带阵列卡的报告没能生成：$(cat "$TMP/errpd")"
fi

echo
echo "=== JBOD/直通：同一块盘不许在清单里出现两次 ==="
#
# 1.7.8 现场实测：阵列卡切到 JBOD 模式，一块 FORESEE 128GB SSD
# （序列号 K48060R002933）在报告里出现了两行 —— 一行是 /dev/sda，
# 另一行是"阵列卡 PD0"，其实是同一块盘。客户看到的是"这台机器有两块盘"。
#
# 直通模式下物理盘**既有 /dev 节点、又能被阵列卡逐块读到**，两条采集路径
# 都会拿到它。判据只能是序列号：RAID 模式下操作系统看到的是逻辑盘
# （序列号是阵列卡自己编的），和后端物理盘本来就该是两行 —— 上面那组钉的就是它。
RDJB="$TMP/run-jbod"
mkdir -p "$RDJB/raw/smart-pre" "$RDJB/raw/smart-post"
cp "$RD/meta.json" "$RDJB/meta.json"
cp "$RD/results.jsonl" "$RDJB/results.jsonl" 2>/dev/null || true
cat > "$RDJB/raw/lsblk.json" <<'EOF'
{"blockdevices":[
 {"name":"sda","path":"/dev/sda","size":128035676160,"type":"disk","rota":false,
  "tran":null,"model":"FORESEE 128GB SSD","serial":"K48060R002933",
  "rm":false,"hotplug":false}
]}
EOF
# 直通盘：/dev 节点和阵列卡透传读到的是同一块，序列号一模一样
cat > "$RDJB/raw/smart-pre/sda.norm.json" <<'EOF'
{"model":"FORESEE 128GB SSD","serial":"K48060R002933","firmware":"V4.6",
 "capacity_bytes":128035676160,"rotation_rate":0,"temperature_c":42,
 "smart_passed":true,"realloc_sectors":0,"pending_sectors":0,
 "uncorrectable":0,"crc_errors":0}
EOF
cp "$RDJB/raw/smart-pre/sda.norm.json" "$RDJB/raw/smart-post/sda.norm.json"
# 阵列卡那条路读到的同一块盘，序列号带补齐空格（真实样本就是这样）
sed 's/"K48060R002933"/"K48060R002933   "/' "$RDJB/raw/smart-pre/sda.norm.json" \
  > "$RDJB/raw/smart-pre/sda-pd0.norm.json"
cp "$RDJB/raw/smart-pre/sda-pd0.norm.json" "$RDJB/raw/smart-post/sda-pd0.norm.json"
OUTJB="$TMP/report-jbod.html"
if python3 "$GEN" --run-dir "$RDJB" --out "$OUTJB" >/dev/null 2>"$TMP/errjb"; then
  check "同一块盘只出现一行（序列号出现次数）" "1" \
        "$(grep -o 'K48060R002933' "$OUTJB" | grep -c . || true)"
  has_no "$OUTJB" "阵列卡 PD0"   "直通盘不再重复列成阵列卡后端盘"
  has "$OUTJB" "阵列卡直通"      "但要说清楚这块盘是挂在阵列卡后面的"
  has "$OUTJB" "/dev/sda"        "盘本身还在清单里"
  has "$OUTJB" "42°C"            "温度照常显示"
else
  bad "JBOD 报告没能生成：$(cat "$TMP/errjb")"
fi

# 反面：序列号读不出来时**绝不能**把两块盘并成一块。
# 空序列号撞空序列号是最容易写出来的 bug，一旦发生就是"少报一块盘"。
RDNS="$TMP/run-noserial"
mkdir -p "$RDNS/raw/smart-pre" "$RDNS/raw/smart-post"
cp "$RD/meta.json" "$RDNS/meta.json"
cp "$RD/results.jsonl" "$RDNS/results.jsonl" 2>/dev/null || true
cat > "$RDNS/raw/lsblk.json" <<'EOF'
{"blockdevices":[
 {"name":"sda","path":"/dev/sda","size":128035676160,"type":"disk","rota":false,
  "tran":"sas","model":"SOME VD","serial":null,"rm":false,"hotplug":false}
]}
EOF
printf '{"model":"SOME VD","serial":null,"smart_passed":null}\n' \
  > "$RDNS/raw/smart-pre/sda.norm.json"
cp "$RDNS/raw/smart-pre/sda.norm.json" "$RDNS/raw/smart-post/sda.norm.json"
printf '{"model":"REAL DISK","serial":null,"firmware":"A1","capacity_bytes":128035676160,"rotation_rate":0,"temperature_c":39,"smart_passed":true}\n' \
  > "$RDNS/raw/smart-pre/sda-pd0.norm.json"
cp "$RDNS/raw/smart-pre/sda-pd0.norm.json" "$RDNS/raw/smart-post/sda-pd0.norm.json"
OUTNS="$TMP/report-noserial.html"
if python3 "$GEN" --run-dir "$RDNS" --out "$OUTNS" >/dev/null 2>"$TMP/errns"; then
  has "$OUTNS" "阵列卡 PD0" "两边都没有序列号时不许合并（合并 = 少报一块盘）"
  has "$OUTNS" "REAL DISK"  "后端那块盘必须还在"
else
  bad "无序列号场景报告没能生成：$(cat "$TMP/errns")"
fi

# 同一件事的另一种形态：序列号不是空的，而是被截成一两个字符。
# 见过阵列卡把逻辑盘的序列号报成 "0" —— 拿它当唯一标识，
# 后面那块真盘会被"认成"同一块盘而整行消失。
RDSS="$TMP/run-shortserial"
mkdir -p "$RDSS/raw/smart-pre" "$RDSS/raw/smart-post"
cp "$RD/meta.json" "$RDSS/meta.json"
cp "$RD/results.jsonl" "$RDSS/results.jsonl" 2>/dev/null || true
cat > "$RDSS/raw/lsblk.json" <<'EOF'
{"blockdevices":[
 {"name":"sda","path":"/dev/sda","size":128035676160,"type":"disk","rota":false,
  "tran":"sas","model":"SOME VD","serial":"0","rm":false,"hotplug":false}
]}
EOF
printf '{"model":"SOME VD","serial":"0","smart_passed":null}\n' \
  > "$RDSS/raw/smart-pre/sda.norm.json"
cp "$RDSS/raw/smart-pre/sda.norm.json" "$RDSS/raw/smart-post/sda.norm.json"
printf '{"model":"SEAGATE ST8000","serial":"0","firmware":"A1","capacity_bytes":8001563222016,"rotation_rate":7200,"temperature_c":39,"smart_passed":true}\n' \
  > "$RDSS/raw/smart-pre/sda-pd0.norm.json"
cp "$RDSS/raw/smart-pre/sda-pd0.norm.json" "$RDSS/raw/smart-post/sda-pd0.norm.json"
OUTSS="$TMP/report-shortserial.html"
if python3 "$GEN" --run-dir "$RDSS" --out "$OUTSS" >/dev/null 2>"$TMP/errss"; then
  has "$OUTSS" "阵列卡 PD0"    "序列号被截成 '0' 时不许当唯一标识去合并"
  has "$OUTSS" "SEAGATE ST8000" "后端那块真盘必须还在清单里"
else
  bad "短序列号场景报告没能生成：$(cat "$TMP/errss")"
fi

echo
echo "=== 硬盘：寿命类字段不进这份报告 ==="
has_no "$OUT" "通电时间"        "不参与判定，留在工程数据里"
has_no "$OUT" "通电次数"        "同上"
has_no "$OUT" "Power_On_Hours"  "SMART 原文不再嵌进报告"
has_no "$OUT" "Total_LBAs_Written" "同上"
has    "$OUT" "WS20SNM6"        "硬盘序列号照常要有"
has    "$OUT" "SMART健康"       "健康状态照常要有"

echo
echo "=== 硬盘压测没跑：整块从客户报告里消失（1.7.6）==="
# 现场 99% 会跳过硬盘压测（客户不让往盘里写破坏性数据）。留着一行
# 「SKIP 硬盘压力测试 现场选择跳过（直接回车）」，客户看到的是"少测了一项"，
# 而那恰恰是他自己的选择 —— 白白惹一次解释。跳过时这几处一起藏干净：
#   逐项结论里的 stress_disk / verify_smart、1.4 表的「本次压测」列、
#   压测时长表的「硬盘压测时长」、以及指向 SMART 复查那一节的那句话。
# 上面的 fixture 就是这个场景（stress_disk = SKIP）。
has_no "$OUT" "硬盘压力测试"       "跳过时逐项结论里不出现这一项"
has_no "$OUT" "现场选择跳过"       "更不能出现「现场选择跳过（直接回车）」这句"
has_no "$OUT" "硬盘 SMART 复查"    "SMART 复查跟着一起藏（没跑压测时它比的是空转前后）"
has_no "$OUT" "本次压测"           "1.4 表格里那一列整列不出现"
has_no "$OUT" "硬盘压测时长"       "压测时长表里那一行也不出现"
has_no "$OUT" "硬盘单独测试"       "时长表下面那句注解跟着走"
has_no "$OUT" "CPU / 内存 / 硬盘全部压测阶段" "曲线那句注解也不能再提硬盘"
# 藏的是"压测"，不是"硬盘"——盘的清单、序列号、SMART 健康照常要有
has    "$OUT" "1.4 硬盘"    "硬盘清单本身照常在"
has    "$OUT" "WS20SNM6"    "序列号照常在"
has    "$OUT" "SMART健康"   "健康状态照常在（这是清单字段，不是压测结论）"

echo
echo "=== 真跑了硬盘压测：一项都不许少 ==="
# 反过来那一半。跑过就是实打实的工作量，藏了反而亏。
RD2="$TMP/run-disktested"
cp -r "$RD" "$RD2"
sed -i 's/"disk_confirmed": 0/"disk_confirmed": 1/'   "$RD2/meta.json"
sed -i 's/"disk_secs": 0/"disk_secs": 600/'           "$RD2/meta.json"
sed -i 's/{"id":"stress_disk","name":"硬盘压力测试","status":"SKIP","detail":"[^"]*"/{"id":"stress_disk","name":"硬盘压力测试","status":"PASS","detail":"顺序写与随机读写各 5 分钟，无 I\/O 错误"/' \
       "$RD2/results.jsonl"
OUT2="$TMP/report-disktested.html"
if python3 "$GEN" --run-dir "$RD2" --out "$OUT2" >/dev/null 2>&1; then
  has "$OUT2" "硬盘压力测试"     "跑过了就要显示这一项"
  has "$OUT2" "硬盘 SMART 复查"  "SMART 复查跟着回来"
  has "$OUT2" "硬盘压测时长"     "时长那一行回来"
  has "$OUT2" "本次压测"         "「本次压测」列回来"
  # 断言用「SMART健康 + 本次压测」这一对相邻单元格，避免误伤正文里别处的是/否
  has "$OUT2" "<td>正常</td><td>是</td>" "真压过的盘要标「是」"
else
  bad "跑过硬盘压测的场景没能生成报告：$(python3 "$GEN" --run-dir "$RD2" --out "$OUT2" 2>&1 | tail -3)"
fi

echo
echo "=== 藏归藏，坏盘一条都不许藏（这是整个改动唯一不能犯的错）==="
# verify_smart 判 FAIL 的意思是**这一轮盘上新增了坏道**。那和跑没跑硬盘压测
# 没关系 —— CPU/内存压测照样跑了十几分钟。把它藏掉就等于把坏盘放出厂，
# 比留着一行 SKIP 惹客户问一句严重得多。
RD3="$TMP/run-smartfail"
cp -r "$RD" "$RD3"
sed -i 's/{"id":"verify_smart","name":"硬盘 SMART 复查","status":"PASS","detail":"[^"]*"/{"id":"verify_smart","name":"硬盘 SMART 复查","status":"FAIL","detail":"\/dev\/sda 压测后新增重映射扇区 0->8"/' \
       "$RD3/results.jsonl"
OUT3="$TMP/report-smartfail.html"
if python3 "$GEN" --run-dir "$RD3" --out "$OUT3" >/dev/null 2>&1; then
  has    "$OUT3" "硬盘 SMART 复查"          "SMART 复查判 FAIL 时必须照常显示"
  has    "$OUT3" "新增重映射扇区 0-&gt;8"    "而且要带上具体读数"
  has_no "$OUT3" "硬盘压力测试"             "但 stress_disk 那条 SKIP 仍然该藏"
  has    "$OUT3" "坏道类计数在压测前后的变化" "1.4 里那句指路要跟着 SMART 复查回来"
else
  bad "SMART 复查 FAIL 的场景没能生成报告"
fi

echo
echo "=== 抬头的计数要和下面列得出来的条数对得上 ==="
# 藏了两条却还写着"跳过 3 项"，客户第一眼就会问剩下那条哪儿去了。
count_of() {   # count_of <文件> <状态中文名>
  grep -oE "通过 [0-9]+ 项 ｜ 失败 [0-9]+ 项 ｜ 告警 [0-9]+ 项 ｜ 跳过 [0-9]+ 项" "$1" \
    | head -1 | grep -oE "$2 [0-9]+" | grep -oE '[0-9]+'
}
# fixture 共 10 条：PASS 3（collect_system / test_nic / verify_smart）
#                   WARN 4（内存容量 / 电源 / 热节流 / AER）FAIL 1  SKIP 2
# 藏掉 stress_disk(SKIP) 和 verify_smart(PASS) 之后：PASS 2  WARN 4  FAIL 1  SKIP 1
check "抬头「通过」数按客户看得到的算" "2" "$(count_of "$OUT" 通过)"
check "抬头「跳过」数按客户看得到的算" "1" "$(count_of "$OUT" 跳过)"
check "「失败」数不受影响"             "1" "$(count_of "$OUT" 失败)"
check "「告警」数不受影响"             "4" "$(count_of "$OUT" 告警)"
# 屏幕上那个大字结论看的是**全部**判定，绝不能因为藏了行就变
has "$OUT" 'class="verdict v-FAIL"' "整机结论仍然按全部判定算（verify_ecc 那条 FAIL）"

echo
echo "=== 网卡：连通性 + Unknown! 归一化 + 型号 ==="
has_no "$OUT" "Unknown!"                     "ethtool 的原始占位不能进表格"
has    "$OUT" "已连通（4/4 通，平均 0.203ms）" "接了线的口"
has    "$OUT" "未连接链路（未接网线）"        "没接线的口"
has    "$OUT" "192.168.1.87/24"              "DHCP 拿到的地址"
has    "$OUT" "192.168.1.1"                  "默认网关"
has    "$OUT" "Intel Corporation 82599ES 10-Gigabit SFI/SFP+ Network Connection" \
              "网卡型号（从 lspci 反查回来的）"

echo
echo "=== 判的是我们、不是机器的那些项，不进客户报告（1.7.7）==="
# 标准就一句：**这一项要是失败了，客户会在意吗？**
#   扩展信息留档失败 = 我们自己的存档薄了一点，客户拿到的报告一个字不少 -> 藏
#   硬件信息采集失败 = 报告里整块硬件清单都没了 -> 客户当然在意，留着
# 「供日后追溯」这种话本身也是内部口径（report-policy 二-1）。
has_no "$OUT" "扩展信息留档"  "这一项判的是我们的存档，不是机器"
has_no "$OUT" "供日后追溯"    "连它的文案也不该出现在交付报告里"
has    "$OUT" "硬件信息采集"  "反过来：这一项失败客户是会在意的，必须留着"

echo
echo "=== 阵列卡：BMC 全哑那条提示不进客户报告（1.7.7）==="
# 它分不开「本来就没装卡」和「卡坏到 PCI 都枚举不到」。分不开的东西不该去染
# 客户的结论 —— 海光那台真没装卡、机器完全正常。
# 提示改走现场屏幕 + klburn.log + raw/raid-bmc-note.txt（内部报告索引得到）。
has_no "$OUT" "为阵列卡/HBA 预留的温度和插槽供电传感器均无读数" \
       "这句模棱两可的提示不该印给客户"
has_no "$OUT" "插到位" "更不该让客户觉得自家的卡可能松了"
has    "$OUT" "未安装阵列卡" "但「没装卡」这个事实照常要写"

echo
echo "=== 内存：装机容量 vs 系统识别容量 ==="
has "$OUT" "装机容量"     "四条 16GB"
has "$OUT" "64 GB"        "DMI 累加值"
has "$OUT" "系统识别容量" "对不上时才看得出来"
has "$OUT" "31 GB"        "MemTotal 换算值"

echo
echo "=== 电源：每一路有没有进电 ==="
has "$OUT" "交流输入" "新增列"
has "$OUT" "未接入"   "PSU2 的 Vin 读不到值"

echo
echo "=== 抬头提示 ==="
has "$OUT" "项为告警"      "WARN 项要在抬头点出来"
has "$OUT" "未能通过网络自动校时" "时钟不准的提示（run-dir 里没有 clock_synced 字段，按未校时处理）"
has "$OUT" "广州市鲲林科技有限公司" "公司名"

echo
echo "=== 二级编号不跳号（本例无 GPU、无 fio）==="
has    "$OUT" "<h3>2.1 各项结论</h3>"       "第一节"
has    "$OUT" "<h3>2.2 CPU 温度 / 频率 / 功耗曲线</h3>" "第二节"
has    "$OUT" "<h3>2.3 其他实测指标</h3>"   "第三节紧接着，不能跳到 2.5"
has_no "$OUT" "<h3>2.4"                     "没有第四节"
has_no "$OUT" "<h3>2.5"                     "更不该有第五节"

echo
echo "=== 老 run-dir 没有 cpu_power_w 这一列，不能崩、也不该画功耗图 ==="
# 上面那份 fixture 用的就是 0.5.0 之前的表头（没有 cpu_power_w）。
# 新增列一律往末尾加，老数据用 DictReader 取不到就跳过——这条守的是这个约定。
has_no "$OUT" "CPU 封装功耗" "老数据没有功耗列时不该凭空画出一张功耗图"
has    "$OUT" "温度峰值 73°C" "温度峰值照常要算出来"

echo
echo "=== 有 GPU + CPU 功耗的完整场景 ==="
RD3="$TMP/run-gpu"
cp -r "$RD" "$RD3"
cat > "$RD3/sys_metrics.csv" <<'EOF'
time,phase,cpu_temp_c,cpu_freq_mhz,load1,mem_used_mb,mem_total_mb,cpu_power_w
02:17:05,cpu,45,1156,8.28,2305,31763,95
02:17:10,cpu,51,2699,17.87,2764,31763,281
02:17:15,cpu,66,2681,64.20,2795,31763,347
02:17:20,cpu,73,2675,99.10,2801,31763,352
EOF
# 两张卡，逐卡一行。gpu_monitor 写出来就是这个格式。
cat > "$RD3/gpu_metrics.csv" <<'EOF'
time,index,name,temp_c,power_w,clock_sm_mhz,util_pct,mem_used_mb
02:17:05,0,NVIDIA GeForce RTX 4090,42,58,420,0,12
02:17:05,1,NVIDIA GeForce RTX 4090,40,55,420,0,12
02:17:10,0,NVIDIA GeForce RTX 4090,71,431,2520,100,21504
02:17:10,1,NVIDIA GeForce RTX 4090,68,428,2505,100,21504
02:17:15,0,NVIDIA GeForce RTX 4090,79,449,2490,100,21504
02:17:15,1,NVIDIA GeForce RTX 4090,75,441,2490,100,21504
EOF
# 现场可以在 klburn.conf 里改阈值，报告必须显示实际生效的那一套，不能写死
python3 - "$RD3/meta.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
m = json.load(open(p, encoding="utf-8"))
m["thresholds"] = {"cpu_temp_warn": 95, "cpu_temp_fail": 100,
                   "gpu_temp_warn": 83, "gpu_temp_fail": 90,
                   "disk_temp_warn": 70, "disk_temp_fail": 80}
json.dump(m, open(p, "w", encoding="utf-8"), ensure_ascii=False)
PYEOF
OUT3="$TMP/report-gpu.html"
if python3 "$GEN" --run-dir "$RD3" --out "$OUT3" >/dev/null 2>"$TMP/err3"; then
  has "$OUT3" "CPU 封装功耗"        "有 cpu_power_w 列时要画 CPU 功耗图"
  has "$OUT3" "封装功耗峰值 352 W"  "CPU 功耗峰值"
  has "$OUT3" "GPU 温度 / 功耗曲线" "GPU 曲线小节"
  has "$OUT3" "GPU0 79°C"           "逐卡温度峰值 - 第 0 张"
  has "$OUT3" "GPU1 75°C"           "逐卡温度峰值 - 第 1 张"
  has "$OUT3" "GPU0 449W"           "逐卡功耗峰值"
  has "$OUT3" "告警线 95°C，判故障线 100°C" "CPU 阈值要取 meta.json 里实际生效的值"
  has "$OUT3" "告警线 83°C，判故障线 90°C"  "GPU 阈值同理"
  # 两张卡的图例都要在，否则多卡机器看不出是哪张卡
  has "$OUT3" "GPU0 NVIDIA GeForce RTX 4090" "图例要带卡号和型号"
  has "$OUT3" "GPU1 NVIDIA GeForce RTX 4090" "第二张卡的图例"
else
  bad "GPU 场景的报告没能生成：$(cat "$TMP/err3")"
fi

echo
echo "=== 交付给客户的 HTML 里不许出现任何内部/开发信息 ==="
# 这份 HTML 是给客户的；ISO、工程目录、meta.json 只留在我们内部。
# 下面这些词一旦出现在报告里，客户要么看不懂，要么以为机器缺东西/有毛病。
# meta.json 里塞了 git_commit（内部追溯用），正好用来验证它没有漏进 HTML。
python3 - "$RD3/meta.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
m = json.load(open(p, encoding="utf-8"))
m["git_commit"] = "deadbee-dirty"
json.dump(m, open(p, "w", encoding="utf-8"), ensure_ascii=False)
PYEOF
OUT4="$TMP/report-clean.html"
if python3 "$GEN" --run-dir "$RD3" --out "$OUT4" >/dev/null 2>"$TMP/err4"; then
  has_no "$OUT4" "deadbee"      "git commit hash 绝不能印在交付给客户的报告上"
  has_no "$OUT4" "源码版本"      "同上"
  for w in "测试盘" "精简版" "storcli" "vendor/" "重新出盘" "构建目录" "盘内缺少"; do
    has_no "$OUT4" "$w" "内部/开发用语"
  done
else
  bad "清洁性检查用的报告没能生成：$(cat "$TMP/err4")"
fi

echo
echo "=== 边界：几乎空的 run-dir 也不能崩 ==="
EMPTY="$TMP/empty"
mkdir -p "$EMPTY"
printf '{}\n' > "$EMPTY/meta.json"
if python3 "$GEN" --run-dir "$EMPTY" --out "$TMP/empty.html" >/dev/null 2>&1; then
  ok "只有一个空 meta.json 时仍能出报告"
else
  bad "空 run-dir 把报告生成器搞崩了"
fi

# ……但"能出报告"不等于"能出一份说它合格的报告"。
#
# 1.3.0 之前，一条判定都没有的 run-dir 会渲染出绿色大字 PASS：采集阶段就崩了、
# U 盘写满了、进程被收掉 —— 一台什么都没测过的机器，客户手里那份报告写着合格。
# 这是整个项目里后果最重的一种误判方向。
EH="$TMP/empty.html"
has_no "$EH" 'verdict v-PASS' "一条判定都没有时不许打出 PASS 大字"
has    "$EH" 'verdict v-FAIL' "一条判定都没有时结论必须是 FAIL"
has    "$EH" '本报告无效'      "要写明这份报告无效，让人知道该重测而不是去查硬件"
# 措辞红线：这个 FAIL 说的是"这轮没跑成"，不能反过来暗示客户的机器坏了
has_no "$EH" '不建议出货'      "无效报告不能借用真 FAIL 的措辞"

# ================================================================
echo
echo "=== 结构性快照：整块塌掉要能查出来 ==="
#
# 上面所有断言查的都是"某个字符串在不在"。但报告生成器是 1100 行 Python，
# 它最危险的失效方式**不是文案写错，是整块塌掉**：一节没渲染出来、
# 曲线画成空图、判定表少了几行 —— 每一条单看都还"有内容"，
# 字符串断言一条都不会红，而客户拿到的是一份缺东西的报告。
#
# 这里只查骨架、不查文案 —— 查文案的话改一次措辞就得改一次测试，
# 那种测试很快就会被人用 sed 批量"修好"，然后彻底失去意义。
#
# 锚点全部拿**真跑出来的报告**核对过（tests/e2e-qemu.sh 在 QEMU 里产出的
# 那份，20 条判定），不是照着源码猜的。

cnt() { grep -oE "$2" "$1" | grep -c . ; }

# ① 一级章节：三节，顺序固定。少一节 = 客户少看一整块
check "一级章节必须是「硬件清单 / 压力测试结果 / 原始日志」三节，顺序固定" \
      "一、硬件清单|二、压力测试结果|三、原始日志|" \
      "$(grep -oE '<h2>[^<]*' "$OUT" | sed 's/<h2>//' | tr '\n' '|')"

# ② 硬件清单八个小节一个都不能少。
#    没装的硬件要标"未安装"（有啥列啥，没有的标出来），**不是整节消失** ——
#    整节消失的话客户根本不知道我们查没查过这一项。
check "硬件清单必须有 8 个小节（没装的硬件标未安装，不是整节不见）" \
      "8" "$(cnt "$OUT" '<h3>1\.[0-9]+ ')"

# ③ 判定条数必须和 results.jsonl 一样多 —— 减掉**故意藏起来的那几条**。
#    这是本组里最要紧的一条：报告悄悄吞掉一条结论，是"汇总入口调用链少人"
#    那个 bug 在报告侧的同款 —— 判定跑过了、结论也写进 results.jsonl 了，
#    只是没渲染出来，于是报告里那一项凭空消失，既不是 PASS 也不是 SKIP。
#
#    1.7.6 起硬盘压测没跑时 stress_disk / verify_smart（且状态是 PASS/SKIP 的）
#    是**故意**不渲染的。期望值按和 generate_report.py 同一条规则从
#    results.jsonl 算出来，**不写死数字** —— 写死的话以后 fixture 多加一条判定，
#    这条守卫就悄悄变成摆设了。规则算错也不会静悄悄：算成 0 就当场红。
HIDE_RE='"id":"(stress_disk|verify_smart)","name":"[^"]*","status":"(PASS|SKIP)"'
INTERNAL_RE='"id":"collect_deep"'
disk_skipped() { grep -qE '"id":"stress_disk","name":"[^"]*","status":"SKIP"' "$1"; }
n_hidden="$(grep -cE "$INTERNAL_RE" "$RD/results.jsonl" || true)"
if disk_skipped "$RD/results.jsonl"; then
  n_hidden=$(( n_hidden + $(grep -cE "$HIDE_RE" "$RD/results.jsonl" || true) ))
fi
check "本 fixture 该藏起来的正好三条（stress_disk + verify_smart + collect_deep）" \
      "3" "$n_hidden"

check "报告里的判定条数 = results.jsonl 条数 - 故意藏起来的（吞一条 = 那项结论凭空消失）" \
      "$(( $(grep -c . "$RD/results.jsonl") - n_hidden ))" \
      "$(cnt "$OUT" '<div class="result-row r-[A-Z]+"')"

# ④ 逐状态也要对得上，不能"总数对了但状态串了"
for st in PASS FAIL SKIP WARN; do
  want="$(grep -c "\"status\":\"$st\"" "$RD/results.jsonl" || true)"
  want=$(( want - $(grep -cE "$INTERNAL_RE.*\"status\":\"$st\"" "$RD/results.jsonl" || true) ))
  if disk_skipped "$RD/results.jsonl" && [[ "$st" == "PASS" || "$st" == "SKIP" ]]; then
    h="$(grep -cE "\"id\":\"(stress_disk|verify_smart)\",\"name\":\"[^\"]*\",\"status\":\"$st\"" \
         "$RD/results.jsonl" || true)"
    want=$(( want - h ))
  fi
  got="$(cnt "$OUT" "<div class=\"result-row r-$st\"")"
  check "$st 的条数要和 results.jsonl 对得上（扣掉故意藏的）" "$want" "$got"
done

# ⑤ 反过来：真跑了硬盘压测的那份报告，**硬盘那几条一条都不许藏**
# （collect_deep 是无条件藏的，所以期望值里照样要扣掉它）
if [[ -f "$OUT2" ]]; then
  check "跑过硬盘压测时硬盘那几条要全在（藏的规则不许扩大化）" \
        "$(( $(grep -c . "$RD2/results.jsonl") - $(grep -cE "$INTERNAL_RE" "$RD2/results.jsonl" || true) ))" \
        "$(cnt "$OUT2" '<div class="result-row r-[A-Z]+"')"
fi

# ⑤ 整机结论大字有且只有一个（多一个 = 页面上自相矛盾）
check "整机结论大字有且只有一个" "1" "$(cnt "$OUT" 'class="verdict v-[A-Z]+"')"

# ================================================================
echo
echo "=== 1.7.0 新增的三条判定要能正常渲染 ==="
# 这三条以前只在 e2e 里以 SKIP 的形态渲染过（QEMU 没有 EDAC / 热节流 / AER），
# WARN 和 FAIL 那两个形态一次都没进过客户报告。
has "$OUT" "内存 ECC 复查"        "新判定要出现在客户报告里"
has "$OUT" "CPU 热节流复查"       "同上"
has "$OUT" "PCIe 错误计数复查"    "同上"
check "有 FAIL 判定时整机结论必须是 FAIL" "1" "$(cnt "$OUT" 'class="verdict v-FAIL"')"

# 判定文案里的 **重点** 是给写代码的人看的记号，不能原样印给客户。
# 以前它一路进 HTML —— 客户看到的是「这是测试环境的容量限制，**不是内存故障** ——」，
# 字面的两串星号，而那句恰恰是最该让人看清的一句。现在渲染成粗体。
check "判定文案里不许出现字面的 ** 星号" "0" "$(cnt "$OUT" '\*\*')"
has "$OUT" "<b>不可纠正</b>" "**重点** 要渲染成粗体，而不是原样印出来"

# ⑥ 有采样数据就必须真画出线。
#    图表是手写 SVG，最容易的失效方式是"框还在、线没了"——
#    页面看着正常，其实一个数据点都没画。
check "sys_metrics.csv 有数据时必须真画出 polyline（不能只剩空图框）" \
      "yes" "$( (( $(cnt "$OUT" '<polyline') > 0 )) && echo yes || echo no )"

# ================================================================
echo
echo "=== 转 PDF：三条只有转出来才露馅的规则 ==="
#
# 1.8.0 那份真实报告转出来是 **179 页**，其中只有 8 页是报告本身，
# 剩下 171 页是被强行展开的原始日志；而且判定行叠印、长行冲出页面。
# 这三样在 HTML 上全都是正常的，**断言抓不到，只有真去转一次才看得见**。

# 先在源码层面钉住三条规则在（weasyprint 不在时这三条也照跑）
CSSSRC="$(python3 - "$GEN" <<'EOF'
import io, re, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'@media print\{.*?\n\}', src, re.S)
print(m.group(0) if m else '')
EOF
)"
check "打印样式里要把折叠块保持折叠（否则原始日志全展开）" "1" \
      "$(printf '%s' "$CSSSRC" | grep -c 'details:not(\[open\]) > \*:not(summary){display:none' || true)"
check "打印样式里 pre 要换行（否则长行冲出页面、右边被切掉）" "1" \
      "$(printf '%s' "$CSSSRC" | grep -c 'white-space:pre-wrap' || true)"
check "打印样式里判定行不能用 flex（否则徽章/名称/详情叠印）" "1" \
      "$(printf '%s' "$CSSSRC" | grep -c '\.result-row{display:block}' || true)"

# 再真转一次。没装 weasyprint 就跳过——盘里有，开发机上不一定有，
# 而"这台机器没装工具"绝不能当成代码有问题（§2-2 的同款道理）。
if command -v weasyprint >/dev/null 2>&1 && command -v pdfinfo >/dev/null 2>&1; then
  # 造一份带巨型折叠日志的报告：40000 行、每行都很长，
  # 正是现场那份 179 页的成因（GPU 压测日志 + 内核日志各几万行）。
  BIG="$TMP/run-bigpdf"
  mkdir -p "$BIG/raw/stress"
  cp "$RD/meta.json" "$BIG/meta.json"
  cp "$RD/results.jsonl" "$BIG/results.jsonl" 2>/dev/null || true
  cp "$RD/raw/lsblk.json" "$BIG/raw/lsblk.json" 2>/dev/null || true
  for i in $(seq 1 4000); do
    printf '[Thu Aug  6 14:08:00 2026] NVRM: GPU0 nvAssertOkFailedNoLog: Assertion failed: GPU lost from the bus [NV_ERR_GPU_IS_LOST] (0x0000000F) returned from _intrServiceStallCommonCheckBegin(pGpu, pIntr, &pOldContext) @ intr.c:%d\n' "$i"
  done > "$BIG/raw/dmesg-errors.txt"
  cp "$BIG/raw/dmesg-errors.txt" "$BIG/raw/dmesg-delta.txt"
  OUTBIG="$TMP/report-big.html"
  if python3 "$GEN" --run-dir "$BIG" --out "$OUTBIG" >/dev/null 2>&1 \
     && weasyprint "$OUTBIG" "$TMP/big.pdf" >/dev/null 2>&1; then
    PGS="$(pdfinfo "$TMP/big.pdf" 2>/dev/null | awk '/^Pages/{print $2}')"
    [[ "$PGS" =~ ^[0-9]+$ ]] || PGS=0
    # 4000 行日志全展开的话光这一块就是几十页。收起来之后整份应该 20 页以内。
    check "4000 行折叠日志不许把 PDF 撑开（<=20 页，实测约 10 页）" "yes" \
          "$( (( PGS > 0 && PGS <= 20 )) && echo yes || echo no )"
    printf '     实际页数：%s\n' "$PGS"
  else
    bad "带巨型日志的报告没能转成 PDF"
  fi
else
  printf '  \033[33m--\033[0m   跳过真转 PDF 那两条（本机没装 weasyprint/pdfinfo）\n'
fi

# ================================================================
echo
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
