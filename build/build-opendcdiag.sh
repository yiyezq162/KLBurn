#!/usr/bin/env bash
#
# 编 OpenDCDiag（Intel 开源的处理器诊断框架，Apache-2.0），
# 产物放进 vendor/bench/opendcdiag/ 供构建 ISO 时打包。
#
#   ./build/build-opendcdiag.sh
#
# 不需要 root。需要 meson / ninja / g++（脚本会先查一遍）。
#
# ================================================================
# 它抓的是什么，为什么 stress-ng 抓不到
# ================================================================
# `stress-ng` 回答的是"跑挂了没有"：进程崩了、内核报错了、温度超了。
# 它抓不到**算完了但算错了** —— 程序正常返回、退出码 0、日志干干净净，
# 只是结果是错的。这类缺陷业界叫**静默数据损坏（SDC）**，也叫"会算错的核"。
#
# Google 和 Meta 各自发过论文之后（"Cores that don't count" /
# "Silent Data Corruptions at Scale"），它已经出现在做 AI / HPC 那批客户的
# 验收单上。OpenDCDiag 就是 Intel 为这件事开源的诊断框架。
#
# ================================================================
# 为什么走 vendor/ 而不是直接装包
# ================================================================
# 它不在 Ubuntu 源里，得自己编。和几个基准程序同一条路子：
# **放进 vendor/bench/ 就带上，不放就干净地 SKIP**，绝不判 FAIL ——
# 没带工具是我们这张盘的能力缺口，跟被测机器好不好毫无关系。
#
# ⚠️ **产物必须能在 live 系统里裸跑。**这张盘的 rootfs 里没有编译期那套库，
#    所以编完当场用 ldd 查一遍：除了 libc / libm / libstdc++ / libgcc_s /
#    libpthread 这几个基础库之外还有别的动态依赖，就直接让脚本失败 ——
#    带一个跑不起来的二进制上盘，现场表现是"这一项莫名其妙 SKIP"，
#    比不带还难查。gpu_burn 和 cuda-samples 都栽过这个坑。
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$PROJ_DIR/vendor/bench/opendcdiag"
SRC_DIR="${OPENDCDIAG_SRC:-/tmp/opendcdiag-src}"
# 钉一个 tag，别跟着 main 走：main 上的测试集会变，而报告里那句
# "全核运行 N 秒的计算正确性诊断"要能对得上盘里那一版。
TAG="${OPENDCDIAG_TAG:-v2024.10.0}"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m错误：\033[0m %s\n' "$*" >&2; exit 1; }

for t in git meson ninja g++; do
  command -v "$t" >/dev/null 2>&1 || die "缺 $t。装一下：sudo apt install git meson ninja-build g++"
done

if [[ ! -d "$SRC_DIR/.git" ]]; then
  log "克隆 opendcdiag（$TAG）"
  git clone --depth 1 --branch "$TAG" https://github.com/opendcdiag/opendcdiag.git "$SRC_DIR" \
    || die "克隆失败（没网？tag 不存在？）"
else
  log "复用已有源码：$SRC_DIR"
fi

log "编译（release）"
rm -rf "$SRC_DIR/builddir"
( cd "$SRC_DIR" && meson setup builddir --buildtype=release >/dev/null \
    && ninja -C builddir >/dev/null ) || die "编译失败"

BIN="$SRC_DIR/builddir/opendcdiag"
[[ -x "$BIN" ]] || BIN="$SRC_DIR/builddir/sandstone"
[[ -x "$BIN" ]] || die "编完了却找不到可执行文件（上游改了产物名？去 builddir 下看看）"

# ---- 动态依赖自检 ----
# 只允许这几个基础库；多一个就说明它在 live 系统里跑不起来。
ALLOW='libc\.so|libm\.so|libstdc\+\+\.so|libgcc_s\.so|libpthread\.so|libdl\.so|librt\.so|ld-linux|linux-vdso'
extra="$(ldd "$BIN" 2>/dev/null | awk '{print $1}' | grep -vE "$ALLOW" || true)"
if [[ -n "$extra" ]]; then
  die "产物有额外的动态依赖，盘里没有这些库，装上去也跑不起来：
$extra
（要么想办法静态链接，要么把这些 .so 一并放进 vendor/bench/opendcdiag/）"
fi

mkdir -p "$OUT_DIR"
cp -f "$BIN" "$OUT_DIR/opendcdiag"
chmod 0755 "$OUT_DIR/opendcdiag"

log "完成：$OUT_DIR/opendcdiag"
log "它会在 PHASE 2/5（机器空闲时）跑 ${VALIDATE_SDC_SECS:-120} 秒；"
log "改时长：在 klburn.conf 里写 VALIDATE_SDC_SECS=<秒>"
printf '\n\033[1;33m⚠ 提醒：\033[0m「带了工具」那条路一次真机都没跑过。\n'
printf '  第一次上真机时照 docs/first-run-checklist.md 里那两条逐项确认。\n'
