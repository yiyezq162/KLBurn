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
REPO="https://github.com/opendcdiag/opendcdiag.git"
# ⚠️ **钉一个 commit，别跟着 main 走**：main 上的测试集会变，而报告里那句
# "全核运行 N 秒的计算正确性诊断"要能对得上盘里那一版。
#
# 为什么钉的是 commit 而不是 tag：**这个仓库一个 tag 都没有**
# （`git ls-remote --tags` 返回空，2026-08 核对过）。原先这里写的是
# `--branch v2024.10.0`，clone 那一步必然失败，报错还是笼统的"没网？tag 不存在？"。
# 上游只有分支，所以只能钉 SHA。
#
# 换版本时：`git ls-remote --heads $REPO refs/heads/main` 取新 SHA 换到这里，
# 然后**重新跑一遍**（编出来的东西变了，报告里那句话对应的版本也就变了）。
OPENDCDIAG_REF="${OPENDCDIAG_REF:-65b0814a06faea44ce48fd1064d8f41bbe23ea83}"   # main @ 2026-08-10

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m错误：\033[0m %s\n' "$*" >&2; exit 1; }

for t in git meson ninja g++; do
  command -v "$t" >/dev/null 2>&1 || die "缺 $t。装一下：sudo apt install git meson ninja-build g++"
done

# 按 SHA 取单个 commit（GitHub 允许 fetch 任意 SHA）。
# 不用 `clone --depth 1` —— 它只能按分支/tag 名取，取不到具体 commit，
# 而"取到的到底是不是钉的那一版"正是这里唯一要保证的事。
if [[ "$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null)" != "$OPENDCDIAG_REF" ]]; then
  log "取 opendcdiag @ ${OPENDCDIAG_REF:0:12}"
  rm -rf "$SRC_DIR"
  mkdir -p "$SRC_DIR"
  ( cd "$SRC_DIR" \
    && git init -q \
    && git remote add origin "$REPO" \
    && git fetch -q --depth 1 origin "$OPENDCDIAG_REF" \
    && git checkout -q FETCH_HEAD ) \
    || die "取源码失败（没网？这个 commit 已经不在上游了？）"
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

# ---- 剥符号 ----
# ⚠️ 别省这一步：meson 的 release 构建**照样带调试符号**，产物 232MB。
# 那 229MB 会一路进 squashfs 再进 ISO，而里面没有一个字节是现场用得上的
# （盘里没有调试器，也没有对应的源码）。剥完 3.0MB。
STRIPPED="$SRC_DIR/builddir/opendcdiag.stripped"
cp -f "$BIN" "$STRIPPED"
strip -s "$STRIPPED" 2>/dev/null || die "strip 失败（装一下 binutils）"
BIN="$STRIPPED"

# ---- 动态依赖自检 ----
# 只允许这几个基础库；多一个就说明它在 live 系统里跑不起来。
ALLOW='libc\.so|libm\.so|libstdc\+\+\.so|libgcc_s\.so|libpthread\.so|libdl\.so|librt\.so|ld-linux|linux-vdso'
# 除基础库之外**跟着一起装进 vendor 子目录**的那几个。
#
# opendcdiag 链了 libzstd 和 libz（日志压缩）。这两个在 Ubuntu 基础系统里
# 一定有，但"一定有"是个推断，而推断错的表现是现场这一项莫名其妙 SKIP、
# 没有任何人查得出为什么。所以照 xlinpack_xeon64 带 libiomp5.so 那个先例，
# 把它们和二进制放在同一个目录里 —— lib/bench.sh 的 bench_run() 会把程序
# 自己那个目录加进 LD_LIBRARY_PATH，盘里有没有都不影响它跑得起来。
COSHIP='libzstd\.so|libz\.so'
extra="$(ldd "$BIN" 2>/dev/null | awk '{print $1}' | grep -vE "$ALLOW|$COSHIP" || true)"
if [[ -n "$extra" ]]; then
  die "产物有额外的动态依赖，盘里没有这些库，装上去也跑不起来：
$extra
（要么想办法静态链接，要么把这些 .so 一并放进 vendor/bench/opendcdiag/，
  并把名字加进本脚本的 COSHIP）"
fi

mkdir -p "$OUT_DIR"
cp -f "$BIN" "$OUT_DIR/opendcdiag"
chmod 0755 "$OUT_DIR/opendcdiag"

# 跟着走的那几个 .so，按 ldd 解析出来的真实路径拷（别去猜 /lib/x86_64-linux-gnu）
while read -r soname _ sopath _; do
  [[ "$soname" =~ ^(libzstd|libz)\. ]] || continue
  [[ -f "$sopath" ]] || continue
  cp -fL "$sopath" "$OUT_DIR/$soname"
  chmod 0644 "$OUT_DIR/$soname"
  log "同目录附带运行库：$soname"
done < <(ldd "$BIN" 2>/dev/null)

cat > "$OUT_DIR/SOURCE.txt" <<EOF
OpenDCDiag @ $OPENDCDIAG_REF
$REPO
License: Apache-2.0（见上游 LICENSE）—— 可自由分发，所以能随盘带
版本自述: $(cd "$OUT_DIR" && LD_LIBRARY_PATH=. ./opendcdiag --version 2>/dev/null || echo '(取不到)')
编译: $(g++ --version | head -1)，meson --buildtype=release，strip -s
同目录附带: $(cd "$OUT_DIR" && ls *.so* 2>/dev/null | tr '\n' ' ')
由 build/build-opendcdiag.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')
EOF

log "完成：$OUT_DIR/opendcdiag"
log "它会在 PHASE 2/5（机器空闲时）跑 ${VALIDATE_SDC_SECS:-120} 秒；"
log "改时长：在 klburn.conf 里写 VALIDATE_SDC_SECS=<秒>"
printf '\n\033[1;33m⚠ 提醒：\033[0m「带了工具」那条路一次真机都没跑过。\n'
printf '  第一次上真机时照 docs/first-run-checklist.md 里那两条逐项确认。\n'
