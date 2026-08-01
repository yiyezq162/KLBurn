#!/usr/bin/env bash
#
# 内部工程报告（raw/INTERNAL_*.html）的渲染回归测试。
#
#     ./tests/test-internal-report.sh
#
# 这份报告和客户报告是**互补**的，所以断言也是成对的：
#   客户报告绝不能有的（通电时间、git commit、内部工具名）  -> 内部报告必须有
#   两份都不能崩：空 run-dir、缺 raw 文件、老版本 run-dir（没有新加的列）
#
# 为什么要专门测"必须有"：内部报告的全部价值就在那几个客户看不到的字段上。
# 哪天有人为了图省事把它改成直接复用客户报告的 disks()，通电时间就没了，
# 而这种"少了点东西"的退化，不写断言根本不会有人发现。
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="$ROOT/rootfs/opt/klburn/report/generate_internal.py"
CUST="$ROOT/rootfs/opt/klburn/report/generate_report.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
has()    { grep -qF -- "$2" "$1" && ok "内部报告含「$2」：$3" || bad "内部报告应含「$2」：$3"; }
has_no() { grep -qF -- "$2" "$1" && bad "内部报告不应有「$2」：$3" || ok "内部报告无「$2」：$3"; }

# 断言函数名打错不能静悄悄地过去（§11-13"断言悄悄停止计数"的同款病）：
# 本脚本不开 set -e，`xxx: command not found` 只往 stderr 打一行就没了，
# PASS/FAIL 都不动 —— 屏幕照样"全部通过"，只是少跑了几条。实测踩到过一次。
command_not_found_handle() {
  bad "调用了不存在的命令 '$1'（多半是断言函数名打错，这条断言根本没跑）" "已定义的函数" "$1"
  return 127
}

command -v python3 >/dev/null 2>&1 || { echo "需要 python3"; exit 1; }

# ================================================================
# 造 run-dir：一台双路机，两颗 CPU 温差 22°C、一块盘通电两万小时、
# 一块 SSD 磨损 23%、内存混插、一个万兆口只协商到千兆、采集有一条超时。
# 每一条都对应内部评估里的一条规则。
# ================================================================
RD="$TMP/20260731_101500_2x-Intel-Xeon-Gold-6530_512GB"
mkdir -p "$RD/raw/smart-pre" "$RD/raw/smart-post" "$RD/raw/nic" "$RD/raw/deep" "$RD/raw/stress"

cat > "$RD/meta.json" <<'EOF'
{
  "klburn_version": "1.0.0",
  "git_commit":     "abc1234-dirty",
  "company_name":   "广州市鲲林科技有限公司",
  "report_title":   "服务器出厂老化测试报告",
  "product_name":   "KLBurn",
  "base_os":        "Ubuntu Server 24.04.4",
  "build_date":     "2026-07-31 09:00:00",
  "include_nvidia": "1",
  "nvidia_version": "595.84",
  "gpu_present":    2,
  "gpu_usable":     1,
  "gpu_mismatch":   1,
  "storcli_present": 0,
  "gpu_burn_present": 1,
  "serial":         "SN-TEST-0001",
  "run_stamp":      "20260731_101500",
  "machine_tag":    "20260731_101500_2x-Intel-Xeon-Gold-6530_512GB",
  "profile":        "STANDARD",
  "planned_secs":   1800,
  "elapsed_secs":   1850,
  "start_time":     "2026-07-31 10:15:00",
  "end_time":       "2026-07-31 10:45:50",
  "kernel":         "6.8.0-45-generic",
  "budget": { "cpu_secs": 1800, "mem_secs": 1800, "disk_secs": 0, "gpu_secs": 1800 },
  "disk_tested":    "",
  "disk_confirmed": 0,
  "thresholds": {
    "cpu_temp_warn": 95, "cpu_temp_fail": 100,
    "gpu_temp_warn": 83, "gpu_temp_fail": 90,
    "disk_temp_warn": 70, "disk_temp_fail": 80
  },
  "data_partition": "/dev/dm-1",
  "clock_synced":   0,
  "clock_suspect":  0
}
EOF

cat > "$RD/results.jsonl" <<'EOF'
{"id":"collect_system","name":"硬件信息采集","status":"PASS","detail":"主板/BIOS/CPU/内存信息采集完成","ref":"raw/dmidecode.txt","time":"2026-07-31 10:15:10"}
{"id":"stress_cpu","name":"CPU 压力测试","status":"PASS","detail":"全核满载 0h30m00s","ref":"raw/stress/cpu-stress-ng.log","time":"2026-07-31 10:45:00"}
{"id":"gpu_detect","name":"GPU","status":"SKIP","detail":"检测到 2 张 NVIDIA 显卡。本次测试环境的显卡驱动版本与其中 1 张不匹配。此项不影响整机结论。","ref":"raw/gpu-lspci.txt","time":"2026-07-31 10:16:00"}
{"id":"stress_disk","name":"硬盘压力测试","status":"SKIP","detail":"现场选择跳过（直接回车），硬盘信息已采集","ref":"","time":"2026-07-31 10:45:30"}
EOF

cat > "$RD/metrics.jsonl" <<'EOF'
{"group":"cpu","key":"峰值温度","value":"78"}
{"group":"pcie","key":"27:00.0 链路","value":"x4 5GT/s / 额定 x8 8GT/s"}
EOF

# sys_metrics.csv：带 0.9.0 新增的 cpu_pkg_temps 列（两颗，温差 22°C）
{
  echo "time,phase,cpu_temp_c,cpu_freq_mhz,load1,mem_used_mb,mem_total_mb,cpu_power_w,cpu_pkg_temps"
  for i in $(seq 1 12); do
    echo "10:$((15+i)):00,cpu,$((60+i)),2400,64.5,12000,524288,320,$((54+i));$((76+i))"
  done
} > "$RD/sys_metrics.csv"

{
  echo "time,index,name,temp_c,power_w,clock_sm_mhz,util_pct,mem_used_mb"
  for i in $(seq 1 8); do
    echo "10:$((15+i)):00,0,NVIDIA GeForce RTX 4090,$((70+i)),430,2520,100,20000"
  done
} > "$RD/gpu_metrics.csv"

# dmidecode：两颗 CPU（基频 2100）、四条内存混插（两个厂商、两种频率）
cat > "$RD/raw/dmidecode.txt" <<'EOF'
Handle 0x0001, DMI type 4, 48 bytes
Processor Information
	Socket Designation: CPU0
	Manufacturer: Intel
	Version: Intel(R) Xeon(R) Gold 6530
	Max Speed: 4000 MHz
	Current Speed: 2100 MHz
	Core Count: 32
	Thread Count: 64
	Status: Populated, Enabled

Handle 0x0002, DMI type 4, 48 bytes
Processor Information
	Socket Designation: CPU1
	Manufacturer: Intel
	Version: Intel(R) Xeon(R) Gold 6530
	Max Speed: 4000 MHz
	Current Speed: 2100 MHz
	Core Count: 32
	Thread Count: 64
	Status: Populated, Enabled

Handle 0x0010, DMI type 17, 92 bytes
Memory Device
	Size: 32 GB
	Locator: CPU0_DIMMA0
	Type: DDR5
	Speed: 5600 MT/s
	Configured Memory Speed: 4800 MT/s
	Manufacturer: Samsung
	Part Number: M321R4GA3BB6
	Serial Number: 11AA22BB

Handle 0x0011, DMI type 17, 92 bytes
Memory Device
	Size: 32 GB
	Locator: CPU0_DIMMB0
	Type: DDR5
	Speed: 4800 MT/s
	Configured Memory Speed: 4800 MT/s
	Manufacturer: Hynix
	Part Number: HMCG88MEBRA
	Serial Number: 33CC44DD

Handle 0x0012, DMI type 17, 92 bytes
Memory Device
	Size: No Module Installed
	Locator: CPU1_DIMMA0

Handle 0x0013, DMI type 17, 92 bytes
Memory Device
	Size: No Module Installed
	Locator: CPU1_DIMMB0
EOF
cp "$RD/raw/dmidecode.txt" "$RD/raw/dmidecode-memory.txt"
printf 'MemTotal:       66584576 kB\n' > "$RD/raw/meminfo.txt"

# 硬盘：sda 通电 21000 小时，nvme0n1 磨损 23% + 异常掉电 300 次 + 压测后新增待处理扇区
cat > "$RD/raw/smart-pre/sda.norm.json" <<'EOF'
{"model":"ST4000NM0035","serial":"WS20SNM6","firmware":"TN04","capacity_bytes":4000787030016,
 "power_on_hours":21000,"power_cycles":412,"temperature_c":38,"smart_passed":true,
 "realloc_sectors":0,"pending_sectors":0,"uncorrectable":0,"crc_errors":0,
 "media_errors":null,"critical_warning":null,"percentage_used":null,"unsafe_shutdowns":null}
EOF
cat > "$RD/raw/smart-post/sda.norm.json" <<'EOF'
{"model":"ST4000NM0035","serial":"WS20SNM6","firmware":"TN04","capacity_bytes":4000787030016,
 "power_on_hours":21000,"power_cycles":412,"temperature_c":47,"smart_passed":true,
 "realloc_sectors":0,"pending_sectors":8,"uncorrectable":0,"crc_errors":0,
 "media_errors":null,"critical_warning":null,"percentage_used":null,"unsafe_shutdowns":null}
EOF
cat > "$RD/raw/smart-pre/nvme0n1.norm.json" <<'EOF'
{"model":"SAMSUNG MZQL21T9HCJR","serial":"S64GNE0T","firmware":"GDC5302Q","capacity_bytes":1920383410176,
 "power_on_hours":9000,"power_cycles":88,"temperature_c":41,"smart_passed":true,
 "realloc_sectors":null,"pending_sectors":null,"uncorrectable":null,"crc_errors":null,
 "media_errors":0,"critical_warning":0,"percentage_used":23,"unsafe_shutdowns":300}
EOF
cp "$RD/raw/smart-pre/nvme0n1.norm.json" "$RD/raw/smart-post/nvme0n1.norm.json"

cat > "$RD/raw/lsblk.json" <<'EOF'
{"blockdevices":[
 {"name":"sda","path":"/dev/sda","size":4000787030016,"type":"disk","rota":true,"tran":"sata","model":"ST4000NM0035"},
 {"name":"nvme0n1","path":"/dev/nvme0n1","size":1920383410176,"type":"disk","rota":false,"tran":"nvme","model":"SAMSUNG MZQL21T9HCJR"}
]}
EOF

# 网卡：一个万兆口只协商到千兆
cat > "$RD/raw/nic/eno1-ethtool.txt" <<'EOF'
Settings for eno1:
	Supported link modes:   1000baseT/Full
	                        10000baseT/Full
	Speed: 1000Mb/s
	Duplex: Full
	Link detected: yes
EOF
printf 'driver: ixgbe\nfirmware-version: 0x800003df\nbus-info: 0000:27:00.0\nmodel: Intel 82599ES\n' \
  > "$RD/raw/nic/eno1-driver.txt"

# 光模块
cat > "$RD/raw/deep/nic-eno1-module.txt" <<'EOF'
	Identifier                                : 0x03 (SFP)
	Vendor name                               : FINISAR CORP
	Vendor PN                                 : FTLX8574D3BCL
	Vendor SN                                 : UW10ABC
	Module temperature                        : 41.32 degrees C
	Laser output power                        : 0.5623 mW / -2.50 dBm
	Rcvr signal avg optical power             : 0.4571 mW / -3.40 dBm
EOF

# 显卡：一张卡不匹配 + PCIe 只跑到 Gen3 x8
cat > "$RD/raw/gpu-driver-mismatch.txt" <<'EOF'
NVRM: The NVIDIA GPU 0000:c9:00.0 (PCI ID: 10de:2bb1) installed in this system is
NVRM: not supported by the NVIDIA 595.84 driver release.
EOF
cat > "$RD/raw/deep/nvidia-inventory.csv" <<'EOF'
index, name, uuid, serial, vbios_version, driver_version, memory.total [MiB], pcie.link.gen.max, pcie.link.gen.current, pcie.link.width.max, pcie.link.width.current
0, NVIDIA GeForce RTX 4090, GPU-abc, N/A, 95.02.18.00.1C, 595.84, 24564 MiB, 4, 3, 16, 8
EOF

# 一条采集超时 + 一条缺工具，验证"环境缺口"那一节
printf 'some output\n\n(TIMEOUT after 20s: lshw -json -quiet)\n' > "$RD/raw/lshw.json"
printf '(command not found: storcli64)\n' > "$RD/raw/storcli-show.txt"

printf 'mce: [Hardware Error]: CPU 3: Machine Check\n' > "$RD/raw/dmesg-errors-boot.txt"
printf 'stress-ng: info: [1] dispatching hogs\n' > "$RD/raw/stress/cpu-stress-ng.log"

# ================================================================
OUT="$RD/raw/INTERNAL_test.html"
echo "=== 生成内部工程报告 ==="
if python3 "$GEN" --run-dir "$RD" --out "$OUT" >"$TMP/stdout" 2>"$TMP/err"; then
  ok "generate_internal.py 正常退出"
else
  bad "generate_internal.py 失败：$(cat "$TMP/err")"
  printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
  exit 1
fi

echo
echo "=== 内部报告必须有这些（客户报告里一个都不能有）==="
has "$OUT" "内部工程报告 · 请勿外发"  "顶部红条，防手滑外发"
has "$OUT" "通电时间"      "挑盘排产的依据"
has "$OUT" "通电次数"      "同上"
has "$OUT" "21000"         "sda 的实际通电小时数"
has "$OUT" "已用寿命"      "SSD 磨损率"
has "$OUT" "abc1234-dirty" "源码 commit，出悬案时靠它对得上"
has "$OUT" "storcli64"     "盘里少带哪个工具，内部要直说"
has "$OUT" "595.84"        "驱动版本"

echo
echo "=== 内部评估必须抓到这台机器的问题 ==="
has "$OUT" "两颗 CPU 满载峰值相差"  "22°C 温差 -> 散热器/风道"
has "$OUT" "内存条厂商不一致"        "Samsung + Hynix 混插"
has "$OUT" "通电时间较长"            "21000 小时那块"
has "$OUT" "已用寿命 23%"            "SSD 磨损"
has "$OUT" "异常掉电"                "300 次"
has "$OUT" "坏道"                    "压测后新增待处理扇区"
has "$OUT" "8 ⚠"                     "前后对比要标出变化"
has "$OUT" "驱动版本不支持"          "不匹配的那张卡"
has "$OUT" "PCIe 链路没跑满"         "Gen3 x8 / 额定 Gen4 x16"
has "$OUT" "没协商到额定速率"        "万兆口只跑千兆"
has "$OUT" "采集过程有"              "超时 + 缺工具"
has "$OUT" "开机阶段有 1 条硬件错误" "dmesg 里的 Machine Check"
has "$OUT" "FINISAR"                 "光模块厂商"
has "$OUT" "本次未做硬盘破坏性读写压测" "disk_confirmed=0"

echo
echo "=== 结论口径不能被内部评估带偏 ==="
# 内部评估里全是"风险/关注"，但整机结论只看 results.jsonl 里有没有 FAIL。
# 这个 fixture 一条 FAIL 都没有，所以必须是 PASS —— 内部的主观判断
# 绝不能反过来把机器判死。
has "$OUT" "无 FAIL 项，整机结论 PASS" "内部评估不改变整机结论"

echo
echo "=== 客户报告仍然干净（成对断言）==="
CUSTOUT="$TMP/customer.html"
if python3 "$CUST" --run-dir "$RD" --out "$CUSTOUT" >/dev/null 2>"$TMP/err2"; then
  for w in "通电时间" "通电次数" "abc1234" "storcli" "已用寿命" "异常掉电"; do
    grep -qF -- "$w" "$CUSTOUT" \
      && bad "客户报告泄漏了「$w」" \
      || ok "客户报告不含「$w」"
  done
else
  bad "客户报告没能生成：$(cat "$TMP/err2")"
fi

echo
echo "=== 边界：不能崩 ==="
EMPTY="$TMP/empty"; mkdir -p "$EMPTY"
printf '{}\n' > "$EMPTY/meta.json"
if python3 "$GEN" --run-dir "$EMPTY" --out "$TMP/empty.html" >/dev/null 2>&1; then
  ok "只有一个空 meta.json 时仍能出内部报告"
else
  bad "空 run-dir 把内部报告生成器搞崩了"
fi

# 三处结论必须同口径：屏幕（factory-test.sh）、交付报告、内部报告。
# 一条判定都没有时，内部这份以前会写"无 FAIL 项，整机结论 PASS" ——
# 而我们正是拿它来查"这轮到底出了什么事"的，它先说了 PASS 就没人往下查了。
EI="$TMP/empty.html"
has_no "$EI" "verdict v-PASS" "一条判定都没有时内部报告也不许打 PASS"
has    "$EI" "verdict v-FAIL" "一条判定都没有时内部报告结论必须是 FAIL"
has    "$EI" "一条判定都没有" "内部评估要点明这轮没跑成，而不是说它通过了"
has_no "$EI" "无 FAIL 项，整机结论 PASS" "没有结果 != 无 FAIL 项"

# 老版本的 run-dir：sys_metrics.csv 没有 cpu_pkg_temps 那一列
OLD="$TMP/old"; mkdir -p "$OLD/raw"
cp "$RD/meta.json" "$OLD/meta.json"
{
  echo "time,phase,cpu_temp_c,cpu_freq_mhz,load1,mem_used_mb,mem_total_mb,cpu_power_w"
  echo "10:16:00,cpu,71,2400,64.5,12000,524288,320"
  echo "10:16:05,cpu,73,2410,65.1,12100,524288,322"
} > "$OLD/sys_metrics.csv"
if python3 "$GEN" --run-dir "$OLD" --out "$TMP/old.html" >/dev/null 2>&1; then
  ok "老 run-dir（没有 cpu_pkg_temps 列）不崩"
else
  bad "老 run-dir 把内部报告生成器搞崩了"
fi

# 默认输出路径必须落在 raw/ 里，且带 INTERNAL_ 前缀 —— 这是防误发的关键
DEF="$TMP/defaultout"; mkdir -p "$DEF"
cp "$RD/meta.json" "$DEF/meta.json"
python3 "$GEN" --run-dir "$DEF" >/dev/null 2>&1
if [[ -f "$DEF/raw/INTERNAL_20260731_101500_2x-Intel-Xeon-Gold-6530_512GB.html" ]]; then
  ok "不给 --out 时默认落到 raw/INTERNAL_<机器名>.html"
else
  bad "默认输出路径不对（防误发全靠它落在 raw/ 里）"
fi

echo
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
