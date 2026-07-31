#!/usr/bin/env bash
#
# U 盘排除逻辑的回归测试。**需要 root**（要创建 loop 和 dm 设备）：
#
#     sudo ./tests/test-disk-exclusion.sh
#
# 这是整个项目最危险的代码路径：一旦反查不出启动 U 盘，fio 会把它当成
# 空盘写穿——测试盘当场报废，历史报告全丢。
#
# 测试用 loop + 分区 + dm-linear 搭出和 Ventoy 一模一样的设备链，
# 并且**故意删掉 /dev/mapper 下的符号链接**，复现 Ventoy 禁用 udev 的条件：
# 那时 /proc/mounts 里记的 "/dev/mapper/ventoy" 路径在系统里根本不存在，
# 只能靠设备号 MAJ:MIN 去 /sys/dev/block/ 里查。
#
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../rootfs/opt/klburn/lib" && pwd)"

if [[ "$(id -u)" != "0" ]]; then
  echo "需要 root: sudo $0" >&2
  exit 2
fi
for c in losetup dmsetup sgdisk blockdev; do
  command -v "$c" >/dev/null || { echo "缺少 $c（apt install gdisk dmsetup util-linux）" >&2; exit 2; }
done

# storage.sh 顶层只有两个变量赋值和一堆函数定义，没有会执行的逻辑，
# 整个 source 进来即可（早期版本用 sed 截前 N 行，文件一变长就在截断处语法错误）。
# shellcheck source=/dev/null
source "$LIB/storage.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n     期望 [%s] 实际 [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }
chk() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$2" "$3"; }

IMG="$(mktemp -u /tmp/klburn-dmtest-XXXX.img)"
DMNAME="klburntest$$"
LOOP=""

cleanup() {
  dmsetup remove "$DMNAME" 2>/dev/null
  [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
  rm -f "$IMG"
}
trap cleanup EXIT

echo "=== 搭建 Ventoy 同构设备链 ==="
truncate -s 200M "$IMG"
LOOP="$(losetup -fP --show "$IMG")"
sgdisk -n 1:0:0 -t 1:0700 "$IMG" >/dev/null 2>&1
losetup -d "$LOOP"; LOOP="$(losetup -fP --show "$IMG")"; sleep 1

PART="${LOOP}p1"
WHOLE="$(basename "$LOOP")"
[[ -b "$PART" ]] || { echo "分区没建出来: $PART" >&2; exit 1; }

dmsetup create "$DMNAME" --table "0 $(blockdev --getsz "$PART") linear $PART 0"
sleep 1
DM="$(readlink -f "/dev/mapper/$DMNAME")"
MM="$(cat "/sys/class/block/$(basename "$DM")/dev")"
echo "  整盘=$WHOLE  分区=$(basename "$PART")  dm=$(basename "$DM")  MAJ:MIN=$MM"
echo

echo "=== 场景 A：/dev/mapper 符号链接正常（普通 dm / LVM）==="
chk "按 /dev/mapper 路径反查" "$WHOLE" "$(resolve_disk_sysfs "/dev/mapper/$DMNAME")"
chk "按 /dev/dm-N 路径反查"   "$WHOLE" "$(resolve_disk_sysfs "$DM")"
chk "按 MAJ:MIN 反查"         "$WHOLE" "$(resolve_disk_sysfs "$MM")"
chk "按分区路径反查"           "$WHOLE" "$(resolve_disk_sysfs "$PART")"
chk "按分区内核名反查"         "$WHOLE" "$(resolve_disk_sysfs "$(basename "$PART")")"

echo
echo "=== 场景 B：删掉 /dev/mapper 符号链接（复现 Ventoy 禁用 udev）==="
rm -f "/dev/mapper/$DMNAME"
chk "MAJ:MIN 仍能反查到整盘（关键）" "$WHOLE" "$(resolve_disk_sysfs "$MM")"
chk "不存在的路径安全返回空"        ""       "$(resolve_disk_sysfs "/dev/mapper/$DMNAME")"

echo
echo "=== 边界情况 ==="
chk "空参数"           "" "$(resolve_disk_sysfs "")"
chk "不存在的设备名"    "" "$(resolve_disk_sysfs "nosuchdev999")"
chk "不存在的 MAJ:MIN"  "" "$(resolve_disk_sysfs "9999:9999")"
chk "整盘自身原样返回"  "$WHOLE" "$(resolve_disk_sysfs "$LOOP")"

echo
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
