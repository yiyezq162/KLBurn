#!/usr/bin/env bash
# KLBurn 构建公共函数：日志、错误处理、chroot 挂载管理
# 被 build-iso.sh source

# ---------- 颜色日志 ----------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[36m'; C_BLD=$'\033[1m';  C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi

_ts() { date '+%H:%M:%S'; }
log()   { printf '%s[%s]%s %s\n'        "$C_BLU" "$(_ts)" "$C_RST" "$*"; }
step()  { printf '\n%s[%s] ==> %s%s\n'  "$C_BLD$C_GRN" "$(_ts)" "$*" "$C_RST"; }
warn()  { printf '%s[%s] WARN%s %s\n'   "$C_YEL" "$(_ts)" "$C_RST" "$*" >&2; }
err()   { printf '%s[%s] ERROR%s %s\n'  "$C_RED" "$(_ts)" "$C_RST" "$*" >&2; }
die()   { err "$*"; exit 1; }

# ---------- 挂载点登记（保证异常时按逆序卸载）----------
# 用文件而不是数组，因为 trap 里读数组在某些 subshell 场景不可靠
MOUNT_LEDGER=""

ledger_init() {
  MOUNT_LEDGER="$1"
  : > "$MOUNT_LEDGER"
}

# mount_bind <src> <dst-inside-rootfs>
mnt_add() {
  local target="$1"
  # 后进先出：新的写到文件开头
  local tmp
  tmp="$(mktemp)"
  { printf '%s\n' "$target"; cat "$MOUNT_LEDGER"; } > "$tmp"
  mv "$tmp" "$MOUNT_LEDGER"
}

unmount_all() {
  [[ -n "$MOUNT_LEDGER" && -f "$MOUNT_LEDGER" ]] || return 0
  local m
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    if mountpoint -q "$m" 2>/dev/null; then
      umount -l "$m" 2>/dev/null || umount -lf "$m" 2>/dev/null || warn "无法卸载 $m"
    fi
  done < "$MOUNT_LEDGER"
  : > "$MOUNT_LEDGER"
}

# ---------- chroot 环境 ----------
# chroot_mount <rootfs>
chroot_mount() {
  local root="$1"
  [[ -d "$root" ]] || die "chroot_mount: $root 不存在"

  mkdir -p "$root/proc" "$root/sys" "$root/dev" "$root/dev/pts" "$root/run"

  mount -t proc  none      "$root/proc"    && mnt_add "$root/proc"
  mount -t sysfs none      "$root/sys"     && mnt_add "$root/sys"
  mount --bind   /dev      "$root/dev"     && mnt_add "$root/dev"
  mount --bind   /dev/pts  "$root/dev/pts" && mnt_add "$root/dev/pts"
  mount -t tmpfs none      "$root/run"     && mnt_add "$root/run"

  # 构建期需要 DNS
  if [[ -e "$root/etc/resolv.conf" || -L "$root/etc/resolv.conf" ]]; then
    mv -f "$root/etc/resolv.conf" "$root/etc/resolv.conf.klburn-bak" 2>/dev/null || true
  fi
  cat > "$root/etc/resolv.conf" <<'EOF'
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 8.8.8.8
EOF

  # 阻止 chroot 内的服务被真的启动
  cat > "$root/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
  chmod +x "$root/usr/sbin/policy-rc.d"
}

# chroot_umount <rootfs>
chroot_umount() {
  local root="$1"
  unmount_all
  rm -f "$root/usr/sbin/policy-rc.d"
  rm -f "$root/etc/resolv.conf"
  if [[ -e "$root/etc/resolv.conf.klburn-bak" || -L "$root/etc/resolv.conf.klburn-bak" ]]; then
    mv -f "$root/etc/resolv.conf.klburn-bak" "$root/etc/resolv.conf"
  fi
}

# in_chroot <rootfs> <cmd...>
in_chroot() {
  local root="$1"; shift
  LC_ALL=C LANGUAGE=C LANG=C DEBIAN_FRONTEND=noninteractive \
    chroot "$root" "$@"
}

# ---------- 工具 ----------
require_root() {
  [[ "$(id -u)" == "0" ]] || die "需要 root 权限，请用: sudo $0 $*"
}

require_cmds() {
  local missing=()
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]})); then
    err "缺少命令: ${missing[*]}"
    die "请先执行: sudo apt-get install -y xorriso squashfs-tools rsync curl gdisk fdisk zstd"
  fi
}

# 去掉 Windows 换行（源码在 /mnt/c 上编辑时可能带 CRLF）
strip_crlf() {
  local f
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    if grep -qU $'\r' "$f" 2>/dev/null; then
      sed -i 's/\r$//' "$f"
    fi
  done
}

human() {
  local b="$1"
  numfmt --to=iec --suffix=B "$b" 2>/dev/null || echo "${b}B"
}
