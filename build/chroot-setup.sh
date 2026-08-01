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
PKGS=( "${PKGS_COLLECT[@]}" "${PKGS_NET[@]}" "${PKGS_STRESS[@]}" "${PKGS_MISC[@]}"
       "${PKGS_PLATFORM[@]}" )
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
               stress-ng stressapptest fio sysbench dhclient ping ip chronyd; do
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
         chrony.service systemd-timesyncd.service; do
  systemctl mask "$u" >/dev/null 2>&1 || true
done
# 说明：smartd 装 smartmontools 时会被自动 enable。它后台定期轮询硬盘，
# 会和 fio 的裸盘压测抢 IO、也可能在日志里插入干扰信息，所以关掉。
# 我们自己在测前测后各显式跑一次 smartctl 就够了。

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

# 开机自动拉起测试主脚本
systemctl enable klburn.service >/dev/null 2>&1 \
  || fail "systemctl enable klburn.service 失败"
[[ -L /etc/systemd/system/multi-user.target.wants/klburn.service ]] \
  || fail "klburn.service 没有真正 enable 成功，做出来的盘开机不会自动跑测试"
say "klburn.service 已设为开机自启"

# 构建期常量写进配置文件，运行时脚本读它。
# 抬头（公司名 / 报告标题 / 产品名）就是在这里钉死进盘里的 —— 现场不会再问任何人。
cat > /opt/klburn/klburn.conf <<EOF
# 由 build/chroot-setup.sh 在构建时生成，勿手改
KLBURN_VERSION="${KLBURN_VERSION}"
COMPANY_NAME="${COMPANY_NAME}"
REPORT_TITLE="${REPORT_TITLE:-服务器出厂老化测试报告}"
PRODUCT_NAME="${PRODUCT_NAME:-KLBurn}"
BUILD_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
BASE_OS="Ubuntu Server ${UBUNTU_POINT}"
INCLUDE_NVIDIA="${INCLUDE_NVIDIA:-0}"
NVIDIA_VERSION="${NVIDIA_VERSION:-}"
# 源码的 git commit（由 build-iso.sh 追加进暂存的 config.sh 后传到这里）。
# 版本号靠人记得 bump，commit hash 是构建脚本自己取的，骗不了人。
GIT_COMMIT="${GIT_COMMIT:-unknown}"
EOF

# ---------------------------------------------------------------- vendor: storcli
STORCLI=""
for cand in "$STAGE/vendor/storcli/storcli64" "$STAGE/vendor/storcli/storcli"; do
  if [[ -f "$cand" ]]; then STORCLI="$cand"; break; fi
done
# Broadcom 发的是 zip（里面还套 rpm），解出来是 Unified_storcli_all_os/Linux/storcli64
# 这种一层套一层的目录。允许把整个解压结果原样丢进 vendor/storcli/，这里自己往下找，
# 省得每次出盘都要手工翻目录把那个文件捞出来。
#
# 注意 `|| true`：本脚本是 -o pipefail，find 在目录不存在时返回 1，
# 而 pipefail 会把这个 1 带出整条管道，一个赋值就能把整个 chroot 脚本静默弄死。
if [[ -z "$STORCLI" && -d "$STAGE/vendor/storcli" ]]; then
  STORCLI="$(find "$STAGE/vendor/storcli" -type f \( -name 'storcli64' -o -name 'storcli' \) \
             2>/dev/null | head -1 || true)"
fi

if [[ -n "$STORCLI" ]]; then
  install -m 0755 "$STORCLI" /opt/klburn/tools/storcli64
  say "storcli64 已安装（来自 vendor/${STORCLI#"$STAGE/vendor/"}）"
else
  say "vendor/storcli/ 下没找到 storcli64 -> 阵列卡只能报 PCI 型号（见 vendor/README.md）"
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

# autoremove 顺手收走别的东西这件事已经发生过一次（amd64-microcode），
# 所以清理完再把关键工具点一遍名。
verify_tools "清理内核后"
for d in intel-ucode amd-ucode; do
  [[ -d "/lib/firmware/$d" && -n "$(ls -A "/lib/firmware/$d" 2>/dev/null)" ]] \
    || fail "CPU 微码 /lib/firmware/$d 没了 —— 多半又被 autoremove 收走了。
     显式装它的地方在 config.sh 的 PKGS_PLATFORM。"
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
