#!/usr/bin/env bash
#
# 内存专用盘（KLBURN_EDITION=mem）的回归测试。不需要任何硬件：
#
#     ./tests/test-mem-edition.sh
#
# 这套锁住的是这张盘的**存在理由**和它的**判定边界**：
#
#   1. 报告里必须有逐条内存的序列号 —— 这张盘就是拿来按 SN 点坏条子的，
#      SN 那一列丢了，整张盘就白做了
#   2. **只有内存坏才 FAIL。**坏网卡、坏阵列卡、PCIe 报错一律不许影响结论
#      （用户 2026-08-12 当面定的口径）。所以 dmesg 模式里那几个"看着像该收"
#      的词有成对断言钉着：EDAC 内存错误必须命中，AER/阵列卡报错必须**不**命中
#   3. 报告不许看起来像"这台机器全测过了" —— 和单项专测那条红线同一把尺子
#   4. 出的是哪一种盘，构建时必须真的改到 klburn.service 的 ExecStart
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/rootfs/opt/klburn/lib"
GEN="$ROOT/rootfs/opt/klburn/report/generate_mem_report.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

RAW_DIR="$TMP"; RUN_DIR="$TMP"
# shellcheck source=/dev/null
source "$LIB/core.sh"
# collect.sh 提供 dmi_installed_mem_mb / capture / check_memory_capacity
# shellcheck source=/dev/null
source "$LIB/collect.sh"
# conformance.sh 提供 dmi_dimm_field（memcheck.sh 的 mem_dimm_count 用它）
# shellcheck source=/dev/null
source "$LIB/conformance.sh"
# shellcheck source=/dev/null
source "$LIB/memcheck.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n     期望 [%s] 实际 [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }
check(){ [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$2" "$3"; }
has()    { grep -qF -- "$2" "$1" && ok "$3" || bad "$3" "含「$2」" "没有"; }
has_no() { grep -qF -- "$2" "$1" && bad "$3" "不含「$2」" "出现了" || ok "$3"; }

# 断言函数名打错不能静悄悄地过去（§11-13"断言悄悄停止计数"的同款病）。
command_not_found_handle() {
  # ⚠️ 这里**不能**写 FAIL=$((FAIL+1))：handler 跑在 fork 出来的子进程里，
  #    加了也加不到父进程头上，屏幕上红一条、汇总还是"失败 0 项"。
  printf "  \033[31mFAIL\033[0m 调用了不存在的命令 %s —— 多半是断言函数名打错了，\n" "$1"
  printf "       这条断言根本没跑。中止本套件。\n"
  kill -TERM $$
  return 127
}

# ================================================================
echo "=== 内存条明细解析 ==="

# 真机形状：DDR5 每条多打一行 Volatile Size（不能算两遍容量），
# 中间夹一个空槽（不能列进表里），最后一条 BIOS 没填序列号（不是故障）。
cat > "$TMP/dmidecode-memory.txt" <<'EOF'
Handle 0x0040, DMI type 16, 23 bytes
Physical Memory Array
	Maximum Capacity: 4 TB
	Number Of Devices: 32

Handle 0x006B, DMI type 17, 92 bytes
Memory Device
	Array Handle: 0x006A
	Size: 32 GB
	Locator: CPU0_DIMM_A1
	Bank Locator: NODE 1
	Total Width: 72 bits
	Data Width: 64 bits
	Type: DDR5
	Speed: 5600 MT/s
	Manufacturer: Hynix
	Serial Number: 3A2F91C7
	Asset Tag: CPU0_DIMM_A1_AssetTag (date:22/51)
	Part Number: HMCG88AEBRA123N-XX
	Rank: 2
	Configured Memory Speed: 4800 MT/s
	Volatile Size: 32 GB

Handle 0x006C, DMI type 17, 92 bytes
Memory Device
	Size: No Module Installed
	Locator: CPU0_DIMM_A2
	Manufacturer: NO DIMM
	Serial Number: NO DIMM

Handle 0x006D, DMI type 17, 92 bytes
Memory Device
	Size: 32 GB
	Locator: CPU0_DIMM_B1
	Bank Locator: NODE 1
	Type: DDR5
	Speed: 5600 MT/s
	Manufacturer: Samsung
	Serial Number: Not Specified
	Part Number: M321R4GA3BB6-CQK, 32GB
	Configured Memory Speed: 4800 MT/s
	Volatile Size: 32 GB
EOF

check "已装内存条数（空槽不算）" "2" "$(mem_dimm_count "$TMP/dmidecode-memory.txt")"
check "装机容量不被 Volatile Size 算成两倍" "65536" \
      "$(dmi_installed_mem_mb "$TMP/dmidecode-memory.txt")"
check "读到内存条时 mem_require_dimms 放行" "0" \
      "$(mem_require_dimms >/dev/null 2>&1; echo $?)"

cat > "$TMP/mem-empty.txt" <<'EOF'
Handle 0x006C, DMI type 17, 92 bytes
Memory Device
	Size: No Module Installed
	Locator: CPU0_DIMM_A2
EOF
check "一条都没装时条数为 0" "0" "$(mem_dimm_count "$TMP/mem-empty.txt")"

# ================================================================
echo
echo "=== 序列号核对：查假条子 ==="
#
# 现场 2026-08-12 买到一批假内存，特征就是好几条的序列号一模一样。
# 序列号写在条子自己的存储芯片里、厂商唯一分配 —— 两条正品撞不到一起。
# 这一组守的就是"这种条子必须被拦下来"。

# 槽位和序列号必须成对取，不能各取一列再拼：缺序列号的那条会整行不出，
# 两列行数对不上就错位了 —— 表现是"报告说 A1 槽的条子是假的"，指着一条好内存。
check "槽位和序列号成对取（含缺序列号的那条）" \
      "CPU0_DIMM_A1|3A2F91C7
CPU0_DIMM_B1|Not Specified" \
      "$(mem_sn_pairs "$TMP/dmidecode-memory.txt")"
check "占位符不算读到了序列号" "1" \
      "$(mem_sn_valid_pairs "$TMP/dmidecode-memory.txt" | grep -c . || true)"

# ---- 四条内存，其中三条序列号一样（真实买到的那种假条子）----
cat > "$TMP/mem-fake.txt" <<'EOF'
Handle 0x1, DMI type 17, 92 bytes
Memory Device
	Size: 32 GB
	Locator: DIMM_A1
	Serial Number: DEADBEEF

Handle 0x2, DMI type 17, 92 bytes
Memory Device
	Size: 32 GB
	Locator: DIMM_A2
	Serial Number: DEADBEEF

Handle 0x3, DMI type 17, 92 bytes
Memory Device
	Size: 32 GB
	Locator: DIMM_B1
	Serial Number: DEADBEEF

Handle 0x4, DMI type 17, 92 bytes
Memory Device
	Size: 32 GB
	Locator: DIMM_B2
	Serial Number: 12345678
EOF
check "认出重复的那一组（3 条撞在一起）" "DEADBEEF 3 DIMM_A1,DIMM_A2,DIMM_B1" \
      "$(mem_sn_dups "$TMP/mem-fake.txt")"
check "没重复的那条不进重复名单" "0" \
      "$(mem_sn_dups "$TMP/mem-fake.txt" | grep -c '12345678' || true)"

# 空槽不参与比对（多个空槽的占位符都是 NO DIMM，会假重复）
cat > "$TMP/mem-empty-slots.txt" <<'EOF'
Handle 0x1, DMI type 17, 92 bytes
Memory Device
	Size: 32 GB
	Locator: DIMM_A1
	Serial Number: AAA111

Handle 0x2, DMI type 17, 92 bytes
Memory Device
	Size: No Module Installed
	Locator: DIMM_A2
	Serial Number: NO DIMM

Handle 0x3, DMI type 17, 92 bytes
Memory Device
	Size: No Module Installed
	Locator: DIMM_B1
	Serial Number: NO DIMM
EOF
check "多个空槽不许被当成序列号重复" "0" \
      "$(mem_sn_dups "$TMP/mem-empty-slots.txt" | grep -c . || true)"

# ---- 判定 ----
sn_verdict() {   # sn_verdict <内存明细文件> [MEM_SN_MISSING_IS_FAIL]
  local f="$1" missfail="${2:-1}"
  local d; d="$(mktemp -d)"
  cp "$f" "$d/dmidecode-memory.txt"
  ( RAW_DIR="$d"; RUN_DIR="$d"; MEM_SN_MISSING_IS_FAIL="$missfail"
    check_dimm_serial >/dev/null 2>&1
    jq -r 'select(.id=="check_dimm_serial") | .status' "$d/results.jsonl" 2>/dev/null )
  rm -rf "$d"
}
check "序列号重复 -> FAIL（假条子必须拦下来）" "FAIL" "$(sn_verdict "$TMP/mem-fake.txt")"
check "序列号读不到 -> 默认 FAIL"              "FAIL" "$(sn_verdict "$TMP/dmidecode-memory.txt")"
check "读不到那一支可以降成 WARN（留了开关）"  "WARN" "$(sn_verdict "$TMP/dmidecode-memory.txt" 0)"
check "全读到且不重复 -> PASS"                 "PASS" "$(sn_verdict "$TMP/mem-empty-slots.txt")"
# ⚠️ 重复那一支**不许**有开关：序列号撞车没有任何正当解释
check "重复那一支不受开关影响" "FAIL" "$(sn_verdict "$TMP/mem-fake.txt" 0)"

# 结论文案里要点明"两条正品不可能一样"，否则现场看到 FAIL 也不知道该干什么
sn_detail() {
  local d; d="$(mktemp -d)"
  cp "$1" "$d/dmidecode-memory.txt"
  ( RAW_DIR="$d"; RUN_DIR="$d"
    check_dimm_serial >/dev/null 2>&1
    jq -r 'select(.id=="check_dimm_serial") | .detail' "$d/results.jsonl" 2>/dev/null )
  rm -rf "$d"
}
DET="$(sn_detail "$TMP/mem-fake.txt")"
check "结论里点名是哪几个槽位" "yes" \
      "$(if [[ "$DET" == *"DIMM_A1,DIMM_A2,DIMM_B1"* ]]; then echo yes; else echo no; fi)"
check "结论里说清楚为什么这是假的" "yes" \
      "$(if [[ "$DET" == *"不可能出现相同的序列号"* ]]; then echo yes; else echo no; fi)"
check "结论里给出处置意见" "yes" \
      "$(if [[ "$DET" == *"翻新或假冒"* ]]; then echo yes; else echo no; fi)"

# ================================================================
echo
echo "=== SPD 原片：读内存条自己的芯片 ==="
#
# 现场 2026-08-12 问：报告里的序列号只有 8 位十六进制，而内存条标签上印的是
# HOPA00030844522378 这样十几位的长号，能不能读到长的？
#
# 答案分两半，这一组把两半都钉住：
#   1. 那 8 位**就是完整的** —— JEDEC 规定 DDR4 的模组序列号字段只有 4 字节。
#      报告里必须把这句话说清楚，否则现场会一直以为我们截断了。
#   2. 长号如果有电子记录，只可能在**厂商专属数据区**里 —— 那片字节
#      dmidecode 给不了，只有读 SPD 原片才拿得到。读到了就如实摆出来。

# 造一片 DDR4 SPD：偏移 2 = 0x0C 标明是 DDR4，
# 325~328 序列号，329~348 型号，320~324 厂商/产地/年周，353~381 厂商专属区。
mk_spd_ddr4() {   # mk_spd_ddr4 <输出文件> <序列号16进制8位> <厂商专属区文本>
  python3 - "$@" <<'PY'
import sys
out, ser, vendor = sys.argv[1], sys.argv[2], sys.argv[3]
b = bytearray(512)
b[2] = 0x0C                                   # DDR4
b[320], b[321] = 0x80, 0xCE                   # Bank 1 / 0xCE = Samsung
b[322] = 0x01                                 # 生产地点
b[323], b[324] = 0x22, 0x51                   # BCD：2022 年第 51 周
b[325:329] = bytes.fromhex(ser)
b[329:349] = b"M393A4K40EB3-CWE    "
b[350], b[351] = 0x80, 0xCE                   # 颗粒厂商也是三星
v = vendor.encode()[:29]
b[353:353 + len(v)] = v
open(out, "wb").write(bytes(b))
PY
}

SPD="$TMP/spd"; mkdir -p "$SPD"
mk_spd_ddr4 "$SPD/0-0050.bin" "175B36BA" "HOPA00030844522378"
mk_spd_ddr4 "$SPD/0-0051.bin" "175D12EE" ""

spd_field() {   # spd_field <bin> <字段>
  python3 -c "
import sys
sys.path.insert(0, '$(dirname "$GEN")')
import importlib.util
spec = importlib.util.spec_from_file_location('g', '$GEN')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
info = m.parse_spd(open(sys.argv[1], 'rb').read())
print('' if info is None else (info.get(sys.argv[2]) or ''))
" "$1" "$2"
}

check "认出这是 DDR4"        "DDR4"      "$(spd_field "$SPD/0-0050.bin" kind)"
check "序列号和 DMI 那格对得上" "175B36BA" "$(spd_field "$SPD/0-0050.bin" serial)"
check "型号读得出来"          "M393A4K40EB3-CWE" "$(spd_field "$SPD/0-0050.bin" part)"
check "生产日期（BCD 年/周）"  "2022 年第 51 周"  "$(spd_field "$SPD/0-0050.bin" made)"
check "模组厂商 ID 译成名字"   "Samsung"  "$(spd_field "$SPD/0-0050.bin" mfr)"
check "颗粒厂商 ID 译成名字"   "Samsung"  "$(spd_field "$SPD/0-0050.bin" dram_mfr)"
# ⚠️ 这一条就是现场那个问题的答案：长号在专属区里就必须被读出来
check "厂商专属区里的长号要读出来" "HOPA00030844522378" \
      "$(spd_field "$SPD/0-0050.bin" vendor_text)"
check "专属区是空的时候不许编内容" "" "$(spd_field "$SPD/0-0051.bin" vendor_text)"
# 认不出的字节流不许当成 SPD（读了半片、平台给的是别的 eeprom 都可能）
head -c 200 /dev/zero > "$TMP/notspd.bin"
check "认不出的内容一律不当 SPD" "" "$(spd_field "$TMP/notspd.bin" kind)"

# ---- SPD 整片克隆 = 比序列号重复还硬的证据 ----
spd_clone_verdict() {   # spd_clone_verdict <spd目录>
  local d; d="$(mktemp -d)"
  mkdir -p "$d/spd"; cp "$1"/*.bin "$d/spd/" 2>/dev/null || true
  ( RAW_DIR="$d"; RUN_DIR="$d"
    check_spd_clone >/dev/null 2>&1
    jq -r 'select(.id=="check_spd_clone") | .status' "$d/results.jsonl" 2>/dev/null )
  rm -rf "$d"
}
check "两片 SPD 各不相同 -> PASS" "PASS" "$(spd_clone_verdict "$SPD")"
CLONE="$TMP/spd-clone"; mkdir -p "$CLONE"
cp "$SPD/0-0050.bin" "$CLONE/0-0050.bin"
cp "$SPD/0-0050.bin" "$CLONE/0-0051.bin"    # 整片一模一样 = 克隆
check "两片 SPD 逐字节相同 -> FAIL（整片被克隆）" "FAIL" "$(spd_clone_verdict "$CLONE")"
# ⚠️ 读不到 SPD 是平台的事，不是内存的毛病 —— 一号红线
EMPTY="$TMP/spd-none"; mkdir -p "$EMPTY"
check "一片都读不到 -> SKIP（绝不是 FAIL）" "SKIP" "$(spd_clone_verdict "$EMPTY")"
ONE="$TMP/spd-one"; mkdir -p "$ONE"; cp "$SPD/0-0050.bin" "$ONE/"
check "只读到一片 -> SKIP（没有可比的对象）" "SKIP" "$(spd_clone_verdict "$ONE")"

# ================================================================
echo
echo "=== 序列号的两种长度（8 位 / 18 位）==="
#
# 现场 2026-08-12 问：为什么有的机器报 1BA3172A（8 位），有的报
# 80AD01233537A7DDDD（18 位）？是主板 BIOS 有问题吗？
#
# 不是。**和 DDR4/DDR5 无关**（EPYC 7542 是 DDR4，报的就是 18 位），
# 是 BIOS 抄了多少字节：SPD 里模组序列号那一格 JEDEC 只给 4 字节，
# 但 JEDEC 同时定义了 9 字节的「模组唯一标识」＝ 厂商(2)+产地(1)+日期(2)+序号(4)。
# 有的 BIOS 只抄后 4 字节，有的整个 9 字节抄出来。18 位那种信息更全。
uid_field() {   # uid_field <序列号> <字段>
  python3 -c "
import sys, importlib.util
spec = importlib.util.spec_from_file_location('g', '$GEN')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = m.decode_module_uid(sys.argv[1])
print('' if d is None else (d.get(sys.argv[2]) or ''))
" "$1" "$2"
}

# 真机样本：EPYC 7542 那台（DDR4，报 18 位）。三处必须自洽 ——
# 厂商要和同一块里的 `Module Manufacturer ID: Bank 1, Hex 0xAD` 对上，
# 日期要和 `Asset Tag ... (date:23/35)` 对上。
check "18 位序列号解出厂商"     "SK Hynix"        "$(uid_field 80AD01233537A7DDDD mfr)"
check "18 位序列号解出生产日期" "2023 年第 35 周" "$(uid_field 80AD01233537A7DDDD made)"
check "18 位序列号解出模组序号" "37A7DDDD"        "$(uid_field 80AD01233537A7DDDD serial4)"
# Xeon Gold 6530 那台（DDR5，同样 18 位）
check "另一台的厂商也解得对"     "SK Hynix"        "$(uid_field 80AD01220695DED917 mfr)"
check "另一台的日期也解得对"     "2022 年第 6 周"  "$(uid_field 80AD01220695DED917 made)"
# 同一台机器上的第二种厂商（美光）
check "美光的厂商代码也认得"     "Micron"          "$(uid_field 802C0623163FFFAD32 mfr)"
# 8 位那种不是模组唯一标识，绝不能硬拆
check "8 位序列号不当成模组唯一标识" "" "$(uid_field 1BA3172A mfr)"
check "8 位序列号也不编出生产日期"   "" "$(uid_field 175B36BA made)"
# ⚠️ 18 位但那两个字节不像日期时，说明它只是个长序列号 —— 宁可不给，
#    也不能编一个日期出来印进客户报告。
check "18 位但周次不合法时整条不认" "" "$(uid_field 80AD01229999DED917 made)"

# ================================================================
echo
echo "=== 主板字段解析 ==="

cat > "$TMP/dmidecode-system.txt" <<'EOF'
Handle 0x0001, DMI type 1, 27 bytes
System Information
	Manufacturer: Supermicro
	Product Name: SYS-2049U
	Serial Number: S12345X

Handle 0x0002, DMI type 2, 15 bytes
Base Board Information
	Manufacturer: Supermicro
	Product Name: X13DEI-T
	Serial Number: WM24AS012345

Handle 0x0000, DMI type 0, 26 bytes
BIOS Information
	Vendor: American Megatrends
	Version: 2.4
	Release Date: 03/12/2026
EOF

check "主板型号"     "X13DEI-T"     "$(dmi_sys_field "$TMP/dmidecode-system.txt" "Base Board Information" "Product Name")"
check "主板序列号"   "WM24AS012345" "$(dmi_sys_field "$TMP/dmidecode-system.txt" "Base Board Information" "Serial Number")"
check "整机型号"     "SYS-2049U"    "$(dmi_sys_field "$TMP/dmidecode-system.txt" "System Information" "Product Name")"
check "BIOS 版本"    "2.4"          "$(dmi_sys_field "$TMP/dmidecode-system.txt" "BIOS Information" "Version")"
# 段名相同字段名的串台：System 和 Base Board 都有 Product Name，不能取错段
check "同名字段不许取错段" "Supermicro" \
      "$(dmi_sys_field "$TMP/dmidecode-system.txt" "System Information" "Manufacturer")"
check "没有的段返回空" "0" \
      "$(dmi_sys_field "$TMP/dmidecode-system.txt" "Chassis Information" "Type" | grep -c . || true)"

# ================================================================
echo
echo "=== 内核日志：只认内存，绝不把别的部件算到内存头上 ==="
#
# 这一组是这张盘最要紧的守卫。用户定的口径：内存坏才 FAIL，
# 网卡/阵列卡坏了不许影响内存结论。下面每一条"必须不命中"的样本，
# 都是真实机器上会出现、而且**长得很像内存错误**的行。

PAT="$(mem_dmesg_pattern)"
hit() { printf '%s\n' "$2" | grep -aEc "$PAT" || true; }

# ---- 必须命中：这些是真的内存错误 ----
check "命中 EDAC 可纠正内存错误" "1" \
  "$(hit x '[Wed Aug 12 10:00:01 2026] EDAC MC0: 1 CE memory read error on CPU_SrcID#0_MC#0_Chan#1_DIMM#0 (channel:1 slot:0)')"
check "命中 EDAC 不可纠正内存错误" "1" \
  "$(hit x '[Wed Aug 12 10:00:02 2026] EDAC MC1: 4 UE memory scrubbing error on CPU_SrcID#1_MC#0_Chan#0_DIMM#1')"
check "命中 EDAC 驱动自己打的行" "1" \
  "$(hit x '[Wed Aug 12 10:00:03 2026] EDAC skx MC0: HANDLING MCE MEMORY ERROR')"
check "命中 MCE 里明确说内存的那条" "1" \
  "$(hit x '[Wed Aug 12 10:00:04 2026] mce: [Hardware Error]: Memory read error')"
check "命中内核标记坏页" "1" \
  "$(hit x '[Wed Aug 12 10:00:05 2026] Memory failure: 0x1a2b3c: recovery action for dirty LRU page: Recovered')"

# ---- 必须不命中：坏的是别的部件，和内存无关 ----
check "阵列卡故障不算内存坏" "0" \
  "$(hit x '[Wed Aug 12 10:01:00 2026] megaraid_sas 0000:18:00.0: Found FW in FAULT state, will reset adapter scsi0.')"
check "PCIe 不可纠正错误不算内存坏" "0" \
  "$(hit x '[Wed Aug 12 10:01:01 2026] pcieport 0000:00:1c.0: PCIe Bus Error: severity=Uncorrected (Fatal), type=Transaction Layer')"
check "AER 报错不算内存坏" "0" \
  "$(hit x '[Wed Aug 12 10:01:02 2026] pcieport 0000:80:02.0: AER: Corrected error received: 0000:81:00.0')"
check "硬盘读写错误不算内存坏" "0" \
  "$(hit x '[Wed Aug 12 10:01:03 2026] blk_update_request: I/O error, dev sdb, sector 12345 op 0x0:(READ)')"
check "网卡掉链路不算内存坏" "0" \
  "$(hit x '[Wed Aug 12 10:01:04 2026] i40e 0000:3b:00.0 eth0: NIC Link is Down')"
check "裸的 Hardware Error 前缀不算内存坏" "0" \
  "$(hit x '[Wed Aug 12 10:01:05 2026] {1}[Hardware Error]: Hardware error from APEI Generic Hardware Error Source: 1')"
check "显卡掉总线不算内存坏" "0" \
  "$(hit x '[Wed Aug 12 10:01:06 2026] NVRM: GPU at PCI:0000:65:00: GPU lost from the bus')"

# ================================================================
echo
echo "=== 内核日志差集（只算压测新增的） ==="

cat > "$TMP/dmesg-pre.txt" <<'EOF'
[Wed Aug 12 09:00:00 2026] Linux version 6.8.0-100-generic
[Wed Aug 12 09:00:01 2026] EDAC MC0: 1 CE memory read error on CPU_SrcID#0_MC#0_Chan#0_DIMM#0 (channel:0 slot:0)
EOF
cat > "$TMP/dmesg-post.txt" <<'EOF'
[Wed Aug 12 09:00:00 2026] Linux version 6.8.0-100-generic
[Wed Aug 12 09:00:01 2026] EDAC MC0: 1 CE memory read error on CPU_SrcID#0_MC#0_Chan#0_DIMM#0 (channel:0 slot:0)
[Wed Aug 12 10:12:44 2026] EDAC MC0: 3 UE memory read error on CPU_SrcID#0_MC#0_Chan#1_DIMM#1 (channel:1 slot:1)
[Wed Aug 12 10:12:45 2026] pcieport 0000:00:1c.0: PCIe Bus Error: severity=Uncorrected (Fatal)
EOF
check "只数压测期间新增的内存错误（旧的减掉、PCIe 不算）" "1" \
      "$(mem_dmesg_new "$TMP/dmesg-pre.txt" "$TMP/dmesg-post.txt" "$TMP/new.txt")"
has "$TMP/new.txt" "Chan#1_DIMM#1" "新增的那条被记进明细文件"

# 健康机器：压测前一条内存错误都没有 —— 空的模式文件下 grep -vxF 必须放行，
# 弄反了的话真错误会被整段吞掉，而且屏幕全绿。
cat > "$TMP/dmesg-clean-pre.txt" <<'EOF'
[Wed Aug 12 09:00:00 2026] Linux version 6.8.0-100-generic
EOF
# post 里有两条内存错误 + 一条 PCIe。pre 干净，所以两条内存错误都是新增的
# （PCIe 那条照样不算）。数到 0 就说明空模式文件那一支把输入整段吞了。
check "压测前干净时，压出来的错误必须数得到" "2" \
      "$(mem_dmesg_new "$TMP/dmesg-clean-pre.txt" "$TMP/dmesg-post.txt" "$TMP/new2.txt")"
check "两份都干净时为 0" "0" \
      "$(mem_dmesg_new "$TMP/dmesg-clean-pre.txt" "$TMP/dmesg-clean-pre.txt" "$TMP/new3.txt")"

# ================================================================
echo
echo "=== 工程文件（CSV） ==="

mem_export_csv "$TMP/out.csv"
check "一条内存一行（表头 + 2 行）" "3" "$(count_lines "$TMP/out.csv")"
has "$TMP/out.csv" "序列号"           "表头有序列号那一列"
has "$TMP/out.csv" "生产日期"         "表头有生产日期那一列"
has "$TMP/out.csv" "2022-W51"         "生产日期真的解出来了（不是空列）"
has "$TMP/out.csv" "3A2F91C7"         "第一条内存的序列号在里面"
has "$TMP/out.csv" "X13DEI-T"         "主板型号在里面"
has "$TMP/out.csv" "CPU0_DIMM_B1"     "第二条内存的槽位在里面"
has_no "$TMP/out.csv" "CPU0_DIMM_A2"  "空槽不写进 CSV"
# 内存型号里带逗号是常事（"M321R4GA3BB6-CQK, 32GB"），不加引号整张表就错列
has "$TMP/out.csv" '"M321R4GA3BB6-CQK, 32GB"' "带逗号的型号被正确引起来"
check "CSV 带 UTF-8 BOM（否则 Excel 里中文表头是乱码）" "efbbbf" \
      "$(head -c 3 "$TMP/out.csv" | od -An -tx1 | tr -d ' \n')"
# 主板信息在每一行都重复 —— 多台机器的 CSV 首尾相接就能拼成一张总表
check "主板型号在每一条内存的行上都有" "2" \
      "$(grep -c 'X13DEI-T' "$TMP/out.csv" || true)"

# ================================================================
echo
echo "=== 报告目录名 ==="
# 用户指定的格式：内存测试_日期_内存容量_CPU
tag="$(MEM_DIR_PREFIX=内存测试 mem_run_tag 20260812_143022)"
check "目录名以中文前缀开头" "yes" \
      "$(if [[ "$tag" == 内存测试_* ]]; then echo yes; else echo no; fi)"
check "目录名里有日期时间" "yes" \
      "$(if [[ "$tag" == *_20260812_143022_* ]]; then echo yes; else echo no; fi)"
check "容量排在 CPU 前面（用户指定的顺序）" "yes" \
      "$(if [[ "$tag" =~ _[0-9]+GB_ ]]; then echo yes; else echo no; fi)"
# 前缀可换成纯 ASCII（现场只有文本控制台时用）
check "前缀可以换掉" "yes" \
      "$(if [[ "$(MEM_DIR_PREFIX=MEMTEST mem_run_tag 20260812_143022)" == MEMTEST_* ]]; \
         then echo yes; else echo no; fi)"

# ================================================================
echo
echo "=== 报告渲染 ==="
command -v python3 >/dev/null 2>&1 || { echo "  需要 python3"; exit 1; }

RD="$TMP/run"; mkdir -p "$RD/raw"
cp "$TMP/dmidecode-memory.txt" "$TMP/dmidecode-system.txt" "$RD/raw/"
cat > "$RD/raw/dmidecode-cpu.txt" <<'EOF'
Handle 0x0004, DMI type 4, 48 bytes
Processor Information
	Socket Designation: CPU1
	Version: Intel(R) Xeon(R) Gold 6430
	Core Count: 32

Handle 0x0005, DMI type 4, 48 bytes
Processor Information
	Socket Designation: CPU2
	Version: Intel(R) Xeon(R) Gold 6430
	Core Count: 32
EOF
cat > "$RD/meta.json" <<'EOF'
{
  "klburn_version": "1.10.0",
  "klburn_edition": "mem",
  "git_commit":     "deadbee",
  "company_name":   "广州市鲲林科技有限公司",
  "report_title":   "内存专用测试报告",
  "product_name":   "KLBurn-MEM",
  "serial":         "S12345X",
  "machine_tag":    "内存测试_20260812_143022_64GB_2x-Intel-Xeon-Gold-6430",
  "planned_secs":   150,
  "elapsed_secs":   153,
  "start_time":     "2026-08-12 14:30:22",
  "end_time":       "2026-08-12 14:33:05",
  "clock_suspect":  0
}
EOF
cat > "$RD/metrics.jsonl" <<'EOF'
{"group":"mem","key":"装机容量MB","value":"65536"}
{"group":"mem","key":"系统识别MB","value":"64512"}
{"group":"mem","key":"测试容量MB","value":"58000"}
{"group":"mem","key":"占识别容量","value":"90%"}
{"group":"mem","key":"测试工具","value":"stressapptest"}
{"group":"mem","key":"校验错误数","value":"0"}
{"group":"mem","key":"硬件异常数","value":"0"}
{"group":"mem","key":"新增ECC可纠正条目","value":"0"}
{"group":"mem","key":"新增ECC不可纠正条目","value":"0"}
EOF
cat > "$RD/results.jsonl" <<'EOF'
{"id":"collect_memory","name":"内存信息采集","status":"PASS","detail":"已读取逐条内存明细","ref":"","time":"t"}
{"id":"check_mem_cap","name":"内存容量核对","status":"PASS","detail":"装机 64GB，系统识别 63GB，一致","ref":"","time":"t"}
{"id":"check_dimm_uniform","name":"内存条一致性","status":"WARN","detail":"本机装有 2 条内存，规格不完全一致：厂商 2 种；","ref":"","time":"t"}
{"id":"stress_mem","name":"内存压力测试","status":"PASS","detail":"无数据校验错误；覆盖 58000MB，持续 0h02m30s","ref":"","time":"t"}
{"id":"verify_ecc","name":"内存 ECC 复查","status":"PASS","detail":"压测前后无新增内存 ECC 错误","ref":"","time":"t"}
{"id":"mem_dmesg","name":"压测期间内核日志","status":"PASS","detail":"没有出现任何内存相关的错误记录","ref":"","time":"t"}
EOF

R="$TMP/report.html"
python3 "$GEN" --run-dir "$RD" --out "$R" > "$TMP/gen.out" 2>&1
check "报告生成成功" "0" "$?"

# ⚠️ 生成器打在屏幕上的那几行**只能是 ASCII**。
#    Linux 文本控制台显示不了中文，打中文出去就是一行 ◆◆◆ ——
#    1.10.0 第一版这里写的是「报告已生成: <带中文的路径>」，
#    QEMU 截图上就是一串方块，而所有断言照样全绿。看图才发现的。
check "生成器的屏幕输出里没有非 ASCII 字节" "0" \
      "$(LC_ALL=C grep -c '[^ -~]' "$TMP/gen.out" || true)"
# 报告路径也不许打：内存盘的目录名带中文前缀，打出来照样是方块。
check "生成器不把报告路径打到屏幕上" "0" \
      "$(grep -c '/' "$TMP/gen.out" || true)"

has "$R" "内存专用测试报告"  "报告标题"
has "$R" "3A2F91C7"          "内存序列号进了报告（这张盘的存在理由）"
has "$R" "HMCG88AEBRA123N-XX" "内存型号进了报告"
has "$R" "CPU0_DIMM_A1"      "槽位进了报告"
has "$R" "4800 MT/s"         "运行频率进了报告"
# DMI 里本来就有、1.9.9 却没渲染的那几格（查翻新条的硬线索）
has "$R" "2022 年第 51 周"    "生产日期（藏在 Asset Tag 里）被解出来"
has "$R" "有（72/64 位）"     "从总位宽/数据位宽算出有没有 ECC"
has_no "$R" "AssetTag"       "Asset Tag 那串占位文字不许原样印出来"
has "$R" "X13DEI-T"          "主板型号进了报告"
has "$R" "2 x Intel Xeon Gold 6430" "处理器型号和路数（几路 CPU 一眼看得到）"
has "$R" "verdict v-PASS"    "全过时打 PASS 大字"
# ⚠️ 这一条是红线：一份只测了内存的报告，绝不能看起来像整机验收过了
has "$R" "本报告仅针对内存"  "结论旁必须说明本轮只测了内存"
has "$R" "不能作为整机验收依据" "必须写明不能当整机验收依据"
has_no "$R" "CPU0_DIMM_A2"   "空槽不列进明细表"

# ---- 压力测试单独一节：做没做、做了什么、多久、多少容量 ----
has "$R" "三、压力测试"       "压力测试单独成一节"
has "$R" "是否执行"           "写明这一轮到底有没有做压测"
has "$R" "内存读写校验"       "写明压测的项目是什么"
has "$R" "56.6 GB"           "写明覆盖容量（58000MB）"
has "$R" "占系统识别内存的 90%" "写明覆盖比例"
has "$R" "2 分 30 秒"         "写明计划时长（150 秒）"
has "$R" "2 分 33 秒"         "写明实际时长（153 秒）"
has "$R" "压测时段"           "写明压测的起止时间"
has "$R" "数据校验错误"       "写明校验错误数"
has "$R" "压测新增 ECC 错误"  "写明压测前后 ECC 计数的变化"

# ---- SPD 那一块：读到了才出现 ----
has_no "$R" "内存条芯片中的出厂记录" "读不到 SPD 时整块不印（空表格只会让人以为漏了）"
mkdir -p "$RD/raw/spd"; cp "$SPD"/*.bin "$RD/raw/spd/"
python3 "$GEN" --run-dir "$RD" --out "$R" 2>/dev/null
has "$R" "内存条芯片中的出厂记录" "读到 SPD 时出现这一块"
has "$R" "HOPA00030844522378"     "厂商专属区里的长号印进报告（现场要的就是这个）"
has "$R" "颗粒厂商"                "SPD 才有的颗粒厂商也列出来"
# ⚠️ 这句话必须在：否则现场会一直以为 8 位的序列号是被我们截断的
has "$R" "4 字节"                  "说明序列号字段就是 4 字节，没有截断"
has "$R" "生产追溯号"              "并说明标签上那串长号是什么"
rm -rf "$RD/raw/spd"
# 工具名属于内部实现，数字照常给，名字不给
has_no "$R" "测试工具"        "不写用的是哪个程序（内部实现）"

# 报告里不许出现的东西（措辞红线）
has_no "$R" "deadbee"        "报告里不许出现源码版本号"
has_no "$R" "**"             "报告里不许出现字面的星号"
for w in stressapptest stress-ng dmidecode weasyprint edac-util rasdaemon vendor/ 构建目录; do
  has_no "$R" "$w" "报告里不许出现内部/开发用语：$w"
done

# ---- 内存坏了要打 FAIL ----
cat > "$RD/results.jsonl" <<'EOF'
{"id":"collect_memory","name":"内存信息采集","status":"PASS","detail":"已读取逐条内存明细","ref":"","time":"t"}
{"id":"verify_ecc","name":"内存 ECC 复查","status":"FAIL","detail":"压测期间出现**不可纠正**内存错误：CPU0_DIMM_B1 不可纠正 0->3","ref":"","time":"t"}
EOF
python3 "$GEN" --run-dir "$RD" --out "$R" 2>/dev/null
has "$R" "verdict v-FAIL"     "有 FAIL 时打 FAIL 大字"
has "$R" "不建议出货"          "FAIL 时给出处置意见"
has "$R" "<b>不可纠正</b>"     "文案里的重点被渲染成粗体而不是字面星号"

# ---- 只有 WARN 时仍然是 PASS（混插是配置问题，不是内存坏了）----
cat > "$RD/results.jsonl" <<'EOF'
{"id":"collect_memory","name":"内存信息采集","status":"PASS","detail":"已读取逐条内存明细","ref":"","time":"t"}
{"id":"check_dimm_uniform","name":"内存条一致性","status":"WARN","detail":"规格不完全一致","ref":"","time":"t"}
{"id":"stress_mem","name":"内存压力测试","status":"PASS","detail":"无数据校验错误","ref":"","time":"t"}
EOF
python3 "$GEN" --run-dir "$RD" --out "$R" 2>/dev/null
has "$R" "verdict v-PASS"  "混插只判 WARN，整体仍然 PASS（配置问题不是硬件故障）"

# ---- 序列号重复：报告里必须一眼看得到 ----
cp "$TMP/mem-fake.txt" "$RD/raw/dmidecode-memory.txt"
cat > "$RD/results.jsonl" <<'EOF'
{"id":"check_dimm_serial","name":"内存序列号核对","status":"FAIL","detail":"本机 4 条内存中，有 3 条的序列号互相重复","ref":"","time":"t"}
EOF
python3 "$GEN" --run-dir "$RD" --out "$R" 2>/dev/null
has "$R" 'tr class="dup"'      "重复的那几行整行标出来"
has "$R" "与其它内存条重复"     "重复的序列号那一格挂个标签"
has "$R" "下表中标红的内存条"   "表格前面先给一句警告（不能让人看完一屏才发现）"
has "$R" "两条正品内存不可能出现相同的序列号" "说清楚为什么这是假的"
check "只标重复的那 3 条，不误伤第 4 条" "3" \
      "$(grep -o 'tr class="dup"' "$R" | grep -c . || true)"
cp "$TMP/dmidecode-memory.txt" "$RD/raw/dmidecode-memory.txt"

# ---- 序列号读不到：报告里也要说一句 ----
python3 "$GEN" --run-dir "$RD" --out "$R" 2>/dev/null
has "$R" "读不出序列号"        "读不到序列号的条数要写出来"
has_no "$R" 'tr class="dup"'   "没有重复时不许标红"

# ---- 压测没跑成时，绝不能让报告看着像压过了 ----
# （results.jsonl 里没有 stress_mem 那一行 = 这一轮压根没压）
cat > "$RD/results.jsonl" <<'EOF'
{"id":"collect_memory","name":"内存信息采集","status":"PASS","detail":"已读取逐条内存明细","ref":"","time":"t"}
EOF
python3 "$GEN" --run-dir "$RD" --out "$R" 2>/dev/null
has "$R" "本轮未进行内存压力测试"   "没压过就明说没压过"
has "$R" "不能用于判断这些内存能否正常工作" "并且说清楚这份报告因此不能用来判好坏"
has_no "$R" "内存读写校验"          "没压过时不许列出压测项目（说得比做得多）"

# ---- 一条判定都没有 != 通过 ----
: > "$RD/results.jsonl"
python3 "$GEN" --run-dir "$RD" --out "$R" 2>/dev/null
has "$R" "verdict v-FAIL"        "一条判定都没有时不许打 PASS"
has "$R" "本报告无效"             "说明这一轮没跑成"
has "$R" "这不是内存故障"          "并且说清楚不是硬件的问题"

# ================================================================
echo
echo "=== 主流程只碰内存 ==="
MT="$ROOT/rootfs/opt/klburn/memtest.sh"

# 这几样在这张盘上一条都不许跑：被测平台可能压根没有这些部件，
# 采了不但没人看，还会在报告里多出一堆和内存无关的 SKIP。
for fn in collect_all collect_smart collect_raid collect_nic collect_ipmi \
          gpu_detect gpu_stress stress_disk stress_cpu bench_all validate_all \
          check_psu check_pcie_link net_test; do
  check "主流程不调用 $fn" "0" \
        "$(grep -cE "^[[:space:]]*(if[[:space:]]+)?${fn}([[:space:]]|$|\")" "$MT" || true)"
done

# 反过来：这几样必须在，否则这张盘就不做事了
for fn in mem_collect check_memory_capacity check_dimm_uniform check_dimm_serial \
          stress_mem verify_ecc mem_verify_dmesg mem_export_csv; do
  check "主流程调用了 $fn" "yes" \
        "$(grep -qE "(^|[[:space:](])${fn}([[:space:]]|$|\")" "$MT" && echo yes || echo no)"
done

# 现场不许弹任何菜单：这张盘的定位就是"开机自己跑完"
for fn in select_scope select_duration confirm_disk_write config_review; do
  check "开机不问：不调用 $fn" "0" \
        "$(grep -cE "^[[:space:]]*${fn}" "$MT" || true)"
done

# ⚠️ 开机第一屏的抬头。默认是「Server Factory Burn-in Test」，一张只测内存的盘
#    顶着那句话就是在说一件它没做过的事 —— 和报告那条红线同一把尺子，
#    只是搬到了屏幕上（那块屏经常被拍照发群里）。1.10.0 第一次出盘就错了，
#    是看 QEMU 截图才发现的，断言全绿。
check "开机抬头改成了内存盘自己的那句" "yes" \
      "$(grep -q '^BRAND_TAGLINE="Memory-Only Test"' "$MT" && echo yes || echo no)"
# 而且必须设在 source ui.sh **之前** —— ui.sh 里是 `: "${BRAND_TAGLINE:=...}"`，
# 设晚了顶不掉默认值，改了等于没改。
check "抬头必须设在 source ui.sh 之前（否则顶不掉默认值）" "yes" \
      "$(awk '/^BRAND_TAGLINE=/{b=NR} /^source .*lib\/ui\.sh/{u=NR}
              END{print (b > 0 && u > 0 && b < u) ? "yes" : "no"}' "$MT")"

# 网卡只用来校时，不许产生任何网卡判定
check "网卡只用于校时（没有 net_test / check_nic_*）" "0" \
      "$(grep -cE '^[[:space:]]*(net_test|check_nic_speed|check_nic_selftest)' "$MT" || true)"

# ================================================================
echo
echo "=== 构建期接线 ==="

# 版本开关必须真的改到三处：报告标题、产品名、ISO 文件名
edition_val() {   # edition_val <KLBURN_EDITION> <变量名>
  ( set -u; export KLBURN_EDITION="$1"
    # shellcheck source=/dev/null
    source "$ROOT/build/config.sh" >/dev/null 2>&1
    printf '%s' "${!2}" )
}
check "mem 盘换报告标题"   "内存专用测试报告"  "$(edition_val mem  REPORT_TITLE)"
check "full 盘标题不变"    "服务器出厂老化测试报告" "$(edition_val full REPORT_TITLE)"
check "mem 盘换产品名"     "KLBurn-MEM"        "$(edition_val mem  PRODUCT_NAME)"
check "mem 盘的 ISO 文件名区分得开" "yes" \
      "$(if [[ "$(edition_val mem OUT_ISO_NAME)" == KLBurn-MEM-* ]]; then echo yes; else echo no; fi)"
check "full 盘的 ISO 文件名不带 MEM" "no" \
      "$(if [[ "$(edition_val full OUT_ISO_NAME)" == *MEM* ]]; then echo yes; else echo no; fi)"
check "压测时长有默认值（现场不问）" "150" "$(edition_val mem MEM_BURN_SECONDS)"

# ⚠️ 最要紧的一条：mem 盘构建时必须真的把 klburn.service 的 ExecStart 改掉。
#    改不成的后果是一张"文件名写着 MEM、开机却跑整机全测流程"的盘，
#    而且构建日志里一个字的异常都没有。
CS="$ROOT/build/chroot-setup.sh"
check "chroot-setup 会按版本改 ExecStart" "yes" \
      "$(grep -q 'ExecStart=.*KLB_MAIN\|s#\^ExecStart' "$CS" && echo yes || echo no)"
check "chroot-setup 改完会当场核对（sed 没匹配上是静默的）" "yes" \
      "$(grep -q 'grep -qx "ExecStart=\$KLB_MAIN"' "$CS" && echo yes || echo no)"
check "chroot-setup 把版本写进 klburn.conf" "yes" \
      "$(grep -q '^KLBURN_EDITION=' "$CS" && echo yes || echo no)"
check "build-iso 把版本钉进 chroot 用的那份配置" "yes" \
      "$(grep -q 'KLBURN_EDITION="\${KLBURN_EDITION}"' "$ROOT/build/build-iso.sh" && echo yes || echo no)"
check "memtest.sh 有可执行位设置" "yes" \
      "$(grep -q 'chmod 0755 /opt/klburn/memtest.sh' "$CS" && echo yes || echo no)"

# ================================================================
echo
echo "=== 三份占位符名单必须一致 ==="
# BIOS 没填的那些写法：shell 认、Python 不认（或者反过来）的后果是现成的 ——
# "N/A" 被当成真的序列号印进报告。整机盘上真实发生过一次。
py_bogus() { python3 -c "
import sys, re
src = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'^BOGUS = \{(.*?)^\}', src, re.S | re.M)
vals = re.findall(r'\"([^\"]*)\"', m.group(1)) if m else []
print('yes' if sys.argv[2].lower() in [v.lower() for v in vals] else 'no')
" "$GEN" "$1"; }

for v in "N/A" "NA" "Not Specified" "To be filled by O.E.M." "None" "Unknown" \
         "NO DIMM" "<BAD INDEX>" "<OUT OF SPEC>"; do
  check "shell 认得占位符 [$v]" "0" "$(_serial_is_bogus "$v"; echo $?)"
  # "To be filled by O.E.M." 在 Python 那边靠前缀兜，不在集合里，单独判
  if [[ "$v" != "To be filled by O.E.M." ]]; then
    check "报告生成器也认得占位符 [$v]" "yes" "$(py_bogus "$v")"
  fi
done
check "报告生成器有 to be filled 前缀兜底" "yes" \
      "$(grep -q '_BOGUS_PREFIX = "to be filled"' "$GEN" && echo yes || echo no)"

# ================================================================
# 收尾自检：本脚本 source 了被测的 lib，而 lib 里也有 ok()。
# 被顶掉的话后面的断言会照常打勾却不再计数 —— 屏幕全绿、总数悄悄少一截。
check "ok() 必须还是本脚本自己的那个（否则断言会停止计数）" "yes" \
      "$(declare -f ok | grep -q 'PASS=' && echo yes || echo no)"

echo
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
