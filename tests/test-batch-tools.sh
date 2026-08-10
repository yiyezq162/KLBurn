#!/usr/bin/env bash
#
# 批次工具（tools/klburn-summary.py、tools/klburn-diff.py）的回归测试。
#
#     ./tests/test-batch-tools.sh
#
# 这两个是**仓库侧**的工具，不进盘：一次出厂跑一百台，产物是一百个文件夹，
# "这批里有几台 FAIL""第 37 台和别人差在哪"现在只能一个个点开报告看。
#
# 两条定性，改之前先读：
#
# 1. **它们不做任何新判定。**汇总表里的"整机结论"必须和盘里、和两份报告
#    同一个口径：只看有没有 FAIL，一条判定都没有不算通过。
#    多一套口径就意味着"报告说 PASS、汇总表说 FAIL"这种事迟早发生。
#
# 2. **对比工具只报差异，不判合格。**它是"跨机器一致性"唯一诚实的做法：
#    参照物是同批次的另一台真机，不是我们编的数字（1.9.0 删掉的那套阈值
#    正是后者）。所以它不许碰性能数字，也不许输出任何 PASS/FAIL。
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUM="$ROOT/tools/klburn-summary.py"
DIFF="$ROOT/tools/klburn-diff.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
check() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1（期望 [$2]，实际 [$3]）"; }
has()   { grep -qF -- "$2" "$1" && ok "$3" || bad "$3（应含「$2」）"; }

# 断言函数名打错不能静悄悄地过去（和别的套件同一条道理）
command_not_found_handle() {
  printf "  \033[31mFAIL\033[0m 调用了不存在的命令 %s —— 多半是断言函数名打错了。\n" "$1"
  kill -TERM $$
  return 127
}

command -v python3 >/dev/null 2>&1 || { echo "需要 python3"; exit 1; }

mkrun() {          # mkrun <目录> <results.jsonl 内容> [scope]
  local d="$TMP/$1"; shift
  local rows="$1"; shift
  local scope="${1:-}"
  mkdir -p "$d/raw"
  # scope 留空 = **老 run-dir 的形状**（1.9.4 及以前根本没有这个字段）。
  # 它们确实都是全量跑出来的，所以工具那边必须默认成 full。
  #
  # ⚠️ 这一段先拼成变量再进 heredoc。写成 `${scope:+,"scope":"$scope"}` 是不行的：
  #    `${x:+word}` 里的 word 会走一遍**引号移除**，双引号原地消失，
  #    落到文件里是 `,scope:cpu` —— 不是合法 JSON，读出来整份 meta 都是空的，
  #    而报错只会表现为"范围列写着全量"，指向一个完全不相干的地方。
  local sfrag=""
  [[ -n "$scope" ]] && sfrag=",\"scope\":\"$scope\""
  cat > "$d/meta.json" <<EOF
{"klburn_version":"1.9.2","serial":"SN-$(basename "$d")","profile":"QUICK",
 "start_time":"2026-08-10 10:00:00","elapsed_secs":600$sfrag}
EOF
  printf '%s\n' "$rows" > "$d/results.jsonl"
  printf '%s' "$d"
}

echo "=== 汇总：整机结论必须和盘里同一个口径 ==="
mkrun good '{"id":"collect_system","name":"硬件信息采集","status":"PASS","detail":"d","ref":"","time":"t"}
{"id":"stress_cpu","name":"CPU 压力测试","status":"PASS","detail":"d","ref":"","time":"t"}
{"id":"check_mem_cap","name":"内存容量核对","status":"WARN","detail":"d","ref":"","time":"t"}' >/dev/null
mkrun bad1 '{"id":"collect_system","name":"硬件信息采集","status":"PASS","detail":"d","ref":"","time":"t"}
{"id":"verify_smart","name":"硬盘 SMART 复查","status":"FAIL","detail":"d","ref":"","time":"t"}' >/dev/null
# 一条判定都没有 != 全都通过（和 report-policy 三、factory-test.sh 同一条规矩）
mkrun empty '' >/dev/null

OUT="$TMP/summary.csv"
python3 "$SUM" "$TMP" -o "$OUT" > "$TMP/sum.log" 2>&1
check "汇总跑得通" "0" "$?"
check "三台都被认出来（判据是 meta.json，不是目录名的形状）" "3" \
      "$(( $(grep -c . "$OUT") - 1 ))"
check "有 WARN 但没 FAIL -> PASS" "PASS" \
      "$(awk -F, '$1=="good"{print $2}' "$OUT")"
check "有 FAIL -> FAIL" "FAIL" \
      "$(awk -F, '$1=="bad1"{print $2}' "$OUT")"
# ⚠️ 这一条是重点：一条判定都没有的那份**不许**算成 PASS。
#    盘里、客户报告、内部报告三处都是这个口径，汇总表是第四处，不能自成一套。
check "一条判定都没有 -> INVALID（绝不能算成 PASS）" "INVALID" \
      "$(awk -F, '$1=="empty"{print $2}' "$OUT")"
has "$OUT" "硬盘 SMART 复查" "FAIL 项要列出项目名"
has "$TMP/sum.log" "FAIL 1 台" "屏幕上要直接报出有几台不合格"

# 目录名带中文备注、带空格都要认（test_out 里就是这样的）
mkrun "20260810_101500_2x-Intel_64GB_备注 带空格" \
  '{"id":"collect_system","name":"硬件信息采集","status":"PASS","detail":"d","ref":"","time":"t"}' >/dev/null
python3 "$SUM" "$TMP" -o "$OUT" >/dev/null 2>&1
check "目录名带中文备注和空格照样认" "4" "$(( $(grep -c . "$OUT") - 1 ))"

echo
echo "=== 汇总：单项专测不许和全量混成同一个「已通过」（1.9.5）==="
#
# ⚠️⚠️ 这一组守的是这个功能在批次侧**唯一致命的**失效方式：
#
#   一台只跑了 CPU 专测的机器，results.jsonl 里当然没有 FAIL，
#   汇总表就把它列成 PASS。可它的内存、硬盘、显卡**根本没测过**。
#   而这张表正是拿来做"这一批能不能出货"这个决定的 ——
#   一列全是 PASS 的表格里混进这么一台，没有任何人会发现。
#
# 所以非全量的结论列自带范围后缀（PASS(CPU)），排序筛选时和 PASS 不是同一个值。
mkrun "20260810_120000_2x-Intel_64GB_CPU" \
  '{"id":"collect_system","name":"硬件信息采集","status":"PASS","detail":"d","ref":"","time":"t"}
{"id":"stress_cpu","name":"CPU 压力测试","status":"PASS","detail":"d","ref":"","time":"t"}' cpu >/dev/null
mkrun "20260810_130000_2x-Intel_64GB_INFO" \
  '{"id":"collect_system","name":"硬件信息采集","status":"PASS","detail":"d","ref":"","time":"t"}' info >/dev/null
OUTS="$TMP/summary-scope.csv"
python3 "$SUM" "$TMP" -o "$OUTS" > "$TMP/sum-scope.log" 2>&1
check "带范围后缀的目录名照样认得出来" "0" "$?"
check "CPU 专测的结论不许是光秃秃的 PASS" "PASS(CPU)" \
      "$(awk -F, '$1=="20260810_120000_2x-Intel_64GB_CPU"{print $2}' "$OUTS")"
check "仅导出信息那一档同理" "PASS(INFO)" \
      "$(awk -F, '$1=="20260810_130000_2x-Intel_64GB_INFO"{print $2}' "$OUTS")"
check "范围单独占一列" "CPU 专项测试" \
      "$(awk -F, '$1=="20260810_120000_2x-Intel_64GB_CPU"{print $3}' "$OUTS")"
# 老 run-dir（meta.json 里根本没有 scope 字段）必须默认成全量 ——
# 默认成别的值会把历史上所有报告重新解释一遍。
check "老 run-dir 没有 scope 字段时按全量算" "PASS" \
      "$(awk -F, '$1=="good"{print $2}' "$OUTS")"
check "老 run-dir 的范围列写「全量老化测试」" "全量老化测试" \
      "$(awk -F, '$1=="good"{print $3}' "$OUTS")"
has "$TMP/sum-scope.log" "非全量 2 台" "屏幕上要直接报出有几台不是全量测的"
has "$TMP/sum-scope.log" "不能和全量测试的 PASS 一起算作" "并且当场说清楚这意味着什么"

echo
echo "=== 汇总：CSV 要能在 Windows 上直接双击打开 ==="
# utf-8-sig 的 BOM。没有它的话 Excel 会把中文列名显示成乱码 ——
# 而这张表的用途就是发给人看。
check "CSV 带 UTF-8 BOM（否则 Excel 打开是乱码）" "efbbbf" \
      "$(head -c 3 "$OUT" | od -An -tx1 | tr -d ' \n')"

echo
echo "=== 对比：只报差异，不判合格 ==="
DA="$TMP/dA"; DB="$TMP/dB"
for d in "$DA" "$DB"; do
  mkdir -p "$d/raw"
  printf '{"klburn_version":"1.9.2"}\n' > "$d/meta.json"
  cat > "$d/raw/dmidecode.txt" <<'EOF'
Handle 0x0001, DMI type 0, 24 bytes
BIOS Information
	Vendor: AMI
	Version: 1.02

Handle 0x0002, DMI type 17, 92 bytes
Memory Device
	Size: 32 GB
	Part Number: M393A4K40EB3-CWE

Handle 0x0003, DMI type 17, 92 bytes
Memory Device
	Size: 32 GB
	Part Number: M393A4K40EB3-CWE
EOF
  printf '{"id":"collect_system","name":"硬件信息采集","status":"PASS","detail":"d","ref":"","time":"t"}\n' \
    > "$d/results.jsonl"
done
python3 "$DIFF" "$DA" "$DB" > "$TMP/same.log" 2>&1
check '一模一样的两台 -> 报「完全一致」' "1" "$(grep -c '完全一致' "$TMP/same.log")"
check "而且不输出任何 PASS/FAIL 字样" "0" \
      "$(grep -cE '\bPASS\b|\bFAIL\b' "$TMP/same.log" || true)"

# B 台少一根内存 + BIOS 版本落后一版
cat > "$DB/raw/dmidecode.txt" <<'EOF'
Handle 0x0001, DMI type 0, 24 bytes
BIOS Information
	Vendor: AMI
	Version: 1.01

Handle 0x0002, DMI type 17, 92 bytes
Memory Device
	Size: 32 GB
	Part Number: M393A4K40EB3-CWE
EOF
python3 "$DIFF" "$DA" "$DB" > "$TMP/diff.log" 2>&1
has "$TMP/diff.log" "内存条数"   "少一根内存要查得出来"
has "$TMP/diff.log" "BIOS 版本"  "固件版本落后一版要查得出来"
has "$TMP/diff.log" "不同 ≠ 有问题" "必须写明它不做判定"
check "对比结果里同样不许出现 PASS/FAIL 结论字样" "0" \
      "$(grep -cE '不合格|判定为|verdict' "$TMP/diff.log" || true)"

# ⚠️ **不许碰性能数字。**同型号机器之间跑分本来就有正常波动，
#    拿它比只会制造噪音，而且离"我们替客户定标准"只有一步之遥。
printf '{"group":"bench","key":"CPU 浮点算力（GFlops）","value":"3010.0"}\n' > "$DA/metrics.jsonl"
printf '{"group":"bench","key":"CPU 浮点算力（GFlops）","value":"2980.0"}\n' > "$DB/metrics.jsonl"
python3 "$DIFF" "$DA" "$DB" > "$TMP/diff2.log" 2>&1
check "性能数字的波动不许被报成差异" "0" \
      "$(grep -cE 'GFlops|算力|带宽' "$TMP/diff2.log" || true)"

echo
echo "=== GRUB 菜单：追加 memtest86+ 绝不能碰第一条（1.9.2）==="
#
# ⚠️⚠️ **这是整个项目里最容易把盘变成砖的一处改动。**
# `set default=0` 指的是**第一条** menuentry —— 我们那条自启动的测试项。
# 往前插一条的后果是：插上盘开机跑的是内存测试，而这张盘的全部意义
# 就是"插上就跑"。所以这一组盯的不是"memtest 能不能进"，
# 而是"**原来那条还在不在第一位**"。
PG="$ROOT/build/lib/patch-grub.py"
cat > "$TMP/grub.cfg" <<'EOF'
set timeout=30
set default=0
menuentry "Try or Install Ubuntu Server" {
	linux	/casper/vmlinuz  ---
	initrd	/casper/initrd
}
menuentry "Ubuntu Server with the HWE kernel" {
	linux	/casper/hwe-vmlinuz  ---
	initrd	/casper/hwe-initrd
}
EOF
cat > "$TMP/mt.cfg" <<'EOF'
menuentry "Memory test (memtest86+, KLBURN-MEMTEST)" {
	if [ "$grub_platform" = "efi" ]; then
		chainloader /boot/memtest86+x64.efi
	else
		linux16 /boot/memtest86+x64.bin
	fi
}
EOF
python3 "$PG" --cfg "$TMP/grub.cfg" --args "consoleblank=0" \
  --title "KLBurn Factory Test v9.9.9" --drop "HWE kernel" --timeout 5 \
  --append-entry "$TMP/mt.cfg" --append-marker KLBURN-MEMTEST >/dev/null 2>&1
check "追加之后仍然只有两条菜单项（HWE 那条被删掉了）" "2" \
      "$(grep -c '^menuentry' "$TMP/grub.cfg")"
check "**第一条必须还是我们的测试项**（default=0 指的就是它）" "1" \
      "$(grep -m1 '^menuentry' "$TMP/grub.cfg" | grep -c 'KLBurn Factory Test')"
check "memtest 必须排在后面，不能是第一条" "0" \
      "$(grep -m1 '^menuentry' "$TMP/grub.cfg" | grep -c 'KLBURN-MEMTEST' || true)"
has "$TMP/grub.cfg" "KLBURN-MEMTEST" "memtest 那条要在"
has "$TMP/grub.cfg" "consoleblank=0" "内核参数照常打上"
check "default 仍然是 0" "1" "$(grep -c '^set default=0' "$TMP/grub.cfg")"
# 幂等：构建脚本会对 grub.cfg 和 loopback.cfg 各跑一次，增量构建还会再跑，
# 重复执行不许越加越多
python3 "$PG" --cfg "$TMP/grub.cfg" --args "consoleblank=0" \
  --title "KLBurn Factory Test v9.9.9" --drop "HWE kernel" --timeout 5 \
  --append-entry "$TMP/mt.cfg" --append-marker KLBURN-MEMTEST >/dev/null 2>&1
check "重复执行不许越加越多（增量构建会再跑一遍）" "1" \
      "$(grep -c 'KLBURN-MEMTEST' "$TMP/grub.cfg")"
check "重复执行之后第一条还是我们的" "1" \
      "$(grep -m1 '^menuentry' "$TMP/grub.cfg" | grep -c 'KLBurn Factory Test')"
# 大括号要配对，否则 GRUB 直接进不了菜单 —— 那就是一张砖
check "大括号配平（不配平的话 GRUB 连菜单都进不去）" "yes" \
      "$(awk '{o+=gsub(/{/,"{"); c+=gsub(/}/,"}")} END{print (o==c)?"yes":"no"}' "$TMP/grub.cfg")"
# 没有 memtest 二进制时（构建机上装不上包），不传这两个参数，一切照旧
cp "$TMP/grub.cfg" "$TMP/grub2.cfg"
python3 "$PG" --cfg "$TMP/grub2.cfg" --args "consoleblank=0" --timeout 5 >/dev/null 2>&1
check "不传 --append-entry 时不影响任何东西" "1" \
      "$(grep -c 'KLBURN-MEMTEST' "$TMP/grub2.cfg")"

echo
echo "=== 边界：不能崩 ==="
python3 "$SUM" "$TMP/nope" >/dev/null 2>&1
check "目录不存在时干净退出（非 0），不是抛异常" "1" "$?"
python3 "$DIFF" "$DA" "$TMP/nope" >/dev/null 2>&1
check "对比时目录不存在也干净退出" "1" "$?"
mkdir -p "$TMP/emptydir"
python3 "$SUM" "$TMP/emptydir" >/dev/null 2>&1
check "目录里一个 run-dir 都没有时干净退出" "1" "$?"

echo
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
