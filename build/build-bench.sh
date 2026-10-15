#!/usr/bin/env bash
#
# 编译 NVIDIA cuda-samples 里的两个基准程序，产物放进 vendor/bench/cuda-samples/
# 供构建 ISO 时打包。
#
#   ./build/build-bench.sh
#
# 不需要 root，也不需要机器上真有 N 卡（只编译，不运行）。
# 需要先装好 CUDA（和 build-gpu-burn.sh 同一套），步骤见 vendor/README.md。
#
# ================================================================
# 为什么要有这个脚本，而不是让人自己去 cmake
# ================================================================
# 客户验收单点名要 bandwidthTest 和 p2pBandwidthLatencyTest 的数字。这两个
# 是 NVIDIA 官方 cuda-samples 里的（BSD-3，可以自由编译分发），但**必须静态
# 链接 CUDA 运行时** —— 这张盘的 rootfs 里没有 libcudart.so，动态链接的二进制
# 一跑就是 "error while loading shared libraries"，而那行报错落在日志里，
# 看上去像"这台机器有问题"。gpu_burn 栽过一模一样的坑（见 build-gpu-burn.sh）。
#
# 上游的 cmake 构建默认动态链接，而且新版本还要 cmake（本机没有）。所以这里
# 直接用 nvcc 编那两个 .cu，参数写死，编完当场用 ldd 验一遍。
#
# ================================================================
# 为什么钉在 v12.8 这个 tag
# ================================================================
# **上游从 13.0 起把 bandwidthTest 整个删掉了**（换成了 nvbandwidth，
# 输出格式完全不同）。而验收单上写的就是 bandwidthTest，报告里的解析函数
# （lib/bench.sh 的 bw_parse_bandwidthtest）也是按它的表头写的。
# 所以这里钉 v12.8：它是最后一批带 bandwidthTest 的，而且正好和本机
# CUDA 12.8 对得上。
#
# 换 tag 之前先确认两件事：那一版还有没有 bandwidthTest、它的
# "Bandwidth(GB/s)" 表头有没有变 —— 变了的话 bw_parse_bandwidthtest 要跟着改，
# tests/test-log-parsing.sh 里有它的样本。
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SAMPLES_TAG="${SAMPLES_TAG:-v12.8}"
SRC_DIR="${KLBURN_WORK:-$HOME/klburn-build}/cuda-samples-src"
OUT_DIR="$PROJ_DIR/vendor/bench/cuda-samples"
REPO="https://github.com/NVIDIA/cuda-samples.git"

# 和 gpu_burn 那边同一张架构表，理由见 build-gpu-burn.sh 顶部：
# **少一代就是那一代的卡跑不出数**。这两个样例的核很小，多带几代不占体积。
GPU_ARCHS="${GPU_ARCHS:-60 61 70 75 80 86 89 90 100 120}"

info() { printf '\033[36m[bench]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[bench] 警告\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[bench] ERROR\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 找 CUDA
CUDAPATH="${CUDAPATH:-}"
if [[ -z "$CUDAPATH" ]]; then
  for c in /usr/local/cuda /usr/local/cuda-13* /usr/local/cuda-12*; do
    [[ -x "$c/bin/nvcc" ]] && CUDAPATH="$c" && break
  done
fi
[[ -n "$CUDAPATH" && -x "$CUDAPATH/bin/nvcc" ]] \
  || die "找不到 nvcc。请先装 CUDA（见 vendor/README.md），或手动指定:
     CUDAPATH=/usr/local/cuda-12.8 $0"
info "CUDA: $CUDAPATH ($("$CUDAPATH/bin/nvcc" --version | sed -n 's/.*release \([0-9.]*\).*/\1/p' | tail -1))"

# ---------------------------------------------------------------- 取源码
if [[ -d "$SRC_DIR/.git" ]]; then
  info "复用已有源码: $SRC_DIR"
else
  info "克隆 cuda-samples ..."
  mkdir -p "$(dirname "$SRC_DIR")"
  git clone --filter=blob:none --no-checkout "$REPO" "$SRC_DIR"
fi
cd "$SRC_DIR"
git fetch --depth 1 origin "refs/tags/$SAMPLES_TAG:refs/tags/$SAMPLES_TAG" 2>/dev/null || true
git checkout -q "$SAMPLES_TAG" || die "切不到 tag $SAMPLES_TAG"
info "源码版本: $SAMPLES_TAG ($(git log -1 --format=%h))"

BW_SRC="Samples/1_Utilities/bandwidthTest/bandwidthTest.cu"
P2P_SRC="Samples/5_Domain_Specific/p2pBandwidthLatencyTest/p2pBandwidthLatencyTest.cu"
[[ -f "$BW_SRC"  ]] || die "$SAMPLES_TAG 里没有 bandwidthTest（13.0 起被上游删了，见本文件顶部说明）"
[[ -f "$P2P_SRC" ]] || die "$SAMPLES_TAG 里没有 p2pBandwidthLatencyTest"

# ---------------------------------------------------------------- 编译
GENCODE=()
for a in $GPU_ARCHS; do GENCODE+=(-gencode "arch=compute_${a},code=sm_${a}"); done
# 最老的那一代再留一份 PTX，好让更新的卡也能 JIT（和 gpu_burn 的 COMPUTE 同理）
oldest="$(printf '%s\n' $GPU_ARCHS | sort -n | head -1)"
GENCODE+=(-gencode "arch=compute_${oldest},code=compute_${oldest}")

mkdir -p "$OUT_DIR"
build_one() {   # build_one <源文件> <产物名>
  local src="$1" out="$2"
  info "编译 $out ..."
  # -cudart static 是这里的**要害**：盘里没有 libcudart.so
  "$CUDAPATH/bin/nvcc" -O2 -std=c++14 \
      -I "$SRC_DIR/Common" -I "$CUDAPATH/include" \
      "${GENCODE[@]}" -cudart static \
      -o "$OUT_DIR/$out" "$src"

  # 自检：除了驱动自带的 libcuda，不该再依赖任何 CUDA 库。
  # **不能只在构建机上"看着能跑"就算数** —— 构建机上装了完整 CUDA，
  # 动态链接照样跑得起来，而盘里没有，出盘一跑才炸。
  if ldd "$OUT_DIR/$out" 2>/dev/null | grep -qE 'libcudart|libcublas'; then
    die "$out 动态依赖了 CUDA 运行时，盘内没有这些库，出盘必然跑不起来"
  fi
  info "  -> $OUT_DIR/$out ($(du -h "$OUT_DIR/$out" | cut -f1))"
}

build_one "$BW_SRC"  bandwidthTest
build_one "$P2P_SRC" p2pBandwidthLatencyTest

# ---------------------------------------------------------------- 收尾
python3 "$SCRIPT_DIR/vendor-notices.py" "$SRC_DIR" "$OUT_DIR" \
  --required LICENSE --optional NOTICE
cat > "$OUT_DIR/SOURCE.txt" <<EOF
NVIDIA cuda-samples $SAMPLES_TAG ($(git log -1 --format=%H))
$REPO
License: BSD-3-Clause（见上游 LICENSE）
编译: $("$CUDAPATH/bin/nvcc" --version | tail -2 | head -1)，-cudart static
架构: $GPU_ARCHS (+ compute_${oldest} PTX)
由 build/build-bench.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')
EOF

info "完成。产物："
ls -la "$OUT_DIR"
echo
info "剩下两个（Intel LINPACK / MLC）不能自动下载，见 vendor/README.md 第 5 节"
