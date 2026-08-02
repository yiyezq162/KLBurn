#!/usr/bin/env bash
#
# 固件对账：盘里的关键驱动要的固件，一个都不能少。
#
#     ./tests/check-firmware.sh
#     ./tests/check-firmware.sh --rootfs /home/li/klburn-build/rootfs
#
# 为什么单独立一条、而且**不在 run-all.sh 里**：它要对着一个**已经构建出来的
# rootfs** 查，没构建过就无从查起。定位和 e2e-qemu.sh 一样 —— 构建完之后跑。
#
# 它守的是什么：
#
#   Ubuntu 的 live-server 镜像把 linux-firmware 的文件**剪掉了**（dpkg 说装了
#   500 多 MB，磁盘上只剩 118MB / 140 个文件，连 .list 都删了）。剪掉之后，
#   bnx2x（Broadcom 10G，Dell R6x0 / HP Gen8-9 上到处都是）这类**必须加载固件
#   才能起来**的驱动直接起不来 —— 一台有 4 个网口的机器，`ip link` 里一个物理口
#   都看不到，collect_nic 只能判 WARN「无物理口」。
#   **报告上写着这台机器没网卡，而它明明有四个。**
#
#   这种缺失没有任何报错会指出来：驱动加载失败只在 dmesg 里留一行
#   "Direct firmware load for bnx2x/... failed"，采集正常、报告正常、结论正常，
#   只是硬件凭空少了一块。所以要有人对着账本一项一项点。
#
# 做法：对盘里每个关键驱动跑 `modinfo -F firmware`（问驱动自己要什么，
# 不是查资料猜），再逐个去 <rootfs>/lib/firmware 下找。
# 驱动本身不需要固件（in-tree 自带、或者固件烧在卡上，如 mlx5）就自动 0 项通过，
# 不用维护"哪些不需要"的名单 —— 那种名单会随内核升级悄悄过期。
#
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

ROOTFS="${KLBURN_ROOTFS:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rootfs) ROOTFS="$2"; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done
if [[ -z "$ROOTFS" ]]; then
  ROOTFS="${KLBURN_WORK:-$HOME/klburn-build}/rootfs"
fi

PASS=0; FAIL=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# 断言函数名打错不能静悄悄地过去（§11-13"断言悄悄停止计数"的同款病）
command_not_found_handle() {
  # ⚠️ 不能在这里改 FAIL：handler 跑在 fork 出来的子进程里，加了也加不到父进程头上，
  #    屏幕红一条、汇总还是"失败 0 项"。直接把整个套件干掉，让退出码非零。
  printf "  \033[31mFAIL\033[0m 调用了不存在的命令 %s —— 多半是断言函数名打错了，\n" "$1"
  printf "       这条断言根本没跑。中止本套件。\n"
  kill -TERM $$
  return 127
}

if [[ ! -d "$ROOTFS" ]]; then
  printf '  \033[0;33m跳过：没有已构建的 rootfs（%s）\033[0m\n' "$ROOTFS"
  printf '  先构建一次：sudo KLBURN_WORK=... ./build/build-iso.sh\n'
  printf '通过 %d 项，失败 %d 项\n' 0 0
  exit 0
fi
command -v modinfo >/dev/null 2>&1 || { echo "缺少 modinfo（apt install kmod）" >&2; exit 2; }

FWDIR="$ROOTFS/lib/firmware"

# ================================================================
# 关键驱动清单
# ================================================================
# 只列**服务器上真会插的东西**：网卡、FC HBA、阵列卡 / HBA、板载与独立显示。
# NVIDIA 不在这里 —— 它走 vendor/ 里的闭源驱动，GSP 固件是驱动自己铺的
# （chroot-setup.sh 里另有一条断言盯着那份）。
#
# 不需要固件的驱动留在表里是**故意的**：这样"某天内核升级后它开始需要固件了"
# 会当场跑红，而不是等到现场发现少了一块网卡。
DRIVERS=(
  # ---- 以太网 ----
  bnx2x      # Broadcom NetXtreme II 10G —— 缺固件驱动根本起不来
  tg3        # Broadcom NetXtreme 1G（板载最常见）
  bnxt_en    # Broadcom NetXtreme-E 25/100G
  ice        # Intel E810 25/100G —— 缺 DDP 包会降级进 safe mode
  i40e       # Intel X710/XL710
  ixgbe      # Intel 82599 / X520 / X550
  igb igc e1000e
  qede       # Marvell/QLogic FastLinQ 以太网
  qed        # ↑ 的公共层，固件在这一层
  be2net     # Emulex/Broadcom OneConnect
  cxgb4      # Chelsio T4/T5/T6
  nfp        # Netronome Agilio
  mlx5_core  # Mellanox CX-4 及以后（固件烧在卡上 flash 里）
  mlx4_core  # Mellanox CX-3
  # ---- FC HBA ----
  qla2xxx    # QLogic
  lpfc       # Emulex
  bfa        # Brocade
  # ---- 阵列卡 / HBA ----
  megaraid_sas mpt3sas mpi3mr smartpqi aacraid hpsa
)

# ⚠️ **显示驱动不能放进上面那张表。**
#
# 上面那套"MODULE_FIRMWARE 声明了什么，盘里就得有什么"对网卡/HBA 成立
# （实测 852 项里网卡一个不缺），对显卡**不成立**：amdgpu 声明了 584 个固件，
# 而 Ubuntu 的 linux-firmware 本来就只发其中 574 个 —— 少的那 10 个
# （ip_discovery.bin / *_cap.bin / *_mes.bin）要么是从显存里读的、要么上游没发。
# ast 的 ast_dp501_fw.bin 同理，Debian/Ubuntu 从来不发。
#
# 拿声明当账本去对，只会得到 3 条永远红着的假警报，然后逼着人把守卫关掉。
#
# 我们真正要守的不是"声明的都在"，而是**"我们的剪裁没有把本来有的剪掉"**
# （1.5.0 就是这么把 amdgpu 整个目录剪没的：模块还在、固件没了，
#  装了 AMD 独显的机器屏幕点不亮，而且全程零报错）。
# 所以显示驱动改成查**目录在不在、文件数够不够**。
FW_DIRS_MUST_EXIST=(
  "amdgpu|400"    # AMD 独显（Ubuntu 发 570+ 个文件，卡在 400 留足上游增删的余量）
  "radeon|100"    # 老 AMD 卡
)

# ================================================================
# 1. 内核目录：有且只有一个
# ================================================================
mapfile -t KDIRS < <(find "$ROOTFS/lib/modules" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
if (( ${#KDIRS[@]} == 1 )); then
  ok "rootfs 里有且只有一个内核（$(basename "${KDIRS[0]}")）"
else
  bad "rootfs/lib/modules 下有 ${#KDIRS[@]} 个内核目录，应该只有 1 个：$(printf '%s ' "${KDIRS[@]##*/}")"
fi
(( ${#KDIRS[@]} )) || { printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"; exit 1; }
KDIR="${KDIRS[0]}"
KVER="$(basename "$KDIR")"

echo
echo "=== rootfs: $ROOTFS"
echo "=== 内核:   $KVER"
echo "=== 固件:   $(find "$FWDIR" -type f 2>/dev/null | wc -l) 个文件, $(du -sh "$FWDIR" 2>/dev/null | cut -f1)"
echo

# 固件在不在。linux-firmware 可能按 .zst / .xz 压缩发布，内核两种都能直接读，
# 所以三个名字任意一个在就算数。用 -e 不用 -L：符号链接指向的目标也必须真存在
# （intel/ice/ddp/ice.pkg 就是个符号链接，断了和没有是一回事）。
fw_present() {
  local f="$1"
  [[ -e "$FWDIR/$f" || -e "$FWDIR/$f.zst" || -e "$FWDIR/$f.xz" ]]
}

# ================================================================
# 2. 逐个驱动对账
# ================================================================
total_need=0; total_miss=0; miss_drivers=()
for drv in "${DRIVERS[@]}"; do
  ko="$(find "$KDIR" -name "$drv.ko" -o -name "$drv.ko.*" 2>/dev/null | head -1)"
  if [[ -z "$ko" ]]; then
    bad "$drv：内核里根本没有这个模块（层选错了？）"
    continue
  fi

  mapfile -t need < <(modinfo -F firmware "$ko" 2>/dev/null | sed '/^$/d' | sort -u)
  total_need=$(( total_need + ${#need[@]} ))

  miss=()
  for f in "${need[@]}"; do
    fw_present "$f" || miss+=("$f")
  done
  total_miss=$(( total_miss + ${#miss[@]} ))

  if (( ${#miss[@]} == 0 )); then
    ok "$drv：需要 ${#need[@]} 个固件，缺 0 个"
  else
    miss_drivers+=("$drv")
    bad "$drv：需要 ${#need[@]} 个固件，缺 ${#miss[@]} 个 -> ${miss[*]}"
  fi
done

echo
# ================================================================
# 3. 总账
# ================================================================
# 分驱动的断言已经能定位到人，这条是"总数"的结构性快照：
# 剪裁固件时手一抖多删一个目录，这里一定跑红。
if (( total_miss == 0 )); then
  ok "总账：${#DRIVERS[@]} 个关键驱动共需要 $total_need 个固件，缺 0 个"
else
  bad "总账：共需要 $total_need 个固件，缺 $total_miss 个（涉及 ${miss_drivers[*]}）"
fi

# 显示驱动：查目录在不在、文件数够不够（理由见上面 FW_DIRS_MUST_EXIST 那段）
for entry in "${FW_DIRS_MUST_EXIST[@]}"; do
  d="${entry%%|*}"; want="${entry#*|}"
  n="$(find "$FWDIR/$d" -type f -o -type l 2>/dev/null | grep -c . || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  if (( n >= want )); then
    ok "$d 固件目录在（$n 个文件，下限 $want）"
  else
    bad "$d 固件目录只有 $n 个文件（下限 $want）—— 是不是又被 FIRMWARE_PRUNE 剪了？
       模块还在、固件没了的表现是：装了这类显卡的机器屏幕点不亮，而且全程零报错。"
  fi
done

# 板载显示芯片：ast（AST2400/2500/2600）和 mgag200 是服务器上最常见的两个，
# 现在**都不需要固件**。列在这里是为了万一哪天内核改成要固件了能当场发现 ——
# 那时候这两条会从"0 项"变成"缺 N 项"。
for drv in ast mgag200; do
  ko="$(find "$KDIR" -name "$drv.ko" -o -name "$drv.ko.*" 2>/dev/null | head -1)"
  if [[ -z "$ko" ]]; then
    bad "$drv：内核里没有这个模块（板载显示会点不亮）"
    continue
  fi
  # ast 声明了 ast_dp501_fw.bin，但那是 DP501 转接芯片专用、Ubuntu 从来不发，
  # 绝大多数服务器用不到。所以只确认模块在，不对账它声明的固件。
  ok "$drv：板载显示模块在（不对账其声明的固件，Ubuntu 不发那几个）"
done

# 需要固件的驱动数不能是 0 —— 那说明 modinfo 没真跑起来（比如 .ko.zst 读不了），
# 于是每个驱动都"需要 0 个、缺 0 个"，一路全绿。这正是本项目最恨的那种绿。
if (( total_need > 0 )); then
  ok "modinfo 真读出了固件依赖（$total_need 项），不是全空跑绿"
else
  bad "所有驱动都读出 0 个固件依赖 —— modinfo 多半没能读 .ko.zst，这轮等于没检查"
fi

# CPU 微码：不属于任何驱动的 MODULE_FIRMWARE，但缺了会让本该被微码修掉的
# 勘误在压测时冒出来，然后被记成"硬件不稳定"。
for d in intel-ucode amd-ucode; do
  if [[ -d "$FWDIR/$d" ]] && [[ -n "$(ls -A "$FWDIR/$d" 2>/dev/null)" ]]; then
    ok "CPU 微码 $d 在（$(find "$FWDIR/$d" -type f | wc -l) 个文件）"
  else
    bad "CPU 微码 $d 缺失"
  fi
done

# ================================================================
# 4. PCI / USB ID 库不能太旧
# ================================================================
# 库旧了不会有任何报错，只是新卡在 lspci 里显示成 "Device 2335" ——
# 而网卡型号（nic_pci_model）和阵列卡型号（collect_raid）都是按总线地址从
# lspci 反查的，库一旧整条链就断了，报告上"这台机器装了什么卡"直接失真。
#
# 卡"两年"这条线：pci.ids 每周都在更新，落后两年意味着中间整整两代新硬件
# 都认不出来。noble 自带的那份就停在 2024-03-31，构建时不覆盖的话必然跑红。
#
# 比的是**本机今天的日期**，不是 ISO 里记的构建日期 —— 后者是这次构建自己写的，
# 拿它当基准等于自己给自己打分。
ids_age_days() {          # ids_age_days <文件> -> 距今天多少天；读不出来给空
  local f="$1" d
  d="$(awk -F'Date:[[:space:]]*' '/^#[[:space:]]*Date:/{print $2; exit}' "$f" 2>/dev/null)"
  [[ -n "$d" ]] || return 0
  local epoch; epoch="$(date -d "$d" +%s 2>/dev/null)" || return 0
  printf '%s' $(( ( $(date +%s) - epoch ) / 86400 ))
}
for ids in pci.ids usb.ids; do
  f="$ROOTFS/usr/share/misc/$ids"
  if [[ ! -f "$f" ]]; then
    bad "$ids 在盘里根本不存在（lspci 会连厂商名都报不出来）"
    continue
  fi
  age="$(ids_age_days "$f")"
  if [[ -z "$age" ]]; then
    # usb.ids 的头里不一定有 Date: 行，取不到就只确认它非空，不硬判
    if [[ -s "$f" ]]; then
      ok "$ids 在盘里（头部没有日期行，只确认非空）"
    else
      bad "$ids 是空文件"
    fi
  elif (( age <= 730 )); then
    ok "$ids 的日期距今 $age 天（不到两年）"
  else
    bad "$ids 的日期距今 $age 天（超过两年）—— 新卡会显示成 Device xxxx，
       报告里的网卡/阵列卡型号会失真。构建时是不是没能下载新版？"
  fi
done

echo
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
