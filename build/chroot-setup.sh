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
PKGS=( "${PKGS_COLLECT[@]}" "${PKGS_NET[@]}" "${PKGS_STRESS[@]}" "${PKGS_MISC[@]}" )
if [[ "${INCLUDE_NVIDIA:-0}" == "1" ]]; then
  PKGS+=( "${PKGS_NVIDIA_BUILD[@]}" )
fi

say "安装 ${#PKGS[@]} 个包..."
apt-get install -y -qq --no-install-recommends "${PKGS[@]}" \
  || fail "装包失败"

# 逐个确认关键工具真的到位了（apt 返回成功不代表命令存在）
missing=()
for entry in dmidecode lshw lspci nvme smartctl ipmitool ethtool jq python3 \
             stress-ng stressapptest fio sysbench dhclient ping ip chronyd; do
  command -v "$entry" >/dev/null 2>&1 || missing+=("$entry")
done
if ((${#missing[@]})); then
  fail "以下工具装完仍不存在: ${missing[*]}"
fi
say "关键工具检查通过"

# exfat 内核模块必须在（报告要写进 U 盘的 exFAT 分区）
KVER="$(ls -1 /lib/modules | head -1)"
if [[ -n "$KVER" ]]; then
  if find "/lib/modules/$KVER" -name 'exfat.ko*' | grep -q .; then
    say "exfat 内核模块 OK ($KVER)"
  else
    say "WARN: 没找到 exfat.ko，报告可能无法写入 U 盘数据分区"
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

# 构建期常量写进配置文件，运行时脚本读它
cat > /opt/klburn/klburn.conf <<EOF
# 由 build/chroot-setup.sh 在构建时生成，勿手改
KLBURN_VERSION="${KLBURN_VERSION}"
COMPANY_NAME="${COMPANY_NAME}"
BUILD_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
BASE_OS="Ubuntu Server ${UBUNTU_POINT}"
INCLUDE_NVIDIA="${INCLUDE_NVIDIA:-0}"
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

# ---------------------------------------------------------------- NVIDIA（第二阶段）
if [[ "${INCLUDE_NVIDIA:-0}" == "1" ]]; then
  say "=== NVIDIA 阶段 ==="
  RUNFILE="$(ls -1 "$STAGE"/vendor/nvidia/NVIDIA-Linux-x86_64-*.run 2>/dev/null | head -1 || true)"
  [[ -n "$RUNFILE" ]] || fail "INCLUDE_NVIDIA=1 但 vendor/nvidia/ 下没有 .run 文件"

  KVER="$(ls -1 /lib/modules | head -1)"
  say "为内核 $KVER 安装 headers"
  apt-get install -y -qq "linux-headers-${KVER}" || fail "装 linux-headers-${KVER} 失败"

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
