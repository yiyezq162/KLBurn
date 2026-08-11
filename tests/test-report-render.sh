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
{"group":"cpu","key":"失败压测项","value":"0"}
{"group":"cpu","key":"峰值温度","value":"71"}
{"group":"mem","key":"测试工具","value":"stressapptest"}
{"group":"gpu0","key":"峰值功耗W","value":"453"}
{"group":"gpu","key":"FAULTY卡数","value":"0"}
{"group":"pcie","key":"新增AER可纠正设备数","value":"0"}
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

# lscpu 的 L3 那格给的是 `55 MiB (2 instances)` —— 一份中文报告里挂个英文尾巴
cat > "$RD/raw/lscpu.json" <<'EOF'
{"lscpu":[
 {"field":"Architecture:","data":"x86_64"},
 {"field":"CPU(s):","data":"128"},
 {"field":"Socket(s):","data":"2"},
 {"field":"L3 cache:","data":"55 MiB (2 instances)"},
 {"field":"Virtualization:","data":"VT-x"}
]}
EOF

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
# r8169 这类驱动 ethtool 给的不是版本号，是它加载的**固件文件名**（带目录）。
# 整串印进「固件版本」那一格，看着像我们把一条路径漏出去了。
cat > "$RD/raw/nic/enp129s0-driver.txt" <<'EOF'
driver: r8169
firmware-version: rtl_nic/rtl8168d-2.fw
bus-info: 0000:81:00.0
model: Realtek Semiconductor Co., Ltd. RTL8111/8168/8211/8411 PCI Express Gigabit Ethernet Controller
EOF
cat > "$RD/raw/nic/enp129s0-ethtool.txt" <<'EOF'
Settings for enp129s0:
	Speed: Unknown!
	Duplex: Unknown! (255)
	Link detected: no
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
echo "=== DMI 的状态字段要说人话 ==="
# 一份中文报告里，「状态」那一格原样印着 `Present, OK` / `Populated, Enabled`，
# 客户还得自己猜。逐段翻，翻不出来的段原样留着。
has    "$OUT" "在位，正常"     "电源 Present, OK"
has    "$OUT" "在位，严重异常" "电源 Present, Critical"
has    "$OUT" "已安装，已启用" "CPU Populated, Enabled"
has    "$OUT" "55 MiB（共 2 组）" "lscpu 的 (2 instances) 也是英文尾巴"
has_no "$OUT" "instances"       "同上"

echo
echo "=== 电源：BIOS 没填的额定功率不许印成 65535 W（Supermicro X11DPG-QT）==="
# 现场那台 Supermicro X11DPG-QT：两路电源的厂商/型号/序列号四个字段全是
# dmidecode 的 `<BAD INDEX>`（BIOS 把字符串下标填到了字符串表外面），
# 额定功率是 `65535 W`（0xFFFF，同样是"没填"）。1.8.2 的报告照抄了进去，
# 客户看到「额定功率 65535 W」和四格 `<BAD INDEX>`，每台都要解释一遍。
# **没抓到就显示没抓到** —— 这两样都该是表格里的破折号，电源本身照常列出来。
RDBI="$TMP/run-badindex"
mkdir -p "$RDBI/raw/smart-pre" "$RDBI/raw/smart-post"
cp "$RD/meta.json" "$RDBI/meta.json"
cp "$RD/results.jsonl" "$RDBI/results.jsonl" 2>/dev/null || true
cat > "$RDBI/raw/dmidecode.txt" <<'EOF'
Handle 0x0015, DMI type 39, 22 bytes
System Power Supply
	Power Unit Group: 1
	Location: PSU1
	Name: <BAD INDEX>
	Manufacturer: <BAD INDEX>
	Serial Number: <BAD INDEX>
	Model Part Number: <BAD INDEX>
	Max Power Capacity: 65535 W
	Status: Present, OK

Handle 0x0016, DMI type 39, 22 bytes
System Power Supply
	Power Unit Group: 2
	Location: PSU2
	Name: CRPS1300
	Manufacturer: Great Wall
	Serial Number: 3300033230124689
	Max Power Capacity: 0 W
	Status: Present, OK
EOF
echo '{ "blockdevices": [] }' > "$RDBI/raw/lsblk.json"
OUTBI="$TMP/report-badindex.html"
"$GEN" --run-dir "$RDBI" --out "$OUTBI" >/dev/null 2>&1 \
  && ok "含 <BAD INDEX> 电源的 run-dir 能生成报告" \
  || bad "含 <BAD INDEX> 电源的 run-dir 能生成报告"

# 断言只能盯**电源那张表**：报告末尾的「三、原始日志」本来就该原样附上
# dmidecode 的输出，那里出现 65535 / <BAD INDEX> 是对的（存证），
# 表格里出现才是错的。整份 HTML 是一行，用 python 把那一节切出来。
PSUSEC="$TMP/psu-section.txt"
python3 - "$OUTBI" > "$PSUSEC" <<'PY'
import io, re, sys
s = io.open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"<h3>[0-9.]+ 电源</h3>.*?(?=<h2)", s, re.S)
sys.stdout.write(m.group(0) if m else "")
PY
[[ -s "$PSUSEC" ]] && ok "切得出「电源」那一节（切不出来下面的断言等于没跑）" \
                   || bad "切得出「电源」那一节（切不出来下面的断言等于没跑）"
has_no "$PSUSEC" "65535"      "0xFFFF 是「这一格没填」，不是 65 千瓦的电源"
has_no "$PSUSEC" "BAD INDEX"  "dmidecode 的读不出来标记不许进电源表"
has_no "$PSUSEC" "0 W"        "有些 BIOS 对真电源也不填额定功率，0 W 同样是没填"
has    "$PSUSEC" "PSU1"       "电源本身照常要列出来（身份读不到不等于没有这路电源）"
has    "$PSUSEC" "PSU2"       "额定功率没填但身份是真的，绝不能当空槽位丢掉"
has    "$PSUSEC" "Great Wall" "读得到的字段照常要有"
has    "$PSUSEC" "未填写部分电源模块" "整行破折号要就地解释清楚，否则每台机器都要口头解释一遍"
# 反过来：字段都读得到的机器不该平白多出这句提示
has_no "$OUT"    "未填写部分电源模块" "字段齐全时不该出现这句"

echo
echo "=== 电源：没有 Vin 传感器时，交流输入退到 BMC 的离散量 ==="
# Supermicro X11DPG-QT 的 BMC 只有 `PS1 Status` 这种离散量，
# 1.8.2 的报告里「交流输入」那一列因此整列是破折号 ——
# 而 raw/ipmi-sdr.txt 里其实一直写着答案，只是没人读。
# 判读规则和 lib/collect.sh 的 psu_ac_state_sdr 必须一致。
cat > "$RDBI/raw/ipmi-sdr.txt" <<'EOF'
CPU1 Temp        | 3Ah | ok  |  3.1 | 45 degrees C
PS1 Status       | C4h | ok  | 10.92 | Presence detected
PS2 Status       | C5h | ok  | 10.91 | Presence detected, Power Supply AC lost
EOF
"$GEN" --run-dir "$RDBI" --out "$OUTBI" >/dev/null 2>&1 \
  && ok "带离散量电源传感器的 run-dir 能生成报告" \
  || bad "带离散量电源传感器的 run-dir 能生成报告"
python3 - "$OUTBI" > "$PSUSEC" <<'PY'
import io, re, sys
s = io.open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"<h3>[0-9.]+ 电源</h3>.*?(?=<h2)", s, re.S)
sys.stdout.write(m.group(0) if m else "")
PY
# 盯**格子**，别盯字面 —— 「状态」那一列渲染出来是「在位，正常」，
# 光 grep "正常" 两列都命中，等于没断言。
check_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1（期望 $2，实际 $3）"; }
check_eq "PS1 只置了 Presence detected -> 交流输入那格是「正常」" \
         "1" "$(grep -o '<td>正常</td>' "$PSUSEC" | wc -l)"
check_eq "PS2 明写 AC lost -> 交流输入那格是「未接入」" \
         "1" "$(grep -o '<td>未接入</td>' "$PSUSEC" | wc -l)"

echo
echo "=== 网卡：固件版本那一格不许长得像一条路径 ==="
# r8169 的 ethtool 给的是它加载的固件**文件名**（`rtl_nic/rtl8168d-2.fw`）。
# 去掉目录只留文件名 —— 信息一点没少（这一格本来就是"这块卡在跑哪个固件"），
# 也不再像我们漏了一条路径出去。
has    "$OUT" "rtl8168d-2.fw"        "固件文件名要留着"
has_no "$OUT" "rtl_nic/"             "目录不该出现在客户报告里"
has    "$OUT" "0x00012b2c, 1.1197.0" "多段版本号（I350/82599 那种）原样留着，别拿一个 / 去切"

echo
echo "=== 判的是我们、不是机器的指标，不进客户报告 ==="
# 「失败压测项」是 stress-ng 内部子测试的失败计数。客户看到一个 0，
# 既不知道分母是多少，也不知道它和上面那条 PASS 有什么区别 ——
# 有区别时上面那条就不会是 PASS。工程数据和内部报告里一个字段都没少。
has    "$OUT" "装机容量MB"  "正经指标照常在"
has_no "$OUT" "失败压测项"  "内部计数不进客户报告"
# 内存压测程序叫什么是内部实现（§2-1「盘里带了什么工具」）。这一格失败与否
# 也不由它决定 —— metrics.jsonl 和内部报告里一个字段都没少。
# 查的是**那一行指标**，不是「测试工具」四个字 —— 抬头里
# 「测试工具 KLBurn v1.8.4」说的是我们这个产品自己，那句该留。
has_no "$OUT" "<td>测试工具</td>" "压测程序的名字不进客户报告"
has_no "$OUT" "stressapptest"     "连值也不许漏出去"

echo
echo "=== 「其他实测指标」的分组列是中文，不是内部键 ==="
# metric_add 的第一个参数是内部分组键（mem / pcie / gpu0），给 metrics.jsonl
# 归类用。一份中文报告里夹着一列 mem、pcie，和 1.8.3 修掉的 PCI、Present, OK
# 是同一类：照抄内部写法。
has    "$OUT" "<td>内存</td>"    "mem -> 内存"
has    "$OUT" "<td>处理器</td>"  "cpu -> 处理器"
has    "$OUT" "<td>显卡0</td>"   "带序号的分组：gpu0 -> 显卡0"
has    "$OUT" "<td>PCIe</td>"    "pcie 有它自己的中文写法（就是 PCIe）"
has_no "$OUT" "<td>mem</td>"     "内部分组键不许出现在表格里"
has_no "$OUT" "<td>gpu0</td>"    "同上"
has_no "$OUT" "FAULTY"           "指标名里混进来的英文也要收拾掉"
has    "$OUT" "状态异常卡数"      "但那一行本身还在，信息不许少"

echo
echo "=== 抬头提示 ==="
has "$OUT" "项为告警"      "WARN 项要在抬头点出来"
has "$OUT" "未能通过网络自动校时" "时钟不准的提示（run-dir 里没有 clock_synced 字段，按未校时处理）"
has "$OUT" "广州市鲲林科技有限公司" "公司名"

echo
echo "=== 二级编号不跳号（本例无 GPU、无 fio、无性能基准）==="
# 1.9.0 起一级编号也是动的：跑了性能基准时压测那一节是「四」，没跑就是「三」。
# 本 fixture 没有任何 bench_* 判定，所以性能基准整节不出现，压测是第三节。
has    "$OUT" "<h3>3.1 各项结论</h3>"       "第一节"
has    "$OUT" "<h3>3.2 CPU 温度 / 频率 / 功耗曲线</h3>" "第二节"
has    "$OUT" "<h3>3.3 其他实测指标</h3>"   "第三节紧接着，不能跳到 3.5"
has_no "$OUT" "<h3>3.4"                     "没有第四节"
has_no "$OUT" "<h3>3.5"                     "更不该有第五节"

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
                   "gpu_temp_warn": 86, "gpu_temp_fail": 91,
                   "gpu_temp_from_card": 1,
                   "disk_temp_warn": 70, "disk_temp_fail": 80}
json.dump(m, open(p, "w", encoding="utf-8"), ensure_ascii=False)
PYEOF
# 消费级 GeForce 卡没烧序列号，nvidia-smi 给的是字面的 `0`。
# 印成「序列号 0」比空着更糟 —— 客户会拿这个 0 去对货。
cat > "$RD3/raw/gpu-smi-full.txt" <<'EOF'
Driver Version                            : 595.84

GPU 00000000:C8:00.0
    Product Name                          : NVIDIA GeForce RTX 4090
    Serial Number                         : 0
    VBIOS Version                         : 98.02.2E.80.39
    FB Memory Usage
        Total                             : 24564 MiB
    PCIe Generation
        Max                               : 4
EOF
OUT3="$TMP/report-gpu.html"
if python3 "$GEN" --run-dir "$RD3" --out "$OUT3" >/dev/null 2>"$TMP/err3"; then
  has "$OUT3" "NVIDIA GeForce RTX 4090" "显卡型号照常要有"
  has "$OUT3" "98.02.2E.80.39"          "VBIOS 版本照常要有"
  # 表格那一节切出来单独判：报告别处出现 0 是正常的
  python3 - "$OUT3" > "$TMP/gpu-section.txt" <<'PY'
import io, re, sys
s = io.open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"<h3>[0-9.]+ GPU 显卡</h3>.*?(?=<h3|<h2)", s, re.S)
sys.stdout.write(m.group(0) if m else "")
PY
  [[ -s "$TMP/gpu-section.txt" ]] && ok "切得出「GPU 显卡」那一节" \
                                  || bad "切得出「GPU 显卡」那一节"
  has_no "$TMP/gpu-section.txt" ">0<" "消费级卡的 Serial Number: 0 不许当序列号印出来"
  has "$OUT3" "CPU 封装功耗"        "有 cpu_power_w 列时要画 CPU 功耗图"
  has "$OUT3" "封装功耗峰值 352 W"  "CPU 功耗峰值"
  has "$OUT3" "GPU 温度 / 功耗曲线" "GPU 曲线小节"
  has "$OUT3" "GPU0 79°C"           "逐卡温度峰值 - 第 0 张"
  has "$OUT3" "GPU1 75°C"           "逐卡温度峰值 - 第 1 张"
  has "$OUT3" "GPU0 449W"           "逐卡功耗峰值"
  has "$OUT3" "告警线 95°C，判故障线 100°C" "CPU 阈值要取 meta.json 里实际生效的值"
  has "$OUT3" "告警线 86°C，判故障线 91°C"  "GPU 阈值同理"
  # 1.9.3 起显卡那两条线正常是**卡自己报的**。报告里出现一条线，
  # 看的人第一个问题就是"这条线哪来的" —— 这句必须印出来。
  has "$OUT3" "两条线均取自显卡自身上报的限值" "GPU 阈值要说明出处"
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
  # 采集/压测工具的名字同样是内部实现（§2-1「盘里带了什么工具」）。
  # 这一组和上面那组分开写是有原因的：工具名会从**两条**路进报告 ——
  # 源码里的中文文案（test-hw-checks 的 FORBIDDEN 扫得到），以及
  # metrics.jsonl 的**值**（那是数据，源码里 grep 不到）。1.8.4 之前
  # 「mem / 测试工具 / stressapptest」就是走第二条路一路印到客户手上的。
  # 所以这一组必须查**生成物**。
  #
  # ⚠️ **必须先把 `<pre>` 里嵌的原始日志剔掉再扫。**
  #
  #   `<pre>` 里的原始日志按 report-policy 二-6-2 是**存证、不是结论**，
  #   允许原样保留 —— 而那些日志本来就是工具自己打的，`stress-ng: info:` 这种
  #   前缀一份真报告里有十几处。所以"扫整份 HTML"这个做法有个隐蔽的毛病：
  #
  #     它只在**本测试的 fixture 里恰好没有原始日志**时才是绿的。
  #
  #   1.9.0 实测那份真报告：stress-ng 出现 17 次、dmidecode 3 次、
  #   stressapptest 1 次，**全在 `<pre>` 里**。也就是说这条断言换成真报告
  #   立刻就红，而红的原因和它想守的东西毫无关系 —— 一条只能在玩具输入上
  #   为绿的守卫，和没写没有区别。
  #
  #   剔掉 `<pre>` 之后剩下的才是我们自己写的东西：判定文案、表格、小节标题。
  #   那里面出现工具名才是真违规。剔干净了也就**不必再回避 fio 和几个基准程序**，
  #   它们和别的工具判据完全一样（1.8.4 记的那条"禁词表是被咬过才会长的表"）。
  BODY="$TMP/report-clean-nopre.html"
  python3 - "$OUT4" "$BODY" <<'PYEOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
html = open(src, encoding="utf-8").read()
# 非贪婪、跨行地摘掉每一个 <pre>...</pre>
open(dst, "w", encoding="utf-8").write(re.sub(r"<pre\b.*?</pre>", "", html, flags=re.S))
PYEOF
  # 先自检：剔除这一步真的生效了没有。剔过头（整份被清空）或者没剔掉
  # （正则写错）都会让下面那一串断言变成摆设，而两种都不会有任何报错。
  check "剔掉 <pre> 之后正文还在（没剔过头）" "yes" \
        "$(grep -q '一、硬件清单' "$BODY" && echo yes || echo no)"
  check "剔掉 <pre> 之后原始日志真的没了（没剔漏）" "0" \
        "$(grep -c '<pre' "$BODY" || true)"

  for w in "stressapptest" "stress-ng" "gpu_burn" "nvidia-smi" "smartctl" \
           "fio" "lspci" "lsblk" "turbostat" "mstflint" \
           "bandwidthTest" "p2pBandwidth" "xlinpack" "mlc_avx512"; do
    has_no "$BODY" "$w" "工具名不进客户报告（正文，不含 <pre> 存证）"
  done

  # 这一组同样必须**有能力变红**。拿一份把工具名写进正文的 HTML 喂给同一条判据，
  # 它必须抓住；同时确认同一个词躺在 <pre> 里时不会被误伤 —— 两个方向都要验，
  # 只验一头的话，"剔过头"和"漏网"各自都能装成绿的。
  printf '<h2>一、硬件清单</h2><p>fio 报告 I/O 错误</p>' > "$TMP/leak-body.html"
  check "守卫抓得住写进正文的工具名" "1" \
        "$(grep -c 'fio' "$TMP/leak-body.html" || true)"
  printf '<h2>一、硬件清单</h2><pre>fio-3.36\nstress-ng: info: ok</pre>' > "$TMP/leak-pre.html"
  python3 - "$TMP/leak-pre.html" "$TMP/leak-pre-stripped.html" <<'PYEOF'
import re, sys
open(sys.argv[2], "w", encoding="utf-8").write(
    re.sub(r"<pre\b.*?</pre>", "", open(sys.argv[1], encoding="utf-8").read(), flags=re.S))
PYEOF
  check "<pre> 里的同一个词不许被误伤（存证允许原样保留）" "0" \
        "$(grep -c 'fio' "$TMP/leak-pre-stripped.html" || true)"
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

# ① 一级章节：顺序固定，少一节 = 客户少看一整块。
#
# 1.9.0 起「性能基准」是**有条件的一节**：跑了才出现，没跑整节不显示
# （一节全是 SKIP 的基准只会招来"你们是不是没测"的提问）。
# 所以这里分两组断言：不带基准的那份是四节，带基准的那份是五节，
# 而且编号要跟着往后顺延 —— 断号或者两节都叫「三、」是这一类改动最典型的翻车。
check "一级章节（无性能基准时）必须是四节，顺序固定" \
      "一、硬件清单|二、配置核对|三、压力测试结果|四、原始日志|" \
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
#    1.9.4 起又多两类：
#      - `check_sn_consistency`（序列号一致性）—— 查的是文书对不对得上，
#        不是硬件有没有毛病，和 collect_deep 同一把尺子，无条件藏
#      - **带 `"origin":"self"` 的 SKIP** —— "我们没带那个程序 / 没量到"，
#        跟被测机器毫无关系（1.9.3 印出去过，客户当场发火）
HIDE_RE='"id":"(stress_disk|verify_smart)","name":"[^"]*","status":"(PASS|SKIP)"'
INTERNAL_RE='"id":"(collect_deep|collect_fwts|check_sn_consistency)"'
SELF_RE='"status":"SKIP".*"origin":"self"'
disk_skipped() { grep -qE '"id":"stress_disk","name":"[^"]*","status":"SKIP"' "$1"; }
n_hidden="$(grep -cE "$INTERNAL_RE" "$RD/results.jsonl" || true)"
n_hidden=$(( n_hidden + $(grep -cE "$SELF_RE" "$RD/results.jsonl" || true) ))
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
  if [[ "$st" == "SKIP" ]]; then
    want=$(( want - $(grep -cE "$SELF_RE" "$RD/results.jsonl" || true) ))
  fi
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
        "$(( $(grep -c . "$RD2/results.jsonl") \
             - $(grep -cE "$INTERNAL_RE" "$RD2/results.jsonl" || true) \
             - $(grep -cE "$SELF_RE" "$RD2/results.jsonl" || true) ))" \
        "$(cnt "$OUT2" '<div class="result-row r-[A-Z]+"')"
fi

# ⑤ 整机结论大字有且只有一个（多一个 = 页面上自相矛盾）
check "整机结论大字有且只有一个" "1" "$(cnt "$OUT" 'class="verdict v-[A-Z]+"')"

# ================================================================
echo
echo "=== 报告分节：配置核对 + 性能基准两节（1.9.0）==="
#
# 分节是按"读者关心的三件事"来的：装的东西对不对 / 跑多快 / 扛不扛得住。
# 这一组验的是**分组本身**：判定被分到哪一节、以及分错时会不会有判定凭空
# 消失（"藏一条结论"是这个项目在报告侧最忌讳的事）。
RDA="$TMP/run-accept"
cp -r "$RD" "$RDA"
cat >> "$RDA/results.jsonl" <<'EOF'
{"id":"check_dimm_uniform","name":"内存条一致性","status":"WARN","detail":"本机装有 8 条内存，规格不完全一致：颗粒型号 2 种；建议出货前按订单要求确认。","ref":"","time":"t"}
{"id":"check_sn_consistency","name":"序列号一致性","status":"PASS","detail":"主板 BIOS 与管理控制器记录的整机序列号一致（TESTSN0001）。机身物理标签请人工核对。","ref":"","time":"t"}
{"id":"check_bios_profile","name":"平台关键设置","status":"PASS","detail":"已读取平台关键设置的实际状态：处理器 x2APIC 已关闭；IO 虚拟化 已关闭；每路 NUMA 节点 每路 1 个（未启用子 NUMA 划分）。","ref":"","time":"t"}
{"id":"bench_cpu_flops","name":"CPU 浮点算力","status":"PASS","detail":"全核浮点矩阵运算（问题规模 40000 阶，重复 4 次取最好成绩）的平均算力实测 3010.0 GFlops。","ref":"","time":"t"}
{"id":"bench_mem_bw","name":"内存读取带宽","status":"PASS","detail":"内存满负载读取带宽实测 245678.9 MB/s（本机内存运行频率 4800 MT/s，已装满 16 个通道）。","ref":"","time":"t"}
{"id":"bench_disk_bw","name":"硬盘读写带宽","status":"PASS","detail":"对 1 块硬盘逐块测量 128KB 大块顺序读带宽（每块每个方向各 20 秒），逐盘数值见下方「硬盘顺序读带宽」。本次未进行破坏性写入测试，因此只测量了读带宽。","ref":"raw/bench/","time":"t"}
EOF
cat >> "$RDA/metrics.jsonl" <<'EOF'
{"group":"platform","key":"处理器 x2APIC","value":"已关闭"}
{"group":"conform","key":"内存条数","value":"8"}
{"group":"bench","key":"CPU 浮点算力（GFlops）","value":"3010.0"}
{"group":"bench","key":"内存读取带宽（MB/s）","value":"245678.9"}
{"group":"bench","key":"算力测试问题规模（阶）","value":"40000"}
{"group":"bench","key":"内存运行频率（MT/s）","value":"4800"}
{"group":"bench","key":"内存通道数","value":"16"}
EOF
mkdir -p "$RDA/raw/bench"
cat > "$RDA/raw/bench/fio-sda-read.json" <<'EOF'
{"jobs":[{"jobname":"libaio_read_128k_32_1","read":{"bw":532480,"iops":4160},"write":{"bw":0,"iops":0},"error":0}]}
EOF
OUTA="$TMP/report-accept.html"
"$GEN" --run-dir "$RDA" --out "$OUTA" >/dev/null 2>&1

check "有性能基准时一级章节变成五节，编号跟着顺延" \
      "一、硬件清单|二、配置核对|三、性能基准|四、压力测试结果|五、原始日志|" \
      "$(grep -oE '<h2>[^<]*' "$OUTA" | sed 's/<h2>//' | tr '\n' '|')"
has "$OUTA" "<h3>2.1 核对结论</h3>"        "配置核对的第一小节"
has "$OUTA" "<h3>3.1 各项结论</h3>"        "性能基准的第一小节"
has "$OUTA" "<h3>4.1 各项结论</h3>"        "压测那一节的编号要跟着一级编号走"
has "$OUTA" "内存条一致性"                  "一致性判定要出现在配置核对那一节"
has "$OUTA" "libaio_read_128k_32_1"        "硬盘带宽表要原样标出本次实际用的测试参数"
has "$OUTA" "固件版本清单"                  "固件版本汇总表（同批次比对用）"
# ⚠️ **同一个数字不许在一页上印两遍。**
# 1.9.0 一度在结论列表之外又加了一张"实测数值汇总"表，六个数各印两次 ——
# 那不是排版，是堆砌。逐盘带宽是另一组数（结论里给不出逐盘明细），留着；
# 六个整机数字只在结论里出现一次。
has_no "$OUTA" "实测数值汇总"  "不许再加回那张和结论重复的汇总表"
has_no "$OUTA" "测试条件："     "不许再加回那行和结论重复的测试条件"
check "CPU 算力那个数在整份报告里只出现一次" "1" \
      "$(grep -o '3010.0 GFlops' "$OUTA" | grep -c . || true)"
check "算力的问题规模也只出现一次" "1" \
      "$(grep -o '40000 阶' "$OUTA" | grep -c . || true)"
# 这份 fixture 只有 read 那一份 json（= 现场没确认破坏性写入），所以标题、导语
# 都只能说「顺序读」。写成固定的「顺序读写」就是说得比测得多（六-4）——
# 一张只有读带宽的表顶着"读写"的标题，客户会问"写的数呢"。
has "$OUTA" "<h3>3.2 硬盘顺序读带宽</h3>" "只测了读时，标题不许写成「读写」"
has_no "$OUTA" "128KB 大块顺序读写"        "导语同理，不许说没做过的那个方向"
has_no "$OUTA" "顺序写带宽"                "写那一列整个不画（不是留一列破折号）"

# 读写都跑了的那一份：标题变回「读写」，而且**两个方向的 job 名都要在**。
#
# ⚠️ 这一条钉的是一个真实缺陷：「测试口径」原来是 `row[...] = jobname`，
#    读和写各写一次、后写的把先写的覆盖掉，于是「顺序读带宽」那一格的数字
#    顶着一个 `libaio_write_...` 的口径。客户拿这张表去和自己验收单上的
#    job 名对照时，对到的是另一个方向 —— 数字没错，但标错了它是怎么来的。
RDW="$TMP/run-accept-rw"
cp -r "$RDA" "$RDW"
cat > "$RDW/raw/bench/fio-sda-write.json" <<'EOF'
{"jobs":[{"jobname":"libaio_write_128k_32_1","read":{"bw":0,"iops":0},"write":{"bw":491520,"iops":3840},"error":0}]}
EOF
# 判定文案也换成"读写都跑了"那一版（lib/bench.sh 按 write_ok 拼的另一支），
# 这样下面那条指路守卫在**两个方向上**都过一遍
grep -v '"id":"bench_disk_bw"' "$RDA/results.jsonl" > "$RDW/results.jsonl"
cat >> "$RDW/results.jsonl" <<'EOF'
{"id":"bench_disk_bw","name":"硬盘读写带宽","status":"PASS","detail":"对 1 块硬盘逐块测量 128KB 大块顺序读与顺序写带宽（每块每个方向各 20 秒），逐盘数值见下方「硬盘顺序读写带宽」。","ref":"raw/bench/","time":"t"}
EOF
OUTW="$TMP/report-accept-rw.html"
"$GEN" --run-dir "$RDW" --out "$OUTW" >/dev/null 2>&1
has "$OUTW" "<h3>3.2 硬盘顺序读写带宽</h3>" "读写都测了时标题才写「读写」"
has "$OUTW" "libaio_read_128k_32_1 / libaio_write_128k_32_1" \
    "两个方向的测试口径都要列出来（不许被后写的那个覆盖掉）"
check "读带宽那一格不许只挂着写的口径" "0" \
      "$(python3 - "$OUTW" <<'PYEOF'
import re, sys
h = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"<h3>3\.2 [^<]*</h3>.*?</table>", h, re.S)
seg = m.group(0) if m else ""
# 有读带宽这一列、却一个 read 口径都没有 = 覆盖掉了
print(1 if ("顺序读带宽" in seg and "libaio_read" not in seg) else 0)
PYEOF
)"

# 平台设置那四个值同理：判定行里说"读到了几项"，值只在下面那张表里出现。
check "平台设置的值不在判定行里重复" "1" \
      "$(grep -o '每路 1 个（未启用子 NUMA 划分）' "$OUTA" | grep -c . || true)"

# ⚠️ **性能那一节不许出现"参考值 / 是否达标"这类东西。**
# 这张盘是无人值守跑的，没有任何地方能拿到"这台机器应该达到多少" ——
# 凭空印一个数上去，等于我们替客户定了一个他没定过的标准。
# 1.9.0 一度真做过阈值那一套，整个删掉了；这几条钉住，别再长回来。
for w in "参考值" "验收标准" "未达标" "是否达标" "低于标准" "合格线"; do
  has_no "$OUTA" "$w" "性能一节不许出现合格线概念"
done
has "$OUTA" "不做合格与否的判断" "要明写这一节不判合格"

# **最要紧的一条**：分组只决定"印在哪一节"，绝不能让哪条判定漏印。
# 分组表里漏登记一个 id 时，它应当落到"压测与复查"那一段，而不是消失。
check "分成三节之后，判定总条数一条都不许少" \
      "$(( $(grep -c . "$RDA/results.jsonl") \
           - $(grep -cE "$INTERNAL_RE" "$RDA/results.jsonl" || true) \
           - $(grep -cE "$SELF_RE" "$RDA/results.jsonl" || true) \
           - $(grep -cE "$HIDE_RE" "$RDA/results.jsonl" || true) ))" \
      "$(cnt "$OUTA" '<div class="result-row r-[A-Z]+"')"
# 性能数字**不参与**整机结论 —— 基准项永远不会是 FAIL/WARN。
#
# ⚠️ 这一条以前是拿上面那份 fixture 的 results.jsonl 自己去数的，而那份 jsonl
#    正是本文件几行之前手写的：**它永远是 0，代码怎么改都不会红**。
#    "一个从没红过的测试等于没写"，这条比没写更糟 —— 它看着像有人在守。
#    真正要守的东西在源码里：`lib/bench.sh` 的出口只能是 PASS 或 SKIP。
BENCH_SH="$ROOT/rootfs/opt/klburn/lib/bench.sh"
check "lib/bench.sh 里不许出现 ST_WARN / ST_FAIL（性能数字不判合格）" "0" \
      "$(grep -cE 'ST_WARN|ST_FAIL' "$BENCH_SH" || true)"
# 同一条判据必须抓得住违规：拿一份写了 ST_FAIL 的样本喂进去，它必须给非 0。
check "上面那条判据本身有能力变红" "1" \
      "$(printf 'result_add "bench_x" "x" "$ST_FAIL" "d" ""\n' | grep -cE 'ST_WARN|ST_FAIL' || true)"
# 生成物这一头也钉一条：报告里 bench_ 那几行不许出现 FAIL/WARN 的徽章。
check "报告里性能基准那一节没有 FAIL/WARN 徽章" "0" \
      "$(python3 - "$OUTA" <<'PYEOF'
import re, sys
h = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"<h2>三、性能基准</h2>(.*?)<h2>", h, re.S)
print(len(re.findall(r'class="badge b-(?:FAIL|WARN)"', m.group(1))) if m else 0)
PYEOF
)"

# 同一个数字不许印两遍：platform / conform / bench 三组有自己的小节，
# 就不该再出现在「其他实测指标」那张大表里
check "已经有专属小节的指标不再进「其他实测指标」" "0" \
      "$(grep -oE '<td>平台设置</td>|<td>配置核对</td>|<td>性能基准</td>' "$OUTA" | grep -c . || true)"

# ================================================================
echo
echo "=== 「我们没测到」的 SKIP 不进交付报告（origin=self，1.9.4）==="
#
# 1.9.3 的交付报告里印过这么两行：
#     SKIP  CPU 计算正确性   当前测试环境未包含处理器计算正确性诊断程序
#     SKIP  显卡专项诊断     当前测试环境未包含显卡厂商诊断程序
# 客户读到的不是"这台机器没问题"，是"这家供应商的工具箱是破的"。
# 这一组钉三头，缺一头另外两头都能装成绿的：
#   ① 交付报告里那两行没了            ② 内部报告里一个字都不少
#   ③ **不带 origin 的 SKIP 照常印**（"藏"的规则不许扩大化）
RDS="$TMP/run-selfskip"
cp -r "$RD" "$RDS"
cat >> "$RDS/results.jsonl" <<'EOF'
{"id":"validate_cpu_sdc","name":"CPU 计算正确性","status":"SKIP","detail":"当前测试环境未包含处理器计算正确性诊断程序，本项未做核对。此项不影响整机结论。","ref":"","time":"t","origin":"self"}
{"id":"validate_gpu_diag","name":"显卡专项诊断","status":"SKIP","detail":"当前测试环境未包含显卡厂商诊断程序，本项未做核对。此项不影响整机结论。","ref":"","time":"t","origin":"self"}
{"id":"bench_gpu_p2p","name":"显卡间互联带宽","status":"SKIP","detail":"本机只安装了 1 张显卡，没有卡与卡之间的互联通道可测，本项未做测试。此项不影响整机结论。","ref":"","time":"t"}
{"id":"validate_cpu_sdc_fail_probe","name":"部件自己报的故障","status":"FAIL","detail":"处理器在计算正确性诊断中出现了错误的运算结果。","ref":"","time":"t","origin":"self"}
EOF
OUTS="$TMP/report-selfskip.html"
"$GEN" --run-dir "$RDS" --out "$OUTS" >/dev/null 2>&1
has_no "$OUTS" "当前测试环境未包含处理器计算正确性诊断程序" \
       "没带程序的 SKIP 不许印给客户"
has_no "$OUTS" "当前测试环境未包含显卡厂商诊断程序" \
       "没带程序的 SKIP 不许印给客户（显卡这条同理）"
# ② **"这台机器上没有可测的东西"不是 self**，照常印 —— 客户有权知道哪些没测。
has "$OUTS" "本机只安装了 1 张显卡" \
    "机器本身的事实照常印（藏的规则不许扩大化到所有 SKIP）"
# ③ origin=self **只对 SKIP 有意义**。部件自己给的 FAIL 是真故障，
#    一条都不许藏 —— 这一条是整组里最要紧的。
has "$OUTS" "处理器在计算正确性诊断中出现了错误的运算结果" \
    "带 origin 的 FAIL 一条都不许藏（那是部件自己说的真故障）"

# ================================================================
echo
echo "=== 序列号一致性不进交付报告（1.9.4）==="
#
# 它查的是**文书**对不对得上（主板 BIOS / BMC / 机身标签），不是硬件有没有毛病。
# 组装机上 BIOS 那一格本来就没人填、也没地方填，报告于是每台都挂一条黄的
# 「主板 BIOS 未填写整机序列号，建议出货前补写」——
# 客户读到的是"这台机器有问题"，而它连硬件都不是。
RDN="$TMP/run-sn"
cp -r "$RD" "$RDN"
cat >> "$RDN/results.jsonl" <<'EOF'
{"id":"check_sn_consistency","name":"序列号一致性","status":"WARN","detail":"主板 BIOS 未填写整机序列号，管理控制器记录为 24003702CHK04234。建议出货前在 BIOS 中补写，使系统内、管理控制器与机身标签三处一致。","ref":"raw/ipmi-fru.txt","time":"t"}
EOF
OUTN="$TMP/report-sn.html"
"$GEN" --run-dir "$RDN" --out "$OUTN" >/dev/null 2>&1
has_no "$OUTN" "建议出货前在 BIOS 中补写" "序列号那条告警不进交付报告"
has_no "$OUTN" "序列号一致性"             "整条判定都不进交付报告"
# ⚠️ **藏的只是那条判定，序列号本身照常印**（抬头 + 1.1 整机那张表）——
#    把序列号一起藏掉的话，这份报告就对不上机器了，那是另一种翻车。
has "$OUTN" "整机序列号" "整机序列号本身照常出现在报告里"

# ---------------------------------------------------------------- 指路不许指空
#
# 判定文案里有几处「……见下方「X」」。X 是报告里某个小节的标题，而那些小节
# 是"有数据才画"的、标题本身还会跟着数据变（逐盘带宽表在只测了读的时候
# 叫「硬盘顺序读带宽」）。两边一旦对不上，客户读到的就是一句指向
# 报告里根本不存在的小节的话 —— 和 1.7.6 那句指向被藏掉的 SMART 复查
# 是同一个毛病，那次是靠人眼看出来的。
#
# ⚠️ 先自检**这份报告里真的有指路可查**。一条"遍历零个元素"的断言永远是绿的，
#    而且和"全都指得中"长得一模一样 —— 这正是本轮删掉的那条假断言的病根。
for rpt in "$OUTA" "$OUTW"; do
  check "$(basename "$rpt")：至少有一句「见下方「X」」（否则下面那条是空转）" "yes" \
        "$(grep -oE '见下方「[^」]+」' "$rpt" | grep -q . && echo yes || echo no)"
  check "$(basename "$rpt")：每一句「见下方「X」」都能找到对应的标题" "" \
        "$(python3 - "$rpt" <<'PYEOF'
import re, sys
h = open(sys.argv[1], encoding="utf-8").read()
heads = set(re.findall(r"<h[23]>(?:[\d.]+\s*)?([^<]+)</h[23]>", h))
names = set(re.findall(r'<span class="rn">([^<]+)</span>', h))
bad = [t for t in re.findall(r"见下方「([^」]+)」", h)
       if t not in heads and t not in names]
print("、".join(sorted(set(bad))))
PYEOF
)"
done
# 同样要能变红：把一个不存在的小节名喂给同一条判据。
check "指路守卫抓得住指空的那一句" "查无此节" \
      "$(python3 - <<'PYEOF'
import re
h = '<h3>3.2 真的有这一节</h3><p>见下方「查无此节」</p>'
heads = set(re.findall(r"<h[23]>(?:[\d.]+\s*)?([^<]+)</h[23]>", h))
print("、".join(t for t in re.findall(r"见下方「([^」]+)」", h) if t not in heads))
PYEOF
)"

# ================================================================
echo
echo "=== 测试范围（单项专测，1.9.5）==="
#
# 这一组守的是这个功能**唯一不能犯的错**：
#
#   ⚠️⚠️ 范围模式的报告绝不能看起来像"这台机器全测过了"。
#
# 一台只测了 CPU 的机器，报告上打一个和全量测试一模一样的绿色 PASS，
# 半年后没人分得清它到底测过什么 —— 那比不做这个功能还糟。
# 所以每个范围都要验四件事：抬头写明范围、没测的部件不出结论行、
# 编号不断号、指路句不指空；info 那一档另外验"不许出 PASS 大字"。

# 报告里的编号自检：一级章节按「一二三四五」顺序、二级编号在每一节里
# 从 1 连续数上去。**裁掉小节最典型的翻车就是断号**（3.1 之后直接 3.3），
# 而那是纯人眼才看得出来的东西，所以在这里算给它看。
numbering_bad() {
  python3 - "$1" <<'PYEOF'
import re, sys
h = open(sys.argv[1], encoding="utf-8").read()
CN = "一二三四五六七八九十"
bad = []
h2 = re.findall(r"<h2>([^<]+)</h2>", h)
for i, t in enumerate(h2):
    if not t.startswith(CN[i] + "、"):
        bad.append("一级章节第 %d 个应以「%s、」开头，实际是「%s」" % (i + 1, CN[i], t))
# 二级编号：按出现顺序分组，每组内必须是 N.1 N.2 N.3 …
subs = re.findall(r"<h3>(\d+)\.(\d+) ", h)
seen = {}
for major, minor in subs:
    want = seen.get(major, 0) + 1
    if int(minor) != want:
        bad.append("小节 %s.%s 断号（应为 %s.%d）" % (major, minor, major, want))
    seen[major] = int(minor)
# 一级章节的序号和它下面二级编号的前缀要对得上
for i, t in enumerate(h2):
    m = [k for k in seen if int(k) == i + 1]
    if t.startswith(CN[i] + "、") and not m and i + 1 in [int(k) for k in seen]:
        bad.append("章节「%s」下的小节前缀不是 %d" % (t, i + 1))
print("；".join(bad))
PYEOF
}
# 先证明这个自检**抓得住**断号，否则它和一条永远为真的断言没区别
check "编号自检抓得住断号" "小节 3.3 断号（应为 3.2）" \
      "$(printf '<h2>一、a</h2><h2>二、b</h2><h2>三、c</h2><h3>3.1 x</h3><h3>3.3 y</h3>' \
         > "$TMP/nb.html"; numbering_bad "$TMP/nb.html")"

# 每个范围各造一份 run-dir：**只放这个范围真的会产生的结论行**。
# 这正是产品的行为（范围之外整项不跑、不出结论行），fixture 要照着它造，
# 不能"全都放进去再指望报告去藏"——那是另一种实现，而我们没有实现它。
COMMON_ROWS='{"id":"collect_system","name":"硬件信息采集","status":"PASS","detail":"采集完成","ref":"","time":"t"}
{"id":"check_mem_cap","name":"内存容量核对","status":"PASS","detail":"装机容量与系统识别容量一致","ref":"","time":"t"}
{"id":"check_dimm_uniform","name":"内存条一致性","status":"PASS","detail":"8 条内存规格一致","ref":"","time":"t"}
{"id":"check_bios_profile","name":"平台关键设置","status":"PASS","detail":"已读取平台关键设置的实际状态。","ref":"","time":"t"}
{"id":"test_nic","name":"网卡连通性","status":"PASS","detail":"1 个口 ping 通网关","ref":"","time":"t"}
{"id":"check_psu","name":"电源","status":"PASS","detail":"2 个电源模块均在位且进电","ref":"","time":"t"}'

scope_rows() {
  printf '%s\n' "$COMMON_ROWS"
  case "$1" in
    cpu)  cat <<'EOF'
{"id":"bench_cpu_flops","name":"CPU 浮点算力","status":"PASS","detail":"全核浮点矩阵运算（问题规模 40000 阶，重复 4 次取最好成绩）的平均算力实测 3010.0 GFlops。","ref":"","time":"t"}
{"id":"validate_cpu_sdc","name":"CPU 计算正确性","status":"PASS","detail":"全核运行 120 秒的计算正确性诊断，未发现计算结果错误","ref":"","time":"t"}
{"id":"stress_cpu","name":"CPU 压力测试","status":"PASS","detail":"全核满载 10 分钟，未出现错误","ref":"","time":"t"}
{"id":"verify_ecc","name":"内存 ECC 复查","status":"PASS","detail":"压测前后未新增 ECC 错误","ref":"","time":"t"}
{"id":"verify_throttle","name":"CPU 热节流复查","status":"PASS","detail":"压测期间未触发热节流","ref":"","time":"t"}
{"id":"verify_dmesg","name":"内核日志复查","status":"PASS","detail":"压测期间内核日志无硬件错误","ref":"","time":"t"}
EOF
          ;;
    mem)  cat <<'EOF'
{"id":"bench_mem_bw","name":"内存读取带宽","status":"PASS","detail":"内存满负载读取带宽实测 245678.9 MB/s。","ref":"","time":"t"}
{"id":"stress_mem","name":"内存压力测试","status":"PASS","detail":"内存满载 10 分钟，未出现错误","ref":"","time":"t"}
{"id":"verify_ecc","name":"内存 ECC 复查","status":"PASS","detail":"压测前后未新增 ECC 错误","ref":"","time":"t"}
{"id":"verify_dmesg","name":"内核日志复查","status":"PASS","detail":"压测期间内核日志无硬件错误","ref":"","time":"t"}
EOF
          ;;
    gpu)  cat <<'EOF'
{"id":"bench_gpu_bw","name":"显卡数据传输带宽","status":"PASS","detail":"主机与显卡之间的数据传输带宽实测 24.5 GB/s。","ref":"","time":"t"}
{"id":"check_gpu_ecc","name":"显存 ECC","status":"PASS","detail":"未出现显存 ECC 错误","ref":"","time":"t"}
{"id":"stress_gpu","name":"GPU 压力测试","status":"PASS","detail":"2 张显卡满载 10 分钟，未出现计算错误","ref":"","time":"t"}
{"id":"check_gpu_load","name":"显卡满载运行状态","status":"PASS","detail":"满载期间各卡的实测运行读数：显卡0：平均频率 2500MHz。","ref":"","time":"t"}
{"id":"verify_dmesg","name":"内核日志复查","status":"PASS","detail":"压测期间内核日志无硬件错误","ref":"","time":"t"}
EOF
          ;;
    disk) cat <<'EOF'
{"id":"bench_disk_bw","name":"硬盘读写带宽","status":"PASS","detail":"对 1 块硬盘逐块测量 128KB 大块顺序读带宽（每块每个方向各 20 秒），逐盘数值见下方「硬盘顺序读带宽」。本次未进行破坏性写入测试，因此只测量了读带宽。","ref":"raw/bench/","time":"t"}
{"id":"stress_disk","name":"硬盘压力测试","status":"PASS","detail":"对 1 块硬盘进行了 10 分钟读写压力测试","ref":"","time":"t"}
{"id":"verify_smart","name":"硬盘 SMART 复查","status":"PASS","detail":"1 块盘压测前后无新增坏道/错误计数","ref":"raw/smart-post/","time":"t"}
{"id":"verify_disk_temp","name":"硬盘温度","status":"PASS","detail":"压测后各盘温度均在正常范围","ref":"","time":"t"}
{"id":"verify_dmesg","name":"内核日志复查","status":"PASS","detail":"压测期间内核日志无硬件错误","ref":"","time":"t"}
EOF
          ;;
    info) cat <<'EOF'
{"id":"bench_cpu_flops","name":"CPU 浮点算力","status":"PASS","detail":"全核浮点矩阵运算（问题规模 40000 阶，重复 4 次取最好成绩）的平均算力实测 3010.0 GFlops。","ref":"","time":"t"}
{"id":"bench_mem_bw","name":"内存读取带宽","status":"PASS","detail":"内存满负载读取带宽实测 245678.9 MB/s。","ref":"","time":"t"}
EOF
          ;;
  esac
}

declare -A SCOPE_BUDGET=(
  [cpu]='{"cpu_secs":600,"mem_secs":0,"disk_secs":0,"gpu_secs":0,"bench_secs":90}'
  [mem]='{"cpu_secs":0,"mem_secs":600,"disk_secs":0,"gpu_secs":0,"bench_secs":90}'
  [gpu]='{"cpu_secs":0,"mem_secs":0,"disk_secs":0,"gpu_secs":600,"bench_secs":90}'
  [disk]='{"cpu_secs":0,"mem_secs":0,"disk_secs":600,"gpu_secs":0,"bench_secs":90}'
  [info]='{"cpu_secs":0,"mem_secs":0,"disk_secs":0,"gpu_secs":0,"bench_secs":90}'
)
declare -A SCOPE_NAME=(
  [cpu]="CPU 专项测试" [mem]="内存专项测试" [gpu]="显卡专项测试"
  [disk]="硬盘专项测试" [info]="仅导出硬件信息"
)

for sc in cpu mem gpu disk info; do
  RS="$TMP/run-scope-$sc"
  mkdir -p "$RS/raw"
  cp -r "$RD/raw/." "$RS/raw/" 2>/dev/null || true
  scope_rows "$sc" > "$RS/results.jsonl"
  printf '{"group":"platform","key":"处理器 x2APIC","value":"已关闭"}\n' > "$RS/metrics.jsonl"
  python3 - "$RS/meta.json" "$sc" "${SCOPE_BUDGET[$sc]}" <<'PYEOF'
import json, sys
path, scope, budget = sys.argv[1], sys.argv[2], sys.argv[3]
m = {
    "klburn_version": "1.9.5", "company_name": "广州市鲲林科技有限公司",
    "base_os": "Ubuntu Server 24.04.4", "build_date": "2026-08-10 10:00:00",
    "serial": "TESTSN0001", "scope": scope,
    "profile": "INVENTORY" if scope == "info" else "QUICK",
    "planned_secs": 0 if scope == "info" else 600, "elapsed_secs": 700,
    "start_time": "2026-08-10 10:00:00", "end_time": "2026-08-10 10:11:40",
    "budget": json.loads(budget),
    "disk_confirmed": 1 if scope == "disk" else 0,
    "data_partition": "/dev/sdb1", "clock_synced": 1, "clock_suspect": 0,
}
json.dump(m, open(path, "w", encoding="utf-8"), ensure_ascii=False)
PYEOF
  # 硬盘专测那份要有逐盘带宽表，否则那句「见下方「硬盘顺序读带宽」」指空
  if [[ "$sc" == "disk" ]]; then
    mkdir -p "$RS/raw/bench"
    cat > "$RS/raw/bench/fio-sda-read.json" <<'EOF'
{"jobs":[{"jobname":"libaio_read_128k_32_1","read":{"bw":532480,"iops":4160},"write":{"bw":0,"iops":0},"error":0}]}
EOF
    # 逐盘 SMART 对比要有**坏道类**属性才画得出来。基础 fixture 那块盘一条
    # 都没有（真实存在的情况：某些盘不上报这些属性），所以这里单独造一块。
    # 顺便把寿命类字段也塞进去 —— 下面有一组断言钉着它们**不许**被印出来。
    cat > "$RS/raw/smart-pre/sda.norm.json" <<'EOF'
{"model":"ST1000NM000A-2J3100","serial":"WS20SNM6","firmware":"TN03",
 "realloc_sectors":0,"pending_sectors":0,"uncorrectable":0,"crc_errors":0,
 "power_on_hours":1512,"power_cycles":325,"percentage_used":3,
 "temperature_c":29,"smart_passed":true}
EOF
    cat > "$RS/raw/smart-post/sda.norm.json" <<'EOF'
{"model":"ST1000NM000A-2J3100","serial":"WS20SNM6","firmware":"TN03",
 "realloc_sectors":0,"pending_sectors":0,"uncorrectable":0,"crc_errors":0,
 "power_on_hours":1512,"power_cycles":325,"percentage_used":3,
 "temperature_c":31,"smart_passed":true}
EOF
  fi
  # CPU 专测那份要有逐颗封装温度，才画得出「逐颗 CPU 满载温度」
  if [[ "$sc" == "cpu" ]]; then
    cat > "$RS/sys_metrics.csv" <<'EOF'
time,phase,cpu_temp_c,cpu_freq_mhz,load1,mem_used_mb,mem_total_mb,cpu_power_w,cpu_pkg_temps,ecc_ce,ecc_ue
10:00:05,cpu,45,1156,8.28,2305,31763,95,44;45,0,0
10:00:10,cpu,71,2699,17.87,2764,31763,281,52;71,0,0
10:00:15,cpu,78,2681,64.20,2795,31763,347,55;78,0,0
EOF
  fi
  # 内存专测那份要有前后 ECC 快照，才画得出逐条对比表
  if [[ "$sc" == "mem" ]]; then
    printf '# snap\nECC CPU0_DIMM_A1 0 0\nECC CPU0_DIMM_B1 0 0\n' > "$RS/raw/counters-pre.txt"
    printf '# snap\nECC CPU0_DIMM_A1 3 0\nECC CPU0_DIMM_B1 0 0\n' > "$RS/raw/counters-post.txt"
  fi
  # 显卡专测那份要有逐卡频率/风扇采样
  if [[ "$sc" == "gpu" ]]; then
    cat > "$RS/gpu_metrics.csv" <<'EOF'
time,index,name,temp_c,power_w,clock_sm_mhz,util_pct,mem_used_mb,fan_pct,temp_tlimit_c
10:00:05,0,NVIDIA RTX 4090,42,58,420,0,12,30,42
10:00:10,0,NVIDIA RTX 4090,71,431,2520,100,21504,62,13
10:00:15,0,NVIDIA RTX 4090,79,449,2490,100,21504,71,5
EOF
  fi

  OUTS="$TMP/report-scope-$sc.html"
  "$GEN" --run-dir "$RS" --out "$OUTS" >/dev/null 2>&1
  check "$sc：报告生成成功" "0" "$?"

  # ① 抬头必须写明范围 —— 这是整组里最要紧的一条
  has "$OUTS" "本轮范围 <b>${SCOPE_NAME[$sc]}</b>" "$sc：抬头写明本轮范围"
  # ② 结论块下面紧跟一句"范围以外的部件这一轮没有测过"。
  #    单项专测和 info 的措辞不一样：前者说"这几项不作结论"，
  #    后者要直说"这份报告不能当验收依据"。
  if [[ "$sc" == "info" ]]; then
    has "$OUTS" "不能作为出厂验收依据" "$sc：明说这份报告不能当验收依据"
  else
    has "$OUTS" "本报告不对这几项的可靠性作出结论" "$sc：说明范围外的部件这一轮没测"
  fi
  # ③ 编号不断号
  check "$sc：一级/二级编号都不断号" "" "$(numbering_bad "$OUTS")"
  # ④ 指路句不指空
  check "$sc：每一句「见下方「X」」都能找到对应的标题" "" \
        "$(python3 - "$OUTS" <<'PYEOF'
import re, sys
h = open(sys.argv[1], encoding="utf-8").read()
heads = set(re.findall(r"<h[23]>(?:[\d.]+\s*)?([^<]+)</h[23]>", h))
names = set(re.findall(r'<span class="rn">([^<]+)</span>', h))
print("、".join(sorted({t for t in re.findall(r"见下方「([^」]+)」", h)
                       if t not in heads and t not in names})))
PYEOF
)"
  # ⑤ 硬件清单八节在任何范围下都保留（"有啥列啥、没有的标未安装"这条不变量
  #    不因为范围而松动 —— 那八节正是单项专测的人也要核对的"平台参数"）
  check "$sc：硬件清单仍然是 8 个小节" "8" "$(cnt "$OUTS" '<h3>1\.[0-9]+ ')"
  # ⑥ 范围外的压测时长不许印一行 0 秒（读的人会以为那一项失败了）
  case "$sc" in
    cpu)  has_no "$OUTS" "内存压测时长" "$sc：范围外的压测时长不出现"
          has_no "$OUTS" "GPU 压测时长"  "$sc：同上" ;;
    mem)  has_no "$OUTS" "CPU 压测时长"  "$sc：范围外的压测时长不出现" ;;
    disk) has_no "$OUTS" "CPU 压测时长"  "$sc：范围外的压测时长不出现" ;;
  esac
done

# ---------------------------------------------------------------- info 那一档
#
# ⚠️⚠️ **这是整个功能的安全项。**一台只导出了配置清单的机器，报告上打一个
#    绿色 PASS 大字，读的人得到的信息是"这台机器合格" —— 而报告里没有任何
#    东西支持这个结论。tests/mutate.sh 里有一条变异专门守着它。
OUTI="$TMP/report-scope-info.html"
check "info：不许出现 PASS 大字" "0" "$(cnt "$OUTI" 'class="verdict v-PASS"')"
has "$OUTI" 'class="verdict v-INFO"' "info：换成中性的结论块"
has "$OUTI" "仅硬件信息 · 未做测试"   "info：结论块上写明这不是一次测试"
has "$OUTI" "不能作为出厂验收依据"     "info：明说这份报告不能当验收依据"
has "$OUTI" "四、其他检查结论"         "info：那一节不许顶着「压力测试结果」的标题"
# ⚠️ 抬头里「测试模式 不做压测」和「本轮范围 仅导出硬件信息」是同一件事说两遍。
#    那一档没有时长菜单，档位这一格根本没有意义（1.9.6 去掉）。
#    **成对断言**：info 里没有、别的范围里照常有 —— 只钉前一条的话，
#    把整行删掉也能让它变绿。
has_no "$OUTI" "测试模式"              "info：没有时长可选，就不该印「测试模式」"
has "$TMP/report-scope-cpu.html" "测试模式" "别的范围照常印「测试模式」（证明上面那条不是把整行删了）"
has_no "$OUTI" "压力测试结果"          "info：一个压测都没跑，不许出现这个标题"
has_no "$OUTI" "压测时长"              "info：没有压测就没有压测时长表"
# 但配置核对和硬件清单一个字都不能少 —— 那正是这一档的全部价值
has "$OUTI" "一、硬件清单" "info：硬件清单照常"
has "$OUTI" "二、配置核对" "info：配置核对照常"
has "$OUTI" "三、性能基准" "info：性能基准照跑（几十秒的事，而且不写盘）"

# ---------------------------------------------------------------- 范围里的部件不在这台机器上
#
# 选了「显卡专项测试」，插的却是一台没有独立显卡的机器（现场手滑 / 拿错机器）。
# 1.9.6 之前这种情况打的是**绿色 PASS**，下面还写着"本轮只对显卡做了压力测试
# 与专项诊断"—— 而它一项都没做。把"没测"包装成"通过"，比不做这个功能还糟。
#
# 1.9.7 起：主流程直接跳出、判 FAIL。但 **FAIL 的含义是"这一轮作废"，
# 不是"这台机器坏了"** —— 没装显卡的机器本身一点毛病都没有。
RSM="$TMP/run-scope-missing"
mkdir -p "$RSM/raw"
cp -r "$RD/raw/." "$RSM/raw/" 2>/dev/null || true
cat > "$RSM/results.jsonl" <<'EOF'
{"id":"collect_system","name":"硬件信息采集","status":"PASS","detail":"采集完成","ref":"","time":"t"}
{"id":"gpu_detect","name":"GPU","status":"SKIP","detail":"未安装独立显卡","ref":"","time":"t"}
{"id":"scope_target_missing","name":"本轮测试未执行","status":"FAIL","detail":"本轮选择的是显卡专项测试，但本机未检测到可用的独立显卡，测试**未执行**。这不是硬件故障 —— 请确认是不是选错了测试范围、或者测错了机器，重新测试后以新报告为准。","ref":"","time":"t"}
EOF
printf '' > "$RSM/metrics.jsonl"
python3 - "$RSM/meta.json" <<'PYEOF'
import json, sys
json.dump({"klburn_version":"1.9.7","company_name":"广州市鲲林科技有限公司",
           "base_os":"Ubuntu Server 24.04.4","build_date":"2026-08-11 10:00:00",
           "serial":"TESTSN0001","scope":"gpu","profile":"QUICK",
           "planned_secs":600,"elapsed_secs":180,
           "start_time":"2026-08-11 10:00:00","end_time":"2026-08-11 10:03:00",
           "budget":{"cpu_secs":0,"mem_secs":0,"disk_secs":0,"gpu_secs":0},
           "disk_confirmed":0,"data_partition":"/dev/sdb1"},
          open(sys.argv[1],"w",encoding="utf-8"), ensure_ascii=False)
PYEOF
OUTSM="$TMP/report-scope-missing.html"
"$GEN" --run-dir "$RSM" --out "$OUTSM" >/dev/null 2>&1
check "范围内部件缺失：报告生成成功" "0" "$?"

# ① 必须是 FAIL 大字（用户要的就是这个：绝不能再是绿的）
check "结论必须是 FAIL，不许是 PASS" "1" "$(cnt "$OUTSM" 'class="verdict v-FAIL"')"
check "一个 PASS 大字都不许有" "0" "$(cnt "$OUTSM" 'class="verdict v-PASS"')"

# ② ⚠️ 但**绝不能**说这台机器有毛病 —— 一号红线。
#    没装显卡的机器本身没问题，「不建议出货」会把一台好机器拦在出货前。
has_no "$OUTSM" "本机存在未通过项，不建议出货" \
       "缺部件那条 FAIL 不许套用「不建议出货」（那是说硬件坏了）"
has "$OUTSM" "本轮测试未执行"  "要说清楚这一轮没执行"
has "$OUTSM" "这不是硬件故障"  "要明说这不是硬件故障"
has "$OUTSM" "选错了测试范围"  "要给出下一步怎么办"

# ③ 那句写死的 cover 文案不许出现 —— 它说"本轮只对显卡做了压力测试与专项诊断"，
#    而这一轮根本没做（说得比做得多）。
has_no "$OUTSM" "本轮只对 <b>显卡</b> 做了压力测试与专项诊断" \
       "不许再印那句「已经对显卡做了压测」——这一轮压根没做"

# ④ 硬件清单照常八节：客户还是要知道这台机器装了什么
check "硬件清单仍然是 8 个小节" "8" "$(cnt "$OUTSM" '<h3>1\.[0-9]+ ')"

# ⑤ 硬盘那一档同理（同一个机制，但抬头里的范围名要跟着变）
RSD="$TMP/run-scope-missing-disk"
cp -r "$RSM" "$RSD"
python3 - "$RSD/meta.json" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8")); m["scope"] = "disk"
json.dump(m, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
PYEOF
cat > "$RSD/results.jsonl" <<'EOF'
{"id":"collect_system","name":"硬件信息采集","status":"PASS","detail":"采集完成","ref":"","time":"t"}
{"id":"scope_target_missing","name":"本轮测试未执行","status":"FAIL","detail":"本轮选择的是硬盘专项测试，但本机未发现可测试的硬盘，测试**未执行**（本机未安装硬盘，或者盘都在使用中、不参与破坏性测试）。这不是硬件故障 —— 请确认是不是选错了测试范围、或者测错了机器，重新测试后以新报告为准。","ref":"","time":"t"}
EOF
OUTSD="$TMP/report-scope-missing-disk.html"
"$GEN" --run-dir "$RSD" --out "$OUTSD" >/dev/null 2>&1
check "硬盘那档：报告生成成功" "0" "$?"
check "硬盘那档：结论也是 FAIL" "1" "$(cnt "$OUTSD" 'class="verdict v-FAIL"')"
has "$OUTSD" "硬盘专项测试" "抬头那句要写成硬盘专项测试，不是显卡"
has_no "$OUTSD" "本机存在未通过项，不建议出货" "同样不许说这台机器有毛病"

# ---------------------------------------------------------------- 单项专测写得更细
has "$TMP/report-scope-cpu.html"  "逐颗 CPU 满载温度"          "cpu：给出逐颗温度"
has "$TMP/report-scope-mem.html"  "逐条内存 ECC 计数"          "mem：给出逐条 ECC 对比"
has "$TMP/report-scope-gpu.html"  "逐卡满载频率 / 风扇曲线"     "gpu：给出频率/风扇曲线"
has "$TMP/report-scope-disk.html" "逐盘 SMART 关键项"          "disk：给出逐盘 SMART 对比"
# ⚠️ 加细不等于放宽红线：寿命类字段在**任何**范围下都不进交付报告。
for f in 通电时间 通电次数 已用寿命 percentage_used power_on_hours; do
  has_no "$TMP/report-scope-disk.html" "$f" "disk：寿命类字段照样不进交付报告"
done
# 全量报告里一格都不多（它本来就够长了）
for f in "逐颗 CPU 满载温度" "逐条内存 ECC 计数" "逐盘 SMART 关键项"; do
  has_no "$OUTA" "$f" "全量报告里不加这些专项明细"
done

# ---------------------------------------------------------------- 不许出空章节
#
# 「性能基准」整节是有条件的。判据必须是**这一节真的画得出东西**，
# 不能把 bench 组的指标也算进去 —— 那几个指标在这一节里一格都不单独印
# （每个数都写在对应那条结论里），拿它当判据就会出现一个
# 只有标题和导语、底下什么都没有的空章节。
# 而且指标本身也不能因此蒸发：整节没画时它们要退回「其他实测指标」。
RDB="$TMP/run-bench-metric-only"
cp -r "$RD" "$RDB"
cat >> "$RDB/metrics.jsonl" <<'EOF'
{"group":"bench","key":"内存读取带宽（MB/s）","value":"245678.9"}
EOF
OUTB="$TMP/report-bench-metric-only.html"
"$GEN" --run-dir "$RDB" --out "$OUTB" >/dev/null 2>&1
has_no "$OUTB" "<h2>三、性能基准</h2>" "一条 bench 判定都没有时不许画出性能基准那一节"
has    "$OUTB" "245678.9"              "整节没画时，bench 指标必须退回「其他实测指标」而不是蒸发"
has    "$OUTB" "<td>性能基准</td>"      "退回去的那一行要带上分组名"

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
