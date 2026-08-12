#!/usr/bin/env bash
# KLBurn 构建配置
# 这个文件被 build-iso.sh source，也被 chroot-setup.sh source。
# 只放变量，不要放逻辑。

# ---------- 版本 ----------
# 每次改完脚本/报告生成器就把这个小版本号往上加一格（0.1.0 -> 0.2.0），
# 不要指望靠 build_date 的日期去区分版本——日期一眼看不出改了什么、改了多少，
# 版本号才是人能记住、能对话里引用的东西。
#
# ⚠️ 改完脚本要「先 bump 再构建」。0.3.0 就栽过一次：ISO 构建完之后又改了
# core.sh/collect.sh 却没动版本号，于是现场那根盘自称 0.3.0、跑的却是修复前的
# 代码（lshw 卡满 90s、屏幕上冒 Killed），对着仓库怎么看都对不上。
KLBURN_VERSION="1.10.0"

# ================================================================
# 版本（edition）：这张盘是整机全测盘，还是内存专用盘
# ================================================================
# 同一份源码出两种盘，**构建时钉死**，现场不会再问任何人：
#
#   full  整机出厂老化盘。开机选范围（六个入口）、选时长，跑完出验收报告。
#   mem   内存专用盘。**开机不问任何东西，直接开测**，只碰内存：
#         平台认个大概（CPU / 主板 / BIOS）、逐条内存的 SN / 型号 / 频率 /
#         容量，做一段短压测和 ECC 复查，出一份只谈内存的报告。
#         不采网卡、不采 PCIe、不跑任何性能基准、不碰硬盘。
#
#     KLBURN_EDITION=mem sudo -E ./build/build-iso.sh
#     sudo ./build/build-iso.sh --edition mem        # 等价，推荐
#
# ⚠️ 两种盘的差别**只在这三处**：开机拉起哪个脚本（chroot-setup.sh 改
#    klburn.service 的 ExecStart）、报告标题、ISO 文件名。判定逻辑、
#    四态语义、报告红线全都共用同一套代码 —— 别为了内存盘再分叉一份。
KLBURN_EDITION="${KLBURN_EDITION:-full}"
case "$KLBURN_EDITION" in
  full|mem) ;;
  *) printf 'config.sh: KLBURN_EDITION 只能是 full 或 mem，收到 "%s"\n' \
       "$KLBURN_EDITION" >&2; exit 1 ;;
esac

# ================================================================
# 品牌抬头
# ================================================================
# 这一整块决定"这张盘和它出的报告属于谁"。**在构建时钉死进 ISO**，
# 现场运行时绝不会询问操作员 —— 一根盘做出来是谁的抬头就是谁的。
#
# 换一家公司只要改这几行再重新构建；也可以完全不碰这个文件，
# 用构建期环境变量覆盖（适合同一份源码出多个抬头的盘）：
#
#     KLBURN_COMPANY_NAME="XX科技有限公司" sudo -E ./build/build-iso.sh
#
# 这些值经 chroot-setup.sh 写进 /opt/klburn/klburn.conf，再进 meta.json 和报告抬头。

# 报告抬头显示的公司名。可以写中文，report.html 里显示正常。
# 注意：开机那个 banner 是 Linux 文本控制台，显示不了中文，
#      所以公司名含中文时 banner 上不显示它（只在报告里出现），这是正常的。
COMPANY_NAME="${KLBURN_COMPANY_NAME:-广州市鲲林科技有限公司}"

# 报告大标题（客户报告和内部报告共用这一个主标题）。
# 内存盘换一个标题 —— 一份只测了内存的报告顶着"服务器出厂老化测试报告"
# 这个抬头，就是在说一件它没做过的事（和单项专测那条红线同一把尺子）。
if [[ "$KLBURN_EDITION" == "mem" ]]; then
  REPORT_TITLE="${KLBURN_REPORT_TITLE:-内存专用测试报告}"
else
  REPORT_TITLE="${KLBURN_REPORT_TITLE:-服务器出厂老化测试报告}"
fi

# 产品名：开机 banner、GRUB 菜单项、.disk/info 用它。
# 只能是 ASCII —— 这三个地方都在文本控制台/引导器里，中文显示不出来。
if [[ "$KLBURN_EDITION" == "mem" ]]; then
  PRODUCT_NAME="${KLBURN_PRODUCT_NAME:-KLBurn-MEM}"
else
  PRODUCT_NAME="${KLBURN_PRODUCT_NAME:-KLBurn}"
fi

# 可选 logo：把 png 放到 vendor/logo.png，留空则报告不显示 logo
COMPANY_LOGO_FILE="${KLBURN_LOGO_FILE:-logo.png}"

# ---------- 源 ISO ----------
UBUNTU_RELEASE="24.04"
UBUNTU_POINT="24.04.4"
SRC_ISO_NAME="ubuntu-${UBUNTU_POINT}-live-server-amd64.iso"
SRC_ISO_URL="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/${UBUNTU_RELEASE}/${SRC_ISO_NAME}"
# 留空 = 跳过校验；填上 sha256 则强制校验。
#
# 取自 Ubuntu 官方 https://releases.ubuntu.com/24.04/SHA256SUMS（不是拿本地那份
# 自己算的 —— 那样只能证明"和我下的那次一致"，证明不了下对了东西）。
# 本地缓存的那份已核对过，一致。
#
# 之前一直留空，等于 3.4GB 从镜像站拉下来完全不验：镜像同步到一半、
# 断点续传接错、磁盘悄悄坏一个扇区，都会安安静静做出一张有问题的盘，
# 而且要等装到服务器上才发现。
#
# 换 UBUNTU_POINT 时**必须同时换这个值**，否则每次构建都会在校验那一步停下。
SRC_ISO_SHA256="e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433"

# ---------- 构建路径 ----------
# 必须在 WSL 原生文件系统上，不能在 /mnt/c 下（squashfs 打包性能会崩）
#
# 脚本要 sudo 跑，而 sudo 下 $HOME 可能变成 /root，工作区就跑到别处去了
# （下过的 3GB 源 ISO 白下）。所以显式解析出真正的调用者家目录。
#
# 这个判断必须能容忍 getent 失败：这份 config.sh 同时会被 chroot-setup.sh
# 在 chroot 里再 source 一遍（chroot 里 WORK_DIR 这个值根本用不上，但文件是
# 共用的），那时候 $SUDO_USER 还是外层 sudo 传进来的值，可 chroot 的目标根
# 文件系统里压根没有这个用户，getent 会失败。在 -e -o pipefail 下，
# 一次失败的赋值型命令替换会直接把整个脚本静默杀死——之前就是这么栽的：
# chroot-setup.sh 一行日志都没打就退出了，只是因为 source config.sh 这一步
# 里潜伏的这个 getent。所以这里用 if 条件短路，绝不能写成裸的赋值。
if [[ -n "${KLBURN_WORK:-}" ]]; then
  WORK_DIR="$KLBURN_WORK"
elif [[ -n "${SUDO_USER:-}" ]] \
     && SUDO_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)" \
     && [[ -n "$SUDO_HOME" ]]; then
  WORK_DIR="$SUDO_HOME/klburn-build"
else
  WORK_DIR="$HOME/klburn-build"
fi

# ---------- apt 镜像（构建期用，影响装包速度）----------
APT_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu/"

# ---------- 时区 ----------
# 现场无网络，时间只能取自 BIOS 的 RTC。服务器 RTC 一般走 UTC，
# 不设时区的话报告目录名和时间戳会比北京时间早 8 小时，和现场对不上。
TIMEZONE="Asia/Shanghai"

# ---------- GPU 组件开关 ----------
# 完整的盘是带 NVIDIA 驱动 + gpu_burn 的，所以这里**默认自动检测**：
# vendor/nvidia/ 下放了驱动就带上，没放就出一张不含显卡驱动的盘。
#
# 想手工指定：
#   sudo ./build/build-iso.sh --with-nvidia      强制带（缺驱动会直接报错，不会静默出一张残盘）
#   sudo ./build/build-iso.sh --without-nvidia   强制不带
#
# ⚠️ 这个判断在 chroot 里也会被 source 一次，而 chroot 里没有 vendor/ 目录。
# 所以 build-iso.sh 会在传进 chroot 的那份 config.sh 末尾追加一行确定的
# INCLUDE_NVIDIA=...，覆盖这里的自动检测结果。别把这里写成会在 chroot 里
# 算出不同答案的形式。
if [[ -z "${INCLUDE_NVIDIA:-}" ]]; then
  if compgen -G "$(dirname "${BASH_SOURCE[0]}")/../vendor/nvidia/NVIDIA-Linux-x86_64-*.run" >/dev/null 2>&1; then
    INCLUDE_NVIDIA=1
  else
    INCLUDE_NVIDIA=0
  fi
fi

# ---------- 用哪个内核 ----------
# generic = 24.04 的 GA 内核（6.8），源 ISO 自带的那个，一直用到 1.6.0
# hwe     = 24.04 的 HWE 内核（linux-generic-hwe-24.04），对**新硬件**支持广得多：
#           新网卡、新 NVMe、新阵列卡、新平台的 PCIe / EDAC
#
#     KLBURN_KERNEL=hwe sudo -E ./build/build-iso.sh
#
# ⚠️⚠️ **hwe 这条路 1.7.0 还没打通，默认必须留 generic。**
#
# 1.7.0 实际试了四轮，进展和卡点都很明确：
#
#   已经过了的关：
#     装 linux-generic-hwe-24.04（7.0.0-28-generic，6907 个模块，比 GA 多 428 个）
#     NVIDIA 595.84 能为 7.0 内核编出 open 模块（license = Dual MIT/GPL）
#     清理多余内核之后只剩新内核，和 casper/vmlinuz 对得上
#     check-firmware 36 项全绿（35 个固件在新内核下重新对账，一个不缺）
#     exfat / megaraid_sas / mpt3sas / nvme / mpi3mr / smartpqi 模块都在
#
#   卡在哪：**重新生成的 initrd 不是 casper 的 live initrd。**
#     直接 update-initramfs 出来的是个普通 initrd，开机停在
#         No root device specified. Boot arguments must include a root= parameter.
#         BusyBox ... (initramfs)
#     报告一个字都写不出来（e2e 冒烟实测，截图在手）。
#     已经查明两件事：casper 包和 linux-firmware 一样被镜像剪光了文件（要
#     --reinstall 装回来，已做）；装回来之后 initramfs-tools 仍然不带它的 boot
#     脚本，因为 initramfs.conf 里 BOOT=local，要改成 BOOT=casper 才会带。
#     **下一步就是从这里接着走**，但还没验，也可能后面还有别的 live 集成细节。
#
#   chroot-setup.sh 里有一条自检（生成完检查 initrd 里有没有 casper 的 boot 脚本），
#   所以现在最坏的结果是**构建停下**，不会做出一张开不了机的盘。
#
# 换内核之后必须重新过的关，一关都不能少：
#   build-iso.sh 的内核唯一性 + 与 casper/vmlinuz 对版本          [已过]
#   tests/check-firmware.sh（驱动要的固件文件名会随内核版本变）    [已过]
#   exfat / megaraid_sas / mpt3sas / nvme 模块自检                 [已过]
#   e2e 冒烟 BIOS 和 UEFI **都要**（引导链完全不同）               [没过：停在 initramfs]
#   e2e --stage full --disk-stress 完整跑一遍                      [没跑到]
KLBURN_KERNEL="${KLBURN_KERNEL:-generic}"
HWE_KERNEL_PKG="linux-generic-hwe-24.04"

# ---------- squashfs 层裁剪 ----------
# 24.04.4 的 live server ISO 有 5 层 squashfs，依赖链靠文件名里的点表示
# （下面是压缩后的体积，解开约 3~4 倍）：
#   ubuntu-server-minimal.squashfs                          159M  基础系统
#   ...ubuntu-server.squashfs                               142M  server 软件集
#   ...installer.squashfs                                   671M  subiquity 安装器  <- 丢
#   ...installer.generic.squashfs                           256M  内核 + 驱动模块 + firmware  <- 必须留！
#   ...installer.generic-hwe.squashfs                       267M  第二套 HWE 内核    <- 丢
# 注意：内核模块（exfat / megaraid_sas / mpt3sas ...）全在 installer.generic 层，
# 丢掉它会得到一个没有任何驱动的系统。
LAYER_EXCLUDE_PATTERNS=(
  '*.installer.squashfs'      # subiquity 安装器
  '*generic-hwe*'             # HWE 内核（我们只用 generic）
)

# ---------- squashfs 压缩 ----------
SQUASHFS_COMP="zstd"
SQUASHFS_LEVEL="19"

# ---------- 固件剪裁 ----------
# live-server 镜像把 linux-firmware 的文件剪光了（dpkg 说装了 611MB，磁盘上只剩
# 118MB / 140 个文件），chroot-setup.sh 会 `--reinstall linux-firmware` 装回来。
# 装回来是 616MB，整包带上去太亏，所以按这张表剪。
#
# **这是黑名单不是白名单**，而且必须一直是黑名单：漏掉一条只是多占点地方，
# 而白名单漏掉一条就是"某张网卡的驱动起不来 -> 报告上说这台机器没网卡"。
# 每一条都写清楚为什么服务器上用不到；拿不准的一律留着。
#
# 剪完的验收在 tests/check-firmware.sh：它拿 modinfo 问驱动自己要什么固件，
# 再逐个去盘里找。剪多了那边会当场跑红。
#
# 路径相对 /lib/firmware，支持 glob。
FIRMWARE_PRUNE=(
  # --- 显卡：我们只跑 NVIDIA，而 NVIDIA 的固件是驱动自己带的 ---
  'nvidia/[a-z]*'   # 107MB，nouveau 用的 GSP 固件，按芯片代号分目录（ad102/ga100/gb202…）。
                    # 内核参数里 nouveau 是 blacklist 的，这些一个都用不上。
                    # ⚠️ 写成 `nvidia` 会把 NVIDIA 驱动自己铺的 nvidia/595.84/ 一起删掉 ——
                    #    那是 open 内核模块必须的 GSP 固件，删了 nvidia.ko 直接加载失败，
                    #    然后被判成"显卡故障"。用 [a-z] 开头卡死：驱动那份是版本号，数字开头。
  # ⚠️ amdgpu（28MB）和 radeon（1.9MB）**1.7.0 起不再剪**。
  #    1.5.0 把它们剪掉是按"控体积优先"定的，代价是：装了 AMD 独显的机器上
  #    内核模块还在、固件没了 -> 显示驱动起不来 -> 屏幕点不亮 / 认不到显卡。
  #    这一版取向反过来（兼容性优先、体积次要），所以加回来，
  #    并且把 amdgpu 加进 check-firmware.sh 的驱动清单，以后自动受守。
  'xe'              # Intel Arc 独显，服务器上没有
  # --- 无线 / 蓝牙：服务器没有，也不参与任何判定 ---
  'mrvl'            # 79MB，Marvell wifi/蓝牙
  'qcom'            # 61MB，高通 SoC
  'ath10k' 'ath11k' 'ath12k' 'ath' 'ath6k' 'ath9k_htc' 'ar3k' 'qca'
  'mediatek' 'brcm' 'cypress' 'libertas' 'rsi' 'rtlwifi' 'rtw88' 'rtw89'
  'rtl_bt' 'ti-connectivity' 'wfx' 'cw1200' 'ueagle-atm'
  'iwlwifi-*'       # ~150MB，Intel 无线网卡固件，散在顶层
  'iwlmvm*' 'iwlax*'
  # --- 嵌入式 SoC / 手机平台 ---
  'dpaa2'           # NXP LS 系列 SoC
  # --- 声卡 ---
  'cirrus' 'asihpi'
  # --- 交换机 ASIC ---
  'mellanox'        # 79MB，全是 mlxsw_spectrum-*.mfa2 和 lc_ini_bundle_*，
                    # 那是 Mellanox **交换机**芯片跑 Linux 时刷的固件，被测服务器上没有。
                    # 迈络思**网卡**（mlx5_core/mlx4_core）固件烧在卡上 flash 里，
                    # modinfo 报 0 个固件依赖 —— check-firmware.sh 每次构建都复核这一条，
                    # 哪天它开始要固件了，那边会当场跑红。
)
# ⚠️ 有几个名字长得像该剪、其实**必须留**，别手滑：
#   rtl_nic      Realtek r8169 有线网卡固件（rtl_bt 才是蓝牙）
#   intel        里面有 intel/ice/ddp/ice.pkg —— E810 缺它会降级进 safe mode
#   i915         Xeon 一般没核显，但边缘机型有；缺固件顶多丢电源管理，
#                留着 9.7MB 换"屏幕一定点得亮"

# ---------- 预装软件包 ----------
# 采集类
PKGS_COLLECT=(
  dmidecode lshw pciutils usbutils nvme-cli smartmontools ipmitool
  ethtool jq python3 hdparm sdparm lsscsi lm-sensors numactl
  efibootmgr kmod util-linux bc gawk
  # decode-dimms：直接读**内存条自己的 SPD 芯片**，拿到 dmidecode 给不了的
  # 那几样 —— 生产地点、颗粒厂商、以及厂商专属数据区。
  #
  # 为什么要它：客户报告里的内存序列号只有 8 位十六进制（JEDEC 规定这一格
  # 就是 4 字节，没被截断），而内存条标签上印的是十几位的生产追溯号。
  # 长号如果有电子记录，只可能在专属区里 —— 那片字节只有读 SPD 原片才拿得到。
  #
  # ⚠️ 我们**只读，绝不写**，而且绝不做 i2cdetect 盲扫：服务器的 SMBus 上
  #    还挂着 BMC、风扇控制器、背板，盲扫能把机器扫挂。只读内核驱动
  #    （ee1004 / at24 / spd5118）已经建好的那些 eeprom 节点。
  #    读不到一律 SKIP —— 很多服务器平台的 SMBus 归 BMC 管，主机侧本来就读不到。
  i2c-tools
  # ↓ 基础镜像里本来就有，但**显式列出来** = 手动安装标记 = autoremove 不会碰。
  #   清理多余内核那步的 autoremove 射程比想象中远（1.5.0 第一次就顺手带走了
  #   amd64-microcode），而这几个是采集要用的。
  sg3-utils fwupd
)

# ---------- 深度诊断类（1.7.0 新增）----------
# 每一个都写清楚它换来什么数据。都在 Ubuntu 24.04 的官方源里
# （多数在 universe，chroot-setup.sh 已经启用），不需要任何闭源二进制。
#
# ⚠️ 这几个包装进来是为了**那几条命令**，不是为了它们带的 daemon。
#    chroot-setup.sh 会把对应的 service 一律 mask 掉，理由和 smartd 一样：
#    压测期间不能有别的东西在后台动硬件、抢 IO、往日志里插东西。
PKGS_DIAG=(
  # ras-mc-ctl --error-count：**逐条 DIMM 的 ECC 可纠正/不可纠正错误计数**。
  # 出厂老化最该抓的就是内存的早期退化，而在这之前我们只能扫 dmesg 关键字 ——
  # 那既不结构化、也归不到具体是哪一条内存上。
  # --error-count 读的是内核的 EDAC sysfs，**不需要 rasdaemon 在跑**。
  rasdaemon
  # edac-util -v：EDAC 的另一条路。和上面互为备份，不同平台上可用性不一样
  #（有的机型 ras-mc-ctl 读得到、edac-util 读不到，反过来也有）。
  edac-utils
  # 迈络思网卡的固件版本 / PSID / PXE 版本。这类卡在服务器上很常见，
  # 而 ethtool -i 在 mlx5 上给的固件版本串信息量很少。
  mstflint
  # CPU 特性位、步进、勘误相关标志 —— lscpu 给不全。
  cpuid
  # rdmsr：读功耗/温度/降频寄存器，补 turbostat 够不到的平台。
  msr-tools
  # lldpctl：这个网口接在**哪台交换机的哪个口**。现场排线错误一眼就看出来。
  # LLDP 邻居要有 daemon 在收才有，所以采集阶段会临时把 lldpd 拉起来，
  # 但**只用接收模式**：绝不往客户的交换机上发我们自己的通告。
  lldpd
  # fwts：固件（BIOS / UEFI / ACPI）自检。Canonical 的 Ubuntu 服务器认证就是
  # 拿它做固件那一段，UEFI Forum 也把它列为 ACPI 自认证工具。
  #
  # ⚠️ **它的结果只进内部报告，不进客户报告**（见 lib/collect.sh 的 collect_fwts）。
  #    出厂机器的 BIOS 是刚刷的，而 ACPI 表上的告警在**完全正常**的服务器上
  #    极其常见 —— 印给客户就是白白让人去找机器的毛病，正是我们那几条
  #    措辞红线要挡的东西。我们自己留着，用来回答"这批板子的 BIOS 有没有共性问题"。
  fwts
)
# 网卡连通性测试 + 联网校时用
# 24.04 的 live server 层里没有 dhclient，必须显式装；
# iputils-ping / iproute2 基础层里有，列出来是为了万一换基础镜像也不会缺；
# chrony 给 sync_clock_now() 用一次性模式（chronyd -q）联网校时，
# 不装 ntpdate——Ubuntu 早就把它从源里拿掉了，写进包列表会导致整个装包失败。
PKGS_NET=(
  isc-dhcp-client iputils-ping iproute2 chrony
)
# 压测类
PKGS_STRESS=(
  stress-ng stressapptest fio sysbench
  # CPU 浮点算力那一项要的 BLAS 运行库（vendor/bench/cpuflops/klburn_flops
  # 动态链它，见 build/build-cpuflops.sh）。
  #
  # ⚠️ **删了它这一项就永远 SKIP**，而且现场看不出原因 —— 程序在，只是
  #    一跑就是 "error while loading shared libraries"，那行报错落进日志里
  #    看着像"这台机器有问题"。tests/check-firmware.sh 之外没人守着它，
  #    改这一行之前先想清楚。
  #
  # 为什么是 -pthread 那个变体：Ubuntu 把 libopenblas 拆成 pthread / openmp /
  # serial 三个包，三个都 provide libopenblas.so.0。显式钉一个，免得依赖
  # 解析在不同时期挑中不同的那个（openmp 那版会和 stress-ng 抢线程）。
  # 它会把 libgfortran5 一起带进来，那是 OpenBLAS 自己的依赖。
  libopenblas0-pthread
)
# 报告落盘 / 杂项
PKGS_MISC=(
  exfatprogs dosfstools ntfs-3g xz-utils zstd pciutils
  # memtest86+（GPLv2，不是 PassMark 那个商业版）。装它是为了拿到那个可引导的
  # 二进制，构建时会把它拷到 ISO 的 /boot/ 下、并在 GRUB 里挂一个菜单项。
  #
  # 为什么需要它：`stressapptest` 跑在操作系统里，只能测到**系统可见内存减去
  # 安全余量**那一部分 —— 真机报告上写的是"占系统识别内存的 81%~95%"，
  # 也就是说另外那 5%~19% 从来没被测过；而且它做不了 memtest 那种
  # 地址线 / 位模式测试。memtest86+ 裸机跑，覆盖几乎全部内存。
  #
  # ⚠️ 它**不是**无人值守流程的一部分：跑完只在屏幕上显示，不落结果文件，
  #    所以进不了报告。它是"操作员另选的第二种跑法"，写在真机清单里。
  memtest86+
)
# ---------- 报告转 PDF（1.8.0 新增）----------
# 客户拿 HTML 转发不方便（一个 456KB 的单文件，微信/邮件里点开还得挑浏览器），
# PDF 归档和转发都省事。两份报告各出一份 PDF，和 .html 放同一个目录。
#
# 为什么是 weasyprint 而不是别的：
#   wkhtmltopdf   底层是老 QtWebKit，**不认 CSS 变量**，而报告里 var(--xxx)
#                 用了 19 处，整份配色会塌掉
#   chromium      24.04 上是 snap 包，塞进 live 系统不现实
#   weasyprint    官方源里就有（61.1），纯 Python + cairo/pango，无头无依赖服务
#
# 实测：456KB 的报告 -> 122 页 A4，9 秒，表格/曲线图/中文都正常。
# 已知它会忽略 display:grid（键值块退化成逐行，可读性不受影响）。
#
# 字体必须显式带一个中文字体，否则 PDF 里所有中文是空白框 ——
# live 系统本身不带任何 CJK 字体（HTML 报告是在客户自己的 Windows 上看的，
# 用的是客户机器上的字体，所以以前不需要）。
# 选微米黑（5MB）而不是 Noto CJK（89MB）：两个都试过，出来的页面肉眼没差别，
# 微米黑那版 PDF 反而更小（317KB vs 728KB）。
PKGS_REPORT=(
  weasyprint fonts-wqy-microhei
)
# CPU 微码 / 平台守护进程
#
# 这几个本来是 `linux-image-generic` 的 Recommends，带的是**自动安装**标记。
# chroot-setup.sh 会 purge 掉那个元包（它是多余内核的来源），紧接着的
# autoremove 就把它们一起带走了 —— 1.5.0 第一次构建就这么把 amd64-microcode
# 弄丢了，是 tests/check-firmware.sh 那条微码断言逮住的。
# 显式列在这里 = 手动安装标记 = autoremove 不会碰。
#
#   amd64-microcode / intel-microcode
#       CPU 微码。缺了的话，本该被微码修掉的勘误会在压测里冒出来，
#       然后被记成"这台机器不稳定"—— 又是一次把好机器拦在出货前。
#   thermald
#       1.4.2 及以前的盘里一直有它。它在服务器上到底管不管用是另一回事，
#       但"同一台机器换张盘测出来的温度/性能不一样"这种变化不能悄悄发生。
PKGS_PLATFORM=(
  amd64-microcode intel-microcode thermald
)

# 编译 NVIDIA 内核模块需要的包（INCLUDE_NVIDIA=1 时才装，装完就删）
PKGS_NVIDIA_BUILD=(
  build-essential dkms libglvnd-dev pkg-config
)

# ---------- 内存专用盘的压测时长（秒）----------
# 只对 KLBURN_EDITION=mem 有意义。这张盘的定位是"插上去两三分钟，
# 把内存的 SN / 型号读出来、顺手验一遍这条内存还能不能用"，
# 所以默认给 150 秒（连采集和出报告，整轮约 3 分钟）。
# **现场没有时长菜单** —— 开机就按这个值开跑，不问任何人。
#
# ⚠️ **两分钟压不出"内存能长期稳定工作"这个结论，它压的是"现在有没有明显坏"。**
#    真要筛一批可疑内存，把这个值加大（比如 1800 = 半小时）再出一张盘；
#    报告里会如实写出本次压了多久，不会拿两分钟的结果去冒充老化测试。
#
#     KLBURN_MEM_BURN_SECONDS=600 sudo -E ./build/build-iso.sh --edition mem
MEM_BURN_SECONDS="${KLBURN_MEM_BURN_SECONDS:-150}"

# ---------- 输出 ----------
# 内存盘的文件名必须一眼区分得开 —— 两张盘长得一样、跑起来完全不是一回事。
if [[ "$KLBURN_EDITION" == "mem" ]]; then
  OUT_ISO_NAME="KLBurn-MEM-${KLBURN_VERSION}-$(date +%Y%m%d).iso"
else
  OUT_ISO_NAME="KLBurn-${KLBURN_VERSION}-$(date +%Y%m%d).iso"
fi
