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

# 打错断言函数名（比如把 has_no 写成别的套件里才有的 check）不能静悄悄地过去。
# 本脚本不开 set -e，`check: command not found` 只往 stderr 打一行就没了，
# PASS/FAIL 都不动 —— 屏幕上照样"全部通过"，只是少数了几条。
# 这是 §11-13 那条"断言悄悄停止计数"的同款病，实测又踩了一次，所以立个网。
command_not_found_handle() {
  bad "调用了不存在的命令 '$1' —— 多半是断言函数名打错了，这条断言根本没跑"
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
{"id":"collect_raid","name":"阵列卡","status":"SKIP","detail":"未安装阵列卡；BMC 上为阵列卡/HBA 预留的温度和插槽供电传感器均无读数（板子设计上支持装卡，但这次没读到任何反馈——如果确实装了卡，建议检查卡和转接板/riser 是否插到位）","ref":"","time":"t"}
{"id":"stress_disk","name":"硬盘压力测试","status":"SKIP","detail":"现场选择跳过","ref":"","time":"t"}
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
  has_no "$OUTPD" "通电时间"     "物理盘同样不列寿命类字段"
  has_no "$OUTPD" "megaraid"     "透传参数是内部实现，不该出现在交付报告里"
else
  bad "带阵列卡的报告没能生成：$(cat "$TMP/errpd")"
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
echo "=== 硬盘：跳过压测时「本次压测」必须是「否」 ==="
# 0.3.0 的真实 bug：meta.json 里 disk_tested 写的是"候选盘"而不是"真被写过的盘"，
# 于是现场明明按回车跳过了破坏性写入，1.4 表格里「本次压测」还是显示「是」，
# 和下面 stress_disk 的 SKIP 自相矛盾。上面的 fixture 就是照那次现场数据造的
# （disk_tested 有值、disk_confirmed=0）。
# 断言用「SMART健康 + 本次压测」这一对相邻单元格，避免误伤正文里别处的是/否。
has    "$OUT" "<td>正常</td><td>否</td>" "disk_confirmed=0 时哪怕 disk_tested 有值也必须是「否」"
has_no "$OUT" "<td>正常</td><td>是</td>" "跳过了却标「是」就是 0.3.0 那个 bug"

# 反过来：真的确认并压测了，就必须显示「是」，别矫枉过正一律写成否
RD2="$TMP/run-confirmed"
cp -r "$RD" "$RD2"
sed -i 's/"disk_confirmed": 0/"disk_confirmed": 1/' "$RD2/meta.json"
OUT2="$TMP/report-confirmed.html"
if python3 "$GEN" --run-dir "$RD2" --out "$OUT2" >/dev/null 2>&1; then
  has "$OUT2" "<td>正常</td><td>是</td>" "disk_confirmed=1 时要照常显示「是」"
else
  bad "confirmed 场景的报告没能生成"
fi

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
echo "=== 阵列卡：没装卡时的 BMC 交叉核对提示 ==="
has "$OUT" "为阵列卡/HBA 预留的温度和插槽供电传感器均无读数" \
    "板子有预留传感器但读不到数据时，SKIP 详情里要带上这句提示"

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
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
