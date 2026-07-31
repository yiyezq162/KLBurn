#!/usr/bin/env bash
#
# 在 WSL 里编译 gpu_burn，产物放进 vendor/gpu_burn/ 供第二阶段 ISO 打包。
#
#   ./build/build-gpu-burn.sh
#
# 不需要 root，也不需要机器上真有 N 卡（只是编译，不运行）。
# 需要先装好 CUDA Toolkit，见 README「第二阶段」一节。
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC_DIR="${KLBURN_WORK:-$HOME/klburn-build}/gpu-burn-src"
OUT_DIR="$PROJ_DIR/vendor/gpu_burn"
GPU_BURN_REPO="https://github.com/wilicc/gpu-burn.git"

# PTX 目标架构。
#   89  = Ada    (RTX 4090)
#   120 = Blackwell (RTX 5090 / RTX Pro 6000)
# gpu_burn 走的是 PTX + 驱动 JIT 的路子（不是预编译 cubin），
# 而 PTX 是向上兼容的：用 compute_89 编出来的 PTX，在 sm_120 的卡上
# 由驱动 JIT 成原生代码，一个文件通吃两代卡。
# 想改成别的基线架构就改这个值。
COMPUTE="${COMPUTE:-89}"

info() { printf '\033[36m[gpu-burn]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[gpu-burn] ERROR\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 找 CUDA
CUDAPATH="${CUDAPATH:-}"
if [[ -z "$CUDAPATH" ]]; then
  for c in /usr/local/cuda /usr/local/cuda-13* /usr/local/cuda-12*; do
    [[ -x "$c/bin/nvcc" ]] && CUDAPATH="$c" && break
  done
fi
[[ -n "$CUDAPATH" && -x "$CUDAPATH/bin/nvcc" ]] \
  || die "找不到 nvcc。请先装 CUDA Toolkit（见 README 第二阶段），
     或手动指定: CUDAPATH=/usr/local/cuda-12.8 $0"

NVCC_VER="$("$CUDAPATH/bin/nvcc" --version | sed -n 's/.*release \([0-9.]*\).*/\1/p')"
info "CUDA: $CUDAPATH (nvcc $NVCC_VER)"

# sm_120 需要 CUDA >= 12.8，低于这个版本编不出 Blackwell 能用的东西
major="${NVCC_VER%%.*}"; minor="$(printf '%s' "$NVCC_VER" | cut -d. -f2)"
if (( major < 12 || (major == 12 && minor < 8) )); then
  printf '\033[33m[gpu-burn] 警告\033[0m CUDA %s 低于 12.8，RTX 5090 / Blackwell 可能不被支持。\n' "$NVCC_VER"
  printf '            4090 不受影响。要测 5090 请升级到 CUDA 12.8 或更新版本。\n'
fi

command -v g++ >/dev/null || die "缺少 g++，执行: sudo apt-get install -y build-essential"

# ---------------------------------------------------------------- 取源码
mkdir -p "$(dirname "$SRC_DIR")"
if [[ -d "$SRC_DIR/.git" ]]; then
  info "复用已有源码 $SRC_DIR"
  git -C "$SRC_DIR" pull --ff-only >/dev/null 2>&1 || info "（拉取更新失败，用本地版本继续）"
else
  info "克隆 gpu-burn ..."
  rm -rf "$SRC_DIR"
  git clone --depth 1 "$GPU_BURN_REPO" "$SRC_DIR" \
    || die "克隆失败。可手动下载 https://github.com/wilicc/gpu-burn 解压到 $SRC_DIR 后重跑本脚本"
fi

# ---------------------------------------------------------------- 编译
info "编译（COMPUTE=$COMPUTE）..."
make -C "$SRC_DIR" clean >/dev/null 2>&1 || true
make -C "$SRC_DIR" COMPUTE="$COMPUTE" CUDAPATH="$CUDAPATH" \
  || die "编译失败，检查上面的 nvcc/g++ 报错"

[[ -x "$SRC_DIR/gpu_burn" ]]     || die "编译完成但没找到 $SRC_DIR/gpu_burn"
[[ -f "$SRC_DIR/compare.ptx" ]]  || die "编译完成但没找到 $SRC_DIR/compare.ptx"

# ---------------------------------------------------------------- 安装到 vendor
mkdir -p "$OUT_DIR"
install -m 0755 "$SRC_DIR/gpu_burn"    "$OUT_DIR/gpu_burn"
install -m 0644 "$SRC_DIR/compare.ptx" "$OUT_DIR/compare.ptx"

info "完成："
ls -la "$OUT_DIR"
printf '\n'
info "PTX 目标架构: compute_${COMPUTE}（sm_${COMPUTE} 原生，更新的架构由驱动 JIT）"
info "下一步: sudo ./build/build-iso.sh --with-nvidia"
