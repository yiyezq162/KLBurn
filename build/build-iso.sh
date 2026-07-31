#!/usr/bin/env bash
#
# KLBurn ISO 一键构建
#
#   sudo ./build/build-iso.sh                # 第一阶段：精简版（无 NVIDIA）
#   sudo ./build/build-iso.sh --with-nvidia  # 第二阶段：带 NVIDIA 驱动 + gpu_burn
#   sudo ./build/build-iso.sh --clean        # 清空工作区从头来
#   sudo ./build/build-iso.sh --rebuild-fs   # 强制重新解 squashfs（换源 ISO 后用）
#
# 必须在 WSL 里执行，工作区在 WSL 原生文件系统（默认 ~/klburn-build）。
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------- 参数
OPT_CLEAN=0
OPT_REBUILD_FS=0
OPT_SKIP_DOWNLOAD=0
SRC_ISO_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)        OPT_CLEAN=1 ;;
    --rebuild-fs)   OPT_REBUILD_FS=1 ;;
    --skip-download) OPT_SKIP_DOWNLOAD=1 ;;
    --with-nvidia)  export INCLUDE_NVIDIA=1 ;;
    --iso)          SRC_ISO_OVERRIDE="$2"; shift ;;
    -h|--help)      sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
  shift
done

# ---------------------------------------------------------------- 载入配置
# 源码可能在 /mnt/c 上被 Windows 编辑器加了 CRLF，先就地清一遍
for f in "$SCRIPT_DIR/config.sh" "$SCRIPT_DIR/lib/common.sh" "$SCRIPT_DIR/chroot-setup.sh"; do
  [[ -f "$f" ]] && sed -i 's/\r$//' "$f" 2>/dev/null || true
done

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

require_root "$@"
require_cmds xorriso mksquashfs unsquashfs rsync curl chroot md5sum numfmt find sed awk

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
      rm -rf -- "$dst/$rel"      # 兑现删除（可能是目录）
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
      unsquashfs -d "$ROOTFS_DIR" -f "$ISO_DIR/casper/$l" >/dev/null
      apply_whiteouts "$ROOTFS_DIR" "$ROOTFS_DIR"
      first=0
    else
      # 后续层不能用 unsquashfs -f 直接往上叠：层里带硬链接时，
      # 目标文件已存在会直接 FATAL（failed to create hardlink, File exists）。
      # 所以先解到独立目录，处理完删除标记，再用 rsync 覆盖合并。
      log "  解包 $l ..."
      rm -rf "$LAYER_TMP"
      unsquashfs -d "$LAYER_TMP" "$ISO_DIR/casper/$l" >/dev/null
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
  KMOD_DIR="$(find "$ROOTFS_DIR/usr/lib/modules" "$ROOTFS_DIR/lib/modules" \
              -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)"
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
if [[ -d "$PROJ_DIR/vendor" ]]; then
  rsync -a --exclude='README.md' "$PROJ_DIR/vendor/" "$STAGE/vendor/"
fi

chroot_mount "$ROOTFS_DIR"
if ! in_chroot "$ROOTFS_DIR" /bin/bash /tmp/klburn-stage/chroot-setup.sh; then
  die "chroot 定制失败，详见上方输出"
fi
chroot_umount "$ROOTFS_DIR"

rm -rf "$STAGE"
log "chroot 定制完成"

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
  -b 1M -noappend -no-progress -quiet

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

for cfg in "$ISO_DIR/boot/grub/grub.cfg" "$ISO_DIR/boot/grub/loopback.cfg"; do
  python3 "$SCRIPT_DIR/lib/patch-grub.py" \
    --cfg "$cfg" \
    --args "$KERNEL_ARGS" \
    --title "KLBurn 出厂测试 v${KLBURN_VERSION}" \
    --drop "HWE kernel" \
    --timeout 5
done

# 安装器的自动应答残留，删掉以免干扰
rm -f "$ISO_DIR/autoinstall.yaml" "$ISO_DIR/user-data" "$ISO_DIR/meta-data" 2>/dev/null || true

# .disk/info 标识我们的构建
mkdir -p "$ISO_DIR/.disk"
printf 'KLBurn Factory Test %s (based on Ubuntu Server %s) - %s\n' \
  "$KLBURN_VERSION" "$UBUNTU_POINT" "$(date '+%Y-%m-%d %H:%M')" > "$ISO_DIR/.disk/info"

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
printf '  NVIDIA   : %s\n' "$( ((INCLUDE_NVIDIA)) && echo '已包含' || echo '未包含（第一阶段）')"
printf '  sha256   : %s\n' "$(cat "$PROJ_DIR/out/$OUT_ISO_NAME.sha256")"
printf '\n  下一步：用 Rufus 写盘，见 docs/usb-rufus.md\n'
printf '%s========================================%s\n\n' "$C_GRN$C_BLD" "$C_RST"
