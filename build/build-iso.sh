#!/usr/bin/env bash
#
# KLBurn ISO 一键构建
#
#   sudo ./build/build-iso.sh                  # 常规构建（vendor/nvidia 里有驱动就自动带上）
#   sudo ./build/build-iso.sh --edition mem    # 内存专用盘（开机不问、直接测内存）
#   sudo ./build/build-iso.sh --without-nvidia # 强制出一张不含显卡驱动的盘
#   sudo ./build/build-iso.sh --clean          # 清空工作区从头来
#   sudo ./build/build-iso.sh --rebuild-fs     # 强制重新解 squashfs（换源 ISO 后用）
#
# 在 x86_64 Ubuntu 执行，工作区放 Linux 本地文件系统。
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------- 参数
OPT_CLEAN=0
OPT_REBUILD_FS=0
OPT_SKIP_DOWNLOAD=0
OPT_NVIDIA_FORCED=0
OPT_NVIDIA_ENABLE=0
SRC_ISO_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)        OPT_CLEAN=1 ;;
    --rebuild-fs)   OPT_REBUILD_FS=1 ;;
    --skip-download) OPT_SKIP_DOWNLOAD=1 ;;
    --with-nvidia)    export INCLUDE_NVIDIA=1; OPT_NVIDIA_FORCED=1; OPT_NVIDIA_ENABLE=1 ;;
    --without-nvidia) export INCLUDE_NVIDIA=0; OPT_NVIDIA_FORCED=1; OPT_NVIDIA_ENABLE=0 ;;
    # 出哪一种盘。必须 export：config.sh 在下面才被 source，它按这个值
    # 决定报告标题、产品名和 ISO 文件名。
    --edition)      export KLBURN_EDITION="$2"; shift ;;
    --iso)          SRC_ISO_OVERRIDE="$2"; shift ;;
    -h|--help)      sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
  shift
done

# ---------------------------------------------------------------- 载入配置
# 构建不能偷偷改源码；换行问题交给 lint 和 .gitattributes。

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

require_root "$@"
require_cmds xorriso mksquashfs unsquashfs rsync curl chroot md5sum numfmt find sed awk
BUILD_JOBS="${KLBURN_BUILD_JOBS:-$(nproc)}"
[[ "$BUILD_JOBS" =~ ^[0-9]+$ ]] && (( BUILD_JOBS > 0 )) || die "KLBURN_BUILD_JOBS 必须为正整数"

if [[ "$KLBURN_EDITION" == "mem" && "$OPT_NVIDIA_ENABLE" == 1 ]]; then
  die "内存专用盘不包含 NVIDIA/CUDA，不能使用 --with-nvidia"
fi

# ---------------------------------------------------------------- GPU 组件
# config.sh 已经按 vendor/nvidia/ 里有没有驱动自动决定了 INCLUDE_NVIDIA。
# 这里把结论落成一句人看得懂的日志，并且守住一条：**显式要求带驱动却没有驱动
# 文件时直接停下**，绝不静默出一张"自称带驱动、其实没有"的盘。
NVIDIA_RUNFILE="$(ls -1 "$PROJ_DIR"/vendor/nvidia/NVIDIA-Linux-x86_64-*.run 2>/dev/null | head -1 || true)"
NVIDIA_VERSION=""
if [[ "$KLBURN_EDITION" == "full" && -n "$NVIDIA_RUNFILE" ]]; then
  NVIDIA_VERSION="$(basename "$NVIDIA_RUNFILE")"
  NVIDIA_VERSION="${NVIDIA_VERSION#NVIDIA-Linux-x86_64-}"
  NVIDIA_VERSION="${NVIDIA_VERSION%.run}"
fi

if ((INCLUDE_NVIDIA)); then
  [[ -n "$NVIDIA_RUNFILE" ]] \
    || die "要求构建带显卡驱动的盘，但 vendor/nvidia/ 下没有 NVIDIA-Linux-x86_64-*.run
     放好驱动再重来，或者用 --without-nvidia 出一张不含显卡驱动的盘。"
  log "显卡组件: NVIDIA 驱动 ${NVIDIA_VERSION} + gpu_burn"
  [[ -f "$PROJ_DIR/vendor/gpu_burn/gpu_burn" ]] \
    || warn "vendor/gpu_burn/gpu_burn 不存在：显卡信息照常采集，但不做满载压测"
else
  if (( OPT_NVIDIA_FORCED )); then
    log "显卡组件: 按 --without-nvidia 跳过"
  else
    log "显卡组件: vendor/nvidia/ 下没有驱动，本次不含显卡驱动"
  fi
fi

# ---------------------------------------------------------------- 路径
CACHE_DIR="$WORK_DIR/cache"
ISO_DIR="$WORK_DIR/iso"          # 解包出来的 ISO 目录树
ROOTFS_DIR="$WORK_DIR/rootfs"    # 合并后的根文件系统
OUT_DIR="$WORK_DIR/out"
STAMP_DIR="$WORK_DIR/.stamps"
LEDGER="$WORK_DIR/.mounts"

# 安全检查：绝不允许在 /mnt/c 下解 squashfs
case "$WORK_DIR" in
  /mnt/*|/media/*|/c/*)
    die "WORK_DIR=$WORK_DIR 位于 Windows 挂载盘上。squashfs 打包会慢到不可用，
     请设置 KLBURN_WORK 到 WSL 原生路径，例如: export KLBURN_WORK=\$HOME/klburn-build"
    ;;
esac

if (( OPT_CLEAN )); then
  step "清空工作区 $WORK_DIR"
  MOUNT_LEDGER="$LEDGER"; unmount_all
  rm -rf "$ISO_DIR" "$ROOTFS_DIR" "$STAMP_DIR"
  log "已清空（cache/ 里的源 ISO 保留）"
fi

mkdir -p "$CACHE_DIR" "$OUT_DIR" "$STAMP_DIR"

# edition 改变必须回到源 ISO，避免 full 的驱动/工具残留在 mem 中，
# 也避免 mem 精简后再构建 full 时复用不完整的根文件系统。
PREV_EDITION="$(sed -n 's/^KLBURN_EDITION="\([^"]*\)"$/\1/p' \
  "$ROOTFS_DIR/opt/klburn/klburn.conf" 2>/dev/null || true)"
if [[ -d "$ROOTFS_DIR" && "$PREV_EDITION" != "$KLBURN_EDITION" ]]; then
  log "edition 从 ${PREV_EDITION:-unknown} 换成 $KLBURN_EDITION，重新解包 rootfs"
  OPT_REBUILD_FS=1
fi

# ---------------------------------------------------------------- 换内核要强制重解
# 增量构建复用上一轮的 ISO 目录树和 rootfs。而 KLBURN_KERNEL 一换，这两样
# 都不能再复用：
#   hwe -> generic  casper/vmlinuz 还是上一轮换上去的 HWE 内核、rootfs 里也只有
#                   HWE 的模块，而 generic 模式不会把 GA 装回来 —— 于是做出来的
#                   盘明明是 HWE 的，却自称 generic。
#   generic -> hwe  这个方向本来是安全的（chroot 里会装新内核再清旧的），
#                   但一并处理更省心，也省得下次有人改了顺序又踩回去。
# 所以把上一轮的模式记在 stamp 里，一旦不同就当 --rebuild-fs 处理。
KERNEL_STAMP="$STAMP_DIR/kernel-flavour"
PREV_KERNEL="$(cat "$KERNEL_STAMP" 2>/dev/null || true)"
if [[ -n "$PREV_KERNEL" && "$PREV_KERNEL" != "$KLBURN_KERNEL" ]]; then
  warn "内核从 $PREV_KERNEL 换成 $KLBURN_KERNEL —— 强制重新解包 ISO 与 rootfs（不能复用上一轮的）"
  OPT_REBUILD_FS=1
fi
printf '%s\n' "$KLBURN_KERNEL" > "$KERNEL_STAMP"

# hwe 模式**一律**重解，不做增量。
#
# 理由：hwe 那条路的 chroot 会**改掉 rootfs 里的内核**（装 HWE、purge GA），
# 而 casper/vmlinuz 要等 chroot 跑完才被替换。这两样一旦不同步，下一轮就对不上：
#
#   实测：第一次 hwe 构建在最后的微码断言上失败了 —— 此时 rootfs 里已经只剩
#   7.0.0-28，而 casper/vmlinuz 还是 6.8.0-100。直接重跑一次，ISO_KVER 读成
#   6.8.0-100、chroot 里却只有 7.0.0-28，报
#   "ISO_KVER=6.8.0-100-generic 在 /lib/modules 下不存在"。
#
# 只在"上一次成功"时增量才是对的 —— 而"只要上次没失败就没问题"这种前提，
# 这个项目一向不接受。多花几分钟重解，换掉一整类查起来很绕的失败。
if [[ "$KLBURN_KERNEL" == "hwe" ]]; then
  (( OPT_REBUILD_FS )) || log "hwe 模式：强制重新解包 ISO 与 rootfs（chroot 会改掉内核，增量不安全）"
  OPT_REBUILD_FS=1
fi
ledger_init "$LEDGER"

# ---------------------------------------------------------------- 异常清理
_cleanup() {
  local rc=$?
  if (( rc != 0 )); then
    err "构建失败（exit $rc），正在清理挂载点..."
  fi
  chroot_umount "$ROOTFS_DIR" 2>/dev/null || true
  exit $rc
}
trap _cleanup EXIT
trap 'die "收到中断信号"' INT TERM

# ================================================================ 1. 源 ISO
step "1/9 准备源 ISO"

if [[ -n "$SRC_ISO_OVERRIDE" ]]; then
  SRC_ISO="$SRC_ISO_OVERRIDE"
  [[ -f "$SRC_ISO" ]] || die "指定的 ISO 不存在: $SRC_ISO"
else
  SRC_ISO="$CACHE_DIR/$SRC_ISO_NAME"
  if [[ ! -f "$SRC_ISO" ]]; then
    (( OPT_SKIP_DOWNLOAD )) && die "源 ISO 不存在且指定了 --skip-download: $SRC_ISO"
    log "下载 $SRC_ISO_URL"
    log "（约 3GB，断点续传，中断后重跑本脚本即可继续）"
    curl -fL -C - --retry 5 --retry-delay 3 -o "$SRC_ISO" "$SRC_ISO_URL" \
      || die "下载失败，可手动下载后放到 $SRC_ISO"
  fi
fi

log "源 ISO: $SRC_ISO ($(human "$(stat -c %s "$SRC_ISO")"))"

if [[ -n "$SRC_ISO_SHA256" ]]; then
  log "校验 sha256 ..."
  echo "$SRC_ISO_SHA256  $SRC_ISO" | sha256sum -c - || die "源 ISO 校验失败"
fi

# ================================================================ 2. 解包 ISO
step "2/9 解包 ISO 目录树"

if (( OPT_REBUILD_FS )) || [[ ! -f "$STAMP_DIR/iso-extracted" ]]; then
  rm -rf "$ISO_DIR"
  mkdir -p "$ISO_DIR"
  # 用 xorriso 抽取，不需要 loop mount（WSL 里更稳）
  xorriso -osirrox on -indev "$SRC_ISO" -extract / "$ISO_DIR" 2>&1 \
    | grep -Ev '^xorriso : (UPDATE|NOTE)' || true
  chmod -R u+w "$ISO_DIR"
  touch "$STAMP_DIR/iso-extracted"
  log "已解包到 $ISO_DIR"
else
  log "已解包过，跳过（--rebuild-fs 可强制重来）"
fi

[[ -d "$ISO_DIR/casper" ]] || die "$ISO_DIR/casper 不存在，这不像 Ubuntu live ISO"

# 盘上真正会被引导的内核版本。后面 chroot 定制、清理多余内核、自检全靠它对齐。
ISO_KVER="$(bzimage_kver "$ISO_DIR/casper/vmlinuz" || true)"
[[ -n "$ISO_KVER" ]] \
  || die "读不出 casper/vmlinuz 的内核版本。没有它就只能靠猜哪套模块该留，
     而猜错的表现是开机认不到任何硬盘 —— 宁可在这里停下。"
log "引导内核: $ISO_KVER"
[[ "$KLBURN_KERNEL" == "hwe" ]] \
  && log "KLBURN_KERNEL=hwe：chroot 里会装 ${HWE_KERNEL_PKG}，之后替换 casper/vmlinuz 与 initrd"

# 记录原始卷标，重打包时原样保留（避免 UEFI grub 找不到介质）
ISO_LABEL="$(xorriso -indev "$SRC_ISO" -pvd_info 2>/dev/null \
             | sed -n 's/^Volume Id *: *//p' | head -1)"
[[ -n "$ISO_LABEL" ]] || ISO_LABEL="Ubuntu-Server ${UBUNTU_POINT} amd64"
log "卷标: $ISO_LABEL"

# ================================================================ 3. 合并 squashfs 层
step "3/9 合并 squashfs 层 -> 单层根文件系统"

# casper 的层通过文件名里的点表示依赖链：
#   ubuntu-server-minimal.squashfs                        (基础层)
#   ubuntu-server-minimal.ubuntu-server.squashfs          (+ server 层)
#   ubuntu-server-minimal.ubuntu-server.installer.squashfs(+ 安装器层, 我们丢弃)
# 按点的个数升序 = 依赖顺序
mapfile -t ALL_LAYERS < <(
  cd "$ISO_DIR/casper" && ls -1 -- *.squashfs 2>/dev/null \
    | awk '{ n=gsub(/\./,"."); print n, $0 }' | sort -n -k1,1 | cut -d' ' -f2-
)
((${#ALL_LAYERS[@]})) || die "casper 下没找到任何 .squashfs"

LAYERS=()
for l in "${ALL_LAYERS[@]}"; do
  drop=0
  for pat in "${LAYER_EXCLUDE_PATTERNS[@]}"; do
    # shellcheck disable=SC2053
    if [[ "$l" == $pat ]]; then drop=1; break; fi
  done
  if (( drop )); then
    log "  丢弃 $l ($(human "$(stat -c %s "$ISO_DIR/casper/$l")"))"
  else
    LAYERS+=("$l")
    log "  保留 $l ($(human "$(stat -c %s "$ISO_DIR/casper/$l")"))"
  fi
done
((${#LAYERS[@]})) || die "所有层都被 LAYER_EXCLUDE_PATTERNS 排除了"

BASE_LAYER="${LAYERS[0]}"                       # 合并后沿用最短的那个名字
BASE_NAME="${BASE_LAYER%.squashfs}"

# 保险：合并结果里必须有内核模块，否则做出来的盘认不到任何硬盘/阵列卡
NEED_MODULES=1

if (( OPT_REBUILD_FS )) || [[ ! -f "$STAMP_DIR/rootfs-extracted" ]]; then
  rm -rf "$ROOTFS_DIR"
  mkdir -p "$ROOTFS_DIR"

  # overlayfs 用 0:0 的字符设备表示"上层把下层这个名字删掉了"，
  # 被删的可能是文件也可能是整个目录。必须在 rsync 之前就把它兑现成
  # 对 rootfs 的删除，否则 rsync 会撞上"字符设备 vs 已存在的非空目录"直接失败。
  apply_whiteouts() {
    local src="${1%/}" dst="${2%/}" n=0 wf rel
    while IFS= read -r -d '' wf; do
      [[ "$(stat -c '%t:%T' "$wf" 2>/dev/null)" == "0:0" ]] || continue
      rel="${wf#"$src"/}"
      # ${rel:?} 不是装饰：这个脚本以 root 跑，rel 万一算成空串（src 前缀没剥掉
      # 之类），"$dst/$rel" 就是 "$dst/"，一条 rm -rf 能把整个 rootfs 端掉。
      # :? 让它在空的时候直接报错退出，而不是安静地删。
      rm -rf -- "$dst/${rel:?whiteout 相对路径为空，拒绝执行 rm -rf}"
      rm -f   -- "$wf"           # 标记本身不要带进最终镜像
      n=$(( n + 1 ))
    done < <(find "$src" -type c -print0 2>/dev/null)
    (( n > 0 )) && log "    处理 $n 个 overlayfs 删除标记"
    return 0
  }

  LAYER_TMP="$WORK_DIR/.layer-tmp"
  first=1
  for l in "${LAYERS[@]}"; do
    if (( first )); then
      # 第一层直接解到目标位置，省一次全量拷贝
      log "  解包 $l ..."
      unsquashfs -processors "$BUILD_JOBS" -d "$ROOTFS_DIR" -f "$ISO_DIR/casper/$l" >/dev/null
      apply_whiteouts "$ROOTFS_DIR" "$ROOTFS_DIR"
      first=0
    else
      # 后续层不能用 unsquashfs -f 直接往上叠：层里带硬链接时，
      # 目标文件已存在会直接 FATAL（failed to create hardlink, File exists）。
      # 所以先解到独立目录，处理完删除标记，再用 rsync 覆盖合并。
      log "  解包 $l ..."
      rm -rf "$LAYER_TMP"
      unsquashfs -processors "$BUILD_JOBS" -d "$LAYER_TMP" "$ISO_DIR/casper/$l" >/dev/null
      apply_whiteouts "$LAYER_TMP" "$ROOTFS_DIR"
      log "  合并 $l -> rootfs"
      rsync -aHAX --numeric-ids "$LAYER_TMP/" "$ROOTFS_DIR/"
      rm -rf "$LAYER_TMP"
    fi
  done

  touch "$STAMP_DIR/rootfs-extracted"
  log "根文件系统: $(du -sh "$ROOTFS_DIR" | cut -f1)"
else
  log "已解包过，跳过（--rebuild-fs 可强制重来）"
fi

# 内核模块自检：Ubuntu 把内核放在 installer.generic 层，一旦层选错就会全丢
if (( NEED_MODULES )); then
  # 增量构建复用上一轮的 rootfs，那里面可能不止一套内核，所以**先按 ISO_KVER 找**，
  # 找不到才退回"随便挑一个"。挑错的话下面那几条 ✓ 查的是不会被引导的那套模块，
  # 看着全绿、其实什么都没验。
  KMOD_DIR=""
  for cand in "$ROOTFS_DIR/usr/lib/modules/$ISO_KVER" "$ROOTFS_DIR/lib/modules/$ISO_KVER"; do
    [[ -d "$cand" ]] && { KMOD_DIR="$cand"; break; }
  done
  if [[ -z "$KMOD_DIR" ]]; then
    KMOD_DIR="$(find "$ROOTFS_DIR/usr/lib/modules" "$ROOTFS_DIR/lib/modules" \
                -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)"
  fi
  [[ -n "$KMOD_DIR" ]] || die "合并后的根文件系统里没有 /lib/modules —— 层选错了。
     检查 config.sh 的 LAYER_EXCLUDE_PATTERNS，内核在 *.installer.generic.squashfs 层里。"
  KVER_FOUND="$(basename "$KMOD_DIR")"
  log "内核模块: $KVER_FOUND ($(find "$KMOD_DIR" -name '*.ko*' | wc -l) 个模块)"
  for m in exfat megaraid_sas mpt3sas nvme; do
    if find "$KMOD_DIR" -name "${m}.ko*" | grep -q .; then
      log "    ✓ $m"
    else
      warn "    ✗ 缺少内核模块 $m"
    fi
  done
fi

# ================================================================ 4. chroot 定制
step "4/9 chroot 定制（装包 + 装 KLBurn）"

# 把要用的东西送进 chroot 的暂存目录
STAGE="$ROOTFS_DIR/tmp/klburn-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
install -m 0755 "$SCRIPT_DIR/chroot-setup.sh" "$STAGE/chroot-setup.sh"
install -m 0644 "$SCRIPT_DIR/config.sh"       "$STAGE/config.sh"

# 把源码的 git 状态钉进这张盘。
#
# 0.3.0 出过一次悬案：ISO 构建完 23 分钟后又改了代码却没动版本号，现场那根盘
# 自称 0.3.0、跑的却是修复前的代码，对着仓库怎么看都对不上。版本号靠人记得 bump，
# 而 commit hash 是构建脚本自己取的，骗不了人；工作区脏不脏也一并记上——
# 「0.5.0 + abc1234 + dirty」一眼就知道这盘里有没进版本库的改动。
#
# 每一条都必须 `|| true`：本脚本是 -Eeuo pipefail，而这台机器可能压根没装 git、
# 或者源码目录不是个 git 仓库，一次失败的赋值型命令替换就能把整个构建静默弄死
# （config.sh 里的 getent、chroot-setup.sh 里的 find 都栽过同一个坑）。
# safe.directory 是因为构建要 sudo/root 跑，而仓库属于普通用户，
# 新版 git 会以 "dubious ownership" 拒绝工作。
GIT_ARGS=(-c "safe.directory=*" -C "$PROJ_DIR")
GIT_COMMIT="$(git "${GIT_ARGS[@]}" rev-parse --short HEAD 2>/dev/null || true)"
GIT_DIRTY=""
if [[ -n "$GIT_COMMIT" ]]; then
  # --porcelain 有输出 = 工作区有未提交的改动
  if [[ -n "$(git "${GIT_ARGS[@]}" status --porcelain 2>/dev/null || true)" ]]; then
    GIT_DIRTY="-dirty"
  fi
else
  GIT_COMMIT="unknown"
fi
log "源码版本: ${KLBURN_VERSION}  git ${GIT_COMMIT}${GIT_DIRTY}"
[[ -n "$GIT_DIRTY" ]] && warn "工作区有未提交的改动，这张盘里会标记为 dirty"

# 追加到暂存的 config.sh 末尾，chroot-setup.sh source 它时就能拿到，
# 不用额外开一条传参通道。注意只改暂存副本，不碰仓库里的 build/config.sh。
cat >> "$STAGE/config.sh" <<EOF

# ---------- 以下由 build-iso.sh 在构建时追加，勿手改 ----------
GIT_COMMIT="${GIT_COMMIT}${GIT_DIRTY}"
# 出的是哪一种盘（full / mem）。和 INCLUDE_NVIDIA 同一个道理：chroot 里
# 没有外面的环境变量，不钉死的话 \`--edition mem\` 在 chroot 里会读回
# 默认的 full，于是开机自启的还是整机全测脚本 —— 而且不会有任何报错。
KLBURN_EDITION="${KLBURN_EDITION}"
MEM_BURN_SECONDS="${MEM_BURN_SECONDS}"
# chroot 里没有 vendor/ 目录，自动检测得不出正确答案，这里钉死外面算好的结论
INCLUDE_NVIDIA="${INCLUDE_NVIDIA}"
NVIDIA_VERSION="${NVIDIA_VERSION}"
BUILD_JOBS="${BUILD_JOBS}"
# casper/vmlinuz 的内核版本。chroot 里看不到 ISO 目录树，只能从外面传进去；
# 里面**不许**再用 \`ls /lib/modules | head -1\` 猜（那时候常常有两套内核）。
ISO_KVER="${ISO_KVER}"
# 用哪个内核。config.sh 里那行是 \`\${KLBURN_KERNEL:-generic}\`，而 chroot 里
# 没有外面的环境变量 —— 不钉死的话 \`KLBURN_KERNEL=hwe ./build-iso.sh\`
# 在 chroot 里会读成 generic，于是 HWE 那一段静默不执行。
# 和 INCLUDE_NVIDIA 同一个道理。
KLBURN_KERNEL="${KLBURN_KERNEL}"
EOF

# rootfs 覆盖层（去 CRLF 后再拷）
# 排除 __pycache__：本机跑过 py_compile / 测试后会留下，没必要进 ISO
rsync -a --chmod=D755 --exclude='__pycache__' --exclude='*.pyc' \
      "$PROJ_DIR/rootfs/" "$STAGE/overlay/"
while IFS= read -r -d '' f; do
  sed -i 's/\r$//' "$f"
done < <(find "$STAGE/overlay" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.service' -o -name '*.conf' \) -print0)

# vendor 目录（storcli / nvidia 等离线包）
mkdir -p "$STAGE/vendor"
if [[ "$KLBURN_EDITION" == "mem" ]]; then
  if [[ -n "${COMPANY_LOGO_FILE:-}" && -f "$PROJ_DIR/vendor/$COMPANY_LOGO_FILE" ]]; then
    install -m 0644 "$PROJ_DIR/vendor/$COMPANY_LOGO_FILE" "$STAGE/vendor/$COMPANY_LOGO_FILE"
  fi
elif [[ -d "$PROJ_DIR/vendor" ]]; then
  rsync -a --exclude='README.md' "$PROJ_DIR/vendor/" "$STAGE/vendor/"
fi

# ---------------------------------------------------------------- PCI / USB ID 库
# noble 的 pciutils 里那份 pci.ids 停在 2024-03-31。两年前的库认不出新硬件：
# H200 / RTX 50xx / ConnectX-8 / 新阵列卡在 lspci 里会显示成 "Device 2335"。
# 而"这台机器装了什么卡"是报告的核心信息之一 —— 网卡型号、阵列卡型号都是从
# lspci 按总线地址反查的，认不出来整条链就断了。
#
# 在**外面**下载而不是在 chroot 里：外面这层已经 require_cmds curl 了，
# 而 chroot 里有没有 curl/wget 不一定；更要紧的是失败处理 ——
# **下载失败绝不能让构建失败**，现场可能根本没有外网。拿不到就用镜像自带那份，
# 只是认不出最新的卡而已，不影响任何判定。
mkdir -p "$STAGE/ids"
for spec in "pci.ids|https://pci-ids.ucw.cz/v2.2/pci.ids" \
            "usb.ids|http://www.linux-usb.org/usb.ids"; do
  ids_name="${spec%%|*}"; ids_url="${spec#*|}"
  ids_cache="$CACHE_DIR/$ids_name"
  # -z：本地那份比服务器上的新就不重下。--max-time 60：网络不通时不要卡住构建。
  if curl -fsSL --max-time 60 --retry 2 -z "$ids_cache" -o "$ids_cache.new" "$ids_url" \
     && [[ -s "$ids_cache.new" ]]; then
    mv -f "$ids_cache.new" "$ids_cache"
  fi
  rm -f "$ids_cache.new"
  if [[ -s "$ids_cache" ]]; then
    install -m 0644 "$ids_cache" "$STAGE/ids/$ids_name"
    ids_date="$(awk -F'Date:[[:space:]]*' '/^#[[:space:]]*Date:/{print $2; exit}' "$ids_cache")"
    log "$ids_name: ${ids_date:-日期未知}"
  else
    warn "$ids_name 拿不到（无外网？），沿用镜像自带的那份 —— 新硬件的型号可能认不出来"
  fi
done

chroot_mount "$ROOTFS_DIR"
if ! in_chroot "$ROOTFS_DIR" /bin/bash /tmp/klburn-stage/chroot-setup.sh; then
  die "chroot 定制失败，详见上方输出"
fi
chroot_umount "$ROOTFS_DIR"

# ---------------------------------------------------------------- HWE：换引导文件
# chroot 里装了新内核、也重新生成了 casper 的 initramfs，现在把这两个文件
# 换进 ISO 目录树。**必须在 rm -rf "$STAGE" 之前做**（那两个文件就在 STAGE 里）。
#
# 换完立刻重新读一次 casper/vmlinuz 的版本：下面那条"内核唯一性 + 与
# casper/vmlinuz 对版本"的硬断言用的就是 ISO_KVER，不更新的话它会拿旧的 GA
# 版本去比，然后**误报**成"对不上"——而真正对不上的时候它反倒可能放过去。
if [[ "${KLBURN_KERNEL:-generic}" == "hwe" ]]; then
  # 不走交接文件：chroot 收尾时会 `rm -rf /tmp/*`，而 $STAGE 就在那底下。
  # 直接按 rootfs 里**唯一**那个内核版本去 /boot 取（唯一性下面还会再断言一次）。
  HWE_MODROOT="$ROOTFS_DIR/usr/lib/modules"
  [[ -d "$HWE_MODROOT" ]] || HWE_MODROOT="$ROOTFS_DIR/lib/modules"
  mapfile -t HWE_KVERS < <(
    find "$HWE_MODROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
  )
  (( ${#HWE_KVERS[@]} == 1 )) \
    || die "hwe：rootfs 里有 ${#HWE_KVERS[@]} 套内核模块（应该只剩 1 套）: ${HWE_KVERS[*]:-空}"
  HWE_KVER="${HWE_KVERS[0]}"
  [[ -f "$ROOTFS_DIR/boot/vmlinuz-$HWE_KVER" && -f "$ROOTFS_DIR/boot/initrd.img-$HWE_KVER" ]] \
    || die "hwe：rootfs 的 /boot 下没有 $HWE_KVER 的 vmlinuz/initrd —— 看上面 chroot 的输出"
  install -m 0644 "$ROOTFS_DIR/boot/vmlinuz-$HWE_KVER"    "$ISO_DIR/casper/vmlinuz"
  install -m 0644 "$ROOTFS_DIR/boot/initrd.img-$HWE_KVER" "$ISO_DIR/casper/initrd"
  ISO_KVER="$(bzimage_kver "$ISO_DIR/casper/vmlinuz" || true)"
  [[ -n "$ISO_KVER" ]] \
    || die "换完 HWE 内核之后读不出 casper/vmlinuz 的版本 —— 拷过去的可能不是个 bzImage"
  [[ "$ISO_KVER" == "$HWE_KVER" ]] \
    || die "hwe：casper/vmlinuz 读出来是 $ISO_KVER，而模块目录是 $HWE_KVER —— 对不上"
  log "casper/vmlinuz 已换成 HWE 内核: $ISO_KVER"
fi

rm -rf "$STAGE"
log "chroot 定制完成"

# ---------------------------------------------------------------- 内核唯一性自检
# 和上面"合并后必须有 /lib/modules"那条并列，但守的是另一头：
# 那条防"一个内核都没有"，这条防"有两个、而且可能留错了那个"。
#
# 装 NVIDIA 要 dkms，dkms 的 Recommends 会把 linux-headers-generic 这个元包
# 拖进来，元包又跟着 archive 里最新的 ABI 走，于是盘里悄悄多出一整套
# 从来不会被执行的内核（模块 155MB + 头文件 157MB）。
# chroot-setup.sh 已经清过一遍，这里复核 —— **而且要和 casper/vmlinuz 对版本**，
# 因为"清掉多余的"和"清掉该留的"这两件事，只看数量是分不出来的。
#
# 留错的表现：开机认不到任何硬盘，或者 nvidia.ko 加载失败。
# 两样在报告里都长得像硬件故障，一台好机器会被拦在出货前。
# 24.04 是 usrmerge 的（/lib -> usr/lib），两个路径指的是同一个目录。
# 只挑其中**一个**去数，两个都给 find 会把同一套内核数成两套。
MODULES_ROOT="$ROOTFS_DIR/usr/lib/modules"
[[ -d "$MODULES_ROOT" ]] || MODULES_ROOT="$ROOTFS_DIR/lib/modules"
mapfile -t ROOTFS_KVERS < <(
  find "$MODULES_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
)
if (( ${#ROOTFS_KVERS[@]} != 1 )); then
  die "rootfs 里有 ${#ROOTFS_KVERS[@]} 套内核模块（应该只有 1 套）: ${ROOTFS_KVERS[*]:-空}
     多出来的那套一行代码都不会被执行，只是占地方；而万一留错了那个，
     做出来的盘开机会认不到任何硬盘。检查 chroot-setup.sh 的「清理多余内核」。"
fi
if [[ "${ROOTFS_KVERS[0]}" != "$ISO_KVER" ]]; then
  die "rootfs 里的内核模块是 ${ROOTFS_KVERS[0]}，而 casper/vmlinuz 是 $ISO_KVER —— 对不上。
     做出来的盘开机后一个模块都加载不了（认不到硬盘、认不到网卡）。"
fi
log "内核唯一性自检通过: ${ROOTFS_KVERS[0]}（与 casper/vmlinuz 一致）"

# ================================================================ 5. 打包 squashfs
step "5/9 打包 squashfs（$SQUASHFS_COMP -$SQUASHFS_LEVEL，耗时几分钟）"

NEW_SQUASH="$ISO_DIR/casper/$BASE_LAYER"

# 清掉所有旧层和安装器残留
rm -f "$ISO_DIR/casper/"*.squashfs "$ISO_DIR/casper/"*.squashfs.gpg
rm -f "$ISO_DIR/casper/"*.size "$ISO_DIR/casper/"*.manifest \
      "$ISO_DIR/casper/"*.manifest-remove "$ISO_DIR/casper/"*.manifest-minimal-remove
# HWE 内核我们不用，删掉省 ~120MB
rm -f "$ISO_DIR/casper/hwe-vmlinuz" "$ISO_DIR/casper/hwe-initrd"
# 这两个是给 subiquity 校验安装源用的，安装器已经不在了；留着反而是过期数据
rm -f "$ISO_DIR/casper/SHA256SUMS" "$ISO_DIR/casper/SHA256SUMS.gpg" \
      "$ISO_DIR/casper/install-sources.yaml"

# /pool + /dists 是安装器用的离线 apt 仓库（1.6GB，里面还有两套旧版 NVIDIA 驱动 deb）。
# 安装器已经整层丢掉了，casper 启动只读 /casper/，这些纯属占地方。
if [[ -d "$ISO_DIR/pool" ]]; then
  log "删除安装器离线仓库 /pool ($(du -sh "$ISO_DIR/pool" | cut -f1))"
  rm -rf "$ISO_DIR/pool" "$ISO_DIR/dists"
fi

mksquashfs "$ROOTFS_DIR" "$NEW_SQUASH" \
  -comp "$SQUASHFS_COMP" -Xcompression-level "$SQUASHFS_LEVEL" \
  -b 1M -noappend -no-progress -quiet -processors "$BUILD_JOBS" -mem 256M

RAW_SIZE="$(du -sb --apparent-size "$ROOTFS_DIR" | cut -f1)"
printf '%s' "$RAW_SIZE" > "$ISO_DIR/casper/${BASE_NAME}.size"
log "squashfs: $(human "$(stat -c %s "$NEW_SQUASH")")  (原始 $(human "$RAW_SIZE"))"

# 包清单
chroot_mount "$ROOTFS_DIR"
in_chroot "$ROOTFS_DIR" dpkg-query -W --showformat='${Package} ${Version}\n' \
  > "$ISO_DIR/casper/${BASE_NAME}.manifest" 2>/dev/null || true
chroot_umount "$ROOTFS_DIR"

# ================================================================ 6. 改 grub 引导配置
step "6/9 改写引导配置"

# layerfs-path 显式指定，避免 casper 在只剩一层时还去猜
# consoleblank=0 防止 2 小时长测时屏幕黑屏，现场看不到进度
KERNEL_ARGS="layerfs-path=${BASE_LAYER} nouveau.modeset=0 modprobe.blacklist=nouveau consoleblank=0"

# ---- memtest86+：第二个启动项（1.9.2 新增）----
#
# 为什么要它：`stressapptest` 跑在操作系统里，只覆盖得到**系统可见内存减去
# 安全余量**那一部分 —— 真机报告上写的就是"占系统识别内存的 81%~95%"。
# 剩下那 5%~19%（内核自己占的）从来没被测过，而且 memtest 的地址线 /
# 位模式测试是 OS 里那套做不了的。
#
# ⚠️ **它不进无人值守流程**：跑完只在屏幕上显示、不落任何结果文件，
#    所以它一个字都进不了报告。它是"操作员另选的第二种跑法"。
#
# ⚠️ **必须追加在最后，绝不能动第一条。**`set default=0` 指的就是第一条 ——
#    我们那条自启动的测试项。往前插一条的后果是插上盘开机跑的是内存测试，
#    而这张盘的全部意义是"插上就跑"。
MEMTEST_ENTRY=""
mt_found=""
for mt in "$ROOTFS_DIR"/boot/memtest86+*.efi "$ROOTFS_DIR"/boot/memtest86+*.bin; do
  [[ -f "$mt" ]] || continue
  cp -f "$mt" "$ISO_DIR/boot/"
  mt_found="yes"
  log "memtest86+: $(basename "$mt") -> ISO /boot/"
done
if [[ -n "$mt_found" ]]; then
  MEMTEST_ENTRY="$WORK_DIR/memtest-entry.cfg"
  # $grub_platform 是 GRUB 自己的变量：EFI 下链式加载 .efi，传统 BIOS 下直接
  # 引导 .bin。两条路都写上，省得换一台机器就进不去。
  cat > "$MEMTEST_ENTRY" <<'MTEOF'
menuentry "Memory test (memtest86+, KLBURN-MEMTEST)" {
	if [ "$grub_platform" = "efi" ]; then
		chainloader /boot/memtest86+x64.efi
	else
		linux16 /boot/memtest86+x64.bin
	fi
}
MTEOF
fi

for cfg in "$ISO_DIR/boot/grub/grub.cfg" "$ISO_DIR/boot/grub/loopback.cfg"; do
  python3 "$SCRIPT_DIR/lib/patch-grub.py" \
    --cfg "$cfg" \
    --args "$KERNEL_ARGS" \
    --title "${PRODUCT_NAME} Factory Test v${KLBURN_VERSION}" \
    --drop "HWE kernel" \
    --timeout 5 \
    ${MEMTEST_ENTRY:+--append-entry "$MEMTEST_ENTRY" --append-marker KLBURN-MEMTEST}
done

# 安装器的自动应答残留，删掉以免干扰
rm -f "$ISO_DIR/autoinstall.yaml" "$ISO_DIR/user-data" "$ISO_DIR/meta-data" 2>/dev/null || true

# .disk/info 标识我们的构建
mkdir -p "$ISO_DIR/.disk"
printf '%s Factory Test %s (based on Ubuntu Server %s) - %s\n' \
  "$PRODUCT_NAME" "$KLBURN_VERSION" "$UBUNTU_POINT" "$(date '+%Y-%m-%d %H:%M')" > "$ISO_DIR/.disk/info"

# ================================================================ 7. md5sum.txt
step "7/9 重算 md5sum.txt"
( cd "$ISO_DIR"
  rm -f md5sum.txt
  find . -type f ! -name md5sum.txt ! -path './isolinux/*' -print0 \
    | sort -z | xargs -0 md5sum > md5sum.txt
)
log "$(wc -l < "$ISO_DIR/md5sum.txt") 个文件已登记"

# ================================================================ 8. 重打包 ISO
step "8/9 重打包 ISO"

OUT_ISO="$OUT_DIR/$OUT_ISO_NAME"
rm -f "$OUT_ISO"

# 从源 ISO 原样取回引导相关参数（MBR / EFI 分区 / El Torito），
# 这样 BIOS + UEFI 双引导与官方 ISO 完全一致，不用手工拼参数。
SYSAREA="$(xorriso -indev "$SRC_ISO" -report_system_area as_mkisofs 2>/dev/null \
           | grep -v -- '^-o ' | grep -v '^$' | tr '\n' ' ')"

if [[ -z "$SYSAREA" ]]; then
  die "无法从源 ISO 提取引导参数（xorriso -report_system_area 失败）"
fi

# 源 ISO 路径可能是相对的，system area 参数里引用了它，切到其所在目录
SRC_ISO_ABS="$(readlink -f "$SRC_ISO")"
SYSAREA="${SYSAREA//$SRC_ISO/$SRC_ISO_ABS}"

log "引导参数: ${SYSAREA:0:120}..."

eval xorriso -as mkisofs -r \
  $SYSAREA \
  -o "'$OUT_ISO'" "'$ISO_DIR'" 2>&1 | grep -Ev '^xorriso : UPDATE' || true

[[ -f "$OUT_ISO" ]] || die "ISO 生成失败"

ISO_SIZE="$(stat -c %s "$OUT_ISO")"
log "ISO: $OUT_ISO  ($(human "$ISO_SIZE"))"
if (( ISO_SIZE > 8*1024*1024*1024 )); then
  warn "ISO 超过 8GB，超出预期体积目标"
fi

# ================================================================ 9. 拷回 Windows 侧
step "9/9 拷贝到项目 out/ 目录"
mkdir -p "$PROJ_DIR/out"
cp -f "$OUT_ISO" "$PROJ_DIR/out/$OUT_ISO_NAME"
sha256sum "$OUT_ISO" | awk '{print $1}' > "$PROJ_DIR/out/$OUT_ISO_NAME.sha256"

# rootfs 一直保留着，下次构建直接复用（增量构建 5~8 分钟就靠它）。
# 要腾空间用 --clean。以前这里有个 --keep-rootfs 开关，但两个分支做的事一样，
# 是个纯粹的空操作，已经删掉。

trap - EXIT
printf '\n%s========================================%s\n' "$C_GRN$C_BLD" "$C_RST"
printf '%s 构建完成%s\n' "$C_GRN$C_BLD" "$C_RST"
printf '  ISO      : out/%s\n' "$OUT_ISO_NAME"
printf '  体积     : %s\n' "$(human "$ISO_SIZE")"
printf '  抬头     : %s\n' "$COMPANY_NAME"
# 版本必须打在这儿。两张盘的文件名只差三个字母，而跑起来完全不是一回事，
# 构建完看一眼就能确认自己出的是哪一张。
if [[ "$KLBURN_EDITION" == "mem" ]]; then
  printf '  盘型     : 内存专用盘（开机直接测内存，压测 %s 秒）\n' "$MEM_BURN_SECONDS"
else
  printf '  盘型     : 整机出厂老化盘（开机选范围 + 选时长）\n'
fi
printf '  显卡驱动 : %s\n' \
  "$( ((INCLUDE_NVIDIA)) && echo "已包含 NVIDIA ${NVIDIA_VERSION}" || echo '未包含')"
printf '  sha256   : %s\n' "$(cat "$PROJ_DIR/out/$OUT_ISO_NAME.sha256")"
printf '\n  下一步：用 Rufus 写盘，见 docs/usb-rufus.md\n'
printf '%s========================================%s\n\n' "$C_GRN$C_BLD" "$C_RST"
