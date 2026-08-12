#!/usr/bin/env bash
#
# 在 chroot 内执行的定制脚本。由 build-iso.sh 调用，不要手动跑。
# 依赖 /tmp/klburn-stage/{config.sh,overlay/,vendor/}
#
set -Eeuo pipefail

STAGE="/tmp/klburn-stage"
# shellcheck source=config.sh
source "$STAGE/config.sh"

say()  { printf '    [chroot] %s\n' "$*"; }
fail() { printf '    [chroot] ERROR %s\n' "$*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
export LANG=C LC_ALL=C

# ---------------------------------------------------------------- apt 源
say "配置 apt 源（启用 universe，走 $APT_MIRROR）"

SRC_LIST="/etc/apt/sources.list.d/ubuntu.sources"
BAK_LIST="/etc/apt/sources.list.d/ubuntu.sources.klburn-bak"
if [[ -f "$SRC_LIST" && ! -f "$BAK_LIST" ]]; then
  cp -a "$SRC_LIST" "$BAK_LIST"
fi

cat > "$SRC_LIST" <<EOF
Types: deb
URIs: ${APT_MIRROR}
Suites: noble noble-updates noble-backports noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
# 旧式 sources.list 若存在会和上面重复，清空它
[[ -f /etc/apt/sources.list ]] && : > /etc/apt/sources.list

say "apt-get update"
apt-get update -qq || fail "apt update 失败（检查 WSL 网络 / 镜像地址）"

# ---------------------------------------------------------------- 装包
PKGS=( "${PKGS_COLLECT[@]}" "${PKGS_DIAG[@]}" "${PKGS_NET[@]}" "${PKGS_STRESS[@]}"
       "${PKGS_MISC[@]}" "${PKGS_REPORT[@]}" "${PKGS_PLATFORM[@]}" )
if [[ "${INCLUDE_NVIDIA:-0}" == "1" ]]; then
  PKGS+=( "${PKGS_NVIDIA_BUILD[@]}" )
fi

say "安装 ${#PKGS[@]} 个包..."
apt-get install -y -qq --no-install-recommends "${PKGS[@]}" \
  || fail "装包失败"

# 逐个确认关键工具真的到位了（apt 返回成功不代表命令存在）。
#
# 这一段后面还要**再跑一遍**：清理多余内核那步会 purge 元包 + autoremove，
# 而 autoremove 的射程比想象中远（第一次跑就顺手带走了 amd64-microcode）。
# 只在装完时查一次的话，"装上了、后来又被 autoremove 收走"这条路完全没人看着。
verify_tools() {
  local when="$1" entry missing=()
  for entry in dmidecode lshw lspci nvme smartctl ipmitool ethtool jq python3 \
               stress-ng stressapptest fio sysbench dhclient ping ip chronyd \
               sg_ses sg_logs sg_vpd fwupdmgr \
               ras-mc-ctl edac-util mstflint cpuid rdmsr lldpctl lldpd; do
    command -v "$entry" >/dev/null 2>&1 || missing+=("$entry")
  done
  if ((${#missing[@]})); then
    fail "$when：以下工具不存在: ${missing[*]}"
  fi
  say "关键工具检查通过（$when）"
}
verify_tools "装包后"

# ---------------------------------------------------------------- 目标内核
# 盘上真正会被引导的是 casper/vmlinuz 里那个内核。版本由 build-iso.sh 从 bzImage
# 头部读出来、追加进暂存的 config.sh 传进来。
#
# **绝不能在这里用 `ls -1 /lib/modules | head -1` 猜。** 那是按字典序取第一个，
# 而 chroot 里此刻常常有两个内核（装 dkms 会连带把 linux-image-generic 元包
# 指向的那套新内核拉进来）。猜错的两种后果都很难查：
#   - 给不会被引导的那个内核编 NVIDIA 模块 -> 开机 nvidia.ko 加载失败 -> 判"显卡故障"
#   - 把要用的那套模块当多余的删掉         -> 开机认不到任何硬盘 -> 判"硬盘故障"
# 两样都会被记成硬件问题，而机器其实是好的。
KVER="${ISO_KVER:-}"
[[ -n "$KVER" ]] \
  || fail "ISO_KVER 没传进来。build-iso.sh 要在暂存的 config.sh 末尾追加它。"
[[ -d "/lib/modules/$KVER" ]] \
  || fail "ISO_KVER=$KVER 在 /lib/modules 下不存在，现有: $(ls -1 /lib/modules | tr '\n' ' ')"
say "目标内核（casper/vmlinuz 引导的那个）: $KVER"

# ---------------------------------------------------------------- 可选：换 HWE 内核
# 24.04 的 HWE 内核对**新硬件**支持广得多（新网卡、新 NVMe、新阵列卡、
# 新平台的 PCIe / EDAC）。默认不开，见 config.sh 里 KLBURN_KERNEL 那段。
#
# 换法是"装上新的、把旧的清掉"，**不是"留两个"** —— 盘里只能有一个内核这条
# 不变量不放松（两套内核意味着"开机会加载哪一套"不确定，而搞反的表现是
# 开机认不到任何硬盘）。下面「清理多余内核」那一段照常会把 GA 那套 purge 掉，
# 因为这里已经把 $KVER 改成新内核了。
if [[ "${KLBURN_KERNEL:-generic}" == "hwe" ]]; then
  say "=== 换 HWE 内核（KLBURN_KERNEL=hwe）==="
  GA_KVER="$KVER"
  apt-get install -y -qq --no-install-recommends "${HWE_KERNEL_PKG:?}" \
    || fail "装 ${HWE_KERNEL_PKG} 失败"

  # 新内核 = /lib/modules 下不是 GA 那个的、版本号最大的那个。
  # 用 glob 不用 `ls | grep`（shellcheck SC2010，而且内核版本号里带点和减号，
  # 交给 ls 解析本来就没必要）。
  KCANDS=()
  for kd in /lib/modules/*/; do
    kb="$(basename "$kd")"
    [[ "$kb" == "$GA_KVER" ]] && continue
    [[ -d "$kd" ]] && KCANDS+=("$kb")
  done
  NEW_KVER=""
  if ((${#KCANDS[@]})); then
    NEW_KVER="$(printf '%s\n' "${KCANDS[@]}" | sort -V | tail -1)"
  fi
  [[ -n "$NEW_KVER" ]] \
    || fail "装完 ${HWE_KERNEL_PKG} 之后 /lib/modules 下没有出现新内核，
     现有: $(printf '%s ' /lib/modules/*/)"
  [[ -d "/lib/modules/$NEW_KVER" ]] || fail "新内核目录 /lib/modules/$NEW_KVER 不存在"
  KVER="$NEW_KVER"
  say "HWE 内核: $KVER（原 GA 内核 $GA_KVER 会在「清理多余内核」那步被清掉）"
fi

# exfat 内核模块必须在（报告要写进 U 盘的 exFAT 分区）
if find "/lib/modules/$KVER" -name 'exfat.ko*' | grep -q .; then
  say "exfat 内核模块 OK ($KVER)"
else
  say "WARN: 没找到 exfat.ko，报告可能无法写入 U 盘数据分区"
fi

# ---------------------------------------------------------------- 网卡固件
# Ubuntu 的 live-server 镜像把 linux-firmware 的**文件**剪掉了（dpkg 里它还是
# "install ok installed"，连 .list 都被删了，所以看包管理器完全看不出来），
# 磁盘上只剩 amd / amd-ucode / intel-ucode / regulatory.db 这么几样。
#
# 后果不是"少个功能"，是**报告说谎**：bnx2x（Broadcom 10G，Dell R6x0 / HP Gen8-9
# 上到处都是）必须先加载固件才能起来，固件不在 -> 驱动起不来 -> `ip link` 里
# 一个物理口都看不到 -> collect_nic 判 WARN「无物理口」。
# 一台有 4 个网口的机器，报告上写着它没网卡。
# 而且全程没有任何报错，只在 dmesg 里留一行 "Direct firmware load ... failed"。
#
# 同样受影响的还有 qla2xxx / bfa（FC HBA）、cxgb4、nfp、tg3，
# 以及 ice（Intel E810，缺 DDP 包会降级进 safe mode）。
say "=== 装回 linux-firmware ==="
say "现状: $(du -sh /lib/firmware 2>/dev/null | cut -f1) / $(find /lib/firmware -type f 2>/dev/null | wc -l) 个文件"
apt-get install -y -qq --reinstall linux-firmware || fail "装 linux-firmware 失败"
say "装回后: $(du -sh /lib/firmware | cut -f1) / $(find /lib/firmware -type f -o -type l | wc -l) 个文件"

# 整包 600MB 全带上太亏，按 config.sh 的 FIRMWARE_PRUNE 剪。
# 那是**黑名单**（漏一条只是多占地方），不是白名单（漏一条就是少一块网卡）。
say "剪裁前各顶层目录（KB）:"
du -sk /lib/firmware/* 2>/dev/null | sort -rn | head -12 | sed 's/^/      /'
fw_pruned=0
for pat in "${FIRMWARE_PRUNE[@]}"; do
  # 这是以 root 跑的 rm -rf，模式本身先卡一道：空串会展开成 /lib/firmware/，
  # 绝对路径和 .. 能跑出这个目录。任何一条不对就停下，不要"尽力而为"。
  [[ -n "$pat" && "$pat" != /* && "$pat" != *".."* ]] \
    || fail "FIRMWARE_PRUNE 里有危险的模式: [$pat]"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    rm -rf -- "$p"
    fw_pruned=$(( fw_pruned + 1 ))
  done < <(compgen -G "/lib/firmware/$pat" || true)
done
say "剪掉 $fw_pruned 项，剩 $(du -sh /lib/firmware | cut -f1) / $(find /lib/firmware -type f -o -type l | wc -l) 个文件"

# ---------------------------------------------------------------- PCI / USB ID 库
# noble 的 pciutils 里那份 pci.ids 停在 2024-03-31，两年前的库认不出新硬件：
# H200 / RTX 50xx / ConnectX-8 / 新阵列卡在 lspci 里只会显示成 "Device 2335"。
# 而"这台机器装了什么卡"是报告的核心信息之一 —— 网卡型号（nic_pci_model）和
# 阵列卡型号（collect_raid）都是按总线地址从 lspci 反查的，库旧了整条链就断了。
#
# 新版由 build-iso.sh 在外面下载好放进 $STAGE/ids/（那边失败一律降级、不中断构建），
# 这里只管装。没送进来就沿用镜像自带的那份。
#
# /usr/share/hwdata/pci.ids 是指向 misc/ 那份的符号链接（hwdata 包铺的），
# 覆盖 misc/ 那一份两边就都是新的。
say "=== 更新 PCI / USB ID 库 ==="
for ids in pci.ids usb.ids; do
  src="$STAGE/ids/$ids"
  dst="/usr/share/misc/$ids"
  if [[ -s "$src" ]]; then
    old="$(awk -F'Date:[[:space:]]*' '/^#[[:space:]]*Date:/{print $2; exit}' "$dst" 2>/dev/null || true)"
    install -m 0644 "$src" "$dst"
    new="$(awk -F'Date:[[:space:]]*' '/^#[[:space:]]*Date:/{print $2; exit}' "$dst" 2>/dev/null || true)"
    say "$ids: ${old:-未知} -> ${new:-未知}"
  else
    say "WARN: 没有送进来新的 $ids，沿用镜像自带的那份（新硬件的型号可能认不出来）"
  fi
done

# smartmontools 的 drivedb 同理：新盘型号的 SMART 属性名要靠它解释，
# 库旧了属性会显示成 "Unknown_Attribute"。和 pci.ids 一个道理。
# 它自带 --update 子命令，**失败绝不能中断构建**（现场可能没有外网）。
if command -v update-smart-drivedb >/dev/null 2>&1; then
  if update-smart-drivedb >/dev/null 2>&1; then
    say "smartmontools drivedb 已更新"
  else
    say "WARN: drivedb 更新失败（无外网？），沿用包里自带的那份"
  fi
fi

# ---------------------------------------------------------------- 瘦身 & 关掉碍事的服务
say "移除 snapd / 关闭 cloud-init"
apt-get purge -y -qq snapd >/dev/null 2>&1 || true
rm -rf /var/lib/snapd /snap /root/snap 2>/dev/null || true

mkdir -p /etc/cloud
touch /etc/cloud/cloud-init.disabled

for u in snapd.service snapd.socket snapd.seeded.service \
         systemd-networkd-wait-online.service \
         unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer \
         apt-news.service esm-cache.service \
         cloud-init.service cloud-init-local.service cloud-config.service cloud-final.service \
         smartd.service smartmontools.service \
         nvmefc-boot-connections.service nvmf-autoconnect.service \
         chrony.service systemd-timesyncd.service \
         rasdaemon.service lldpd.service lldpd.socket \
         fwupd.service fwupd-refresh.service fwupd-refresh.timer; do
  systemctl mask "$u" >/dev/null 2>&1 || true
done
# 说明：smartd 装 smartmontools 时会被自动 enable。它后台定期轮询硬盘，
# 会和 fio 的裸盘压测抢 IO、也可能在日志里插入干扰信息，所以关掉。
# 我们自己在测前测后各显式跑一次 smartctl 就够了。
#
# 1.7.0 新装的几个包同理 —— 装它们是为了那几条**命令**，不是为了 daemon：
#   rasdaemon  ras-mc-ctl --error-count 读的是内核的 EDAC sysfs，不需要它在跑
#   lldpd      LLDP 邻居确实要 daemon 在收才有，但只在采集阶段临时拉起、
#              而且只用接收模式（见 lib/network.sh），绝不常驻
#   fwupd      我们只用 `fwupdmgr get-devices` 读一次固件版本清单；
#              它的 refresh timer 会去联网拉厂商元数据，现场没网只会白等超时

# tty1 归 KLBurn 独占
systemctl mask getty@tty1.service >/dev/null 2>&1 || true
systemctl set-default multi-user.target >/dev/null 2>&1 || true

# casper 里的 live 用户不需要走首次登录向导
rm -f /etc/systemd/system/multi-user.target.wants/console-setup.service 2>/dev/null || true

# ---------------------------------------------------------------- 铺 overlay
say "安装 KLBurn 到 /opt/klburn"
# 先整个清掉再铺。增量构建会复用上一轮的 rootfs，只 cp 覆盖的话，
# 上一版里有、这一版已经删掉/改名的文件会永远残留在镜像里
# （轻则塞垃圾，重则残留的旧 lib 被 source 到）。
rm -rf /opt/klburn
cp -a "$STAGE/overlay/." /

mkdir -p /opt/klburn/tools
find /opt/klburn -type f -name '*.sh' -exec chmod 0755 {} +
find /opt/klburn -type f -name '*.py' -exec chmod 0755 {} +
chmod 0755 /opt/klburn/factory-test.sh
chmod 0755 /opt/klburn/memtest.sh

# ---------------------------------------------------------------- 开机拉起哪个脚本
# 这是 full 盘和 mem 盘**唯一**的行为差别：换掉 klburn.service 的 ExecStart。
#
# ⚠️ 改完必须当场核一遍改成功了没有。sed 没匹配上是**静默**的 ——
#    做出来的会是一张文件名写着 MEM、开机却跑整机全测流程（还会弹范围菜单）
#    的盘，而构建日志里一个字的异常都没有。
KLB_MAIN="/opt/klburn/factory-test.sh"
if [[ "${KLBURN_EDITION:-full}" == "mem" ]]; then
  KLB_MAIN="/opt/klburn/memtest.sh"
  sed -i \
    -e "s#^ExecStart=.*#ExecStart=${KLB_MAIN}#" \
    -e 's#^Description=.*#Description=KLBurn Memory-Only Test#' \
    /etc/systemd/system/klburn.service
fi
[[ -x "$KLB_MAIN" ]] || fail "开机要拉起的 $KLB_MAIN 不存在或不可执行"
grep -qx "ExecStart=$KLB_MAIN" /etc/systemd/system/klburn.service \
  || fail "klburn.service 的 ExecStart 不是 $KLB_MAIN —— 这张盘开机会跑错流程"

# 开机自动拉起测试主脚本
systemctl enable klburn.service >/dev/null 2>&1 \
  || fail "systemctl enable klburn.service 失败"
[[ -L /etc/systemd/system/multi-user.target.wants/klburn.service ]] \
  || fail "klburn.service 没有真正 enable 成功，做出来的盘开机不会自动跑测试"
say "klburn.service 已设为开机自启（ExecStart=$KLB_MAIN）"

# 构建期常量写进配置文件，运行时脚本读它。
# 抬头（公司名 / 报告标题 / 产品名）就是在这里钉死进盘里的 —— 现场不会再问任何人。
cat > /opt/klburn/klburn.conf <<EOF
# 由 build/chroot-setup.sh 在构建时生成，勿手改
KLBURN_VERSION="${KLBURN_VERSION}"
COMPANY_NAME="${COMPANY_NAME}"
REPORT_TITLE="${REPORT_TITLE:-服务器出厂老化测试报告}"
PRODUCT_NAME="${PRODUCT_NAME:-KLBurn}"
# 这张盘是整机全测盘（full）还是内存专用盘（mem）。运行时脚本和报告生成器
# 都读它 —— 报告抬头那句"本轮只测了内存"就是按它写的。
KLBURN_EDITION="${KLBURN_EDITION:-full}"
# 内存专用盘的压测时长（秒）。只有 mem 盘用得上；现场想改测多久，
# 改这一行重新出盘即可，不需要动代码。
MEM_BURN_SECONDS="${MEM_BURN_SECONDS:-150}"
BUILD_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
BASE_OS="Ubuntu Server ${UBUNTU_POINT}"
INCLUDE_NVIDIA="${INCLUDE_NVIDIA:-0}"
NVIDIA_VERSION="${NVIDIA_VERSION:-}"
# 源码的 git commit（由 build-iso.sh 追加进暂存的 config.sh 后传到这里）。
# 版本号靠人记得 bump，commit hash 是构建脚本自己取的，骗不了人。
GIT_COMMIT="${GIT_COMMIT:-unknown}"

# ================================================================
# 现场内网的 NTP 服务器（**这一行是留给你填的**）
# ================================================================
# ⚠️ 工厂里最常见的情况是"有内网、出不了公网"。1.9.7 现场那台 7542 就是：
#    网通着、ping 网关 4/4 通、0.525ms，但三个公网 NTP 全部拨不通，
#    报告日期停在一个八个月前的假日期上。
#
# 校时的候选源按"由近及远"依次试，拨通一个就收工：
#     ①这一行 -> ②DHCP 下发的 NTP(option 42) -> ③默认网关 -> ④公网那几个 -> ⑤BMC 时钟
#
# **③默认网关只是碰运气**：多数企业网关会应答 NTP，但这不是必然的
# （用户 2026-08-12 明确指出这一点）。所以把①放在最前面 ——
# 你们内网的 NTP 地址填在这里，现场就不用再赌网关。
#
# 空着不影响任何功能，只是少一条最快的路。可以填多个，空格分开。
KLB_NTP_SERVERS="${KLB_NTP_SERVERS:-}"

# ================================================================
# 性能基准的**测试参数**（不是合格线）
# ================================================================
# ⚠️ 这里**没有、也不会有"阈值 / 门槛 / 参考值 / 预期值"这类东西**。
#
# 这张盘是插上就跑、无人值守的：现场没有人、也没有地方去填"这台机器的带宽
# 应该是多少"。凭空写一个数进来，等于我们替客户定了一个他没定过的标准，
# 再拿它去判一台机器合不合格 —— 那个数字从哪来的谁也说不清。
#
# **报告里只有实测值。**谁做验收，谁拿自己那份要求去对。
#
# 下面这几个是"怎么测"的参数（跑多久、用多大队列深度），不是"该达到多少"。
BENCH_LINPACK_RUNS="${BENCH_LINPACK_RUNS:-4}"
# 算力测试的矩阵规模。留空 = 按内存容量自动推算（上限 40000 阶，四次约一分钟）
BENCH_LINPACK_N="${BENCH_LINPACK_N:-}"
# 硬盘带宽的队列深度与每个方向跑多少秒。
# 32 / 128 是 SATA / NVMe 上通行的取法，不是某一家的要求。
BENCH_DISK_QD_SATA="${BENCH_DISK_QD_SATA:-32}"
BENCH_DISK_QD_NVME="${BENCH_DISK_QD_NVME:-128}"
BENCH_DISK_SECS="${BENCH_DISK_SECS:-20}"
# 单个基准程序的超时上限（秒）。**这两个也是"怎么测"的参数**，
# 写在这里是为了让它可见、可改 —— 不写的话现场只会看到某一项莫名其妙
# 判了 SKIP，没人知道是被超时掐掉的（1.9.0 就是被一个 1800 秒的超时
# 拖住整轮才发现的，见 architecture.md §11-44-3）。
#
# 算力那一项单独一档：它是几项里最重的（耗时按 N³ 涨），一台内存很大、
# 单核又慢的机器上 40000 阶跑四次是可能超过 600 秒的 —— 真遇上就在这里
# 调大，或者用 BENCH_LINPACK_N 把规模压小。
BENCH_TIMEOUT="${BENCH_TIMEOUT:-300}"
BENCH_LINPACK_TIMEOUT="${BENCH_LINPACK_TIMEOUT:-600}"

# ================================================================
# 部件专项验证（可选件，1.9.2）
# ================================================================
# 这两项和上面那几个基准**性质不一样**：基准只报数不判合格，而这两个工具
# 会明确说"这颗 CPU 算错了""这张卡的显存有问题"——那是真故障，会判 FAIL。
# 但它们仍然**不需要我们定任何数值**：结论是工具给的。
#
# 都是可选件：vendor/bench/ 里放了就带上，没放就干净地 SKIP。
VALIDATE_SDC_SECS="${VALIDATE_SDC_SECS:-120}"     # 处理器计算正确性诊断跑多久
VALIDATE_DCGM_LEVEL="${VALIDATE_DCGM_LEVEL:-2}"   # 显卡诊断档位：2=快速(约30秒) 3=更全(几分钟)
EOF

# ---------------------------------------------------------------- vendor: 阵列卡管理工具
# 内核驱动 in-tree 全都有，缺的是读**阵列卡自己**的固件版本和逻辑盘状态的闭源 CLI。
# 一家一个，谁也认不了别家的卡：
#
#   storcli/storcli64   Broadcom / LSI MegaRAID
#   perccli/perccli64   Dell PERC（storcli 换的皮，但版本对不上会认不到卡）
#   arcconf             Microchip / Adaptec（smartpqi、aacraid）
#   ssacli              HPE Smart Array
#   sas3ircu            LSI/Broadcom HBA 的非 RAID（IT）模式
#
# 每一项：<vendor 子目录>|<装进盘里的名字>|<在子目录里递归找的候选文件名(空格分隔)>
#
# 厂商发的往往是 zip 里套 rpm、解出来一层套一层的目录（Broadcom 的
# Unified_storcli_all_os/Linux/storcli64 就是），所以允许把整个解压结果原样丢进
# vendor/<子目录>/，这里自己往下递归找，省得每次出盘都手工翻目录捞文件。
#
# 一个都不放也**完全正常**：collect_raid 会判 SKIP（只报 PCI 反查到的型号），
# 绝不判 FAIL —— 那是我们这边少带工具，不是被测机器有问题。
#   arcconf（Microchip / Adaptec）**不备**：它按控制器系列分版本，手上没有对应的
#   卡就无从判断该下哪一个，备一个错版本还不如不备。真遇到 Adaptec 卡时，
#   在这张表和 lib/collect.sh 的 RAID_TOOL_ORDER 里各加一行就行。
VENDOR_RAID_TOOLS=(
  "storcli|storcli64|storcli64 storcli"
  "perccli|perccli64|perccli64 perccli"
  "ssacli|ssacli|ssacli"
  "sas3ircu|sas3ircu|sas3ircu"
)

raid_tools_found=0
for entry in "${VENDOR_RAID_TOOLS[@]}"; do
  IFS='|' read -r vdir vname vcands <<< "$entry"
  read -r -a cands <<< "$vcands"

  found=""
  for cand in "${cands[@]}"; do
    if [[ -f "$STAGE/vendor/$vdir/$cand" ]]; then found="$STAGE/vendor/$vdir/$cand"; break; fi
  done

  # 没在顶层，就往下递归找。
  # `|| true` 不是装饰：本脚本是 -o pipefail，find 在目录不存在时返回 1，
  # 一个失败的赋值型命令替换就能把整个 chroot 脚本静默弄死（§11-9）。
  if [[ -z "$found" && -d "$STAGE/vendor/$vdir" ]]; then
    findargs=()
    for cand in "${cands[@]}"; do
      ((${#findargs[@]})) && findargs+=(-o)
      findargs+=(-name "$cand")
    done
    found="$(find "$STAGE/vendor/$vdir" -type f \( "${findargs[@]}" \) 2>/dev/null | head -1 || true)"
  fi

  if [[ -n "$found" ]]; then
    install -m 0755 "$found" "/opt/klburn/tools/$vname"
    say "$vname 已安装（来自 vendor/${found#"$STAGE/vendor/"}）"
    raid_tools_found=$(( raid_tools_found + 1 ))

    # 动态链接的工具要自检依赖库在不在盘里。
    #
    # storcli64 / perccli64 / sas3ircu 都是静态链接，ssacli **不是**（要
    # libstdc++ / libgcc_s 等 7 个库）。而这张盘的 rootfs 是剪过的 ——
    # 缺一个库的表现是：现场跑起来什么都不输出，collect_raid 只看到
    # "这个工具认不了这张卡"，判 SKIP，**没有任何人会知道真正的原因**。
    # 所以在构建期就查死：用 readelf 读 NEEDED（**不执行**这个二进制），
    # 逐个去 ldconfig 的缓存里找。缺了直接让构建停下。
    #
    # ⚠️ readelf 没有的话**不能静默跳过** —— 那样这条自检就成了摆设，
    #    而摆设正是这个项目最恨的东西。宁可让构建停下。
    command -v readelf >/dev/null 2>&1 \
      || fail "chroot 里没有 readelf，无法自检 $vname 的依赖库（装 binutils）"

    needed="$(readelf -d "/opt/klburn/tools/$vname" 2>/dev/null \
              | sed -nE 's/.*NEEDED.*\[(.+)\]/\1/p' || true)"
    if [[ -n "$needed" ]]; then
      # 变量名别叫 missing —— 上面 need_cmds() 里 missing 是个数组局部变量，
      # 同名会让 shellcheck 报 SC2178（用作数组的变量又被赋成字符串）。
      # ⚠️ `ldconfig -p` 只跑**一次**，结果存下来再逐个比。
      #    原来是在循环里每个库跑一次（7 次），而 ldconfig 更新缓存是
      #    "写临时文件再 rename"，正好撞上那一瞬间就会读到空的一份 ——
      #    表现是随机一个库被判成"缺"、构建停下，而那个库明明就在盘里。
      #    实测撞到过一次（librt.so.1，同一份 rootfs 前两次构建都是好的）。
      #    读空了要当场说清楚是"没读到缓存"，不能顺势报成"库都缺了"。
      ldcache="$(ldconfig -p 2>/dev/null | awk 'NR>1{print $1}')"
      [[ -n "$ldcache" ]] \
        || fail "chroot 里读不到 ldconfig 缓存，没法自检 $vname 的依赖库"
      miss_libs=""
      while IFS= read -r lib; do
        [[ -n "$lib" ]] || continue
        # ⚠️ `ldconfig -p` 每行是 **TAB** 开头，不是空格：
        #       \tlibc.so.6 (libc6,x86-64) => /lib/x86_64-linux-gnu/libc.so.6
        #    第一版写的 `grep -qF " $lib "` 一个都匹配不上，于是**每个库都被判成缺**，
        #    构建当场停在这儿。取第一个字段再整词比，别再拿子串去猜。
        grep -qxF "$lib" <<< "$ldcache" || miss_libs="$miss_libs $lib"
      done <<< "$needed"
      if [[ -n "$miss_libs" ]]; then
        fail "$vname 是动态链接的，但盘里缺这些库：$miss_libs
       —— 现场表现是它什么都不输出、阵列卡那项静默判 SKIP，没人查得出原因。
       要么把对应的包加进装包列表，要么换一个静态链接的版本。"
      fi
      say "  $vname 动态链接，$(printf '%s\n' "$needed" | grep -c . || true) 个依赖库自检通过"
    fi
  fi
done
if (( raid_tools_found == 0 )); then
  say "vendor/ 下一个阵列卡管理工具都没有 -> 阵列卡只能报 PCI 型号（见 vendor/README.md）"
else
  say "阵列卡管理工具共装了 $raid_tools_found 个"
fi

# ---------------------------------------------------------------- vendor: logo
if [[ -n "${COMPANY_LOGO_FILE:-}" && -f "$STAGE/vendor/${COMPANY_LOGO_FILE}" ]]; then
  install -m 0644 "$STAGE/vendor/${COMPANY_LOGO_FILE}" /opt/klburn/report/logo.png
  say "报告 logo 已安装"
fi

# ---------------------------------------------------------------- NVIDIA 驱动 + gpu_burn
if [[ "${INCLUDE_NVIDIA:-0}" == "1" ]]; then
  say "=== 安装 NVIDIA 驱动与 gpu_burn ==="
  RUNFILE="$(ls -1 "$STAGE"/vendor/nvidia/NVIDIA-Linux-x86_64-*.run 2>/dev/null | head -1 || true)"
  [[ -n "$RUNFILE" ]] || fail "INCLUDE_NVIDIA=1 但 vendor/nvidia/ 下没有 .run 文件"

  say "为内核 $KVER 安装 headers"
  # --no-install-recommends：dkms 的 Recommends 里有 linux-headers-generic 这个
  # **元包**，它跟着 archive 里的最新 ABI 走，一装就把整套 6.8.0-136 内核
  # （image + modules + modules-extra + headers，300MB 上下）拉进盘里。
  # 下面的"清理多余内核"会兜底，但没必要先装进来再删。
  apt-get install -y -qq --no-install-recommends "linux-headers-${KVER}" \
    || fail "装 linux-headers-${KVER} 失败"

  say "静默安装 $(basename "$RUNFILE")"
  chmod +x "$RUNFILE"
  # -M=open 必须显式写死，不能靠默认值。
  #
  # NVIDIA 官方说明：proprietary 内核模块只支持到 Turing / Ampere / Ada / Hopper，
  # **Blackwell 及以后只有 open 模块支持**。也就是说用 proprietary 装完，
  # RTX 5090 / RTX PRO 6000 上 nvidia-smi 一张卡都认不到 —— 而按 gpu.sh 的判定
  # 那会被记成 FAIL「驱动加载失败，显卡/供电/插槽异常」，把好卡判成坏卡。
  # 595 系列的默认值恰好就是 open，但默认值是会变的，不能拿它当保证。
  "$RUNFILE" --silent --no-questions --accept-license \
             --kernel-name="$KVER" --no-drm --no-nvidia-modprobe \
             -M=open \
             --install-libglvnd --no-backup --no-check-for-alternate-installs \
    || fail "NVIDIA 驱动安装失败，看 /var/log/nvidia-installer.log"

  # 确认装出来的真是 open 模块：license 字段 open 是 "Dual MIT/GPL"，
  # proprietary 是 "NVIDIA"。装错了在 Blackwell 上就是全盘认不到卡。
  # open 内核模块**必须**有 GSP 固件才能起来（Turing 及以后全部如此），
  # 而这份固件是 .run 自己铺到 /lib/firmware/nvidia/<版本号>/ 的、不归 dpkg 管。
  # 上面剪固件那一步用的是 `nvidia/[a-z]*`，正是为了绕开这个数字开头的目录；
  # 万一哪天有人把它改回 `nvidia`，或者把两步的顺序调过来，这里当场停。
  # 漏掉的话表现是开机 nvidia.ko 加载失败 -> gpu.sh 判 FAIL「驱动加载失败」，
  # 一台好机器的好显卡被判成坏的。
  if [[ -d "/lib/firmware/nvidia/${NVIDIA_VERSION}" ]] \
     && [[ -n "$(ls -A "/lib/firmware/nvidia/${NVIDIA_VERSION}" 2>/dev/null)" ]]; then
    say "GSP 固件 OK (/lib/firmware/nvidia/${NVIDIA_VERSION})"
  else
    fail "/lib/firmware/nvidia/${NVIDIA_VERSION} 不存在或为空 —— open 内核模块没有 GSP 固件起不来。
     检查 config.sh 的 FIRMWARE_PRUNE 是不是把 nvidia/ 整个剪掉了。"
  fi

  NVMOD="$(find "/lib/modules/$KVER" -name 'nvidia.ko*' | head -1)"
  if [[ -n "$NVMOD" ]]; then
    NVLIC="$(modinfo -F license "$NVMOD" 2>/dev/null || true)"
    say "nvidia.ko license = ${NVLIC:-未知}"
    case "$NVLIC" in
      *MIT*|*GPL*) say "确认为 open 内核模块（Blackwell 可用）" ;;
      *)           say "WARN: 装出来的不是 open 模块，RTX 5090 / RTX PRO 6000 将认不到卡" ;;
    esac
  fi

  if [[ -f "$STAGE/vendor/gpu_burn/gpu_burn" ]]; then
    install -m 0755 "$STAGE/vendor/gpu_burn/gpu_burn" /opt/klburn/tools/gpu_burn
    # 上游从 compare.ptx 换成了 compare.fatbin，两个名字都认。
    # 这个文件 gpu_burn 是在运行时按相对路径加载的，丢了会直接跑不起来。
    GPUBURN_COMPARE=0
    for c in compare.fatbin compare.ptx; do
      if [[ -f "$STAGE/vendor/gpu_burn/$c" ]]; then
        install -m 0644 "$STAGE/vendor/gpu_burn/$c" "/opt/klburn/tools/$c"
        GPUBURN_COMPARE=1
      fi
    done
    (( GPUBURN_COMPARE )) || fail "有 gpu_burn 但没有 compare.fatbin/compare.ptx，运行时会加载失败"

    # gpu_burn 是静态链接的，除了驱动自带的 libcuda 不该再依赖任何 CUDA 库。
    # 真依赖了就是构建机上没走静态链接那条路，出盘一跑就是
    # "error while loading shared libraries"，然后被误判成显卡故障。
    if ldd /opt/klburn/tools/gpu_burn 2>/dev/null | grep -qE 'libcublas|libcudart'; then
      fail "gpu_burn 动态依赖 cuBLAS/cudart，盘内没有这些库，出盘必然跑不起来。
     请重新执行 ./build/build-gpu-burn.sh（它会走静态链接）"
    fi
    say "gpu_burn 已安装（静态链接，自包含）"
  else
    # 别写"降级为 nvidia-smi 监控"——代码里没有这条降级路径。
    # 实际行为是 gpu_stress() 记一条 SKIP：显卡型号/显存/驱动版本照常进报告，
    # 但不做满载压测，也就出不了温度/功耗曲线。
    say "WARN: vendor/gpu_burn/gpu_burn 不存在，GPU 压测会记为 SKIP（只采集显卡信息，不做满载压测）"
  fi

  # headers / 编译器只在构建期需要，装完就删
  apt-get purge -y -qq "linux-headers-${KVER}" >/dev/null 2>&1 || true
  apt-get autoremove -y -qq >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------- vendor: 性能基准程序
# 验收单点名的那几个基准程序都不在 Ubuntu 源里，也都不能重新分发到我们的仓库里：
#
#   bandwidthTest / p2pBandwidthLatencyTest   NVIDIA cuda-samples，BSD-3，需自行编译
#   xlinpack_xeon64                           Intel Optimized LINPACK Benchmark
#   mlc / mlc_avx512                          Intel Memory Latency Checker
#
# 所以走和阵列卡工具一样的路子：**放进 vendor/bench/ 就带上，不放就不带**，
# 不放时每一项干净地判 SKIP（lib/bench.sh），绝不判 FAIL。
#
# ⚠️ 和阵列卡工具不同的是**整个子目录原样铺进去**，不是只捞一个可执行文件：
#    xlinpack_xeon64 要同目录的 libiomp5.so 才跑得起来，只捞二进制的话
#    现场是一行 "error while loading shared libraries"，
#    而那行报错落在日志里看着像"这台机器有问题"。
#    lib/bench.sh 的 bench_run() 会把程序自己那个目录加进 LD_LIBRARY_PATH。
if [[ -d "$STAGE/vendor/bench" ]]; then
  bench_n=0
  for bdir in "$STAGE/vendor/bench"/*/; do
    [[ -d "$bdir" ]] || continue
    bname="$(basename "$bdir")"
    mkdir -p "/opt/klburn/tools/bench/$bname"
    cp -a "$bdir." "/opt/klburn/tools/bench/$bname/"
    find "/opt/klburn/tools/bench/$bname" -type f \
         ! -name '*.so' ! -name '*.so.*' ! -name '*.txt' ! -name '*.md' \
         -exec chmod 0755 {} + 2>/dev/null || true
    bench_n=$(( bench_n + 1 ))
    say "性能基准程序已安装: bench/$bname"
  done
  if (( bench_n == 0 )); then
    say "vendor/bench/ 是空的，性能基准项会全部记为 SKIP"
  else
    # 动态依赖自检，和阵列卡工具那边同一个道理：缺一个 .so 的表现是
    # 现场跑起来什么都不输出，判定只看到"没测出结果"，没人知道真正的原因。
    # 这里只警告不中断 —— 基准程序是可选件，缺了不该让整张盘出不来。
    while IFS= read -r bexe; do
      [[ -x "$bexe" ]] || continue
      readelf -d "$bexe" 2>/dev/null | grep -q NEEDED || continue
      miss=""
      ldcache="$(ldconfig -p 2>/dev/null | awk 'NR>1{print $1}')"
      while IFS= read -r lib; do
        [[ -n "$lib" ]] || continue
        # 程序自己目录里带的 .so 也算数（运行时会加进 LD_LIBRARY_PATH）
        [[ -e "$(dirname "$bexe")/$lib" ]] && continue
        printf '%s\n' "$ldcache" | grep -qxF "$lib" || miss="$miss $lib"
      done < <(readelf -d "$bexe" 2>/dev/null | sed -nE 's/.*NEEDED.*\[(.+)\]/\1/p')
      [[ -n "$miss" ]] && say "WARN: ${bexe#/opt/klburn/tools/} 缺少依赖库:$miss（该基准项在现场会跑不出结果）"
    done < <(find /opt/klburn/tools/bench -type f -perm -u+x 2>/dev/null)
  fi
else
  say "vendor/bench/ 不存在，性能基准项会全部记为 SKIP（不影响整机结论）"
fi

# ---------------------------------------------------------------- 清理多余内核
# 盘里只该有一个内核：casper/vmlinuz 引导的那个（$KVER）。
#
# 另一套是这么混进来的 —— 装 NVIDIA 驱动要 dkms，dkms 的 Recommends 指向
# linux-headers-generic 这个**元包**；元包跟着 archive 里最新的 ABI 走，
# 于是 linux-image-generic / linux-modules-* / linux-headers-* 一整套新内核
# （模块 155MB + /usr/src 头文件 157MB）跟着进了盘，而它一行代码都不会被执行。
#
# 上面装 headers 时加 --no-install-recommends 是从源头挡；这里是兜底 ——
# 增量构建复用上一轮的 rootfs，光挡住新的没用，得把已经躺在里面的清掉。
say "=== 清理多余内核（只留 $KVER）==="

# ⚠️ 先把"绝不能被 autoremove 收走"的包**显式打上手动标记**。
#
# config.sh 里 PKGS_PLATFORM 那段的原话是「显式列在这里 = 手动安装标记 =
# autoremove 不会碰」—— 那句话建立在"apt-get install 一定会把包标成 manual"
# 这个假设上，而这个假设**不总是成立**：
#
#   实测（KLBURN_KERNEL=hwe，全新工作区）：amd64-microcode 在装包阶段被从
#   3.20250311 升级到 3.20251202，装完是在的；等清理内核那步 purge 掉 GA 内核、
#   再 autoremove，它就**连包带文件一起没了**（dpkg 里查是"未安装"）。
#   下面那条微码断言当场把构建拦下 —— 那正是 1.5.0 加它的原因。
#
# apt-mark manual 是直接改标记，不依赖任何关于 apt 行为的假设。
# 微码缺了的后果：本该被微码修掉的 CPU 勘误会在压测里冒出来，
# 然后被记成"这台机器不稳定"—— 又是一次把好机器拦在出货前。
say "给平台包打手动标记（挡住 autoremove）: ${PKGS_PLATFORM[*]}"
apt-mark manual "${PKGS_PLATFORM[@]}" >/dev/null 2>&1 || true

# 先拆元包：它们钉着"最新内核"，不先拆掉，下面 purge 具体版本会被依赖挡回来。
apt-get purge -y -qq linux-generic linux-image-generic linux-headers-generic \
  >/dev/null 2>&1 || true

# 找出不属于 $KVER 的内核包。
# 每一段都要能失败：dpkg-query 的模式一个都没匹配上返回 1，grep 过滤到空也返回 1，
# 而 -o pipefail 下任何一个都足以把整个 chroot 脚本静默弄死（§11-9 同款）。
mapfile -t EXTRA_KPKGS < <(
  dpkg-query -W -f='${Package} ${Status}\n' \
    'linux-image-*' 'linux-modules-*' 'linux-headers-*' 2>/dev/null \
    | awk '$NF=="installed"{print $1}' \
    | grep -E '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' \
    | grep -vF -- "$KVER" || true
)
if ((${#EXTRA_KPKGS[@]})); then
  say "purge ${#EXTRA_KPKGS[@]} 个包: ${EXTRA_KPKGS[*]}"
  # 不 fail：内核包的 postrm 会去调 update-grub，chroot 里没有真的引导设备，
  # 它可能返回非零。真正说了算的是下面那条断言 —— 文件在不在，比 dpkg 怎么记更重要。
  apt-get purge -y -qq "${EXTRA_KPKGS[@]}" >/dev/null 2>&1 \
    || say "WARN: apt-get purge 返回非零（chroot 里 update-grub 常见），改由下面按目录清"
else
  say "没有多余的内核包"
fi
apt-get autoremove --purge -y -qq >/dev/null 2>&1 || true

# 残留目录：dkms 往 updates/ 下写过东西的话 dpkg 不会删父目录；
# /usr/src 下的头文件树运行时也完全用不上。
for d in /lib/modules/*/; do
  [[ -d "$d" ]] || continue
  b="$(basename "$d")"
  if [[ "$b" != "$KVER" ]]; then
    say "删除残留模块目录 $b"
    rm -rf -- "${d:?}"
  fi
done
rm -rf /usr/src/linux-headers-* 2>/dev/null || true

# 硬断言。剩两套内核意味着"开机会加载哪一套"不确定，而搞反的表现是
# 开机认不到任何硬盘、或者显卡模块加载失败 —— 两样都会被误判成硬件故障。
# build-iso.sh 出了 chroot 还会再验一次（那边还要和 casper/vmlinuz 对版本）。
# 两处都留着不重复：这一条能指出是 chroot 里哪一步没干净。
mapfile -t LEFT_KVERS < <(ls -1 /lib/modules 2>/dev/null)
if (( ${#LEFT_KVERS[@]} != 1 )) || [[ "${LEFT_KVERS[0]}" != "$KVER" ]]; then
  fail "清理完 /lib/modules 下还有: ${LEFT_KVERS[*]}（应该只剩 $KVER）"
fi
say "只剩 $KVER（$(du -sh "/lib/modules/$KVER" | cut -f1)）"

# ---------------------------------------------------------------- HWE：交出新的引导文件
# 换了内核就必须**重新生成 casper 的 initramfs**，否则开机加载的还是旧内核的
# 模块集 —— 表现是认不到任何硬盘。casper 的 initramfs hook 在 live 层里本来就有，
# 这里只要触发一次生成。
#
# 放在清理内核之后：那时候模块集才是最终的（NVIDIA 的模块也已经编好了）。
if [[ "${KLBURN_KERNEL:-generic}" == "hwe" ]]; then
  say "=== 为 $KVER 重新生成 casper 的 initramfs ==="

  # ⚠️ **先把 casper 装回来。** 它和 linux-firmware 是一模一样的坑：
  # dpkg 里 casper 是 "install ok installed"，但**文件被剪掉了** ——
  # 它的 initramfs 脚本原本在我们丢弃的 installer 层里。
  #
  # 不装回来的话，update-initramfs 生成的是一个**普通的 initramfs，不是 live 的**：
  # 里面没有 casper 的 boot 脚本，开机走到挂根文件系统那一步直接停在
  #     No root device specified. Boot arguments must include a root= parameter.
  #     BusyBox ... (initramfs)
  # 报告一个字都写不出来。这是实测出来的 —— 第一次 hwe 构建一切都成功，
  # e2e 却卡在 initramfs 提示符上。
  say "装回 casper（它的 initramfs 脚本和 linux-firmware 一样被镜像剪掉了）"
  apt-get install -y -qq --reinstall casper || fail "装 casper 失败"
  [[ -d /usr/share/initramfs-tools/scripts/casper-bottom ]] \
    || fail "装完 casper 之后仍然没有 initramfs 脚本 —— 生成出来的会是个进不去系统的 initrd"

  # 包安装时可能已经生成过一份，-c 遇到已存在会失败，所以先删再建
  update-initramfs -d -k "$KVER" >/dev/null 2>&1 || true
  update-initramfs -c -k "$KVER" \
    || fail "为 $KVER 生成 initramfs 失败 —— 做出来的盘开机会认不到任何硬盘"

  # 生成出来的必须**真的是 live 的**：里面要有 casper 的 boot 脚本。
  # 只看"文件生成了"不够 —— 上面那次翻车就是文件正常生成、内容不对。
  if ! lsinitramfs "/boot/initrd.img-$KVER" 2>/dev/null | grep -q 'scripts/casper'; then
    fail "生成的 initrd 里没有 casper 的 boot 脚本 —— 开机会停在 (initramfs) 提示符，
     报告一个字都写不出来。检查上面 casper 是不是真的装回来了。"
  fi
  say "initrd 自检通过：里面有 casper 的 boot 脚本"

  # ⚠️ **不要把它们拷到 $STAGE 里交出去。** 下面「收尾」那一步有
  #    `rm -rf /tmp/*`，而 $STAGE 就在 /tmp 下 —— 拷过去会被自己删掉，
  #    然后 build-iso.sh 报"chroot 没有交出 vmlinuz/initrd"（实测踩过）。
  #    留在 /boot 里就行：外面按 rootfs 里唯一那个内核版本去取，不需要交接文件。
  [[ -f "/boot/vmlinuz-$KVER"    ]] || fail "/boot/vmlinuz-$KVER 不存在"
  [[ -f "/boot/initrd.img-$KVER" ]] || fail "/boot/initrd.img-$KVER 不存在"
  say "vmlinuz / initrd 已就绪（$(du -sh "/boot/initrd.img-$KVER" | cut -f1)），
     build-iso.sh 会从 rootfs 的 /boot 里取走换进 casper/"
fi

# autoremove 顺手收走别的东西这件事已经发生过一次（amd64-microcode），
# 所以清理完再把关键工具点一遍名。
verify_tools "清理内核后"
for d in intel-ucode amd-ucode; do
  if [[ -d "/lib/firmware/$d" && -n "$(ls -A "/lib/firmware/$d" 2>/dev/null)" ]]; then
    continue
  fi
  # 兜底再装一次。上面已经 apt-mark manual 过，正常不该走到这儿；
  # 走到了就说明还有别的路径能把它弄没，装回来之后下面那条断言仍然说了算。
  say "WARN: /lib/firmware/$d 不见了，尝试重新安装微码包"
  apt-get install -y -qq --reinstall amd64-microcode intel-microcode >/dev/null 2>&1 || true
  [[ -d "/lib/firmware/$d" && -n "$(ls -A "/lib/firmware/$d" 2>/dev/null)" ]] \
    || fail "CPU 微码 /lib/firmware/$d 没了，重装也没回来。
     显式装它的地方在 config.sh 的 PKGS_PLATFORM，清理内核前有 apt-mark manual。
     缺微码的后果：本该被微码修掉的 CPU 勘误会在压测里冒出来，
     然后被记成「这台机器不稳定」——又是一次把好机器拦在出货前。"
done
say "CPU 微码 intel-ucode / amd-ucode 都在"

# ---------------------------------------------------------------- 收尾
say "清理 apt 缓存 / 还原源"
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
rm -f /var/log/*.log /var/log/**/*.log 2>/dev/null || true

if [[ -f "$BAK_LIST" ]]; then
  mv -f "$BAK_LIST" "$SRC_LIST"
fi

# 主机名，方便现场辨认
echo "klburn" > /etc/hostname

# 时区：报告目录名是"序列号_日期时间"，时间必须是现场看得懂的本地时间。
# 无网络，时间来自 BIOS RTC（服务器通常是 UTC），不设时区就会差 8 小时。
if [[ -n "${TIMEZONE:-}" && -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
  ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
  echo "$TIMEZONE" > /etc/timezone
  say "时区设为 $TIMEZONE"
else
  say "WARN: 时区 ${TIMEZONE:-未设置} 无效，报告时间将使用 UTC"
fi

say "chroot 定制完成"
