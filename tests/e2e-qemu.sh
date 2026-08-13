#!/usr/bin/env bash
#
# 端到端测试：把出好的 ISO 在 QEMU 里真的启动一次，跑完，再把报告从"U 盘"里
# 挖出来检查。
#
#     sudo ./tests/e2e-qemu.sh                    # 冒烟：约 3 分钟
#     sudo ./tests/e2e-qemu.sh --stage full       # 完整 QUICK 跑完：约 20 分钟
#     sudo ./tests/e2e-qemu.sh --iso out/xxx.iso  # 指定 ISO（默认取 out/ 里最新的）
#
# ================================================================
# 为什么需要它
# ================================================================
# tests/ 里其余 400 多项断言全是**单元级**的：喂文件给纯函数、看它吐什么。
# 没有任何一条验证过「插上去、开机、真的跑完、报告真的落到盘上」——
# 而这中间任何一环断掉（服务没起、数据分区没认出来、报告生成器在真环境里崩），
# 单元测试一条都不会红，现场却是空手而归。
#
# v0.4.0 的 tag 里写着"已在 QEMU 里做过完整端到端验证"，但那是**人工做的**，
# 仓库里一行脚本都没留下，成果全在做的人脑子里。这个文件就是把它固化下来。
#
# ================================================================
# 它怎么模拟一根 KLBurn U 盘
# ================================================================
# Rufus 的 DD 模式就是把 ISO 原样写进 U 盘，然后在剩余空间建 exFAT 分区。
# 这里做的是同一件事，只不过对象是个文件：
#
#     cp ISO img  ->  truncate 撑大  ->  sgdisk -e 把 GPT 备份头挪到新的末尾
#                 ->  新建第 4 个分区  ->  mkfs.exfat -n KLBURN
#
# ISO 本身已经带了 3 个分区（ISO9660 / EFI / Gap1），所以数据分区是第 4 个。
#
# 另外再挂两块空白盘当"本机硬盘"，让 scan_disks / collect_disk 有东西可采
# —— collect_disk 是 21 个判定 id 里唯一一个单元测试覆盖不到的。
#
# ================================================================
# 怎么在没有串口的情况下操作它
# ================================================================
# klburn.service 是钉死在 tty1 上的（TTYPath=/dev/tty1），UI 不会走串口，
# 所以没法用 expect 那套。这里走 QEMU 的 monitor：`sendkey` 直接往虚拟键盘上
# 打字，和现场工程师按键盘是同一条路径 —— 不需要给产品加任何"无人值守模式"，
# 测的就是真正的交互流程。
#
# 断言则完全落在**磁盘产物**上：跑完把第 4 个分区挂起来看。这比抓屏幕文字
# 可靠得多，也正好是现场真正在乎的东西（报告到底有没有落到 U 盘里）。
#
# ⚠️ 按键是按时间窗口盲发的，发早了会打到 GRUB 菜单上。所以第一次按键要等到
#    GRUB（5 秒超时）早就过去之后，见 SELECT_START。
#
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# ---------------------------------------------------------------- 参数
STAGE="smoke"
ISO=""
DATA_MB=1024          # 模拟 U 盘的数据分区
SPARE_GB=2            # 每块"本机硬盘"多大
SPARE_N=2             # 挂几块
MEM_MB=4096
CPUS=4
KEEP=0
NET=0
WORKDIR=""
FIRMWARE="bios"
NO_DATA=0
DISK_STRESS=0
# 硬盘专测那一轮，确认屏有没有被我们**故意拒掉**（1.10.1）。
# 拒掉之后这一轮应该作废（FAIL + 「本轮测试未执行」），而不是静默跳过继续跑。
DISK_SCOPE_DECLINED_EXPECTED=0
SCOPE="full"          # 本轮测试范围（1.9.5 新增的那个菜单）
# 验的是哪一种盘（1.10.0）。mem 盘**开机不问任何东西**，所以下面所有
# 按键时序、范围后缀断言、INTERNAL_ 报告断言都不适用，要单走一条。
EDITION="full"

usage() {
  cat <<'EOF'
用法: sudo ./tests/e2e-qemu.sh [选项]

  --stage smoke|full   smoke=只验能不能起来并落盘（~3 分钟，默认）
                       full =完整跑一遍 QUICK 档（~20 分钟）
  --firmware bios|uefi bios=SeaBIOS（默认）；uefi=OVMF。真服务器基本都是 UEFI，
                       两条引导路径都得验
  --no-data-partition  把第 4 个分区格成 ext4 而不是 exFAT，模拟"U 盘上没有
                       可用数据分区"。验的是：报告不会被写到不该写的地方、
                       而且流程照常跑完不卡死（现场应看到黄色大框警告）
  --disk-stress        真的过掉两道破坏性写确认，让 fio 往那两块空白盘上写。
                       **只在 --stage full 下有效，默认关。**
                       验的是全项目最危险的一条：fio 不会写穿启动 U 盘
  --scope S            本轮测试范围：full（默认）/ cpu / mem / gpu / disk / info。
                       脚本会在范围菜单上按对应的键，并断言报告目录名带上了
                       对应的后缀（_Full / _CPU / …）。冒烟档跑 --scope info
                       最快：那一档不做任何压测
  --edition full|mem   验的是哪一种盘（默认 full）。mem = 内存专用盘：
                       开机不问任何东西、约三分钟跑完，所以这条路**一次按键
                       都不发**，断言也换成内存盘那一套（中文目录名、.csv、
                       没有 INTERNAL_ 报告）。配 --scope 无意义，会直接报错
  --iso PATH           用指定 ISO（默认取 out/ 里 mtime 最新的）
  --net                给虚拟机接一块网卡（默认不接，网卡项会判 SKIP）
  --keep               跑完保留磁盘镜像和截图，方便手工看
  --workdir DIR        指定工作目录（默认 mktemp）。排查时务必用它 ——
                       /tmp 在 WSL 里跨会话不保留，--keep 也留不住
  --spare-disks N      挂几块空白盘当"本机硬盘"（默认 2）
EOF
}

while (( $# )); do
  case "$1" in
    --stage)       STAGE="$2"; shift 2 ;;
    --iso)         ISO="$2";   shift 2 ;;
    --net)         NET=1;      shift ;;
    --keep)        KEEP=1;     shift ;;
    --firmware)    FIRMWARE="$2"; shift 2 ;;
    --no-data-partition) NO_DATA=1; shift ;;
    --disk-stress) DISK_STRESS=1; shift ;;
    --scope)       SCOPE="$2";  shift 2 ;;
    --edition)     EDITION="$2"; shift 2 ;;
    --workdir)     WORKDIR="$2"; shift 2 ;;
    --spare-disks) SPARE_N="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) printf '未知参数: %s\n' "$1"; usage; exit 2 ;;
  esac
done

PASS=0; FAIL=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '  \033[36m--\033[0m   %s\n' "$1"; }
die()  { printf '\033[31m致命: %s\033[0m\n' "$1" >&2; exit 1; }

# 打错断言函数名不能静悄悄地过去（§11-13 那条，test-report-render.sh 里踩过）
command_not_found_handle() {
  # ⚠️ 第一句必须是抓现场，别在它前面插任何命令 —— BASH_COMMAND 是"当前正在
  #    执行的命令"，handler 里一旦跑过一条命令它就被覆盖成那一条了
  #    （第一版把它写在 printf 的参数里，打出来的是 printf 自己，实测）。
  local _line="${BASH_LINENO[0]:-?}" _src="${BASH_SOURCE[1]:-?}" _cmd="$BASH_COMMAND"
  # ⚠️ 这里**不能**写 FAIL=$((FAIL+1))。bash 是在 fork 出来的子进程里执行这个
  #    handler 的，加了也加不到父进程头上 —— 屏幕上红一条，最后那行汇总却还是
  #    "失败 0 项"，正好是本项目最恨的那种"屏幕全绿"。（实测踩过。）
  #    所以直接把整个套件干掉，让退出码非零、run-all 能看见。
  printf "  \033[31mFAIL\033[0m 调用了不存在的命令 [%s]\n" "$1"
  # ⚠️ **必须把位置打出来。**这个脚本 1100 行、还分成 smoke / full /
  #    disk-stress 三条互不相干的路，只知道命令名根本查不下去。
  #    1.10.0 加内存盘那一路时实测：报了个"命令 0 不存在"，光靠名字找了很久 ——
  #    而 `0` 这种名字压根不是打错函数名，是 **`$空变量 0` 这种写法**
  #    （变量展开成空，后面那个参数就顶上来当了命令名）。
  printf "       位置：%s 第 %s 行\n" "$_src" "$_line"
  printf "       整条：%s\n" "${_cmd:-?}"
  printf "       中止本套件。\n"
  kill -TERM $$
  return 127
}

# --disk-stress 只有在真跑完一轮的时候才有意义：冒烟档根本走不到压测阶段。
# 这里直接停下而不是"静默忽略"—— 静默忽略的结果是有人以为验过了，其实没有。
if (( DISK_STRESS )) && [[ "$STAGE" != "full" ]]; then
  printf '致命: --disk-stress 只能配 --stage full（冒烟档走不到压测阶段）\n' >&2
  exit 2
fi
if (( DISK_STRESS )) && (( NO_DATA )); then
  printf '致命: --disk-stress 和 --no-data-partition 不能一起用\n' >&2
  printf '      后者故意让报告落不到"U 盘"上，那正是前者要检查的东西\n' >&2
  exit 2
fi

# ---------------------------------------------------------------- 范围 -> 按键 / 目录后缀
#
# 范围菜单排在**建立报告目录之前**（范围要进目录名），所以这一键必须比
# 时长菜单那一键更早发出去。两张表和 lib/ui.sh 的 select_scope、
# lib/core.sh 的 scope_tag 是同一套，改一处这里就要跟着改。
case "$SCOPE" in
  full) SCOPE_KEY=1; SCOPE_TAG="Full" ;;
  cpu)  SCOPE_KEY=2; SCOPE_TAG="CPU"  ;;
  mem)  SCOPE_KEY=3; SCOPE_TAG="MEM"  ;;
  gpu)  SCOPE_KEY=4; SCOPE_TAG="GPU"  ;;
  disk) SCOPE_KEY=5; SCOPE_TAG="DISK" ;;
  info) SCOPE_KEY=6; SCOPE_TAG="INFO" ;;
  *) printf '致命: --scope 只能是 full/cpu/mem/gpu/disk/info，收到 %s\n' "$SCOPE" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------- 时长菜单之后的第一条日志
#
# ⚠️⚠️ **这个锚点必须是「时长菜单之后」才写出来的那条，不能是它之前的。**
#
# 它的用途是验证"那一下 `1` 真的被时长菜单吃到了"：等到它 = 菜单过了；
# 等不到 = 还卡在菜单上，那时候补一次按键是安全的（除了菜单没有别的读取者）。
# 锚点要是落在菜单**之前**，这个 wait 会立刻命中，于是：
#   * 断言永远绿，却什么都没验到（§11-13 那种空转）
#   * 真的按漏了的时候，那个"补一次"的兜底永远不会触发，
#     整轮静默回落到 STANDARD 档（30 分钟），冒烟档直接超时
#
# 1.10.1 踩过一次：原来用的是 `live media disks`（`scan_disks` 打的）。
# 那一版把 `scan_disks` 提到了选时长**之前**（硬盘专测那一屏要列候选盘），
# 于是这条锚点一夜之间跑到了菜单前面 —— **而它照样全绿**。
# 现在改用 `collect_all` 的头一句，它在选时长之后、任何按键之前。
AFTER_DURATION="Collecting system / board / CPU / memory"
# ---------------------------------------------------------------- 版本（1.10.0）
#
# mem 盘和 full 盘是两条完全不同的现场流程，混着用只会红在完全不相干的地方。
# 所以不兼容的组合一律**当场停下**，不做"静默忽略"——
# 静默忽略的结果是有人以为验过了，其实没有。
case "$EDITION" in
  full|mem) ;;
  *) printf '致命: --edition 只能是 full 或 mem，收到 %s\n' "$EDITION" >&2; exit 2 ;;
esac
if [[ "$EDITION" == "mem" ]]; then
  # 内存盘没有范围菜单 —— 它永远只测内存。传了 --scope 说明用的人搞混了两种盘。
  if [[ "$SCOPE" != "full" ]]; then
    printf '致命: --edition mem 不接受 --scope（内存盘开机不问范围，它只测内存）\n' >&2
    exit 2
  fi
  if (( DISK_STRESS )); then
    printf '致命: --edition mem 不接受 --disk-stress（内存盘一个字节都不往硬盘写）\n' >&2
    exit 2
  fi
fi

# --disk-stress 验的是"fio 真写盘、而且不会写穿启动 U 盘"。硬盘专测那一档
# 拿的是**全部**时长（不是全量档的 30%），跑起来久得多，而且这条路的按键
# 时序是按全量档调的。要验硬盘专测另开一轮，别把两件事绞在一起。
if (( DISK_STRESS )) && [[ "$SCOPE" != "full" ]]; then
  printf '致命: --disk-stress 目前只支持 --scope full（按键时序是按它调的）\n' >&2
  exit 2
fi

# ---------------------------------------------------------------- 前置检查
(( EUID == 0 )) || die "要 root：要 losetup 造分区、要挂 exFAT、还要用 /dev/kvm"

for t in qemu-system-x86_64 sgdisk mkfs.exfat losetup truncate; do
  command -v "$t" >/dev/null 2>&1 || die "缺 $t（apt-get install qemu-system-x86 gdisk exfatprogs）"
done

# ⚠️⚠️ **自动挑 ISO 必须按 edition 挑，不能只按 mtime。**（1.10.1）
#
# 原来写的是 `ls -t out/KLBurn-*.iso | head -1`，而这个通配**同时命中两种盘**：
#     out/KLBurn-1.10.1-….iso        整机盘
#     out/KLBurn-MEM-1.10.1-….iso    内存盘
# 于是"先构建 full、再构建 mem、然后跑一轮整机盘的 e2e"这个再正常不过的顺序，
# 挑到的是**刚构建的内存盘**。踩到的时候屏幕上是：
#     ISO : out/KLBurn-MEM-1.10.1-….iso
#     阶段 : full   范围 : disk        <- 内存盘压根没有范围菜单
# 一路跑下去不会有任何报错，只是**验的东西和你以为的不是同一个**。
#
# 整机盘的文件名里没有 MEM 段，内存盘一定有 —— 按这个分开挑。
if [[ -z "$ISO" ]]; then
  # 两种盘的文件名前缀是分得开的，直接用 glob 挑，不用 ls|grep 过滤
  # （整机盘：KLBurn-<版本>-<日期>.iso；内存盘：KLBurn-MEM-<版本>-<日期>.iso）。
  _cands=()
  for _f in out/KLBurn-*.iso; do
    [[ -f "$_f" ]] || continue
    case "$_f" in
      */KLBurn-MEM-*) [[ "$EDITION" == "mem"  ]] && _cands+=("$_f") ;;
      *)              [[ "$EDITION" == "full" ]] && _cands+=("$_f") ;;
    esac
  done
  # 取 mtime 最新的那个
  for _f in "${_cands[@]}"; do
    [[ -z "$ISO" || "$_f" -nt "$ISO" ]] && ISO="$_f"
  done
  unset _cands _f
fi
[[ -n "$ISO" && -f "$ISO" ]] || die "找不到 ${EDITION} 版的 ISO。先 build/build-iso.sh$([[ "$EDITION" == "mem" ]] && printf ' --edition mem')，或用 --iso 指定"

# ⚠️ 显式传 --iso 时也要核一遍：传错盘和自动挑错盘的后果一模一样，
#    而且显式传的那次更容易让人确信"我传的肯定对"。
case "$ISO" in
  */KLBurn-MEM-*) _iso_ed="mem" ;;
  *)              _iso_ed="full" ;;
esac
[[ "$_iso_ed" == "$EDITION" ]] || \
  die "ISO 和 --edition 对不上：$ISO 是${_iso_ed}版，而 --edition 是 ${EDITION}"

KVM_ARGS=()
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  KVM_ARGS=(-enable-kvm -cpu host)
else
  info "没有 /dev/kvm，走纯模拟 —— 会慢很多，full 档可能要几小时"
fi

# 这个版本号后面要拿去和盘里 meta.json 对
EXPECT_VER="$(grep -oE 'KLBURN_VERSION="[^"]+"' build/config.sh | cut -d'"' -f2)"

printf '\n\033[1;36m===== KLBurn 端到端（QEMU）=====\033[0m\n'
info "ISO      : $ISO ($(du -h "$ISO" | cut -f1))"
info "期望版本 : $EXPECT_VER"
info "阶段     : $STAGE"

# ---------------------------------------------------------------- 工作区
if [[ -n "$WORKDIR" ]]; then
  rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"
  WORK="$WORKDIR"; KEEP=1
else
  WORK="$(mktemp -d)"
fi
LOOP=""
MNT="$WORK/mnt"
MON_PORT=$(( 20000 + RANDOM % 20000 ))
QEMU_PID=""

cleanup() {
  [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null
  mountpoint -q "$MNT" 2>/dev/null && umount "$MNT" 2>/dev/null
  [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
  if (( KEEP )); then
    printf '\n  镜像和截图保留在: %s\n' "$WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

mkdir -p "$MNT"

# ---------------------------------------------------------------- 1. 造 U 盘镜像
printf '\n\033[1m[1/4] 造模拟 U 盘镜像\033[0m\n'

IMG="$WORK/usb.img"
cp --sparse=always "$ISO" "$IMG"
ISO_BYTES="$(stat -c %s "$IMG")"
truncate -s "$(( ISO_BYTES + DATA_MB * 1024 * 1024 ))" "$IMG"

# ISO 被撑大之后，GPT 的备份头还留在原来的位置（老的"末尾"），
# 不挪的话新分区建不出来。-e 就是干这个的。
sgdisk -e "$IMG" >/dev/null 2>&1

# ISO 自带 3 个分区，数据分区是第 4 个。0700 = Microsoft basic data。
sgdisk -n 4:0:0 -t 4:0700 -c 4:KLBURNDATA "$IMG" >/dev/null 2>&1

LOOP="$(losetup -P --find --show "$IMG")"
[[ -n "$LOOP" ]] || die "losetup 失败"
sleep 1

if [[ -b "${LOOP}p4" ]]; then
  ok "第 4 个分区建出来了（${LOOP}p4）"
else
  bad "第 4 个分区没建出来 —— 后面全白搭"
  sgdisk -p "$IMG" 2>&1 | tail -8 | sed 's/^/       /'
  printf '\n通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"; exit 1
fi

if (( NO_DATA )); then
  # 故意格成 ext4：四层回退找的全是 exFAT，所以一层都不会命中，
  # KLBurn 应该退到 /tmp 并打黄色大框警告，**而不是**往这个分区上乱写。
  mkfs.ext4 -q -F -L NOTKLBURN "${LOOP}p4" >/dev/null 2>&1
  ok "数据分区故意格成 ext4（模拟 U 盘上没有可用的 exFAT 数据分区）"
else
  # 卷标必须是大写 KLBURN —— 四层回退的第 1 层就是按它找的
  mkfs.exfat -n KLBURN "${LOOP}p4" >/dev/null 2>&1
  lbl="$(blkid -s LABEL -o value "${LOOP}p4" 2>/dev/null)"
  [[ "$lbl" == "KLBURN" ]] && ok "数据分区格式化为 exFAT，卷标 KLBURN" \
                           || bad "卷标不对：拿到 [$lbl]，要的是 KLBURN"
fi

# --disk-stress：先往「U 盘」里放一份**上一轮的报告**。
#
# 这是三条验收里最要紧那条的锚：fio 一旦写穿启动 U 盘，最先没的就是历史报告
# —— 而那是这根盘上唯一不可再生的东西（客户半年后说盘坏了，我们要拿它出来）。
# 只验「分区还挂得上」远远不够：分区表没被动、文件全没了，照样挂得上。
SENTINEL_DIR="out/20250101_000000_PREVIOUS_RUN"
SENTINEL_TEXT="KLBURN-E2E-SENTINEL-DO-NOT-TOUCH-上一轮的报告"
if (( DISK_STRESS )); then
  if mount "${LOOP}p4" "$MNT" 2>/dev/null; then
    mkdir -p "$MNT/$SENTINEL_DIR"
    printf '%s\n' "$SENTINEL_TEXT" > "$MNT/$SENTINEL_DIR/report.html"
    sync
    umount "$MNT"
    ok "已在「U 盘」里放好一份上一轮的报告（$SENTINEL_DIR）"
  else
    bad "放不进上一轮的报告 —— 那条「没写穿」的断言就没有锚了"
  fi
fi

losetup -d "$LOOP"; LOOP=""

# "本机硬盘"：稀疏文件，不占真实空间
SPARE_ARGS=()
SPARES=()
for (( i = 0; i < SPARE_N; i++ )); do
  d="$WORK/spare$i.img"
  truncate -s "${SPARE_GB}G" "$d"
  SPARES+=("$d")
  SPARE_ARGS+=(-drive "file=$d,format=raw,if=virtio,cache=unsafe")
done
info "另挂 $SPARE_N 块 ${SPARE_GB}G 空白盘当本机硬盘"

# 空白盘现在是稀疏文件：apparent size 是 2G，**实际占用**几乎为 0。
# fio 真写过之后实际占用会涨上去 —— 这是「fio 确实动过这块盘」最便宜的证据，
# 不用去 md5 两遍 2GB。
spare_alloc() { du -B1 -- "$1" 2>/dev/null | cut -f1; }
SPARE_ALLOC_BEFORE=()
for d in "${SPARES[@]}"; do SPARE_ALLOC_BEFORE+=("$(spare_alloc "$d")"); done

# ---------------------------------------------------------------- 2. 起虚拟机
printf '\n\033[1m[2/4] 启动虚拟机\033[0m\n'

NET_ARGS=(-nic none)
# shellcheck disable=SC2054  # 这里的逗号是 qemu 参数自己的语法，不是数组分隔符
(( NET )) && NET_ARGS=(-nic "user,model=virtio-net-pci")

# UEFI：真服务器基本都是 UEFI 启动，而 ISO 是 BIOS/UEFI 双引导的 —— 两条路
# 走的是完全不同的引导链（SeaBIOS + isohybrid MBR  vs  OVMF + ESP 里的 grub），
# 只验一条等于只验了一半。
FW_ARGS=()
if [[ "$FIRMWARE" == "uefi" ]]; then
  OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
  OVMF_VARS_SRC=/usr/share/OVMF/OVMF_VARS_4M.fd
  [[ -f "$OVMF_CODE" ]] || die "缺 OVMF（apt-get install ovmf）：$OVMF_CODE"
  # VARS 必须是可写副本，直接用系统那份会失败（而且不该污染它）
  cp "$OVMF_VARS_SRC" "$WORK/OVMF_VARS.fd"
  FW_ARGS=(
    -machine q35
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,unit=1,file=$WORK/OVMF_VARS.fd"
  )
  info "固件：UEFI（OVMF，q35）"
else
  info "固件：BIOS（SeaBIOS，i440fx）"
fi

# U 盘走 USB 总线，和现场一致 —— storage.sh 里那套 removable/hotplug 判断
# 和 live 介质反查都指望这个身份。用 virtio 挂的话就测不到那条路了。
#
# ⚠️ U 盘这块**绝对不能加 cache=unsafe**。那个选项让 QEMU 直接忽略 flush 请求，
#    虚拟机一停，还在缓存里的写入就没了 —— 表现是"跑完挂上去，分区里空空如也"，
#    而虚拟机里其实一切正常。第一版就是这么栽的，查了半天以为是产品没落盘。
#    空白盘无所谓（本来就是丢弃的），所以只有它们留着 cache=unsafe。
#
# ⚠️ bootindex=0 也不是可有可无。挂了空白盘之后，SeaBIOS 会先去试那几块
#    virtio 盘（它们是"硬盘"），试完不会正确回落到 USB，直接
#    "No bootable device" 停在那儿 —— 而脚本这边看到的现象是
#    "跑完 U 盘里什么都没有"，和产品没落盘长得一模一样。
#    现场是工程师在 BIOS 菜单里手动选 U 盘，bootindex 就是在模拟这一下。
qemu-system-x86_64 \
  "${KVM_ARGS[@]}" \
  "${FW_ARGS[@]}" \
  -m "$MEM_MB" -smp "$CPUS" \
  -device qemu-xhci,id=xhci \
  -drive "file=$IMG,format=raw,if=none,id=usbstick" \
  -device usb-storage,bus=xhci.0,drive=usbstick,removable=on,bootindex=0 \
  "${SPARE_ARGS[@]}" \
  "${NET_ARGS[@]}" \
  -display none \
  -monitor "tcp:127.0.0.1:$MON_PORT,server,nowait" \
  >"$WORK/qemu.log" 2>&1 &
QEMU_PID=$!

sleep 3
kill -0 "$QEMU_PID" 2>/dev/null || {
  bad "QEMU 没起来"
  sed 's/^/       /' "$WORK/qemu.log"
  printf '\n通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"; exit 1
}
ok "QEMU 已启动（pid $QEMU_PID, monitor 127.0.0.1:$MON_PORT）"

# monitor 用一条常驻连接，省得每次重连
exec 3<>"/dev/tcp/127.0.0.1/$MON_PORT" || die "连不上 QEMU monitor"

# ⚠️ 虚拟机可能在任何时候自己退出（关机键生效了、内核 panic 了），
#    此后再往 monitor 写就是**往已关闭的 socket 写 -> SIGPIPE -> 整个脚本被杀**。
#    第一版就是这么死的：完整档的关机循环把 'p' 发进去、虚拟机正常退出，
#    紧接着那句 screendump 直接把脚本干掉了 —— 后面所有断言一条都没跑，
#    而磁盘上其实躺着一份完整的报告。
#    所以每次写之前先确认它还活着，写失败也不算错。
mon() {
  kill -0 "$QEMU_PID" 2>/dev/null || return 0
  printf '%s\n' "$*" >&3 2>/dev/null || return 0
  sleep 0.2
}

shot() { mon "screendump $WORK/shot-$1.ppm"; }

# ---------------------------------------------------------------- 等一行日志出现
# wait_for_log <日志里的字串> <最多等几秒> [人话标签]
#
# 虚拟机把 klburn.log 写在 exFAT 数据分区上，而那个分区就是 usb.img 里的一段
# 字节 —— **虚拟机还在跑的时候，宿主机直接 grep 这个镜像就能看到**。
# 实测：虚拟机写下去到宿主机 grep 得到，延迟在 3 秒以内（U 盘那块**没有**
# cache=unsafe，flush 是真的会落盘的）；2.4GB 的镜像 grep 一遍约 3 秒。
#
# 这是整条 --disk-stress 的地基。两道确认提示出现的时刻随机器而变（采集快慢
# 差很多），**按时间盲发按键不可接受 —— 按错方向就是真擦盘**。
# 有了锚点才敢发第一个 y。
# ⚠️ 计时必须走 date，不能拿"sleep 了几次 × 3"当秒数。
#    每轮里那次 grep 自己就要扫 2.4GB、花掉 3 秒左右，累加出来的数字只有真实
#    耗时的一半 —— 于是 limit=900 实际能等 1800 秒，日志里"第 252s"其实是第
#    600 秒。超时和读数一旦对不上，排查的人会从完全错误的地方开始找。
wait_for_log() {
  local needle="$1" limit="$2" label="${3:-$1}" start now
  start="$(date +%s)"
  while :; do
    now="$(date +%s)"
    (( now - start >= limit )) && break
    kill -0 "$QEMU_PID" 2>/dev/null || { info "等「$label」时虚拟机已经退出"; return 1; }
    if grep -aqF -- "$needle" "$IMG" 2>/dev/null; then
      info "看到「$label」（第 $(( now - start ))s）"
      return 0
    fi
    sleep 3
  done
  info "等了 ${limit}s 也没等到「$label」"
  return 1
}

# ---------------------------------------------------------------- 3. 驱动它
printf '\n\033[1m[3/4] 操作虚拟机\033[0m\n'

SELECT_START=40      # GRUB 超时只有 5 秒，40 秒之后按键一定打不到 GRUB 上
                     # （之后还要等一个日志锚点才真的开始按，见完整档那一段）

if [[ "$STAGE" == "smoke" ]]; then
  # 冒烟只想知道"起没起来、认没认出数据分区"。
  # KLBurn 一开机就 mount_data_partition + log_attach，klburn.log 会立刻落盘 ——
  # 所以根本不用等它跑完，看盘上有没有东西就够了。
  if [[ "$EDITION" == "mem" ]]; then
    info "冒烟档（内存盘）：不按任何键，等它自己跑完一整轮"
  else
    info "冒烟档：等 150 秒让它开机并建立报告目录（范围 $SCOPE）"
  fi
  # 15 秒这一张是专门为 --no-data-partition 留的：找不到数据分区时那个黄色大框
  # 警告出现在 STEP 1、只停 8 秒，等到 30 秒就已经被后面的采集日志顶走了。
  # 那条"有没有打警告"没法程序化断言，只能靠人看截图，所以至少得截到。
  sleep 15; shot "15"

  # ---------------- 内存专用盘：一次按键都不发（1.10.0）----------------
  #
  # 这张盘开机什么都不问，直接开测。**这里发任何一键都是错的** ——
  # 那些键会留在 tty 缓冲里，一路飘到最后的收尾菜单被吃掉
  # （[t] 会让它当场重跑一轮，[p] 会直接关机）。
  #
  # 整轮约三分钟（采集几秒 + 压测 150 秒 + 复查出报告十几秒），
  # 所以冒烟档等到它**真的跑完**，断言能一直做到报告本体。
  if [[ "$EDITION" == "mem" ]]; then
    info "内存盘：不发任何按键，等它自己跑完（约 3 分钟）"
    for t in 45 75 105 135 165 195 225 255; do
      sleep 30
      kill -0 "$QEMU_PID" 2>/dev/null || { bad "虚拟机在第 ${t}s 意外退出了"; break; }
      shot "$t"
      printf '       ... %ss\n' "$t"
    done
  else

  # ---------------- 范围菜单（1.9.5）----------------
  # 它排在**建立报告目录之前**，60 秒倒计时。不按的话它超时回落全量，
  # 报告目录要等到第 100 秒左右才建出来 —— 冒烟档统共只有 150 秒，太紧。
  # 按一次把它放过去，顺便把 --scope 那条路真跑一遍。
  #
  # 这一键**只按一次**：多按出来的键会留在 tty 缓冲里被时长菜单吃掉
  # （那一屏是单键读），后果是档位不是你以为的那个。
  sleep 25
  shot "scope-menu"          # 界面改动只有截图看得出来，先截再按
  mon "sendkey $SCOPE_KEY"
  info "范围菜单已按 [$SCOPE_KEY]（$SCOPE）"
  for t in 60 90 120 150; do
    sleep 30
    kill -0 "$QEMU_PID" 2>/dev/null || { bad "虚拟机在第 ${t}s 意外退出了"; break; }
    shot "$t"
    printf '       ... %ss\n' "$t"
  done
  fi   # EDITION == mem 的那一支到此为止
elif (( DISK_STRESS )); then
  # ================================================================
  # 完整档 + 真写盘：全程按**日志锚点**走，一次盲发按键都没有
  # ================================================================
  info "完整档 + 破坏性写：选 QUICK -> 过两道确认 -> fio 真写盘 -> 关机"

  # 锚点必须是"虚拟机写出来的"，不能是 ISO 里本来就有的字节。
  # 万一某个字串在镜像里一开始就有，轮询会在第 0 秒命中，按键就在完全错误的
  # 时刻发出去 —— 而这一轮的按键是"确认擦盘"。所以先验一遍它们现在都不在。
  preexist=""
  for n in "Report      :" "$AFTER_DURATION" "verify_dmesg_boot" \
           "Configuration review done" "Disk stress test confirmed by operator"; do
    grep -aqF -- "$n" "$IMG" 2>/dev/null && preexist="$preexist [$n]"
  done
  if [[ -z "$preexist" ]]; then
    ok "五个日志锚点在开机前都不在镜像里（不会在错误的时刻发出确认键）"
  else
    bad "这些锚点在开机前就已经在镜像里了，轮询会立刻误命中：$preexist"
    printf '\n通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"; exit 1
  fi

  # ---------------- 选档：只按一次 ----------------
  # 时长菜单是**单键**读（read -n 1），一个 "1" 就选中了。
  # **绝不能像下面那个分支那样反复按**：多按出来的键会留在 tty 缓冲里，
  # 被后面 confirm_disk_write 的整行读取吃掉 —— "1yes" 不等于 "yes"，
  # 于是本该擦盘的这一轮又静默变成了跳过，而且看起来像是机制不灵。
  # ---------------- 范围菜单（1.9.5，排在时长菜单之前）----------------
  # 它在建立报告目录之前，所以没有任何日志锚点可等（那时候 klburn.log 还在
  # 内存里，没落到"U 盘"上）。只能按时间：SELECT_START 之后菜单已经画出来，
  # 而它有 60 秒倒计时，窗口很宽。**只按一次**（多按的键会被后面的整行读吃掉，
  # "1yes" 不等于 "yes"，那一轮就静默变成跳过擦盘）。
  sleep "$SELECT_START"
  mon "sendkey $SCOPE_KEY"
  info "范围菜单已按 [$SCOPE_KEY]（$SCOPE）"

  if wait_for_log "Report      :" 240 "开机完成，时长菜单要出来了"; then
    sleep 2
    mon "sendkey 1"
    if ! wait_for_log "$AFTER_DURATION" 60 "选档已生效、开始采集"; then
      # 还没进采集说明还卡在菜单上（这时候补一下键是安全的，
      # 因为除了菜单没有别的读取者）
      mon "sendkey 1"
      wait_for_log "$AFTER_DURATION" 60 "选档已生效、开始采集" || true
    fi
  else
    bad "开机 240s 都没写出第一批日志 —— 后面的按键一律不发"
  fi
  shot "boot"

  # ---------------- 配置核对面板（1.7.0 新增，插在采集和写确认之间）----------------
  # 这一屏有 60 秒倒计时、按任意键立即继续。它把原来那个"看到
  # verify_dmesg_boot 就发 yes"的时序整个顶开了：现在 yes 的第一个字符会被
  # 面板的单键读吃掉，剩下 "es" 进整行读 —— 不等于 "yes"，这一轮静默变成跳过。
  #
  # 所以改成：先等采集结束，按一下空格把面板放过去，再等面板**自己的**锚点，
  # 确认已经走到写确认那一步了才发 yes。
  #
  # 空格这个键是特意选的：万一它落到了后面那个整行读上，confirm_disk_write
  # 会先把空白全部去掉再比（norm="${answer//[[:space:]]/}"），一个前导空格
  # 不会把 "yes" 变成别的东西。方向永远是安全的那一侧。
  if wait_for_log "verify_dmesg_boot" 900 "采集跑完（下一步是配置核对面板）"; then
    sleep 3
    mon "sendkey spc"
    shot "config-review"
  else
    bad "没等到采集结束的锚点 —— 按键一律不发（盲发按错方向就是真擦盘）"
  fi

  # ---------------- 第 1 道：整行读，必须原样打出 yes ----------------
  # 锚点用配置核对面板收尾那条日志。它一落盘，紧接着就是 confirm_disk_write
  # 把提示打出来（120s 超时）。
  # 等 90s：面板自己最多停 60 秒（没按到键就靠超时走），留够余量。
  disk_confirm_sent=0
  if wait_for_log "Configuration review done" 90 "配置核对面板已过（下一步就是破坏性写确认）"; then
    sleep 3
    for c in y e s; do mon "sendkey $c"; done
    mon "sendkey ret"
    disk_confirm_sent=1
    info "第 1 道确认已发出（yes + 回车）"
  else
    bad "没等到配置核对面板结束的锚点 —— 按键不敢发（盲发按错方向就是真擦盘）"
  fi

  # ---------------- 第 2 道：最终警告面板，打 y 再回车 ----------------
  # 这一道没有自己的日志锚点（面板只是 printf），但它**紧跟着**第 1 道，
  # 中间不做任何硬件动作，时间窗是确定的，而且面板本身有 60s 超时。
  # 发完之后有锚点可验：两道都过了 confirm_disk_write 会打一条 ok。
  #
  # ⚠️ 1.9.9 起第 2 道**也是整行读**（打 y 或 yes 再回车），不再是单键。
  #    现场反馈是"第一遍 yes 没毛病，第二遍不知道该打 y 还是 yes" ——
  #    同一件事在相邻两屏上换了两种交互本身就是个坑，而且单键那种
  #    按下去的一瞬间就开始擦盘，连反悔的余地都没有。
  #    **所以这里必须补一个 ret，只发 y 是过不去的。**
  if (( disk_confirm_sent )); then
    sleep 4
    mon "sendkey y"; sleep 1; mon "sendkey ret"
    if wait_for_log "Disk stress test confirmed by operator" 90 "两道确认都通过"; then
      ok "两道破坏性写确认都通过了（fio 会真的往裸盘上写）"
    else
      mon "sendkey y"; sleep 1; mon "sendkey ret"
      if wait_for_log "Disk stress test confirmed by operator" 60 "两道确认都通过"; then
        ok "两道破坏性写确认都通过了（第 2 道补发了一次 y+回车）"
      else
        bad "没能通过破坏性写确认 —— 这一轮 fio 不会写盘，下面几条必然红"
      fi
    fi
  fi
  shot "confirmed"

  # ---------------- 等它跑完 ----------------
  # QUICK 是 CPU/内存并发 600s，硬盘再单独 180s（30%），加上采集/复查/出报告。
  # 这里不再盲等固定秒数，而是等最后那条 "Report written:"。
  info "等压测 + 出报告（QUICK 600s 并发 + 硬盘 180s + 余量）"

  # 压测期间截一张。**界面改动只有截图验得了** —— 单元测试能保证列宽和字符集，
  # 保证不了"在真控制台上看着对不对"（颜色、对齐、有没有被别的输出顶花）。
  # 挑第 90 秒：这时候并发压测已经跑起来、读数都有值了，离硬盘阶段还远。
  sleep 90
  shot "burn-in"

  if wait_for_log "Sequential write" 900 "fio 开始跑了"; then
    ok "fio 真的启动了（日志里有顺序写那一段）"
    sleep 25          # 让逐盘带宽/IOPS 采到第二个点，否则那一屏还是 "warming up"
    shot "disk-stress"
  else
    bad "日志里没有 fio 启动的痕迹"
  fi
  wait_for_log "Report written:" 1500 "报告已生成，可以关机了" || \
    info "没等到出报告，照常往下走（下面的断言会说明发生了什么）"
  # 出完报告再等一下：PASS/FAIL 大字和收尾菜单是在那之后才打的
  sleep 12
  shot "burn-done"

  info "发关机键"
  for (( t = 0; t < 300; t += 10 )); do
    kill -0 "$QEMU_PID" 2>/dev/null || { ok "收尾菜单按 p 之后虚拟机正常关机"; break; }
    mon "sendkey p"
    sleep 10
  done
else
  info "完整档：等开机 -> 选 QUICK -> 跑完 -> 关机"
  # 先等 KLBurn 真的起来，**别按 QEMU 的秒表**：开机快慢差十几秒，
  # 按早了打到 GRUB 上。"Report      :" 是它开机时打的最后一批日志之一，
  # 时长菜单紧接着就画出来（30 秒倒计时）。--disk-stress 那条路用的是同一个锚点。
  sleep "$SELECT_START"
  # ---------------- 先过范围菜单（1.9.5）----------------
  # 它排在报告目录建立之前，所以没有日志锚点可等，只能按时间 ——
  # 好在它有 60 秒倒计时，窗口很宽，而且**按不中的后果是回落到全量**
  # （菜单的默认值），也就是这条路本来就要的那个范围。
  mon "sendkey $SCOPE_KEY"
  info "范围菜单已按 [$SCOPE_KEY]（$SCOPE）"

  wait_for_log "Report      :" 300 "KLBurn 起来了（时长菜单马上出来）" || true

  # ---------------- 硬盘专测：确认屏排在时长菜单**之前**（1.10.1）----------------
  #
  # ⚠️⚠️ 只有 `--scope disk` 走这一段。别的范围这一屏根本不出现，
  #    在这儿发键会一路漏到时长菜单上去。
  #
  # 这一段验的是 1.10.1 那个流程改动**在真机上确实是这个顺序**：
  # 选完范围 -> 立刻问擦盘 -> 才问时长。单元测试只能验源码里的行号先后，
  # 验不了"现场那一屏真的先出来"。
  #
  # **故意打一个不是 y/yes 的答案**，验的是「不确认 = 这一轮作废」那条新语义：
  #   * 不写任何一个字节到任何一块盘（冒烟档跑得起来的前提）
  #   * 跑出来的是 FAIL + 「本轮测试未执行」，不是一份看起来完整的绿报告
  #   * 而 1.10.0 那版在这里是**静默跳过继续跑**，最后打绿色 PASS ——
  #     操作员选了「只测硬盘」，拿到一份一项硬盘压测都没跑的"通过"报告
  #
  # ⚠️ **必须同时满足"这一轮真挂了空白盘"**（`--spare-disks` > 0）。
  #    一块候选盘都没有时 `confirm_disk_write` 压根不会被调到（走的是
  #    「没有可测硬盘」那条跳出），这一屏不出现 —— 那时候发出去的键会一路
  #    漏到时长菜单上，而 `ret` 在那儿的意思是"用默认档"，冒烟档直接变 30 分钟。
  if [[ "$SCOPE" == "disk" ]] && (( SPARE_N > 0 )); then
    # scan_disks 的这条日志紧挨着确认屏（它就是拿它列候选盘的）
    if wait_for_log "testable," 240 "候选盘枚举完（下一步就是擦盘确认屏）"; then
      sleep 3
      shot "disk-confirm"
      # 打一个明确不是 y/yes 的答案。**绝不能发 y** —— 那是真擦盘。
      for c in n o; do mon "sendkey $c"; done
      mon "sendkey ret"
      info "硬盘专测确认屏已回答 no（验的是「不确认就作废」）"
      DISK_SCOPE_DECLINED_EXPECTED=1
    else
      bad "硬盘专测没等到候选盘枚举的锚点 —— 后面的键一律不发"
    fi
  fi

  # ---------------- 选档：只按一次 ----------------
  # 和 --disk-stress 那条路用同一套做法（它 1.6 就这么干了，这里是补上）。
  #
  # 菜单是**单键**读（read -n 1），一个 "1" 就选中了，**不要回车** ——
  # 回车在 select_duration 里是"用默认档"，抢在 "1" 前面就是 STANDARD。
  #
  # ⚠️ 也**绝不能反复按**。两头都栽过，各一次：
  #
  #   按少了/按晚了 -> 菜单 30 秒超时回落 STANDARD，整轮从 10 分钟变 30 分钟。
  #     栽的那次是因为循环里每轮先 grep 一遍镜像判断"选中没有"，而 grep 一遍
  #     1.4GB 要 3~5 秒，夹在两次按键之间把节奏拖慢一倍，窗口里一次都没打中。
  #     所以按键这一段里**不许有 grep**，靠锚点定起点、按完再验。
  #
  #   按多了 -> 仪表盘不读键盘，多出来的键一路排在 tty 缓冲里：
  #     先被配置核对面板的单键读吃掉一个（那一屏一闪而过，60 秒倒计时白设），
  #     再被 confirm_disk_write 的整行读吃掉，剩下的等收尾菜单一出现被一次全吃，
  #     把最终结论那一屏刷成满屏 "Unknown option."，PASS 大字全被顶出屏幕。
  #     产品的行为没错（不认识的键就该这么答），毁掉的是最值得看的那一屏。
  #     这两条都是看截图逮到的，断言全绿。
  sleep 2
  mon "sendkey 1"
  if ! wait_for_log "$AFTER_DURATION" 60 "选档已生效、开始采集"; then
    # 还卡在菜单上就补一次（这时候除了菜单没有别的读取者，补键是安全的）
    mon "sendkey 1"
    wait_for_log "$AFTER_DURATION" 60 "选档已生效、开始采集" || true
  fi

  # 配置核对那一屏没人按键了，靠它自己 60 秒倒计时往下走 ——
  # 顺便把「绝不能卡住流程」这条**真跑一遍**（只按一次之后 tty 缓冲是空的，
  # 这一屏才真的会停满 60 秒；以前反复按的时候它一闪就过去了）。
  # 锚点用带冒号的那条（面板画出来时打的），"Configuration review done" 是它走完了。
  wait_for_log "Configuration review:" 420 "配置核对屏出来了" && { sleep 3; shot "config-review"; }

  # 压测仪表盘：现场要盯八个小时的就是这一屏，**改了界面就必须真去看这张图**
  # （1.7.2/1.7.3 有七个问题是只有看图才发现的，当时断言全绿）。
  #
  # ⚠️ **别再用固定的 `sleep 240`。**那个数是按"配置核对 60s + 破坏性写确认
  #    120s + 一小段基准"估的，而 PHASE 2 的长度是会变的：1.9.5 把 OpenDCDiag
  #    放进盘之后，`validate_cpu_sdc` 自己就要跑 120 秒 —— 于是这一张截到的是
  #    基准阶段的滚动日志，仪表盘一张都没截到。**而断言全绿**，因为没有任何
  #    断言在看这张图。这正是这个项目最怕的那种失效。
  #
  #    改成等压测真的开跑：每个压测阶段起来时都会记一条 info()，它会落进
  #    klburn.log，也就会落到"U 盘"镜像上。等到它再多给 20 秒，让采样器攒出
  #    第一批读数（否则频率/占用率那几格是 --）。
  #
  # ⚠️ **锚点必须跟着 --scope 走。**写死 `[CPU] stress-ng` 的话，
  #    `--scope mem/gpu/disk` 那几轮永远等不到它 —— 白等满一整个超时，
  #    然后截一张没有仪表盘的图。而且不会有任何断言发现这件事。
  case "$SCOPE" in
    full|cpu) BURN_ANCHOR="[CPU] stress-ng";   BURN_WAIT=900 ;;
    mem)      BURN_ANCHOR="[MEM] -> testing";  BURN_WAIT=900 ;;
    # 这两个"有没有仪表盘"取决于这台机器：QEMU 里没有显卡、硬盘也不会被确认，
    # 于是根本不进 PHASE 3。等不到就安静地跳过，别把一轮验证拖长 15 分钟。
    gpu)      BURN_ANCHOR="[GPU] gpu_burn on"; BURN_WAIT=300 ;;
    disk)     BURN_ANCHOR="Sequential write";  BURN_WAIT=300 ;;
    info)     BURN_ANCHOR="";                  BURN_WAIT=0   ;;
  esac

  if [[ -z "$BURN_ANCHOR" ]]; then
    info "范围 $SCOPE 不做任何压测，没有仪表盘可截"
  elif wait_for_log "$BURN_ANCHOR" "$BURN_WAIT" "压测开跑了（下一步截仪表盘）"; then
    sleep 20
    shot "burn-in"
  else
    info "这一轮没等到压测开跑（范围 $SCOPE 在这台机器上可能压根没有可压的部件）"
    shot "burn-in"
  fi

  # QUICK 10 分钟 + 采集/复查/出报告的余量。用锚点等而不是死等 900 秒。
  #
  # ⚠️ 收尾锚点必须挑一条**只有跑完才会出现**的日志。
  #    第一版挑了 "Report      :" —— 那是开机时就打的一行（报告路径），
  #    第 0 秒就命中，于是脚本在采集还没做完的时候就开始发关机键，
  #    整轮被拦腰截断，而且**所有断言照样绿**（报告目录建出来了、版本号对得上）。
  #    "Internal engineering report:" 是 factory-test.sh 记的最后一条，
  #    它出现 = 两份报告都写完了。
  # ---------------- 选档到底选中了没有 ----------------
  #
  # 上面那一按是**打时间窗**，打不中的后果是菜单 30 秒超时回落 STANDARD ——
  # 整轮从 10 分钟变 30 分钟。这件事本身是已知会偶发的（见上面那段注释），
  # 真正糟糕的是它以前**没有出口**：下面那句只等 1500 秒，STANDARD 那一轮
  # 无论如何都等不到报告，于是屏幕上只有一句
  #     「等了 1500s 也没等到『两份报告都写完了』」
  # 看上去像是产品卡死了 —— 而实际上机器跑得好好的，是这个脚本按错了键。
  # 1.9.0 实测撞到一次，查了半天才发现截图右上角写着 STANDARD。
  #
  # 所以这里把它变成**说得出话的失败**：读回真正生效的时间预算，
  # 按它算等待上限，并且把"没按中"这件事明明白白打出来。
  # `Time budget:` 是 factory-test.sh 在开跑前打的最后一行，带着实际时长。
  # ⚠️ 判"是哪个档"必须拿**完整的固定串**去 `grep -F`，
  #    **不要用 `grep -oE` 把整行抠出来再看内容**。
  #
  #    这里查的是 2.5GB 的**磁盘镜像**，不是文本文件。第一版写的是
  #        grep -aoE 'Time budget:[^\r\n]{0,120}'
  #    抠回来的永远是截断的一截：
  #        Time budget: CPU + MEMORY co
  #    而同一个镜像上 `grep -aqF "concurrently for 0h30m00s"` 是**命中**的 ——
  #    整句就在那儿，是 `-oE` 在二进制数据上截断了它（实测：跑完之后镜像早已
  #    全部落盘，仍然是这一截，所以和"没写完"无关）。
  #    后果是那条诊断**永远说"没按中"**，连真选中 QUICK 的轮次也一样 ——
  #    一条永远为真的诊断，和没有诊断是一回事。
  #
  #    `sleep 8` 是另一件事：锚点刚出现时这一行的尾巴可能确实还没落盘，
  #    等一下再查，省得在边界上误报。
  REPORT_WAIT=1500
  if wait_for_log "Time budget:" 420 "时间预算已确定"; then
    sleep 8                     # 让这一行的尾巴也落进镜像
    if grep -aqF "concurrently for 0h10m00s" "$IMG" 2>/dev/null; then
      ok "选档生效：QUICK（10 分钟）"
    elif grep -aqF "concurrently for 0h30m00s" "$IMG" 2>/dev/null; then
      # 不在这里判失败：[4/4] 那条读 meta.json 的断言才是正式出口，
      # 这里只负责把等待上限放宽到够用，免得整轮以一句看着像产品卡死的
      # 「等了 1500s 也没等到报告」收场。
      info "选档没按中，回落到了默认档 STANDARD（菜单 30 秒超时）——"
      info "  这是本脚本按键时间窗没打中，**不是产品的问题**；本轮改为按 30 分钟档等。"
      REPORT_WAIT=2700
    else
      info "读不出实际时长（这一行还没完全落盘），按最宽的上限等"
      REPORT_WAIT=2700
    fi
  fi

  info "等压测跑完 + 出报告（上限 ${REPORT_WAIT}s）"
  if wait_for_log "Internal engineering report:" "$REPORT_WAIT" "两份报告都写完了"; then
    sleep 3          # 让逐项结果那二十几行打完
  else
    info "没等到收尾那一行，还是截一张，现场看它卡在哪"
  fi
  shot "burn-done"

  # 收尾菜单：p = 关机。反复按到它真的退出为止。
  info "发关机键"
  for (( t = 0; t < 300; t += 10 )); do
    kill -0 "$QEMU_PID" 2>/dev/null || { ok "收尾菜单按 p 之后虚拟机正常关机"; break; }
    mon "sendkey p"
    sleep 10
  done
fi

shot "final"

# 走 ACPI 关机，不要直接 kill。
#
# 硬杀会把**虚拟机内核的 page cache** 一起扔掉 —— 那些 capture() 刚写下去、
# 还没被 writeback 刷到 exFAT 上的采集文件就没了。表现和"产品没落盘"一模一样，
# 极难区分。ACPI 关机会让 systemd 正常收尾、卸载文件系统，
# 顺带也把关机这条路径本身测了。
if kill -0 "$QEMU_PID" 2>/dev/null; then
  info "发 ACPI 关机信号，等虚拟机自己收尾"
  mon "system_powerdown"
  for (( t = 0; t < 120; t += 5 )); do
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 5
  done
  if kill -0 "$QEMU_PID" 2>/dev/null; then
    info "ACPI 关机 120 秒没关掉，只能硬杀（下面的断言可能因此少东西）"
    kill -9 "$QEMU_PID" 2>/dev/null
  else
    ok "虚拟机响应 ACPI 关机并正常退出"
  fi
else
  info "虚拟机已经自己退出了"
fi
exec 3<&- 2>/dev/null; exec 3>&- 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
QEMU_PID=""

# ---------------------------------------------------------------- 4. 检查产物
printf '\n\033[1m[4/4] 把"U 盘"挂起来看\033[0m\n'

LOOP="$(losetup -P --find --show "$IMG")"
sleep 1
if mount -o ro "${LOOP}p4" "$MNT" 2>/dev/null; then
  ok "第 4 个分区能挂上"
else
  bad "第 4 个分区挂不上"
  printf '\n通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"; exit 1
fi

if (( NO_DATA )); then
  # 没有可用数据分区时该发生什么：
  #   - 报告退到 /tmp（关机就没了，这是已知且会在屏幕上打黄色大框警告的）
  #   - **绝不能**往这个不认识的分区上乱写
  #   - 流程照常跑完，不能卡死 —— 现场最怕的是"插上去没反应"
  #
  # 前两条这里能验；"打了黄框"只能靠截图人工看（shot-*.ppm 都留着）。
  # ⚠️ 这里绝不能写 `grep -c . || echo 0`。§11-7：grep -c 在计数为 0 时
  #    **既打印 "0" 又返回 1**，于是 `|| echo 0` 补出第二个 0，结果是两行的
  #    "0\n0" —— 拿去比较就成了"期望 0、实际 0，却判不相等"。
  #    而且它**只在健康路径上发作**（真没写东西的时候才会为 0），
  #    第一次跑这个场景就撞上了。运行时脚本有 count_lines() 专治这个，
  #    这里不 source core.sh，所以自己写一份同样形状的。
  count_lines_() {
    local n; n="$(grep -c . 2>/dev/null)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
  }
  n_files="$(find "$MNT" -mindepth 1 2>/dev/null | count_lines_)"
  # ext4 会有个 lost+found，那是 mkfs 建的，不算 KLBurn 写的
  n_written="$(find "$MNT" -mindepth 1 -not -name 'lost+found' 2>/dev/null | count_lines_)"
  check_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1（期望 $2，实际 $3）"; }
  check_eq "认不出的分区上一个字节都没写（不是 exFAT 就不该碰它）" "0" "$n_written"
  [[ -d "$MNT/out" ]] && bad "居然在非 exFAT 分区上建了 out/ 目录" \
                      || ok "没有在非 exFAT 分区上建 out/"
  info "分区里共 $n_files 个条目（lost+found 是 mkfs 建的）"
  info "「屏幕上有没有黄色大框警告」只能人工看截图：$WORK/shot-*.ppm"

  umount "$MNT" 2>/dev/null
  losetup -d "$LOOP" 2>/dev/null; LOOP=""
  printf '\n'
  printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
  exit $(( FAIL > 0 ? 1 : 0 ))
fi

# --- 报告目录 ---
# ⚠️ --disk-stress 会先在 out/ 里放一份"上一轮的报告"当哨兵。它也是个目录，
#    不排掉的话 head -1 有一半概率挑中它，然后下面每一条断言都对着一个假目录跑
#    —— 全红，而且原因指向完全不相干的地方。
RUNDIR="$(find "$MNT/out" -maxdepth 1 -mindepth 1 -type d ! -name '*_PREVIOUS_RUN' \
          2>/dev/null | head -1)"
if [[ -n "$RUNDIR" ]]; then
  ok "U 盘里出现了报告目录：out/$(basename "$RUNDIR")"
else
  bad "U 盘的 out/ 下没有任何报告目录 —— 报告没落盘（现场就是白跑一趟）"
  info "U 盘根目录内容：$(ls -A "$MNT" 2>/dev/null | tr '\n' ' ')"
  printf '\n通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"; exit 1
fi

TAG="$(basename "$RUNDIR")"

# --- 一定会有的：日志 ---
[[ -s "$RUNDIR/klburn.log" ]] && ok "klburn.log 有内容" \
                              || bad "klburn.log 不存在或是空的"

# 目录名格式：日期_时间_CPU型号_内存容量_范围[_序号]
#
# ⚠️ 1.9.5 起末尾多了范围后缀，而且它是**安全项**不是装饰：一台只测了 CPU 的
#    机器和一台全量测过的机器，目录名一模一样的话，半年后没人分得清哪份能当
#    验收依据。所以这里既验形状、也验它确实是本轮选的那个范围。
#    末尾可选的 _01/_02 是"同一分钟内连测两次"的去重序号（RTC 卡住的机器上
#    是必然事件），它排在范围后缀**之后**。
if [[ "$EDITION" == "mem" ]]; then
  # 内存盘的目录名是用户指定的格式（1.10.1 起）：
  #     日期_时间_内存容量_CPU_MEMSP
  # （注意和整机盘**顺序不同**：容量在 CPU 前面）。
  #
  # ⚠️⚠️ **整个名字必须是纯 ASCII。**1.10.0 那版带中文前缀「内存测试_」，
  #    而这个串要同时活在现场那块 Linux 文本控制台（没有中文字体，
  #    显示成一排方块）、exFAT 目录名、SHA256SUMS 和批次汇总工具里。
  #    这条断言在真机跑出来的目录上验，不是在单元测试的字符串上验 ——
  #    编码问题恰恰只在真的落盘、真的打屏之后才露出来。
  if [[ "$TAG" == *_MEMSP || "$TAG" =~ _MEMSP_[0-9]{2}$ ]]; then
    ok "报告目录名带 MEMSP 后缀：$TAG"
  else
    bad "报告目录名没有 MEMSP 后缀：$TAG"
  fi
  # ⚠️ 用 case 的通配，不用 `LC_ALL=C [[ ... ]]` —— 变量赋值只能加在**简单命令**
  #    前面，`[[` 是复合命令，那么写是语法错误。
  case "$TAG" in
    *[!A-Za-z0-9_.-]*) bad "目录名里有非 ASCII 字符（现场控制台会显示成方块）：$TAG" ;;
    *)                 ok "目录名是纯 ASCII（控制台/exFAT/校验清单三处都不会出问题）" ;;
  esac
  if [[ "$TAG" =~ ^[0-9]{8}_[0-9]{6}_[0-9]+GB_ ]]; then
    ok "目录名格式对（日期_时间_内存容量_CPU_MEMSP）"
  else
    bad "目录名不像话（少了日期/容量？）：$TAG"
  fi
  # ⚠️ 内存盘的目录名里**绝不能出现整机盘那套范围后缀** ——
  #    两种盘的报告要一眼分得开，混起来就分不清哪份能当什么用。
  if [[ "$TAG" =~ _(Full|CPU|GPU|DISK|INFO)(_[0-9]{2})?$ ]]; then
    bad "内存盘的目录名不该带整机盘的范围后缀：$TAG"
  else
    ok "内存盘的目录名不带整机盘的范围后缀"
  fi
elif [[ "$TAG" =~ ^[0-9]{8}_[0-9]{6}_.+_(Full|CPU|MEM|GPU|DISK|INFO)(_[0-9]{2})?$ ]]; then
  ok "报告目录名格式对（日期_时间_CPU_内存_范围）：$TAG"
else
  bad "报告目录名不像话（少了范围后缀？）：$TAG"
fi
if [[ "$EDITION" != "mem" ]]; then
  if [[ "$TAG" =~ _${SCOPE_TAG}(_[0-9]{2})?$ ]]; then
    ok "目录名上的范围后缀就是本轮选的那个（_${SCOPE_TAG}）"
  else
    bad "范围后缀对不上：期望 _${SCOPE_TAG}，实际目录名是 $TAG"
    info "  = 范围菜单那一键没打中，菜单 60 秒超时回落成了全量。"
    info "    这是本脚本按键时间窗没打中，**不是产品的问题**。"
  fi
fi

if [[ "$EDITION" == "mem" ]]; then
  # ================================================================
  # 内存专用盘：整轮只有三分钟，所以冒烟档就能一路验到报告本体
  # ================================================================
  #
  # 这一段回答的是"这张盘拿到现场会不会白跑一趟"：
  # 开机自己起来了吗、真的压了内存吗、三份交付物都落盘了吗、
  # 有没有混进它不该做的事。
  if grep -q "KLBurn MEMORY EDITION v${EXPECT_VER}" "$RUNDIR/klburn.log" 2>/dev/null; then
    ok "盘里跑的是内存盘、版本是 $EXPECT_VER"
  else
    got_v="$(grep -oE 'KLBurn [A-Z ]*v[0-9.]+' "$RUNDIR/klburn.log" 2>/dev/null | head -1)"
    bad "开机横幅对不上：盘里是「${got_v:-?}」，期望「KLBurn MEMORY EDITION v$EXPECT_VER」"
    info "  = 要么构建时没带 --edition mem，要么改完代码没重新构建。"
  fi

  # 三份交付物
  [[ -s "$RUNDIR/$TAG.html" ]] && ok "交付报告 <目录名>.html 生成了" \
                               || bad "交付报告没生成 —— 现场白跑一趟"
  [[ -s "$RUNDIR/$TAG.csv" ]]  && ok "工程文件 <目录名>.csv 生成了" \
                               || bad "CSV 没生成（拼总表就少了这一台）"
  [[ -s "$RUNDIR/results.jsonl" ]] && ok "results.jsonl 非空" \
                                   || bad "results.jsonl 空的 —— 这一轮什么都没判"

  # ⚠️ 内存盘**不出**内部工程报告（工程数据换成了那份 CSV）。
  #    冒出来说明有人把整机盘那套又接回来了。
  if compgen -G "$RUNDIR/raw/INTERNAL_*.html" >/dev/null 2>&1; then
    bad "内存盘不该生成 INTERNAL_ 工程报告（它的工程数据是那份 CSV）"
  else
    ok "没有 INTERNAL_ 工程报告（内存盘的工程数据是 CSV）"
  fi

  # meta.json：版本 + 这是内存盘
  if [[ -s "$RUNDIR/meta.json" ]]; then
    got_ver="$(grep -oE '"klburn_version":[^,]*' "$RUNDIR/meta.json" | cut -d'"' -f4)"
    [[ "$got_ver" == "$EXPECT_VER" ]] \
      && ok "meta.json 的版本是 $EXPECT_VER" \
      || bad "meta.json 版本对不上：盘里是 [$got_ver]，源码是 [$EXPECT_VER]"
    grep -q '"klburn_edition": *"mem"' "$RUNDIR/meta.json" \
      && ok "meta.json 标明这是内存盘" \
      || bad "meta.json 里没有 klburn_edition=mem"
  else
    bad "meta.json 不存在"
  fi

  # 真的压过内存吗 —— 这张盘的核心。没有这一条，上面全绿也可能是空跑。
  if grep -q '"id":"stress_mem"' "$RUNDIR/results.jsonl" 2>/dev/null; then
    ok "内存压力测试真的跑了（results.jsonl 里有 stress_mem）"
  else
    bad "results.jsonl 里没有 stress_mem —— 这一轮压根没压内存"
  fi
  # 内存明细读到了吗
  grep -q '"id":"check_dimm_serial"' "$RUNDIR/results.jsonl" 2>/dev/null \
    && ok "序列号核对跑了（查假条子那一条）" \
    || bad "results.jsonl 里没有 check_dimm_serial"

  # ⚠️ 这几项是这张盘**明确不做**的。冒出来说明有人把整机盘的采集又接回来了 ——
  #    那正是这次要砍掉的东西（被测平台上这些部件可能压根没有）。
  leaked=""
  for id in stress_cpu stress_disk stress_gpu collect_raid check_psu \
            test_nic check_pcie_link bench_cpu_flops; do
    grep -q "\"id\":\"$id\"" "$RUNDIR/results.jsonl" 2>/dev/null && leaked="$leaked $id"
  done
  [[ -z "$leaked" ]] && ok "报告里没有混进内存以外的判定项" \
                     || bad "内存盘里冒出了不该有的判定项：$leaked"

  # 报告本体：那句红线必须在
  if grep -qF "本报告仅针对内存" "$RUNDIR/$TAG.html" 2>/dev/null; then
    ok "报告里写明了本轮只测内存（不能当整机验收依据）"
  else
    bad "报告里没有「本报告仅针对内存」——一个孤零零的 PASS 会被当成整机验收通过"
  fi

elif [[ "$STAGE" == "smoke" ]]; then
  # 冒烟到此为止：能开机、能认出数据分区、能建目录写日志，就算过。
  if grep -q "KLBurn v${EXPECT_VER}" "$RUNDIR/klburn.log" 2>/dev/null; then
    ok "日志里的版本号是 $EXPECT_VER（盘里跑的确实是这次构建的代码）"
  else
    got_v="$(grep -oE 'KLBurn v[0-9.]+' "$RUNDIR/klburn.log" 2>/dev/null | head -1)"
    bad "版本对不上：盘里是「${got_v:-?}」，源码是 $EXPECT_VER"
    info "  = 你测的不是你以为的那份代码。改完代码要先重新构建："
    info "    sudo KLBURN_WORK=/home/li/klburn-build ./build/build-iso.sh"
    info "  （这条断言就是为了拦住"改完代码直接拿旧 ISO 跑 e2e"）"
  fi
else
  # --- 完整档：报告本体 ---
  [[ -s "$RUNDIR/$TAG.html" ]] && ok "交付报告 $TAG.html 生成了" \
                               || bad "交付报告没生成"
  [[ -s "$RUNDIR/raw/INTERNAL_$TAG.html" ]] \
    && ok "内部工程报告落在 raw/ 里（防手滑那一层）" \
    || bad "内部工程报告没生成"

  [[ -s "$RUNDIR/results.jsonl" ]] && ok "results.jsonl 非空" \
                                   || bad "results.jsonl 空的 —— 这一轮什么都没判"

  # --- meta.json ---
  if [[ -s "$RUNDIR/meta.json" ]]; then
    got_ver="$(grep -oE '"klburn_version":[^,]*' "$RUNDIR/meta.json" | cut -d'"' -f4)"
    [[ "$got_ver" == "$EXPECT_VER" ]] \
      && ok "meta.json 的版本是 $EXPECT_VER" \
      || bad "meta.json 版本对不上：盘里是 [$got_ver]，源码是 [$EXPECT_VER]"
    # ⚠️ 档位这一条要跟着 --scope 走。
    #    「仅导出硬件信息」那一档**根本没有时长菜单**（一个部件都不压，
    #    问"压多久"是句废话），`DURATION_PROFILE` 是 `INVENTORY`。
    #    无条件断言 QUICK 的话，那一轮会红在"选档按键没打中"——
    #    而实际上产品的行为完全正确，是这条断言写错了。
    #    反过来，这一条正好把"info 档必须跳过时长菜单"钉住了。
    if [[ "$SCOPE" == "info" ]]; then
      grep -q '"profile": *"INVENTORY"' "$RUNDIR/meta.json" \
        && ok "info 档跳过了时长菜单（profile=INVENTORY）" \
        || bad "info 档的 profile 不是 INVENTORY —— 时长菜单没被跳过？"
    elif (( DISK_SCOPE_DECLINED_EXPECTED )); then
      # ⚠️ 同一把尺子的第二个用法（1.10.1）：硬盘专测**没确认擦盘**的那一轮
      #    什么都不会跑，所以时长菜单也整个跳过了 —— profile 同样是 INVENTORY。
      #    这不是"按键没打中"，是设计如此：问一个这轮不会执行的东西要跑多久，
      #    和 info 档问"压多久"是同一句废话。
      grep -q '"profile": *"INVENTORY"' "$RUNDIR/meta.json" \
        && ok "拒掉擦盘之后连时长菜单都跳过了（profile=INVENTORY）" \
        || bad "拒掉擦盘之后 profile 不是 INVENTORY —— 时长菜单没被跳过？"
    else
      grep -q '"profile": *"QUICK"' "$RUNDIR/meta.json" \
        && ok "档位确实选中了 QUICK（sendkey 生效了）" \
        || bad "档位不是 QUICK —— 选档按键没打中，实际跑的是默认 STANDARD"
    fi
    # 目录名后缀已经验过了，这里再验一次 meta 里的 scope —— 两处必须一致，
    # 报告、批次汇总都读 meta 那个值。
    grep -q "\"scope\": *\"$SCOPE\"" "$RUNDIR/meta.json" \
      && ok "meta.json 的 scope 是 $SCOPE" \
      || bad "meta.json 的 scope 和 --scope $SCOPE 对不上"
  else
    bad "meta.json 不存在"
  fi

  # --- 校验清单必须真的校验得过 ---
  #
  # ⚠️ 这条只有拿**真跑出来的 run-dir** 才验得了，而且 1.9.6 之前它是红的：
  #    `klburn.log` 在清单生成之后还在被写（"Checksums:"那行自己就会追加），
  #    于是 `sha256sum -c` 永远报 `./klburn.log: FAILED`。
  #    一份永远校验不过的清单，和没有这份清单是一回事 ——
  #    它的用途正是"半年后证明归档的那份和客户手上那份是同一份"。
  if [[ -s "$RUNDIR/SHA256SUMS" ]]; then
    if ( cd "$RUNDIR" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1 ); then
      ok "SHA256SUMS 校验通过（清单里 $(grep -c '^[0-9a-f]' "$RUNDIR/SHA256SUMS") 个文件）"
    else
      bad "SHA256SUMS 校验不过：$( cd "$RUNDIR" && sha256sum -c SHA256SUMS 2>&1 \
             | grep -v ': OK$' | head -3 | tr '\n' ' ' )"
    fi
  else
    bad "没有 SHA256SUMS"
  fi

  # --- 判定分布：这台"机器"是虚拟的，很多项必然 SKIP，但不该有 FAIL ---
  if [[ -s "$RUNDIR/results.jsonl" ]] && command -v jq >/dev/null 2>&1; then
    n_fail="$(jq -s '[.[] | select(.status == "FAIL")] | length' "$RUNDIR/results.jsonl" 2>/dev/null || echo -1)"
    n_all="$(jq -s 'length' "$RUNDIR/results.jsonl" 2>/dev/null || echo 0)"
    info "判定共 $n_all 项，其中 FAIL $n_fail 项"
    # ⚠️ 有**一种 FAIL 是这一轮应该出现的**：`--scope gpu` / `--scope disk` 跑在
    #    一台没有那个部件的机器上（QEMU 恰好就是），1.9.7 起主流程会直接跳出
    #    并落一条 `scope_target_missing` 的 FAIL。那条 FAIL 说的是"这一轮作废"，
    #    不是"硬件坏了"，正是我们要的行为 —— 不能被下面这条断言判成红。
    n_missing="$(jq -s '[.[] | select(.id == "scope_target_missing")] | length' \
                 "$RUNDIR/results.jsonl" 2>/dev/null || echo 0)"
    if [[ "$n_missing" != "0" ]]; then
      if [[ "$SCOPE" == "gpu" || "$SCOPE" == "disk" ]]; then
        ok "范围内的部件不在这台机器上 -> 落了 scope_target_missing 的 FAIL（预期行为）"
        [[ "$n_fail" == "1" ]] \
          && ok "而且**只有**这一条 FAIL（别的项没被连累成故障）" \
          || bad "除了 scope_target_missing 还有 $(( n_fail - 1 )) 条 FAIL"
        # 跳出必须是真的跳出：压测/复查那几项连结论行都不该产生
        for leak in stress_gpu stress_disk verify_dmesg verify_sel bench_gpu_bw; do
          jq -e -s --arg i "$leak" 'any(.[]; .id == $i)' "$RUNDIR/results.jsonl" \
             >/dev/null 2>&1 \
            && bad "说好跳出了，$leak 却还是跑了" \
            || ok "跳出之后 $leak 没有再跑"
        done
        # ---- 1.10.1：我们是**故意拒掉擦盘确认**才作废的，理由必须写对 ----
        #
        # 这一段验的是那条新语义在真机上确实成立：不确认 = 这一轮作废，
        # 而不是 1.10.0 那样静默跳过、最后打一份绿色 PASS。
        if (( DISK_SCOPE_DECLINED_EXPECTED )); then
          _dt="$(jq -r -s '[.[] | select(.id=="scope_target_missing")][0].detail' \
                 "$RUNDIR/results.jsonl" 2>/dev/null)"
          case "$_dt" in
            *"未确认"*)   ok "作废的理由写的是「没确认擦盘」（不是「没有可测硬盘」）" ;;
            *)            bad "作废理由不对，写的是：${_dt:0:60}" ;;
          esac
          # ⚠️ 这条 FAIL 说的是「这一轮作废」，**不是「这台机器坏了」**。
          case "$_dt" in
            *"这不是硬件故障"*) ok "而且写明了这不是硬件故障" ;;
            *)                  bad "作废的文案没说明这不是硬件故障（会被当成机器有毛病）" ;;
          esac
          # 给出下一步：只想留信息不擦盘的，该选「仅导出报告」
          case "$_dt" in
            *"仅导出报告"*) ok "并且指了下一步该怎么做" ;;
            *)              bad "作废的文案没告诉现场下一步该怎么办" ;;
          esac
          # ⚠️⚠️ **最要紧的一条：拒掉之后一个字节都不许写。**
          #    用的是和 --disk-stress 那条路同一个证据（稀疏文件的实际占用），
          #    只不过方向相反：那边要求涨上去，这边要求纹丝不动。
          _wrote=0
          for _i in "${!SPARES[@]}"; do
            [[ -e "${SPARES[$_i]}" ]] || continue
            _a="$(spare_alloc "${SPARES[$_i]}")"; _b="${SPARE_ALLOC_BEFORE[$_i]:-0}"
            [[ "$_a" =~ ^[0-9]+$ ]] || _a=0
            [[ "$_b" =~ ^[0-9]+$ ]] || _b=0
            # 留 64MB 余量：QEMU 自己对 raw 稀疏盘的元数据也会占一点
            (( _a > _b + 64 * 1024 * 1024 )) && _wrote=1
          done
          (( _wrote == 0 )) \
            && ok "拒掉之后空白盘一个字节都没被写过（实际占用纹丝不动）" \
            || bad "说好没确认，空白盘却被写过了 —— 这是本项目最不能犯的错"
        fi
      else
        bad "范围 $SCOPE 不该出现 scope_target_missing"
      fi
    elif [[ "$n_fail" != "0" ]]; then
      # QEMU 里没有 BMC、没有阵列卡、没有显卡，这些都该 SKIP 不该 FAIL。
      # 真出现 FAIL 说明有判定逻辑把"没有这个硬件"当成了"硬件坏了"——
      # 这正是二号原则（能力缺失 ≠ 硬件故障）要防的事。
      bad "虚拟机上出现了 $n_fail 条 FAIL（虚拟环境不该有硬件故障）"
      jq -r 'select(.status=="FAIL") | "       " + .id + ": " + .detail' \
         "$RUNDIR/results.jsonl" 2>/dev/null | head -10
    else
      ok "一条 FAIL 都没有（没把「虚拟机里没这个硬件」误判成故障）"
    fi

    # collect_disk 是 21 个判定 id 里唯一单元测试覆盖不到的，这里正好带上
    jq -e -s 'any(.[]; .id == "collect_disk")' "$RUNDIR/results.jsonl" >/dev/null 2>&1 \
      && ok "collect_disk 有结论（单元测试覆盖不到的那一项）" \
      || bad "collect_disk 这一项没出现在结论里"
  fi

  # ================================================================
  # --disk-stress 的三条验收
  # ================================================================
  # 这一段守的是**全项目最危险的一条路径**：fio 往裸盘上写随机数据，
  # 而启动 U 盘就在同一台机器上。反查排除一旦退化，测试盘当场报废、
  # 历史报告全丢 —— 而且是不可逆的。
  #
  # 以前只有 test-disk-exclusion.sh 用 loop + dm-linear 搭同构设备链验反查逻辑，
  # **从来没真让 fio 跑起来写过一次盘**。三条一起才说明问题：
  #   1. 空白盘真被写了       —— 否则这一轮什么都没验证（SKIP 也能"全绿"）
  #   2. U 盘还在、历史报告还在 —— 这才是"没写穿"
  #   3. stress_disk 判 PASS   —— 确认键真打中了，不是又静默跳过了
  if (( DISK_STRESS )); then
    printf '\n'
    # ---- 1. fio 真写了 ----
    for (( i = 0; i < ${#SPARES[@]}; i++ )); do
      after="$(spare_alloc "${SPARES[$i]}")"
      before="${SPARE_ALLOC_BEFORE[$i]:-0}"
      # 写过之后稀疏文件的实际占用会从 ~0 涨到几百 MB 以上。
      # 阈值取 64MB：fio 顺序写 180s 的 30% 再怎么慢也不止这个数，
      # 而"文件系统元数据"之类的噪声远到不了。
      if (( after > before + 64*1024*1024 )); then
        ok "$(basename "${SPARES[$i]}")：实际占用 $(numfmt --to=iec "$before") -> $(numfmt --to=iec "$after")，fio 真写了"
      else
        bad "$(basename "${SPARES[$i]}")：实际占用还是 $(numfmt --to=iec "$after") —— fio 根本没往它上面写"
      fi
      # 再直接看头 1MB 有没有非零字节。占用涨了但全是零（比如被谁 fallocate 了一下）
      # 也算没写 —— 这条是上面那条的独立佐证，两条查的不是同一件事。
      nz="$(head -c 1048576 "${SPARES[$i]}" 2>/dev/null | tr -d '\0' | wc -c)"
      if (( nz > 0 )); then
        ok "$(basename "${SPARES[$i]}")：头 1MB 里有 $nz 个非零字节（真是数据，不是空洞）"
      else
        bad "$(basename "${SPARES[$i]}")：头 1MB 全是零 —— 没有真正写入的数据"
      fi
    done

    # ---- 2. 没写穿 U 盘 ----
    # 分区挂得上（上面已经断言过）+ 上一轮的报告一个字节都没变。
    # 只验前者是不够的：分区表没被动、文件全没了，照样挂得上。
    sent="$MNT/$SENTINEL_DIR/report.html"
    if [[ -f "$sent" ]]; then
      if [[ "$(cat "$sent" 2>/dev/null)" == "$SENTINEL_TEXT" ]]; then
        ok "上一轮的报告原封不动（fio 没写穿启动 U 盘）"
      else
        bad "上一轮的报告内容被改了 —— 有东西写到 U 盘上了"
      fi
    else
      bad "上一轮的报告没了 —— fio 很可能把启动 U 盘一起擦了"
    fi
    # 本轮自己的报告也还在（前面已断言 RUNDIR 存在，这里确认它和历史那份并存）
    n_runs="$(find "$MNT/out" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)"
    if (( n_runs >= 2 )); then
      ok "U 盘的 out/ 下有 $n_runs 个报告目录（历史那份和这一轮的并存）"
    else
      bad "U 盘的 out/ 下只剩 $n_runs 个报告目录 —— 历史记录被冲掉了"
    fi

    # ---- 3. stress_disk 判 PASS，不是 SKIP ----
    # SKIP 也能让整轮"全绿"，所以必须明确要求 PASS：
    # SKIP 意味着确认键没打中，这一轮压根没写过盘，上面两条也就无从谈起。
    if [[ -s "$RUNDIR/results.jsonl" ]] && command -v jq >/dev/null 2>&1; then
      st="$(jq -r -s '[.[]|select(.id=="stress_disk")]|.[0].status // "(没有这一项)"' \
            "$RUNDIR/results.jsonl" 2>/dev/null)"
      if [[ "$st" == "PASS" ]]; then
        ok "stress_disk 判 PASS（确认键真打中了，不是又静默跳过）"
      else
        bad "stress_disk 是 [$st]，要的是 PASS —— SKIP 等于这一轮根本没写盘"
      fi
    fi
    if [[ -s "$RUNDIR/meta.json" ]]; then
      grep -q '"disk_confirmed": *1' "$RUNDIR/meta.json" \
        && ok "meta.json 记着 disk_confirmed=1" \
        || bad "meta.json 里 disk_confirmed 不是 1"
      dt="$(grep -oE '"disk_tested":[^,]*' "$RUNDIR/meta.json" | cut -d'"' -f4)"
      if [[ -n "$dt" ]]; then
        ok "meta.json 记下了真被写过的盘：$dt"
      else
        bad "meta.json 的 disk_tested 是空的 —— 报告里会说没测过硬盘"
      fi
    fi
    printf '\n'
  fi

  # --- 交付边界：报告里不许有内部用语 ---
  if [[ -s "$RUNDIR/$TAG.html" ]]; then
    leaked=""
    for w in "重新出盘" "构建目录" "盘内缺少" "vendor/" "storcli" "git commit"; do
      grep -qF -- "$w" "$RUNDIR/$TAG.html" 2>/dev/null && leaked="$leaked $w"
    done
    [[ -z "$leaked" ]] && ok "交付报告里没有内部用语（真跑出来的那一份，不是造的 fixture）" \
                       || bad "交付报告泄漏了内部用语：$leaked"
  fi
fi

# ---------------------------------------------------------------- 收尾
umount "$MNT" 2>/dev/null
losetup -d "$LOOP" 2>/dev/null; LOOP=""

printf '\n'
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
