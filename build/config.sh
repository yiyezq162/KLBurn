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
KLBURN_VERSION="1.4.2"

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

# 报告大标题（客户报告和内部报告共用这一个主标题）
REPORT_TITLE="${KLBURN_REPORT_TITLE:-服务器出厂老化测试报告}"

# 产品名：开机 banner、GRUB 菜单项、.disk/info 用它。
# 只能是 ASCII —— 这三个地方都在文本控制台/引导器里，中文显示不出来。
PRODUCT_NAME="${KLBURN_PRODUCT_NAME:-KLBurn}"

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

# ---------- 预装软件包 ----------
# 采集类
PKGS_COLLECT=(
  dmidecode lshw pciutils usbutils nvme-cli smartmontools ipmitool
  ethtool jq python3 hdparm sdparm lsscsi lm-sensors numactl
  efibootmgr kmod util-linux bc gawk
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
)
# 报告落盘 / 杂项
PKGS_MISC=(
  exfatprogs dosfstools ntfs-3g xz-utils zstd pciutils
)

# 编译 NVIDIA 内核模块需要的包（INCLUDE_NVIDIA=1 时才装，装完就删）
PKGS_NVIDIA_BUILD=(
  build-essential dkms libglvnd-dev pkg-config
)

# ---------- 输出 ----------
OUT_ISO_NAME="KLBurn-${KLBURN_VERSION}-$(date +%Y%m%d).iso"
